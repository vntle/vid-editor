## Per-frame speech prosody for the `hesitation` edit method: how loud each
## timebase frame is (RMS, in dBFS), its fundamental frequency (YIN), and how
## periodic it is. None of it depends on the language being spoken.

import std/[math, options, strformat]

import ../[av, cache, ffmpeg, log, resampler]
import ../util/[bar, rational]

const
  speechRate* = 16000 ## loudness is measured at this rate
  pitchRate = 8000    ## and pitch at this one: F0 lives far below 4 kHz
  pitchWin = 256      ## 32 ms YIN integration window
  minF0 = 60.0
  maxF0 = 500.0
  tauMin = int(pitchRate.float / maxF0)
  tauMax = int(ceil(pitchRate.float / minF0))
  yinThres = 0.15'f32 ## YIN's absolute threshold on the normalized difference
  yinWeak = 0.35'f32  ## past this, a frame is unvoiced
  pitchGateDb = -65'f32 ## don't look for pitch in frames quieter than this
  silentDb* = -100'f32

type SpeechFrames* = object
  rms*: seq[float32]     ## dBFS of each timebase frame, at least `silentDb`
  f0*: seq[float32]      ## Hz, 0 where unvoiced
  clarity*: seq[float32] ## 1 - YIN aperiodicity at `f0`, 0 where unvoiced

func len*(s: SpeechFrames): int = s.rms.len

proc yinPitch*(x: openArray[float32]): tuple[f0, clarity: float32] =
  ## YIN (de Cheveigné & Kawahara, 2002) over `x`, which holds
  ## `pitchWin + tauMax` samples at `pitchRate`.
  assert x.len >= pitchWin + tauMax
  var d {.noinit.}: array[tauMax + 1, float32]
  var cmnd {.noinit.}: array[tauMax + 1, float32]
  for tau in 1 .. tauMax:
    var s = 0'f32
    for j in 0 ..< pitchWin:
      let v = x[j] - x[j + tau]
      s += v * v
    d[tau] = s

  cmnd[0] = 1
  var running = 0'f32
  for tau in 1 .. tauMax:
    running += d[tau]
    cmnd[tau] = (if running > 0: d[tau] * tau.float32 / running else: 1'f32)

  var best = -1
  var tau = tauMin
  while tau <= tauMax:
    if cmnd[tau] < yinThres:
      while tau + 1 <= tauMax and cmnd[tau + 1] < cmnd[tau]:
        inc tau
      best = tau
      break
    inc tau
  if best < 0:
    var lowest = tauMin
    for t in tauMin + 1 .. tauMax:
      if cmnd[t] < cmnd[lowest]: lowest = t
    if cmnd[lowest] < yinWeak:
      best = lowest
  if best < 0:
    return (0'f32, 0'f32)

  var shift = 0'f32
  if best > tauMin and best < tauMax:
    let (a, b, c) = (cmnd[best - 1], cmnd[best], cmnd[best + 1])
    let denom = a - 2 * b + c
    if denom > 0:
      shift = clamp(0.5'f32 * (a - c) / denom, -1'f32, 1'f32)
  (float32(pitchRate) / (best.float32 + shift), 1'f32 - cmnd[best])

type SampleBuf = object
  data: seq[float32]
  first: int64 ## absolute index of data[0]

func stop(b: SampleBuf): int64 = b.first + b.data.len

proc dropBefore(b: var SampleBuf, pos: int64) =
  ## Forget the samples before `pos`, moving memory only now and then.
  let n = int(pos - b.first)
  if n >= 65536 and n <= b.data.len:
    b.data = b.data[n .. ^1]
    b.first = pos

proc fill(b: SampleBuf, pos: int64, dst: var openArray[float32]) =
  ## Copy `dst.len` samples from `pos`, zero where `b` has none.
  for i in 0 ..< dst.len:
    let j = pos + i - b.first
    dst[i] = (if j >= 0 and j < b.data.len: b.data[j] else: 0'f32)

proc push(b: var SampleBuf, frames: seq[ptr AVFrame]) =
  for f in frames:
    let p = cast[ptr UncheckedArray[float32]](f.data[0])
    for i in 0 ..< f.nb_samples.int:
      b.data.add p[i]
    var fr = f
    av_frame_free(addr fr)

proc monoLayout(): ref AVChannelLayout =
  new(result)
  av_channel_layout_default(addr result[], 1)

proc analyzeSpeech(container: InputContainer, audioStream: ptr AVStream,
    tb: AVRational, bar: Bar): SpeechFrames =
  var codecCtx = initDecoder(audioStream.codecpar)
  var frame = av_frame_alloc()
  if frame == nil:
    error "Could not allocate frame"
  defer:
    av_frame_free(addr frame)
    avcodec_free_context(addr codecCtx)

  var loud = newAudioResampler(AV_SAMPLE_FMT_FLT, monoLayout(), speechRate.cint)
  var low = newAudioResampler(AV_SAMPLE_FMT_FLT, monoLayout(), pitchRate.cint)
  var hi, lo: SampleBuf
  var win {.noinit.}: array[pitchWin + tauMax, float32]
  var k = 0'i64
  var frames: SpeechFrames

  # Frame k spans [k * rate / tb, (k + 1) * rate / tb) samples.
  template edge(k: int64, rate: int): int64 =
    (k * rate.int64 * tb.den.int64) div tb.num.int64

  template analyzeFrame(k: int64) =
    let a = edge(k, speechRate)
    let b = max(edge(k + 1, speechRate), a + 1)
    var sum = 0'f64
    for i in a ..< b:
      let j = i - hi.first
      if j >= 0 and j < hi.data.len:
        sum += float64(hi.data[j]) * float64(hi.data[j])
    let db = max(float32(10 * log10(sum / float64(b - a) + 1e-12)), silentDb)
    frames.rms.add db

    var f0, clarity = 0'f32
    if db > pitchGateDb:
      let center = (edge(k, pitchRate) + edge(k + 1, pitchRate)) div 2
      lo.fill(center - pitchWin div 2, win)
      (f0, clarity) = yinPitch(win)
    frames.f0.add f0
    frames.clarity.add clarity

  template ready(k: int64): bool =
    hi.stop >= edge(k + 1, speechRate) and
      lo.stop >= (edge(k, pitchRate) + edge(k + 1, pitchRate)) div 2 +
        pitchWin div 2 + tauMax

  template forget(k: int64) =
    hi.dropBefore(edge(k, speechRate))
    lo.dropBefore((edge(k, pitchRate) + edge(k + 1, pitchRate)) div 2 -
      pitchWin div 2)

  for decoded in container.decode(audioStream.index, codecCtx, frame):
    try:
      hi.push(loud.resample(decoded))
      lo.push(low.resample(decoded))
    except ValueError as e:
      error &"Error resampling audio frame: {e.msg}"
    while ready(k):
      analyzeFrame(k)
      inc k
      forget(k)
      bar.tick(k.float)

  try:
    hi.push(loud.resample(nil))
    lo.push(low.resample(nil))
  except ValueError as e:
    error &"Error resampling audio frame: {e.msg}"
  while edge(k, speechRate) < hi.stop:
    analyzeFrame(k)
    inc k
    forget(k)
  frames

proc speech*(bar: Bar, container: InputContainer, path: string, tb: AVRational,
    stream: int16): SpeechFrames =
  ## Loudness, pitch and periodicity of every timebase frame of audio `stream`.
  let cacheArgs = &"{stream}"
  if not noCache:
    let cacheData = readCache[float32](path, tb, "speech", cacheArgs)
    if cacheData.isSome:
      let flat = cacheData.unsafeGet()
      let n = flat.len div 3
      result.rms = flat[0 ..< n]
      result.f0 = flat[n ..< 2 * n]
      result.clarity = flat[2 * n ..< 3 * n]
      return

  if stream < 0 or stream >= container.audio.len:
    error &"hesitation: audio stream '{stream}' does not exist."

  let audioStream: ptr AVStream = container.audio[stream]
  container.seek(0)
  let errorsBefore = decodeErrors

  let inaccurateDur =
    if audioStream.duration != AV_NOPTS_VALUE and audioStream.time_base.isValid:
      float(audioStream.duration) * float(audioStream.time_base * tb)
    else:
      container.duration * float(tb)
  bar.start(inaccurateDur, "Analyzing speech")
  result = analyzeSpeech(container, audioStream, tb, bar)
  bar.`end`()

  if not noCache and decodeErrors == errorsBefore:
    writeCache(result.rms & result.f0 & result.clarity, tb, path, "speech", cacheArgs)
