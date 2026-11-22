# 31.8.1

## Major
 -

## Features
 - Import Final Cut Pro XML: `.fcpxml` files and `.fcpxmld` bundles, with connected clips, transitions, speed, and volume. What a timeline can't hold, such as compound clips, is left out with a warning.
 - Every transition in Premiere Pro, from `push` and `clock-wipe` to `glitch` and `page-peel`, plus its Legacy folder (`iris-round`, `barn-doors`, `push-legacy`, …) and the `constant-power` and `exponential-fade` audio crossfades: `--transition push:0.5sec`. They render natively, and `premiere-otio` exports them as Premiere's own transitions. FCP7 XML carries the dips and `wipe`; other editor exports dissolve instead.
 - Speed ramps: `speed` and `varispeed` take keyframes spread across a section's source, such as `speed:1..8:ease=in` or `speed:1@0%..6@50%..1`. Final Cut Pro and DaVinci Resolve (FCPXML) keep the ramp both ways, including ramps made with Final Cut Pro's Retime menu. Premiere, Shotcut and Kdenlive play the section at the ramp's mean speed.
 - FCP7 XML import brings in Color mattes and Slugs as solid clips, and reads a time remap graph as a speed ramp.

## Performance
 - A source that plays in two places at once, as across a dissolve or as a picture-in-picture or `loop` overlay of the same file, gets its own decoder for each instead of seeking back to a keyframe every frame. An edit with 1-second dissolves renders 2.5× faster, and a same-file overlay up to 40× faster.
 - Rendering no longer slows down quadratically with the number of clips: 160,000 one-frame clips render in 1.6 seconds instead of 58.
 - Importing FCP7 XML uses about 10% less memory.
 - `blackdetect` is 3.2× faster and `motion` 1.6× faster. Both now read a frame's true luma instead of a gray recomputed through RGB, so `motion` values run about 8% lower and `blackdetect` can shift a few frames at the end of a fade.
 - On 64-bit Linux, partial-lossless renders reuse x264's memory instead of faulting it in again for each re-encoded stretch: a 10-minute 720p edit renders 18% faster without audio, at about 90 MB more peak memory.
 - `--cut-out`, `--add-in`, `--set-speed`, `--set-action` and `--edit none` no longer read every video packet to find a file's length: 1.7s to 0.14s on a 42-minute mp4.

## Fixes
 - Rendering to an input's own path (`-o talk.mp4` for `talk.mp4`) stops with an error instead of truncating the input before reading it.
 - `.m4a` and `.m4b` outputs are audio only, like `.mp3` and `.wav`, instead of getting an H.264 track: `-o talk.m4a` from a video is 2.7× faster and a third smaller.
 - FCP7 XML import plays each audio track from the right stream of a multi-stream source, instead of the first stream for all of them, and keeps a mono source mono.
 - FCP7 XML import skips disabled clips, no longer turns Premiere's untouched opacity into an effect on every clip, and warns about the titles and nested sequences it leaves out. It is no longer experimental.
 - FCP7 XML export writes Premiere's exact source times (`pproTicksIn`/`pproTicksOut`), and import reads them, so clips at fractional speeds keep their in points. Reversed and freeze-frame clips are reported instead of silently playing forward.

# Misc.
 -
