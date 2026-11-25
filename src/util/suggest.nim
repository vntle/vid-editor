when not defined(emscripten) and not defined(nimscript):
  import std/[editdistance, os, strutils]

func didYouMean*(input: string, choices: openArray[string]): string =
  when defined(emscripten) or defined(nimscript):
    ""
  else:
    var best = ""
    var bestDist = high(int)
    for choice in choices:
      let dist = editDistance(input, choice)
      if dist < bestDist:
        best = choice
        bestDist = dist

    if best == "" or bestDist == 0:
      return ""

    let limit = max(3, input.len div 3)
    if bestDist <= limit: "\nDid you mean " & best & "?"
    else: ""

proc similarFile*(path: string): string {.raises: [].} =
  ## For a `path` that doesn't exist, a "Did you mean" line naming the file in
  ## its directory whose name is closest, ignoring case, or "" if none is close.
  when defined(emscripten) or defined(nimscript):
    ""
  else:
    let (dir, name, ext) = splitFile(path)
    let given = name & ext
    let want = toLowerAscii(given)
    var best = ""
    var bestDist = high(int)
    try:
      for kind, file in walkDir(if dir == "": "." else: dir, relative = true):
        # A dangling symlink of the very name is no suggestion.
        if kind notin {pcFile, pcLinkToFile} or file == given:
          continue
        let dist = editDistance(want, toLowerAscii(file))
        if dist < bestDist:
          best = file
          bestDist = dist
    except CatchableError:
      return ""

    if best == "" or bestDist > max(3, want.len div 3):
      return ""
    "\nDid you mean " & (if dir == "": best else: dir / best) & "?"
