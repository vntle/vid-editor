## Single source of truth for `--edit` methods and operators.
##
## `src/edit.nim` derives each method's positional argument order and which
## stream it analyzes from these defs; `docs/components/gen_edit.nims`
## renders the Edit Reference page from them. Keep this module dependency-light
## (std-only) so the docs generator can import it without pulling in ffmpeg.

type
  EditMedia* = enum
    emVideo, emAudio, emSubtitle

  EditParam* = object
    name*: string    ## positional argument name, e.g. "threshold"
    typ*: string     ## doc type, e.g. "(U Natural 'all)"
    default*: string ## doc default; "" means the argument is required

  EditMethodDef* = object
    names*: seq[string] ## canonical name first, then aliases (share parsing)
    media*: EditMedia   ## which stream the method analyzes
    params*: seq[EditParam]
    help*: string

  EditOperatorDef* = object
    name*: string
    variadic*: bool ## true => `operand ...`
    help*: string

func p(name, typ: string, default = ""): EditParam =
  EditParam(name: name, typ: typ, default: default)

const editMethodDefs*: seq[EditMethodDef] = @[
  EditMethodDef(names: @["audio"], media: emAudio,
    params: @[p("threshold", "Unorm16", "0.04"),
              p("stream", "(U Natural 'all)", "all"),
              p("channel", "Symbol", "all")],
    help: "Do a one-pass audio filter based on the loudest sample in a " &
          "timebase section, divided by the max value a sample can be. " &
          "`channel` selects a named channel such as `left`, `right`, or " &
          "`center`; `all` analyzes every channel."),
  EditMethodDef(names: @["motion"], media: emVideo,
    params: @[p("threshold", "Unorm16", "0.02"),
              p("stream", "Natural", "0"),
              p("width", "Natural", "400"),
              p("blur", "Natural", "9"),
              p("x", "Float", "0"),
              p("y", "Float", "0"),
              p("w", "Float", "1"),
              p("h", "Float", "1")],
    help: "Scale the video to `width` pixels, convert to grayscale, apply a " &
          "Gaussian blur of `blur` amount, then compare the difference with " &
          "the previous frame. `x`, `y`, `w`, `h` restrict the analysis to a " &
          "region of the frame, as fractions [0-1] of its size."),
  EditMethodDef(names: @["blackdetect"], media: emVideo,
    params: @[p("threshold", "Unorm16", "0.98"),
              p("stream", "Natural", "0"),
              p("pixel-black", "Float", "0.10")],
    help: "Mark a frame as loud when at least `threshold` of its pixels are " &
          "black, where a pixel counts as black when its grayscale luma is at " &
          "or below `pixel-black`. Wrap in `not` to instead cut black frames."),
  EditMethodDef(names: @["subtitle", "regex"], media: emSubtitle,
    params: @[p("pattern", "String"),
              p("stream", "Natural", "0"),
              p("ignore-case", "Bool", "#f")],
    help: "When `pattern`, a RegEx expression, matches a subtitle line, " &
          "consider the time that line occupies as loud."),
  EditMethodDef(names: @["word"], media: emSubtitle,
    params: @[p("value", "String"),
              p("stream", "Natural", "0"),
              p("ignore-case", "Bool", "#t")],
    help: "When `value`, matched as a whole word, appears in a subtitle line, " &
          "consider the time that line occupies as loud. Case-insensitive by " &
          "default."),
  EditMethodDef(names: @["hesitation"], media: emAudio,
    params: @[p("threshold", "(U Unorm16 'auto)", "auto"),
              p("stream", "Natural", "0"),
              p("min-pause", "Time", "0.5s"),
              p("sentence-pause", "(U Time 'none)", "1.5s"),
              p("seam", "Unorm16", "0.04"),
              p("video", "Natural", "0"),
              p("subtitle", "(U Natural 'auto 'none)", "auto"),
              p("commas", "Bool", "#t"),
              p("prosody", "Bool", "#t"),
              p("model", "String", "\"\""),
              p("language", "String", "auto")],
    help: "Mark speech, and the pauses that end a sentence, as loud; mark " &
          "the pauses where the speaker hesitated mid-sentence as silent. A " &
          "pause is silence at least `min-pause` long, where silence is " &
          "quieter than `threshold` (an RMS level; `auto` places it between " &
          "the room and the voice). A transcript says whether a sentence " &
          "ended before a pause: `subtitle` picks its stream, or a sidecar " &
          ".srt/.ass such as `auto-editor whisper` makes; `auto` uses one if " &
          "there is one. Or set `model` to a whisper or parakeet model to " &
          "transcribe the audio first, in `language`. With `commas`, a pause " &
          "at a comma, semicolon, colon or dash counts as a sentence end. " &
          "Without a transcript, `prosody` judges by the voice, in any " &
          "language: pitch falling well below the phrase or rising well " &
          "above it, and the voice fading out, end a sentence; a level pitch " &
          "or a held \"uhh\" does not. A sentence-end pause longer than " &
          "`sentence-pause` is trimmed to it; `none` keeps them whole. A cut " &
          "is only made where the frames it joins differ by at most `seam` " &
          "(0-1), so it can't be seen; when they differ, the cut shrinks to " &
          "frames that match, or the pause stays. Silence before the first " &
          "and after the last word is always silent. `--margin` is kept " &
          "around every cut."),
]

const editOperatorDefs*: seq[EditOperatorDef] = @[
  EditOperatorDef(name: "or", variadic: true,
    help: "\"Logical Or\" one or more boolean arrays. If they are different " &
          "lengths, use the biggest one."),
  EditOperatorDef(name: "and", variadic: true,
    help: "\"Logical And\" one or more boolean arrays. If they are different " &
          "lengths, use the smallest one."),
  EditOperatorDef(name: "xor", variadic: true,
    help: "\"Logical Xor\" one or more boolean arrays."),
  EditOperatorDef(name: "not", variadic: false,
    help: "Invert a boolean array."),
]

func argOrderOf*(name: string): seq[string] {.raises: [].} =
  ## Positional argument names for the method whose canonical name or alias is
  ## `name`. Empty if no such method.
  for d in editMethodDefs:
    if name in d.names:
      for prm in d.params:
        result.add prm.name
      return

func editMediaOf*(name: string): set[EditMedia] {.raises: [].} =
  ## The stream(s) an edit method analyzes; empty for unknown names/operators.
  for d in editMethodDefs:
    if name in d.names:
      return {d.media}

func isEditOperator*(name: string): bool {.raises: [].} =
  for o in editOperatorDefs:
    if o.name == name:
      return true
