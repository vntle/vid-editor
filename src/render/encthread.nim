## An encoder on its own thread, so encoding overlaps the work that makes its
## frames. FFmpeg's AAC encoder is single-threaded and, on the render's thread,
## took as long as decoding, compositing and feeding x264 together.
##
## The thread touches nothing but FFmpeg's own objects: the codec context,
## which the caller must leave alone until `close`, and the frames and packets
## passed through the queues.

import std/strformat

import ../[ffmpeg, log]

type
  EncoderJob = object
    ctx: ptr AVCodecContext
    # `pointer`, not `ptr AVFrame`: a channel builds type info for what it
    # carries, which C's opaque AVDictionary inside AVFrame can't give.
    frames: Channel[pointer]       # ptr AVFrame; nil = end of stream
    packets: Channel[ptr AVPacket] # nil = finished, or failed when err < 0
    err: cint                      # written before the nil packet is sent

  EncoderThread* = ref object
    job: EncoderJob
    thread: Thread[ptr EncoderJob]
    eofSent: bool # the nil frame is queued
    done: bool    # the nil packet has been received
    closed: bool

proc encodeLoop(job: ptr EncoderJob) {.thread.} =
  var failed = false
  template fail(ret: cint) =
    job.err = ret
    failed = true
    job.packets.send(nil)

  while true:
    var frame = cast[ptr AVFrame](job.frames.recv())
    let flushing = frame == nil
    # After a failure, keep taking frames so the producer never blocks on a
    # full queue, and drop them.
    if not failed:
      let sent = avcodec_send_frame(job.ctx, frame)
      if sent < 0:
        fail(sent)
      else:
        while true:
          var pkt = av_packet_alloc()
          if pkt == nil:
            fail(AVERROR(ENOMEM))
            break
          let ret = avcodec_receive_packet(job.ctx, pkt)
          if ret < 0:
            av_packet_free(addr pkt)
            # Like `encode`, a failure while draining at the end isn't one.
            if ret != AVERROR_EAGAIN and ret != AVERROR_EOF and not flushing:
              fail(ret)
            break
          job.packets.send(pkt) # the consumer frees it
    if frame != nil:
      av_frame_free(addr frame)
    if flushing:
      break
  if not failed:
    job.packets.send(nil)

proc newEncoderThread*(ctx: ptr AVCodecContext, queue = 512): EncoderThread =
  ## Start encoding with the opened `ctx`. At most `queue` frames wait to be
  ## encoded; past that, `submit` waits. The default, about 11 seconds of
  ## 48 kHz AAC (4 MB in stereo), rides out the stretches where video is cheap
  ## and audio is wanted faster than it encodes: with 32, a render spent a
  ## third of its time waiting here.
  result = EncoderThread()
  result.job.ctx = ctx
  result.job.frames.open(queue)
  result.job.packets.open()
  createThread(result.thread, encodeLoop, addr result.job)

proc raiseFailure(e: EncoderThread) {.noreturn.} =
  error &"Error encoding {e.job.ctx.codec.name}: {av_err2str(e.job.err)}"

proc submit*(e: EncoderThread, frame: ptr AVFrame) =
  ## Queue `frame` for encoding. The encoder thread owns it from here on.
  e.job.frames.send(frame.pointer)

iterator ready*(e: EncoderThread): ptr AVPacket =
  ## The packets encoded so far, without waiting for more. Each is freed after
  ## its turn in the loop.
  while not e.done:
    let (ok, p) = e.job.packets.tryRecv()
    if not ok:
      break
    if p == nil:
      e.done = true
      if e.job.err < 0:
        e.raiseFailure()
      break
    var pkt = p
    try:
      yield pkt
    finally:
      av_packet_free(addr pkt)

iterator finish*(e: EncoderThread): ptr AVPacket =
  ## End the stream, then every packet still to come, as the encoder makes it.
  if not e.eofSent:
    e.eofSent = true
    e.job.frames.send(nil)
  while not e.done:
    let p = e.job.packets.recv()
    if p == nil:
      e.done = true
      if e.job.err < 0:
        e.raiseFailure()
      break
    var pkt = p
    try:
      yield pkt
    finally:
      av_packet_free(addr pkt)

proc close*(e: EncoderThread) =
  ## Stop the thread and free whatever is still queued. Call it before the
  ## codec context is freed, on every path out of the render.
  if e.closed:
    return
  e.closed = true
  if not e.eofSent:
    e.eofSent = true
    e.job.frames.send(nil)
  joinThread(e.thread)
  while true:
    let (ok, p) = e.job.packets.tryRecv()
    if not ok:
      break
    if p != nil:
      var pkt = p
      av_packet_free(addr pkt)
  while true:
    let (ok, f) = e.job.frames.tryRecv()
    if not ok:
      break
    if f != nil:
      var frame = cast[ptr AVFrame](f)
      av_frame_free(addr frame)
  e.job.frames.close()
  e.job.packets.close()
