## A tiny grayscale thumbnail of every timebase frame, so the `hesitation`
## edit method can tell whether the frames on either side of a cut look alike:
## when they do, the cut can't be seen.

import std/[math, options, strformat]

import ../[av, cache, ffmpeg, log]
import ../util/[bar, rational]
import ../lib/dnorm16
import ./motion # VideoProcessor + videoPipeline

const
  thumbW* = 24
  thumbH* = 14
  thumbSize* = thumbW * thumbH ## bytes per frame

type SceneFrames* = object
  thumbs*: seq[uint8] ## `thumbSize` bytes of luma per frame, row-major

func len*(s: SceneFrames): int = s.thumbs.len div thumbSize

iterator thumbnails(processor: var VideoProcessor): array[thumbSize, uint8] =
  ## One area-averaged thumbnail per timebase index, repeating the last frame
  ## over indexes no source frame lands on, like `motionness`.
  var prevIndex: int64 = -1
  var thumb: array[thumbSize, uint8]
  let filter = &"scale={thumbW}:{thumbH}:flags=area,format=gray"
  for frame in processor.videoPipeline(filter):
    let frameTime = (frame.pts * processor.formatCtx.streams[
        processor.videoIndex].time_base).float64
    let index = round(frameTime * processor.tb.float64).int64
    let stride = frame.linesize[0].int
    let data = cast[ptr UncheckedArray[uint8]](frame.data[0])
    for y in 0 ..< min(thumbH, frame.height.int):
      for x in 0 ..< min(thumbW, frame.width.int):
        thumb[y * thumbW + x] = data[y * stride + x]
    for i in 0 ..< index - prevIndex:
      yield thumb
    prevIndex = max(prevIndex, index)

proc scene*(bar: Bar, container: InputContainer, path: string, tb: AVRational,
    stream: int16): SceneFrames =
  ## Thumbnails of every timebase frame of video `stream`.
  let cacheArgs = &"{stream},{thumbW}x{thumbH}"
  if not noCache:
    # Cached two pixels to a Unorm16, the cache's narrowest element.
    let cacheData = readCache[Unorm16](path, tb, "scene", cacheArgs)
    if cacheData.isSome:
      let packed = cacheData.unsafeGet()
      result.thumbs = newSeq[uint8](packed.len * 2)
      if packed.len > 0:
        copyMem(addr result.thumbs[0], unsafeAddr packed[0], packed.len * 2)
      return

  if stream < 0 or stream >= container.video.len:
    error &"hesitation: video stream '{stream}' does not exist."

  let videoStream: ptr AVStream = container.video[stream]
  container.seek(0)
  let errorsBefore = decodeErrors

  var processor = VideoProcessor(formatCtx: container.formatContext,
    codecCtx: initDecoder(videoStream.codecpar), tb: tb,
    videoIndex: videoStream.index)

  let inaccurateDur =
    if videoStream.duration != AV_NOPTS_VALUE and videoStream.time_base.isValid:
      float(videoStream.duration) * float(videoStream.time_base * tb)
    else:
      container.duration * float(tb)
  bar.start(inaccurateDur, "Analyzing scenes")

  var i: float = 0
  for thumb in processor.thumbnails():
    result.thumbs.add thumb
    bar.tick(i)
    i += 1
  bar.`end`()

  if not noCache and decodeErrors == errorsBefore:
    var packed = newSeq[Unorm16](result.thumbs.len div 2)
    if packed.len > 0:
      copyMem(addr packed[0], addr result.thumbs[0], packed.len * 2)
    writeCache(packed, tb, path, "scene", cacheArgs)
