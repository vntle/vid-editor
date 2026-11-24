## An encoder on a thread of its own. FFmpeg's AAC encoder is single-threaded
## and, for a typical cut, costs about as much as everything else in a render;
## run on the render loop, it adds to the video side instead of overlapping it.
##
## Only FFmpeg pointers cross between threads, and only under `lock`. The
## caller keeps the codec context; after `newEncoderThread` it reads nothing
## from it but fields fixed at open, like `time_base`.

import std/[deques, locks, strformat, typedthreads]
import ../[ffmpeg, log]

type
  Job = object
    ctx: ptr AVCodecContext
    capacity: int              # frames in flight; `submit` waits past this
    lock: Lock
    wake: Cond                 # for the worker: a frame arrived, or stop
    ready: Cond                # for the caller: room, a packet, or done
    input: Deque[ptr AVFrame]  # nil asks for a flush
    output: Deque[ptr AVPacket]
    stop: bool                 # the caller is unwinding; quit without flushing
    done: bool                 # the worker has exited
    err: cint                  # the first error, 0 for none
    errOnSend: bool

  EncoderThread* = ref object
    job: ptr Job
    thread: Thread[ptr Job]
    joined: bool

proc fail(job: ptr Job, ret: cint, onSend: bool) =
  withLock job.lock:
    if job.err == 0:
      job.err = ret
      job.errOnSend = onSend

proc run(job: ptr Job) {.thread.} =
  var pkt = av_packet_alloc()
  if pkt == nil:
    job.fail(AVERROR(ENOMEM), true)
  while pkt != nil:
    var frame: ptr AVFrame
    withLock job.lock:
      while job.input.len == 0 and not job.stop:
        wait(job.wake, job.lock)
      if job.stop:
        break
      frame = job.input.popFirst()
      signal(job.ready)

    let flushing = frame == nil
    var ret = avcodec_send_frame(job.ctx, frame)
    if frame != nil:
      av_frame_free(addr frame)
    if ret < 0:
      job.fail(ret, true)
      break

    var failed = false
    while true:
      ret = avcodec_receive_packet(job.ctx, pkt)
      if ret == AVERROR_EAGAIN or ret == AVERROR_EOF:
        break
      if ret < 0:
        # As `encode` does: an error while draining at the end only ends it.
        if not flushing:
          job.fail(ret, false)
          failed = true
        break
      let owned = av_packet_alloc()
      if owned == nil:
        job.fail(AVERROR(ENOMEM), false)
        failed = true
        break
      av_packet_move_ref(owned, pkt)
      withLock job.lock:
        job.output.addLast owned
        signal(job.ready)
    if failed or flushing:
      break

  if pkt != nil:
    av_packet_free(addr pkt)
  withLock job.lock:
    job.done = true
    broadcast(job.ready)

proc newEncoderThread*(ctx: ptr AVCodecContext, capacity: int): EncoderThread =
  ## Start encoding on another thread with `ctx`, an opened encoder. Up to
  ## `capacity` frames wait for it before `submit` does.
  let job = createShared(Job)
  job.ctx = ctx
  job.capacity = max(capacity, 1)
  job.input = initDeque[ptr AVFrame]()
  job.output = initDeque[ptr AVPacket]()
  initLock(job.lock)
  initCond(job.wake)
  initCond(job.ready)
  result = EncoderThread(job: job)
  createThread(result.thread, run, job)

proc raiseFor(err: cint, onSend: bool) {.noreturn.} =
  if onSend:
    error &"Error sending frame to encoder: {err}"
  error &"Error receiving packet from encoder: {av_err2str(err)}"

proc submit*(enc: EncoderThread, frame: ptr AVFrame) =
  ## Queue `frame` for encoding; the thread frees it. Waits while the queue is
  ## full. A nil `frame` flushes the encoder; see `finish`.
  let job = enc.job
  var queued = false
  var err: cint = 0
  var onSend = false
  withLock job.lock:
    while job.input.len >= job.capacity and not job.done:
      wait(job.ready, job.lock)
    if job.done:
      err = job.err
      onSend = job.errOnSend
    else:
      job.input.addLast frame
      signal(job.wake)
      queued = true
  if not queued:
    var f = frame
    if f != nil:
      av_frame_free(addr f)
    if err != 0:
      raiseFor(err, onSend)
    error "Encoder thread stopped early"

proc take(job: ptr Job, wait: bool): (Deque[ptr AVPacket], bool, cint, bool) =
  withLock job.lock:
    if wait:
      while job.output.len == 0 and not job.done:
        wait(job.ready, job.lock)
    result = (move(job.output), job.done, job.err, job.errOnSend)
    job.output = initDeque[ptr AVPacket]()

iterator ready*(enc: EncoderThread): ptr AVPacket =
  ## The packets encoded so far, in order, without waiting for more. Each is
  ## freed once the loop body has run.
  let (got, _, err, onSend) = take(enc.job, false)
  for p in got:
    var packet = p
    yield packet
    av_packet_free(addr packet)
  if err != 0:
    raiseFor(err, onSend)

iterator finish*(enc: EncoderThread): ptr AVPacket =
  ## Flush the encoder and yield every packet left, then end the thread.
  enc.submit(nil)
  while true:
    let (got, done, err, onSend) = take(enc.job, true)
    for p in got:
      var packet = p
      yield packet
      av_packet_free(addr packet)
    if err != 0:
      raiseFor(err, onSend)
    if done:
      break
  joinThread(enc.thread)
  enc.joined = true

proc close*(enc: EncoderThread) =
  ## Stop the thread, if it's still running, and free what it holds. Call this
  ## before freeing the codec context. Calling it again does nothing.
  if enc == nil or enc.job == nil:
    return
  let job = enc.job
  if not enc.joined:
    withLock job.lock:
      job.stop = true
      signal(job.wake)
    joinThread(enc.thread)
    enc.joined = true
  for f in job.input:
    var frame = f
    if frame != nil:
      av_frame_free(addr frame)
  for p in job.output:
    var packet = p
    av_packet_free(addr packet)
  job.input = default(Deque[ptr AVFrame])
  job.output = default(Deque[ptr AVPacket])
  deinitCond(job.ready)
  deinitCond(job.wake)
  deinitLock(job.lock)
  deallocShared(job)
  enc.job = nil
