import std/[heapqueue, options, sequtils, sets, strformat, strutils]
from std/math import ceil, round

import ../[action, av, ffmpeg, license, log, media, timeline, throttle]
import ../util/[bar, rules, rational]
import ./[video, audio, subtitle, partialplan]
when not defined(emscripten):
  import ./encthread

# Audio encoders run on threads of their own, overlapping the video side.
# WebAssembly builds keep them on the render loop: their encoders can be
# WebCodecs ones, which belong to the thread that made them.
const audioEncoderThreads = not defined(emscripten)
const audioAheadSecs = 6.0 # how far audio may run ahead of video
const audioQueueSecs = 8.0 # how much of it may wait for its encoder

type Priority = object
  index: float64
  order: int64 # push order, to break ties
  frame: ptr AVFrame
  packet: ptr AVPacket
  stream: ptr AVStream

func `<`(a, b: Priority): bool =
  a.index < b.index or (a.index == b.index and a.order < b.order)

func pngDimensions(data: ptr uint8, size: cint): (cint, cint) =
  const sig = [0x89'u8, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
  if size < 24:
    return (0, 0)
  let b = cast[ptr UncheckedArray[uint8]](data)
  for i in 0..7:
    if b[i] != sig[i]:
      return (0, 0)
  # IHDR: sig(8) + chunk_len(4) + "IHDR"(4) + width(4) + height(4)
  let w = (b[16].cint shl 24) or (b[17].cint shl 16) or
          (b[18].cint shl 8) or b[19].cint
  let h = (b[20].cint shl 24) or (b[21].cint shl 16) or
          (b[22].cint shl 8) or b[23].cint
  return (w, h)

proc resolveAudioCodec(layer: seq[Clip], rules: Rules, cache: MediaCache): AVCodecID =
  if layer.len == 0:
    return rules.defaultAud
  # PCM-first containers (WAV, AIFF, AU, W64, CAF, ...) prefer PCM over the
  # source codec.
  if rules.defaultAud.isPCM:
    return rules.defaultAud

  let firstClip = layer[0]
  if firstClip.src == nil:
    return rules.defaultAud
  let stream = int(firstClip.stream)

  var codec: AVCodecID
  if cache != nil:
    let container = cache.getContainer(firstClip.src)
    if stream >= container.audio.len:
      return rules.defaultAud
    codec = container.audio[stream].codecpar.codec_id
  else:
    let srcMi = initMediaInfo(firstClip.src[])
    if stream >= srcMi.a.len:
      return rules.defaultAud
    codec = srcMi.a[stream].codecId

  if rules.allowsCodec(codec):
    return codec
  return (if rules.defaultAud == ID_NONE: ID_AAC else: rules.defaultAud)

func opusRate(rate: cint): cint =
  for r in [8000.cint, 12000, 16000, 24000, 48000]:
    if rate <= r:
      return r
  return 48000

proc checkAudioCtx(ctx: ptr AVCodecContext, rate: cint) =
  let sampleFmts = ctx.codec.supportedSampleFmts
  if sampleFmts == nil:
    error &"{ctx.codec.name}: No known audio formats avail."

  var configPtr: pointer = nil
  var num: cint = 0
  discard avcodec_get_supported_config(
    ctx, nil, AV_CODEC_CONFIG_SAMPLE_RATE, 0.cuint, addr configPtr, addr num
  )

  const AAC_RATES = [48000.cint, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000]

  if configPtr == nil:
    debug "Audio encoder does not have a config"
    if ctx.codec.id == ID_AAC and rate notin AAC_RATES:
      error "AAC encoder only supports these samplerates: " & AAC_RATES.join(", ")
    return

  let rates = cast[ptr UncheckedArray[cint]](configPtr)
  for i in 0..<num:
    if rates[i] == rate:
      return

  error &"samplerate '{rate}' not allowed for {ctx.codec.name}."

proc makePartialLosslessVideo(output: var OutputContainer, tl: v3, args: mainArgs,
    video: VideoSettings):
    tuple[stream: ptr AVStream, packets: iterator(): (ptr AVPacket, int64)] =
  let encoder = initCodec(video.codec)
  if encoder == nil:
    return

  let plan = output.partialLosslessPlan(tl, args, video, encoder.id)
  if plan.len == 0:
    return

  (result.stream, result.packets) =
    makePartialLossless(output, tl, video, plan, encoder.id)

proc dropUndecodableAudio*(tl: var v3, cache: MediaCache) =
  ## A timeline can name an audio stream this build has no decoder for: the
  ## `apac` track in an iPhone Spatial Audio recording, say. The CLI drops those
  ## layers as it builds a timeline, but a v3 written elsewhere (the app builds
  ## its own) arrives with them intact, so drop the clips here too rather than
  ## failing the whole render. The layer is emptied, never removed, so the seqs
  ## indexed alongside it -- `langs`, `at` -- stay aligned.
  var reported: HashSet[(ptr string, int16)]
  for layer in tl.a.mitems:
    var kept = newSeqOfCap[Clip](layer.len)
    for clip in layer:
      if clip.src == nil:
        kept.add clip
        continue
      let container = cache.getContainer(clip.src)
      if clip.stream.int >= container.audio.len:
        kept.add clip
        continue
      let codecId = container.audio[clip.stream.int].codecpar.codec_id
      if canDecode(codecId):
        kept.add clip
      elif not reported.containsOrIncl((clip.src, clip.stream)):
        warning &"Skipping audio stream {clip.stream}: no decoder for " &
          $avcodec_get_name(codecId)
    layer = kept

proc makeMedia*(args: mainArgs, inputVideo: VideoSettings, audio: AudioSettings,
    tl: var v3, outputPath: string, rules: Rules, bar: Bar, cache: MediaCache) =
  var video = inputVideo
  # Before bakeTransitions: output streams are created from `tl` and their
  # frames come from the baked copy, so both must see the same audio layers.
  tl.dropUndecodableAudio(cache)
  let sourceEffectCount = tl.effects.len
  var renderTl = tl.bakeTransitions()
  defer:
    for i in sourceEffectCount ..< renderTl.effects.len:
      renderTl.effects[i].free()
  var throttle = initThrottle()
  let includeVideo = not args.vn and rules.defaultVid notin [ID_NONE, ID_PNG]
  let includeAudio = not args.an and rules.defaultAud != ID_NONE
  let includeSubtitle = not args.sn and rules.defaultSub != ID_NONE
  let renderVideo = includeVideo and renderTl.v.len > 0 and renderTl.v[0].len > 0
  if renderVideo:
    template limitTo(limit: SizeLimit, what: string) =
      let (width, height) = scaledVideoResolution(renderTl.res, video.scale)
      if not fits(width, height, limit):
        # Without a key, shrink to fit, unless the size was asked for exactly.
        if licenseKeyProvided(args) or (video.scaleSet and args.resolutionSet):
          requireLicense(args, "render " & what & " above " & $limit)
        else:
          video.scale = min(video.scale,
            fitScale(renderTl.res[0], renderTl.res[1], limit))
          let (w, h) = scaledVideoResolution(renderTl.res, video.scale)
          warning "Rendering " & what & " without a license is limited to " &
            $limit & "; using --scale " & formatFloat(video.scale, ffDefault, 4) &
            " (" & $w & "x" & $h & ")."

    if renderTl.numberOfSrc > 1:
      limitTo(FREE_MULTI_SOURCE, "video with multiple sources")
    limitTo(FREE_RENDER, "video")

  var options: OutputOptions
  if args.fragmented and not args.noFragmented:
    options.add("frag_duration", "0.2")
    options.add("movflags", "empty_moov+default_base_moof+frag_keyframe+separate_moof")
    if args.faststart:
      warning "Fragmented is enabled, will not apply faststart."
  elif not args.noFaststart:
    options.add("movflags", "faststart")

  var output = openWrite(outputPath)
  output.options = options
  output.streaming = args.fragmented and not args.noFragmented

  var audCodec = ""
  if includeAudio:
    if audio.codec == "auto":
      for layer in tl.a:
        if layer.len > 0:
          audCodec = $avcodec_get_name(resolveAudioCodec(layer, rules, cache))
          break
      when defined(macosx):
        if audCodec == "aac" and avcodec_find_encoder_by_name("aac_at") != nil:
          audCodec = "aac_at"
    else:
      audCodec = audio.codec

    if audCodec in ["opus", "libopus"]:
      let snapped = opusRate(tl.sr)
      if snapped != tl.sr:
        debug &"opus: snapping sample rate {tl.sr} -> {snapped}"
        tl.sr = snapped

  var vEncCtx: ptr AVCodecContext = nil
  var vOutStream: ptr AVStream = nil
  var videoFrameIter: iterator(): (ptr AVFrame, int64) =
    iterator(): (ptr AVFrame, int64) =
      return
  var videoPacketIter: iterator(): (ptr AVPacket, int64) =
    iterator(): (ptr AVPacket, int64) =
      return
  var partialLosslessVideo = false

  if renderVideo:
    (vOutStream, videoPacketIter) =
      output.makePartialLosslessVideo(renderTl, args, video)
    partialLosslessVideo = vOutStream != nil
    if not partialLosslessVideo:
      (vEncCtx, vOutStream, videoFrameIter) =
        makeNewVideoFrames(output, renderTl, args, video, cache)

  var audioStreams: seq[ptr AVStream] = @[]
  var audioEncoders: seq[ptr AVCodecContext] = @[]
  var audioFrameIters: seq[iterator(): (ptr AVFrame, int64)] = @[]

  if includeAudio and args.mixAudioStreams and tl.a.len > 0:
    # Create a single audio stream for mixed output
    var hasAnyClips = false
    for i in 0..<tl.a.len:
      if tl.a[i].len > 0:
        hasAnyClips = true
        break

    if hasAnyClips:
      let rate = AVRational(num: tl.sr, den: 1)
      var (aOutStream, aEncCtx) = output.addStream(audCodec, rate = rate,
          lang = ['u', 'n', 'd', '\0'], layout = tl.layout)
      checkAudioCtx(aEncCtx, tl.sr)
      # avcodec_open2 configures the encoder from bit_rate; set after and it's ignored.
      if audio.bitrate >= 0:
        aEncCtx.bit_rate = audio.bitrate
      resolveEncoderContext(aEncCtx)
      let encoder = aEncCtx.codec
      aEncCtx.open()

      # Update stream parameters after opening encoder for formats like AAC in MKV
      # that need codec-specific extra data (global header) to be propagated to stream
      if avcodec_parameters_from_context(aOutStream.codecpar, aEncCtx) < 0:
        error "Could not update stream parameters after opening encoder"

      if audio.bitrate >= 0:
        debug &"audio bitrate: {aEncCtx.bit_rate}"
      else:
        debug &"[auto] audio bitrate: {aEncCtx.bit_rate}"

      audioStreams.add(aOutStream)
      audioEncoders.add(aEncCtx)

      let frameSize = if aEncCtx.frame_size > 0: aEncCtx.frame_size else: 1024
      let audioFrameIter = makeAudioFrames(encoder.supportedSampleFmts[0], renderTl,
          frameSize, toSeq(0 ..< tl.a.len), audio.normalize, cache)
      audioFrameIters.add(audioFrameIter)
  elif includeAudio:
    # Create separate streams for each timeline layer
    for i in 0..<tl.a.len:
      if tl.a[i].len > 0: # Only create stream if track has clips
        let rate = AVRational(num: tl.sr, den: 1)
        var (aOutStream, aEncCtx) = output.addStream(audCodec, rate = rate,
            lang = tl.langs[tl.v.len + i], layout = tl.layout)
        checkAudioCtx(aEncCtx, tl.sr)
        # avcodec_open2 configures the encoder from bit_rate; setting it after
        # the call has no effect.
        if audio.bitrate >= 0:
          aEncCtx.bit_rate = audio.bitrate
        resolveEncoderContext(aEncCtx)
        let encoder = aEncCtx.codec
        aEncCtx.open()

        # Update stream parameters after opening encoder for formats like AAC in MKV
        # that need codec-specific extra data (global header) to be propagated to stream
        if avcodec_parameters_from_context(aOutStream.codecpar, aEncCtx) < 0:
          error "Could not update stream parameters after opening encoder"

        if audio.bitrate >= 0:
          debug &"audio bitrate: {aEncCtx.bit_rate}"
        else:
          debug &"[auto] audio bitrate: {aEncCtx.bit_rate}"

        audioStreams.add(aOutStream)
        audioEncoders.add(aEncCtx)

        let frameSize = if aEncCtx.frame_size > 0: aEncCtx.frame_size else: 1024
        let audioFrameIter = makeAudioFrames(encoder.supportedSampleFmts[0], renderTl,
            frameSize, @[i], audio.normalize, cache)
        audioFrameIters.add(audioFrameIter)

  defer:
    if vEncCtx != nil:
      avcodec_free_context(addr vEncCtx)
    for aEncCtx in audioEncoders:
      avcodec_free_context(addr aEncCtx)

  # Setup subtitle streams
  var subtitleStreams: seq[ptr AVStream] = @[]
  var subtitleSources: seq[string] = @[]

  if includeSubtitle and tl.s.len > 0:
    for i in 0..<tl.s.len:
      if tl.s[i].len > 0:
        let firstClip = tl.s[i][0]
        let sourcePath = firstClip.src[]
        let streamIdx = firstClip.stream

        var srcContainer: InputContainer
        var ownsContainer = false
        if cache != nil:
          srcContainer = cache.getContainer(firstClip.src)
        else:
          srcContainer = (
            try: av.open(sourcePath)
            except IOError as e: error e.msg
          )
          ownsContainer = true
        if streamIdx >= srcContainer.subtitle.len:
          error &"Subtitle stream {streamIdx} not found in {sourcePath}"

        let srcStream = srcContainer.subtitle[streamIdx]

        # Add subtitle stream to output by copying from template
        let sOutStream = output.addStreamFromTemplate(srcStream)
        subtitleStreams.add(sOutStream)
        subtitleSources.add(sourcePath)

        if ownsContainer:
          srcContainer.close()

  var imageStreams: seq[(ptr AVStream, ptr AVPacket)] = @[]
  var imageSourceCtx: ptr AVFormatContext = nil
  var ownsImageSourceCtx = false
  defer:
    if ownsImageSourceCtx and imageSourceCtx != nil:
      avformat_close_input(addr imageSourceCtx)

  var outPacket = av_packet_alloc()
  if outPacket == nil:
    error "Could not allocate output packet"
  defer: av_packet_free(addr outPacket)

  # Attachments (fonts, cover art) are copied from the template file.
  if not args.dn and tl.templateFile != nil:
    if cache != nil:
      imageSourceCtx = cache.getContainer(tl.templateFile).formatContext
    else:
      imageSourceCtx = av.openFormatCtx(tl.templateFile[].cstring)
      ownsImageSourceCtx = true

    for i in 0 ..< imageSourceCtx.nb_streams:
      let strm = imageSourceCtx.streams[i]
      if strm.codecpar.codec_type == AVMEDIA_TYPE_ATTACHMENT:
        let outStrm = avformat_new_stream(output.formatCtx, nil)
        if outStrm == nil:
          error "Could not allocate attachment stream"
        if avcodec_parameters_copy(outStrm.codecpar, strm.codecpar) < 0:
          error "Could not copy attachment codec parameters"
        if strm.metadata != nil:
          discard av_dict_copy(addr outStrm.metadata, strm.metadata, 0)
      elif strm.codecpar.codec_type == AVMEDIA_TYPE_VIDEO and
          (strm.disposition and AV_DISPOSITION_ATTACHED_PIC) != 0:
        let supported = avformat_query_codec(output.formatCtx.oformat,
          strm.codecpar.codec_id, FF_COMPLIANCE_EXPERIMENTAL)
        if supported == 0 or (supported < 0 and output.formatCtx.oformat.name != "flac"):
          continue
        let outStrm = avformat_new_stream(output.formatCtx, nil)
        if outStrm == nil:
          error "Could not allocate image stream"
        if avcodec_parameters_copy(outStrm.codecpar, strm.codecpar) < 0:
          error "Could not copy image codec parameters"
        if outStrm.codecpar.width == 0 or outStrm.codecpar.height == 0:
          if strm.codecpar.codec_id == ID_PNG:
            let (w, h) = pngDimensions(strm.attached_pic.data, strm.attached_pic.size)
            if w > 0 and h > 0:
              outStrm.codecpar.width = w
              outStrm.codecpar.height = h
        outStrm.time_base = strm.time_base
        outStrm.disposition = strm.disposition
        if strm.metadata != nil:
          discard av_dict_copy(addr outStrm.metadata, strm.metadata, 0)
        imageStreams.add((outStrm, addr strm.attached_pic))

  output.startEncoding()

  when audioEncoderThreads:
    # Declared after the encoders' own `defer`, so this one runs first: each
    # thread stops before its codec context is freed.
    var audioThreads: seq[EncoderThread] = @[]
    defer:
      for t in audioThreads:
        t.close()
    for aEncCtx in audioEncoders:
      # Room for more than `maxAudioAhead`, below, so the loop doesn't wait on
      # an encoder before it's that far ahead.
      let frameSize = if aEncCtx.frame_size > 0: aEncCtx.frame_size else: 1024
      let capacity = int(ceil(audioQueueSecs * aEncCtx.sample_rate.float64 /
        frameSize.float64))
      audioThreads.add newEncoderThread(aEncCtx, capacity)

  # Hand an encoded audio packet of stream `i` to the muxer.
  template muxAudio(i: int, pkt: ptr AVPacket) =
    let aEncCtx = audioEncoders[i]
    pkt.stream_index = audioStreams[i].index
    if vOutStream == nil and pkt.pts != AV_NOPTS_VALUE:
      let time = float(pkt.pts) * float(aEncCtx.time_base)
      if time >= 0:
        bar.tick(round(time * tl.tb))
        throttle.checkpoint(time)
    av_packet_rescale_ts(pkt, aEncCtx.time_base, audioStreams[i].time_base)
    output.mux(pkt[])

  var title = &"({output.formatCtx.oformat.name}) "
  var encoderTitles: seq[string] = @[]

  if vOutStream != nil:
    let name = if vEncCtx != nil: vEncCtx.codec.canonicalName else: vOutStream.name()
    if name != "":
      encoderTitles.add (if noColor: name else: &"\e[95m{name}")
  for aEncCtx in audioEncoders:
    let name = aEncCtx.codec.canonicalName
    encoderTitles.add (if noColor: name else: &"\e[96m{name}")
  for sStream in subtitleStreams:
    let name = $sStream.name()
    if name != "":
      encoderTitles.add (if noColor: name else: &"\e[93m{name}")

  if noColor:
    title &= encoderTitles.join("+")
  else:
    title &= encoderTitles.join("\e[0m+") & "\e[0m"
  bar.start(tl.len.float64, title)

  # How far, in timebase, audio is let run ahead of video. Seconds of it keep
  # an audio encoder on its own thread busy across the stretches where video
  # is slow to come by (re-encoded GOPs) and where it's quick (copied ones);
  # the muxer still interleaves the two closely.
  let maxAudioAhead =
    when audioEncoderThreads:
      max(30'i64, int64(round(audioAheadSecs * tl.tb.float64)))
    else: 30'i64

  # Priority queue for ordered frames by time_base.
  var frameQueue = initHeapQueue[Priority]()
  var pushed = 0'i64
  template enqueue(item: Priority) =
    var it = item
    it.order = pushed # keeps a stream's frames in order when indexes tie
    inc pushed
    frameQueue.push(it)

  var earliestVideoIndex = none(int64)
  var latestAudioIndices = newSeq[int64](audioFrameIters.len)
  for i in 0..<audioFrameIters.len:
    latestAudioIndices[i] = int64.low

  var videoFrame: ptr AVFrame
  var videoPacket: ptr AVPacket
  var index: int64

  while true:
    if partialLosslessVideo:
      videoFrame = nil
      if finished(videoPacketIter):
        videoPacket = nil
      else:
        (videoPacket, index) = videoPacketIter()
        if videoPacket != nil:
          earliestVideoIndex = some(index)
          enqueue(Priority(index: float(index), packet: videoPacket,
            stream: vOutStream))
    else:
      videoPacket = nil
      if finished(videoFrameIter):
        videoFrame = nil
      else:
        (videoFrame, index) = videoFrameIter()
        if videoFrame != nil:
          earliestVideoIndex = some(index)
          enqueue(Priority(index: float(index), frame: videoFrame,
            stream: vOutStream))

    var hasFrames = videoFrame != nil or videoPacket != nil
    # Bring each audio stream up to the video, which a frame of each per loop
    # wouldn't do: there are more audio frames a second than video ones. With
    # no video left, take one a loop.
    let keepUp = hasFrames and earliestVideoIndex.isSome
    for i in 0..<audioFrameIters.len:
      while not finished(audioFrameIters[i]):
        if keepUp and latestAudioIndices[i] > earliestVideoIndex.get() + maxAudioAhead:
          break
        let (audioFrame, _) = audioFrameIters[i]()
        if audioFrame == nil:
          break
        hasFrames = true
        let audioIndex = int64(round(
          audioFrame.time(audioEncoders[i].time_base) * tl.tb))
        latestAudioIndices[i] = audioIndex
        # Update index to the maximum of video and audio indices to ensure progress
        index = max(index, audioIndex)
        enqueue(Priority(index: float(audioIndex), frame: audioFrame,
          stream: audioStreams[i]))
        if not keepUp:
          break

    if not hasFrames:
      break

    while frameQueue.len > 0 and frameQueue[0].index <= float64(index):
      let item = frameQueue.pop()
      let frame = item.frame
      let outputStream = item.stream
      if item.packet != nil:
        let packet = item.packet
        if packet.pts != AV_NOPTS_VALUE:
          let time = float(packet.pts) * float(packet.time_base)
          bar.tick(round(time * tl.tb))
          throttle.checkpoint(time)
        output.mux(packet[])
        var ownedPacket = packet
        av_packet_free(addr ownedPacket)
        continue
      let frameType = outputStream.codecpar.codec_type
      var audioIndex = -1
      if frameType != AVMEDIA_TYPE_VIDEO:
        for i, stream in audioStreams:
          if stream == outputStream:
            audioIndex = i
            break
      when audioEncoderThreads:
        if audioIndex >= 0:
          audioThreads[audioIndex].submit(frame) # the thread frees it
          continue
      let encCtx =
        if frameType == AVMEDIA_TYPE_VIDEO: vEncCtx
        else: audioEncoders[audioIndex]

      for outPacket in encCtx.encode(frame, outPacket):
        outPacket.stream_index = outputStream.index
        av_packet_rescale_ts(outPacket, encCtx.time_base, outputStream.time_base)

        if frameType == AVMEDIA_TYPE_VIDEO or vOutStream == nil:
          let time = frame.time(encCtx.time_base)
          if time != -1.0:
            bar.tick(round(time * tl.tb))
            throttle.checkpoint(time)
        output.mux(outPacket[])
        av_packet_unref(outPacket)

        if frameType == AVMEDIA_TYPE_VIDEO:
          av_frame_unref(frame)

      if frameType == AVMEDIA_TYPE_AUDIO:
        av_frame_free(addr frame)

    when audioEncoderThreads:
      for i, t in audioThreads:
        for pkt in t.ready:
          muxAudio(i, pkt)

  bar.`end`()

  # Flush streams
  if vEncCtx != nil:
    for outPacket in vEncCtx.encode(nil, outPacket):
      outPacket.stream_index = vOutStream.index
      av_packet_rescale_ts(outPacket, vEncCtx.time_base, vOutStream.time_base)
      output.mux(outPacket[])
      av_packet_unref(outPacket)

  when audioEncoderThreads:
    for i, t in audioThreads:
      for pkt in t.finish:
        muxAudio(i, pkt)
  else:
    for i, aEncCtx in audioEncoders:
      for outPacket in aEncCtx.encode(nil, outPacket):
        outPacket.stream_index = audioStreams[i].index
        av_packet_rescale_ts(outPacket, aEncCtx.time_base, audioStreams[i].time_base)
        output.mux(outPacket[])
        av_packet_unref(outPacket)

  # Copy embedded images
  for (outStream, cachedPkt) in imageStreams:
    if cachedPkt != nil and av_packet_ref(outPacket, cachedPkt) >= 0:
      outPacket.stream_index = outStream.index
      if av_interleaved_write_frame(output.formatCtx, outPacket) < 0:
        error "Could not write embedded image packet"
      av_packet_unref(outPacket)

  # Process subtitle streams
  if includeSubtitle:
    for i in 0..<subtitleStreams.len:
      let layer = tl.s[i]
      let sourcePath = subtitleSources[i]
      let outputStream = subtitleStreams[i]
      remuxSubtitles(sourcePath, layer, outputStream, output, tl.tb)

  output.close()
