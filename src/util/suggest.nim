when not defined(emscripten) and not defined(nimscript):
  import std/[editdistance]

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

    # Within 3 edits, or a third of a long input, and never a word that's
    # mostly different: "foo" is 2 edits from "or", but nothing like it.
    let limit = max(3, input.len div 3)
    if bestDist <= limit and bestDist * 2 <= max(input.len, best.len):
      "\nDid you mean " & best & "?"
    else: ""
