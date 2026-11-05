## A parsed `--edit` expression: which methods mark frames active, and how
## their results combine. `edit.parseEdit` builds one from the CLI's syntax;
## a program using auto-editor as a library can build one directly.

import std/math
import ./lib/dnorm16

type
  EditMethodKind* = enum
    ekAudio, ekMotion, ekBlackdetect,
    ekSubtitle ## a regex over subtitle lines (`subtitle`, `regex`)
    ekWord     ## a whole word in subtitle lines
    ekHesitation ## pauses in speech, except where a sentence ended
    ekNone     ## every frame active
    ekAll      ## no frame active

  EditTime* = object
    value*: float64 ## seconds, or timebase units when `units`
    units*: bool

  EditMethod* = object
    threshold*: Unorm16 ## audio, motion, blackdetect
    stream*: int        ## -1 is every audio stream (audio only)
    case kind*: EditMethodKind
    of ekAudio:
      channel*: string ## a channel name such as "left", or "all"
    of ekMotion:
      width*, blur*: int
      region*: tuple[x, y, w, h: float32] ## fractions of the frame
    of ekBlackdetect:
      pixelBlack*: float32
    of ekSubtitle, ekWord:
      pattern*: string ## the regex, or the word as written
      ignoreCase*: bool
    of ekHesitation:
      silenceDb*: float32       ## RMS level of silence; NaN finds it
      minPause*: EditTime       ## shorter silences are left alone
      sentencePause*: EditTime  ## longest pause kept after a sentence
      trimSentences*: bool      ## false keeps sentence-end pauses whole
      seam*: float32            ## most visual difference a cut may join
      video*: int               ## video stream the seam is judged on
      subtitles*: int           ## a subtitle stream; -1 any, -2 none
      commas*: bool             ## keep a pause at a transcript's comma
      prosody*: bool            ## judge sentence ends by pitch and loudness
      model*: string            ## transcribe with this model; "" doesn't
      language*: string         ## the language to transcribe, or "auto"
    of ekNone, ekAll:
      discard

  EditOp* = enum
    eoMethod, eoOr, eoAnd, eoXor, eoNot

  EditExpr* = object
    case op*: EditOp
    of eoMethod:
      m*: EditMethod
    of eoOr, eoAnd, eoXor, eoNot:
      operands*: seq[EditExpr] ## `not` has exactly one

func audioMethod*(threshold = 0.04'f32, stream = -1, channel = "all"): EditMethod =
  EditMethod(kind: ekAudio, threshold: threshold, stream: stream, channel: channel)

func motionMethod*(threshold = 0.02'f32, stream = 0, width = 400, blur = 9,
    region = (x: 0'f32, y: 0'f32, w: 1'f32, h: 1'f32)): EditMethod =
  EditMethod(kind: ekMotion, threshold: threshold, stream: stream, width: width,
    blur: blur, region: region)

func blackdetectMethod*(threshold = 0.98'f32, stream = 0, pixelBlack = 0.10'f32): EditMethod =
  EditMethod(kind: ekBlackdetect, threshold: threshold, stream: stream,
    pixelBlack: pixelBlack)

func subtitleMethod*(pattern: string, stream = 0, ignoreCase = false): EditMethod =
  EditMethod(kind: ekSubtitle, pattern: pattern, stream: stream, ignoreCase: ignoreCase)

func wordMethod*(word: string, stream = 0, ignoreCase = true): EditMethod =
  EditMethod(kind: ekWord, pattern: word, stream: stream, ignoreCase: ignoreCase)

func editSeconds*(s: float64): EditTime = EditTime(value: s)

func toTb*(t: EditTime, tb: float64): int =
  if t.units: int(t.value) else: int(round(t.value * tb))

func hesitationMethod*(silenceDb = NaN.float32, stream = 0,
    minPause = editSeconds(0.5), sentencePause = editSeconds(1.5),
    trimSentences = true, seam = 0.04'f32, video = 0, subtitles = -1,
    commas = true, prosody = true, model = "", language = "auto"): EditMethod =
  EditMethod(kind: ekHesitation, stream: stream, silenceDb: silenceDb,
    minPause: minPause, sentencePause: sentencePause,
    trimSentences: trimSentences, seam: seam, video: video,
    subtitles: subtitles, commas: commas, prosody: prosody, model: model,
    language: language)

func noneMethod*(): EditMethod = EditMethod(kind: ekNone)
func allMethod*(): EditMethod = EditMethod(kind: ekAll)

func edit*(m: EditMethod): EditExpr = EditExpr(op: eoMethod, m: m)

func combine*(op: EditOp, operands: varargs[EditExpr]): EditExpr =
  ## `or`, `and` or `xor` over one or more operands.
  assert op in {eoOr, eoAnd, eoXor} and operands.len > 0
  result = EditExpr(op: op)
  result.operands = @operands

func invert*(e: EditExpr): EditExpr = EditExpr(op: eoNot, operands: @[e])

func needs*(e: EditExpr): tuple[video, audio: bool] =
  ## Whether evaluating `e` analyzes video and/or audio frames. Subtitle
  ## methods read the subtitle stream, so they need neither.
  case e.op
  of eoMethod:
    result = case e.m.kind
      of ekAudio: (false, true)
      of ekMotion, ekBlackdetect: (true, false)
      of ekHesitation: (true, true)
      else: (false, false)
  of eoOr, eoAnd, eoXor, eoNot:
    for o in e.operands:
      let n = o.needs
      result = (result.video or n.video, result.audio or n.audio)
