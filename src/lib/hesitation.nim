## Which pauses in speech are hesitations, and how much of each to cut.
##
## A pause is a run of silence between words. One that ends a sentence is
## left alone, or only trimmed when it drags on; one in the middle of a
## sentence (the speaker lost their words) is cut. Whether a sentence ended
## comes from a transcript's punctuation when there is one, and otherwise from
## the voice itself: pitch falling to the bottom of the speaker's range and
## the voice fading out end a sentence, while a pitch held level up to the
## silence ("uhh", "euh", "äh", "ờ", or a dragged-out syllable) does not.
## None of it looks at what language is spoken.
##
## A cut is only made where the frames it joins look nearly the same, so a
## speaker who froze while thinking loses the pause without a visible jump.
##
## Pure: no FFmpeg, so it can be tested on synthetic data.

import std/[algorithm, math, strformat, strutils, unicode]

type
  PauseKind* = enum
    pkEdge = "edge"             ## before the first or after the last word
    pkHesitation = "hesitation" ## mid-sentence
    pkSentence = "sentence"     ## after a sentence ends
    pkPhrase = "phrase"         ## at a comma, kept like a sentence's

  Pause* = object
    start*, stop*: int ## the silent frames, [start, stop)
    kind*: PauseKind
    score*: float32    ## sentence-end evidence; > 0 means a sentence ended
    why*: string       ## what decided `kind`
    cutA*, cutB*: int  ## frames removed once margins apply; none if cutA >= cutB
    seam*: float32     ## visual difference between the frames the cut joins
    note*: string      ## why less than planned, or nothing, was cut

  Cue* = object
    start*, stop*: float64 ## timebase frames
    text*: string

  HesitationConfig* = object
    thresholdDb*: float32 = NaN ## RMS level of silence; NaN derives it
    minPause*: int              ## frames; shorter silences are ignored
    sentencePause*: int = -1    ## frames a sentence-end pause keeps; < 0 all
    seam*: float32 = 0.04       ## most visual difference a cut may join
    prosody*: bool = true       ## judge sentence ends by the voice
    commas*: bool = true        ## keep a pause at a transcript's comma
    startMargin*, endMargin*: int ## frames `--margin` keeps around speech
    fps*: float64 = 30

  Prosody* = object
    ## The speech frames, as `analyze/speech` measures them.
    rms*, f0*, clarity*: seq[float32]

  Thumbs* = object
    ## Per-frame luma thumbnails, `size` bytes each. Empty when there's no video.
    data*: seq[uint8]
    size*: int

func frames*(t: Thumbs): int =
  if t.size == 0: 0 else: t.data.len div t.size

# --- Statistics ---------------------------------------------------------------

func percentile(xs: openArray[float32], p: float): float32 =
  if xs.len == 0: return 0
  var s = @xs
  s.sort()
  s[clamp(int(round(p * float(s.high))), 0, s.high)]

func median(xs: openArray[float32]): float32 = percentile(xs, 0.5)

func semitones(hz: float32): float32 = 12'f32 * log2(hz / 100'f32)

func stddev(xs: openArray[float32]): float32 =
  if xs.len < 2: return 0
  var mean = 0'f32
  for x in xs: mean += x
  mean /= xs.len.float32
  var v = 0'f32
  for x in xs: v += (x - mean) * (x - mean)
  sqrt(v / xs.len.float32)

# --- Speech and silence -------------------------------------------------------

func autoThresholdDb*(rms: openArray[float32]): float32 =
  ## The RMS level that separates speech from the room: 30% of the way from
  ## the noise floor (5th percentile, no lower than -80 dBFS so digital silence
  ## doesn't drag it down) to the speech level (95th percentile).
  let floor = max(percentile(rms, 0.05), -80'f32)
  let peak = max(percentile(rms, 0.95), floor)
  let span = peak - floor
  if span < 18:
    return floor + span * 0.5
  clamp(floor + 0.3'f32 * span, floor + 6, peak - 12)

func isVoiced(p: Prosody, i: int): bool =
  p.f0[i] > 0 and p.clarity[i] >= 0.5

proc speechMask*(p: Prosody, thresholdDb: float32, fps: float64): seq[bool] =
  ## Which frames hold speech. Silences shorter than a stop consonant's
  ## closure are filled in, and sounds with no voicing at all (breaths, lip
  ## smacks, clicks, a chair) don't count as speech.
  let n = p.rms.len
  result = newSeq[bool](n)
  for i in 0 ..< n:
    result[i] = p.rms[i] > thresholdDb

  let hole = max(1, int(round(0.1 * fps)))
  var i = 0
  while i < n:
    if result[i]:
      inc i
      continue
    var j = i
    while j < n and not result[j]: inc j
    if i > 0 and j < n and j - i < hole:
      for k in i ..< j: result[k] = true
    i = j

  let longest = int(round(1.0 * fps))
  i = 0
  while i < n:
    if not result[i]:
      inc i
      continue
    var j = i
    var voiced = 0
    while j < n and result[j]:
      if p.isVoiced(j): inc voiced
      inc j
    if voiced < 2 and j - i < longest:
      for k in i ..< j: result[k] = false
    i = j

func findPauses*(speech: openArray[bool], minPause: int): seq[Pause] =
  ## Every run of silence at least `minPause` frames long. Silence before the
  ## first or after the last word is an edge, whatever its length.
  let n = speech.len
  var i = 0
  var sawSpeech = false
  while i < n:
    if speech[i]:
      sawSpeech = true
      inc i
      continue
    var j = i
    while j < n and not speech[j]: inc j
    if not sawSpeech or j == n:
      if sawSpeech or j < n: # a file with no speech has no pauses to judge
        result.add Pause(start: i, stop: j, kind: pkEdge, why: "no speech on one side")
    elif j - i >= minPause:
      result.add Pause(start: i, stop: j, kind: pkHesitation)
    i = j

# --- Did a sentence end? ------------------------------------------------------

type Boundary* = enum
  bNone = "no break"
  bPhrase = "phrase"
  bSentence = "sentence"

const closers = ["\"", "'", ")", "]", "}", "»", "”", "’", "」", "』", "*"]
const terminators = [".", "!", "?", "。", "！", "？", "؟", "।", "‼", "⁇", "⁈", "⁉"]
const separators = [",", ";", ":", "—", "–", "，", "、", "；", "：", "،"]

func trimClosers(s: string): string =
  result = unicode.strip(s)
  var changed = true
  while changed and result.len > 0:
    changed = false
    for c in closers:
      if result.endsWith(c):
        result = unicode.strip(result[0 ..< result.len - c.len])
        changed = true

func boundaryAtEnd*(text: string): Boundary =
  ## How `text` ends: a sentence, a phrase (a comma or the like), or neither.
  ## An ellipsis trails off, so it's neither.
  let t = trimClosers(text)
  if t.endsWith("...") or t.endsWith("…"):
    return bNone
  for term in terminators:
    if t.endsWith(term):
      return bSentence
  for sep in separators:
    if t.endsWith(sep):
      return bPhrase

func endsSentence*(text: string): bool = boundaryAtEnd(text) == bSentence

func boundaryNear(text: string, at: float64, tolerance: float64): Boundary =
  ## The strongest break in `text` near fraction `at` of its length, when time
  ## through a cue is taken to run evenly through its characters.
  let runes = text.toRunes
  for i in 0 ..< runes.len:
    let r = $runes[i]
    let kind =
      if r in terminators: bSentence
      elif r in separators: bPhrase
      else: continue
    # Not an ellipsis, a decimal point or a thousands separator: a break is
    # followed by a space, or ends the text.
    if i + 1 < runes.len and not runes[i + 1].isWhiteSpace and
        $runes[i + 1] notin terminators and $runes[i + 1] notin closers:
      continue
    if r == "." and ((i > 0 and $runes[i - 1] == ".") or
        (i + 1 < runes.len and $runes[i + 1] == ".")):
      continue
    if abs(float64(i + 1) / runes.len.float64 - at) <= tolerance:
      result = max(result, kind)

func lastWords(text: string, count = 4): string =
  let words = unicode.splitWhitespace(unicode.strip(text))
  let tail = words[max(0, words.len - count) .. ^1].join(" ")
  (if words.len > count: "…" & tail else: tail)

func wordsBefore(text: string, at: float64): string =
  ## The last few words before fraction `at` of `text`, then an ellipsis.
  let runes = text.toRunes
  let cut = clamp(int(round(at * runes.len.float64)), 0, runes.len)
  var head = $runes[0 ..< cut]
  # Finish a word the estimate lands inside of.
  var k = cut
  while k < runes.len and not runes[k].isWhiteSpace:
    head.add $runes[k]
    inc k
  lastWords(head) & " …"

type Verdict* = tuple[known: bool, boundary: Boundary, why: string]

func byBreak(text: string): Verdict =
  let quoted = lastWords(text)
  case boundaryAtEnd(text)
  of bSentence: (true, bSentence, &"transcript: \"{quoted}\" ends a sentence")
  of bPhrase: (true, bPhrase, &"transcript: \"{quoted}\" ends a phrase")
  of bNone: (true, bNone, &"transcript: \"{quoted}\" doesn't end a sentence")

func transcriptVerdict*(cues: openArray[Cue], start, stop: int, fps: float64):
    Verdict =
  ## Whether the transcript ends a sentence at the pause [start, stop). Works
  ## with a cue per word (`whisper --split-words`) or per phrase, sorted by
  ## start. Unknown when no cue is near the pause.
  let (s, e) = (start.float64, stop.float64)

  # Transcribers time words loosely, so rather than trust which cue starts
  # before the pause, find the break between cues that lines up with it best.
  # `fit` is how much they overlap, or minus how far apart they are.
  var best = -1
  var bestFit = -Inf
  for k in 0 ..< cues.len:
    let a = cues[k].stop
    let b = (if k + 1 < cues.len: cues[k + 1].start else: a)
    let (lo, hi) = (min(a, b), max(a, b))
    # Words the transcript missed would sit in a break much wider than the
    # pause; it can't speak for those.
    if lo < s - 1.0 * fps or hi > e + 1.0 * fps:
      continue
    let fit = min(e, hi) - max(s, lo)
    if fit > bestFit:
      (best, bestFit) = (k, fit)

  if best >= 0 and bestFit >= 0:
    return byBreak(cues[best].text)

  # No break in the pause: a cue holding the words on both sides runs through
  # it. Look for a sentence end in its text near where the pause falls.
  for c in cues:
    let len = c.stop - c.start
    if c.start < s and c.stop > (s + e) / 2 and len > 0:
      let at = clamp((s - c.start) / len, 0, 1)
      let quoted = wordsBefore(c.text, at)
      return case boundaryNear(c.text, at, 0.15)
        of bSentence: (true, bSentence, &"transcript: a sentence ends near \"{quoted}\"")
        of bPhrase: (true, bPhrase, &"transcript: a phrase ends near \"{quoted}\"")
        of bNone: (true, bNone, &"transcript: mid-sentence near \"{quoted}\"")

  if best >= 0 and bestFit >= -0.6 * fps:
    return byBreak(cues[best].text)
  (false, bNone, "")

proc prosodyVerdict*(p: Prosody, speech: openArray[bool], runStart, start: int,
    fps: float64, speakerSt: float32): tuple[score: float32, why: string] =
  ## Sentence-end evidence in the voice just before a pause at `start`, for the
  ## speech that began at `runStart`. Positive when a sentence ended.
  let look = max(runStart, start - int(round(3.0 * fps)))
  var voiced: seq[int]
  for i in look ..< start:
    if speech[i] and p.isVoiced(i):
      voiced.add i
  if voiced.len < 4:
    return (0'f32, "too little voiced speech before it")

  var st = newSeq[float32](voiced.len)
  for k, i in voiced: st[k] = semitones(p.f0[i])

  # Pitch at the end against the pitch of the phrase, in semitones.
  let tailN = max(3, int(round(0.12 * fps)))
  let final = median(st[max(0, st.len - tailN) .. ^1])
  let reference =
    if st.len - tailN >= 4: median(st[0 ..< st.len - tailN])
    else: speakerSt
  let drop = final - reference

  # Voicing held at one pitch right up to the silence is a filled pause
  # ("uhh", "euh", "äh", "ờ") or a syllable dragged out while thinking.
  var heldFrom = voiced.high
  let level = final
  while heldFrom > 0 and voiced[heldFrom] - voiced[heldFrom - 1] <= 2 and
      abs(st[heldFrom - 1] - level) <= 0.8:
    dec heldFrom
  let heldSec =
    if start - voiced[^1] <= 2: float64(voiced[^1] - voiced[heldFrom] + 1) / fps
    else: 0.0

  # How far the voice fades over its last 0.4 seconds. Voiced frames only, so
  # a breath after the last word doesn't pass for a fade.
  var peak = -200'f32
  var ends: seq[float32]
  for i in voiced:
    if i >= voiced[^1] - int(round(0.4 * fps)):
      peak = max(peak, p.rms[i])
      ends.add p.rms[i]
  let endLevel = (if ends.len >= 2: (ends[^1] + ends[^2]) / 2 else: ends[^1])
  let fade = peak - endLevel

  # Falling well below the phrase ends a statement, rising well above it ends
  # a question or a planned phrase; level is neither.
  let pitchCue =
    if drop <= 0: clamp((-drop - 1.5'f32) / 2.5'f32, -0.6'f32, 1'f32)
    else: clamp((drop - 2.5'f32) / 2'f32, -0.6'f32, 1'f32)
  let fadeCue = clamp((fade - 8'f32) / 8'f32, -1'f32, 1'f32) * 0.5'f32
  let heldCue =
    if heldSec >= 0.4: -1'f32
    elif heldSec >= 0.25: -0.5'f32
    else: 0'f32
  let score = pitchCue + fadeCue + heldCue
  var why = &"pitch {drop:+.1f} st, fades {fade.round.int} dB"
  if heldCue < 0:
    why &= &", voice held level {heldSec:.2f}s"
  (score, why)

# --- Where to cut -------------------------------------------------------------

proc planCut*(t: Thumbs, lo, hi, maxLen, center: int, seam: float32):
    tuple[a, b: int, diff: float32, best: float32] =
  ## The longest cut [a, b) inside [lo, hi), at most `maxLen` frames, that
  ## joins frames a - 1 and b looking at most `seam` apart: by the RMS of their
  ## luma difference, 0 to 1, once a uniform brightness change (auto exposure)
  ## is taken out. Among cuts that
  ## long, the one joining the most alike frames, then the one nearest
  ## `center`. `a >= b` when none qualifies; `best` is then the smallest
  ## difference any cut had.
  result = (lo, lo, 0'f32, 1'f32)
  let width = hi - lo
  if width <= 0 or maxLen <= 0:
    return
  if t.frames == 0:
    let len = min(width, maxLen)
    let a = clamp(center - len div 2, lo, hi - len)
    return (a, a + len, 0'f32, 0'f32)

  # The difference is the distance between thumbnails with their mean taken
  # out, so it obeys the triangle inequality: how far two frames each are from
  # a third bounds how alike they can be, which rules out most pairs cheaply.
  let base = lo - 1
  var vecs = newSeq[seq[float32]](hi - base + 1)
  var fromStart = newSeq[float32](hi - base + 1)
  var fromEnd = newSeq[float32](hi - base + 1)
  for k in 0 ..< fromStart.len:
    fromStart[k] = -1
    fromEnd[k] = -1

  proc dist(x, y: int): float32 =
    for f in [x, y]:
      if vecs[f - base].len == 0:
        let off = clamp(f, 0, t.frames - 1) * t.size
        var mean = 0'f32
        for j in 0 ..< t.size: mean += t.data[off + j].float32
        mean /= t.size.float32
        vecs[f - base] = newSeq[float32](t.size)
        for j in 0 ..< t.size: vecs[f - base][j] = t.data[off + j].float32 - mean
    var s = 0'f32
    for j in 0 ..< t.size:
      let d = vecs[x - base][j] - vecs[y - base][j]
      s += d * d
    sqrt(s / t.size.float32) / 255'f32

  proc lowerBound(x, y: int): float32 =
    for f in [x, y]:
      if fromStart[f - base] < 0: fromStart[f - base] = dist(base, f)
      if fromEnd[f - base] < 0: fromEnd[f - base] = dist(hi, f)
    max(abs(fromStart[x - base] - fromStart[y - base]),
      abs(fromEnd[x - base] - fromEnd[y - base]))

  # Differences this small can't be told apart; between them, place the cut.
  const alike = 0.005'f32
  # A long pause has too many cuts to try them all: step through them.
  let step = max(1, (width + 119) div 120)
  var diffs: seq[float32]
  var bound = 2'f32
  var len = min(width, maxLen)
  while len > 0:
    diffs.setLen 0
    var lowest = 2'f32
    var a = lo
    while a + len <= hi:
      let lb = lowerBound(a - 1, a + len)
      if lb > seam + 1e-4:
        bound = min(bound, lb)
        diffs.add 2
      else:
        let d = dist(a - 1, a + len)
        diffs.add d
        lowest = min(lowest, d)
      a += step
    result.best = min(result.best, min(lowest, bound))
    if lowest <= seam:
      let limit = min(seam, lowest + alike)
      var bestA = -1
      for k, d in diffs:
        let a = lo + k * step
        if d <= limit and (bestA < 0 or
            abs(a + len div 2 - center) < abs(bestA + len div 2 - center)):
          bestA = a
      return (bestA, bestA + len, diffs[(bestA - lo) div step], result.best)
    len -= step

# --- All together -------------------------------------------------------------

proc judge*(p: Prosody, thumbs: Thumbs, cues: openArray[Cue],
    cfg: HesitationConfig): tuple[active: seq[bool], pauses: seq[Pause],
    thresholdDb: float32] =
  ## Mark every frame active except the hesitations to cut. Each margin of
  ## `cfg` is the speech `--margin` will add back around the cut, so the frames
  ## left out once it has are exactly a pause's [cutA, cutB).
  let n = p.rms.len
  var cues = @cues
  cues.sort(proc (a, b: Cue): int = cmp(a.start, b.start))
  let thr = (if cfg.thresholdDb.isNaN: autoThresholdDb(p.rms) else: cfg.thresholdDb)
  let speech = speechMask(p, thr, cfg.fps)
  var pauses = findPauses(speech, max(1, cfg.minPause))

  var all: seq[float32]
  for i in 0 ..< n:
    if speech[i] and p.isVoiced(i): all.add semitones(p.f0[i])
  let speakerSt = (if all.len > 0: median(all) else: 0'f32)

  let em = max(0, cfg.endMargin)
  let sm = max(0, cfg.startMargin)
  var active = newSeq[bool](n)
  for i in 0 ..< n: active[i] = true

  var runStart = 0
  for pause in pauses.mitems:
    let (s, e) = (pause.start, pause.stop)
    if pause.kind == pkEdge:
      for i in s ..< e: active[i] = false
      (pause.cutA, pause.cutB) = (s, e)
      runStart = e
      continue

    let verdict = transcriptVerdict(cues, s, e, cfg.fps)
    if verdict.known:
      pause.kind =
        case verdict.boundary
        of bSentence: pkSentence
        of bPhrase: (if cfg.commas: pkPhrase else: pkHesitation)
        of bNone: pkHesitation
      pause.score = (if pause.kind == pkHesitation: -1'f32 else: 1'f32)
      pause.why = verdict.why
    elif cfg.prosody:
      let (score, why) = prosodyVerdict(p, speech, runStart, s, cfg.fps, speakerSt)
      pause.kind = (if score > 0: pkSentence else: pkHesitation)
      pause.score = score
      pause.why = why
    else:
      pause.kind = pkHesitation
      pause.why = "every pause counts"
    runStart = e

    # Margins keep [s, s + em) and [e - sm, e); the cut fits between.
    let (lo, hi) = (s + em, e - sm)
    var maxLen = hi - lo
    if pause.kind in {pkSentence, pkPhrase}:
      if cfg.sentencePause < 0 or e - s <= cfg.sentencePause:
        continue
      maxLen = min(maxLen, e - s - cfg.sentencePause)
    if maxLen <= 0:
      pause.note = "margins keep all of it"
      continue

    let center = (lo + hi) div 2
    let plan = planCut(thumbs, lo, hi, maxLen, center, cfg.seam)
    if plan.a >= plan.b:
      pause.note = &"kept: a cut would show a jump (frames differ {plan.best:.3f})"
      pause.seam = plan.best
      continue
    (pause.cutA, pause.cutB, pause.seam) = (plan.a, plan.b, plan.diff)
    if plan.b - plan.a < maxLen:
      pause.note = &"cut shortened to where frames match"
    for i in plan.a - em ..< plan.b + sm:
      active[i] = false

  (active, pauses, thr)
