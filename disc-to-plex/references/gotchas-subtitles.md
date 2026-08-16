# Subtitle gotchas

Track selection, wrong language tags, bitmap subs and OCR.

Part of the `disc-to-plex` gotchas set — see [gotchas.md](gotchas.md) for the full index.

## Contents

- [Subtitle order is arbitrary — select English by TAG, never by position](#subtitle-order-is-arbitrary-select-english-by-tag-never-by-position)
- [PGS subtitles drift when you crop](#pgs-subtitles-drift-when-you-crop)
- [A disc's subtitle LANGUAGE TAG can simply be wrong — verify by rendering a cue](#a-discs-subtitle-language-tag-can-simply-be-wrong-verify-by-rendering-a-cue)
- [Bitmap subtitles look oversized and blocky, and no Plex setting fixes it](#bitmap-subtitles-look-oversized-and-blocky-and-no-plex-setting-fixes-it)

## Subtitle order is arbitrary — select English by TAG, never by position

A DVD's subtitle order means nothing. It is often simply **alphabetical**: a Boston Legal set
exposes `dan, eng, fin, nor, swe`, putting English at ordinal **1**. The habitual `subTrack: 0`
would have burned a whole season with Danish subtitles, and nothing in the encode log or the
output file would have looked wrong — you would find out from Plex, or not at all.

Do not try to infer the ordering from the release's apparent market; just read the tags:

```
ffprobe -v error -f dvdvideo -title 1 -i <stage> -select_streams s \
        -show_entries stream=index:stream_tags=language -of csv=p=0
```

`transcode.ps1` accepts a language tag directly — `"subTrack": "eng"` — and resolves it per item,
printing the ordinal it picked (`subTrack 'eng' -> s:1`). Prefer that to an ordinal: an index that
is right on one disc of a set is not guaranteed right on the next. If the tag is missing the script
warns and falls back to `s:0` rather than silently continuing.

## PGS subtitles drift when you crop

Cropping the video without moving the PGS canvas leaves subtitles offset (or distorted,
player-dependent). Reposition with SupMover — see `pipelines.md`. Symptom if skipped: subtitles
shifted toward one side on the cropped frame.

## A disc's subtitle LANGUAGE TAG can simply be wrong — verify by rendering a cue

`To Serve Them All My Days` (1980) exposes exactly one subtitle stream, tagged `eng`. It is
**Dutch**. Selecting it by tag — the rule everywhere else in this skill — therefore produced 13
episodes offering Plex an "English" subtitle that displays Dutch, and an OCR pass that ran an
English model over Dutch text and returned gibberish (7-8 unreadable cues per 51-minute episode).

Nothing structural catches this: the tag is present and well-formed, the stream decodes, and the
cue count is the only hint — and only because a wrong-language OCR fails badly.

**When an OCR pass fails on a disc whose subtitles clearly exist, look at the picture before
blaming the engine.** Burn a cue onto a frame:

```
ffmpeg -ss <t> -i file.mkv -filter_complex "[0:v][0:s:0]overlay" -frames:v 1 out.png
```

Sample two or three cues from different episodes. If the text is another language, retag the
stream (`-metadata:s:s:0 language=dut`, stream copy) rather than shipping it as English — and
record that the show has no English subtitles instead of retrying the OCR.

## Bitmap subtitles look oversized and blocky, and no Plex setting fixes it

Disc subtitles are **bitmaps** — PGS on Blu-ray, VOBSUB on DVD — i.e. pictures of text rendered at
a fixed size by the disc author. Plex's subtitle size, font, colour and position settings apply
**only to text subtitles** (SRT/ASS). For a bitmap the player can do nothing except scale the
image, so users see big, soft, blocky captions and there is no client-side remedy.

DVD is the bad case: VOBSUB is 720x576 with a 4-colour palette, so on a 1080p or 4K screen it is
being upscaled 3–5x.

Fix: OCR to SRT (`scripts/ocr-subtitles.ps1`), ship the SRT default-flagged, and **keep** the
bitmap track as a fallback.

### Toolchain traps found the hard way

- **ffmpeg cannot write VOBSUB.** There is no `vobsub` muxer in the BtbN build (`-f vobsub` →
  "Requested output format 'vobsub' is not known"; a bare `.idx` output → "Unable to choose an
  output format"). Use `mkvextract tracks <file> <id>:<out>.idx`, which writes the `.idx`/`.sub`
  pair correctly. PGS is different — ffmpeg *does* have a `sup` muxer.
- **`seconv` cannot read VOBSUB out of an MKV.** It reports "No subtitle tracks in Matroska file"
  even when ffprobe clearly lists a `dvd_subtitle` stream. Extract first, then convert.
- **Tesseract cannot be installed unattended.** Its installer requires UAC elevation, so winget
  from a non-interactive shell fails with `0x800704c7` ("The operation was canceled by the user").
  It has to be a manual, elevated step by the user.
- **Do NOT substitute Subtitle Edit's built-in `nOCR` engine to avoid installing Tesseract.**
  Tried on a real DVD: it returned `*` for all 315 cues — the disc fonts are not in its pattern
  database — while `seconv` still printed "Conversion completed successfully". The only thing that
  catches this is inspecting the output, which is why `ocr-subtitles.ps1` gates on cue count and
  the proportion of one-to-two-character cues.
- Check you have the right file before concluding a track is missing: two different films can both
  contain `Featurette 03.mkv`. A "stream map matches no streams" error was just the wrong path.
- **`seconv` can report "Tesseract not found on PATH" when tesseract demonstrably works.** The
  installer updates the *machine* PATH, but an already-running shell keeps the copy it inherited at
  launch, and seconv resolves tesseract from its child process's PATH. So `tesseract --version`
  succeeds in your shell while seconv still fails. Prepend the tesseract directory to `$env:PATH`
  before invoking seconv (`ocr-subtitles.ps1` does this), or start a fresh shell.
- **`-map 0 -map 1` puts the new SRT LAST, so `-disposition:s:0` flags the BITMAP.** The remux
  succeeds, ffprobe reports no error, and a size check passes — the only symptom is that Plex
  still defaults to the blocky bitmap, i.e. the exact problem the OCR pass exists to solve. Caught
  on the first `-Mode Mux` run (Stardust): output was `dvd_subtitle default=1` / `subrip
  default=0`. Index the disposition and language off the **source's subtitle-stream count**, clear
  `default` on the originals, and assert afterwards that exactly one `subrip` track is default and
  no bitmap is. Sidecar mode never had the bug, so a library retro-fit done that way is unaffected.
  Repairing a mis-flagged file needs only a disposition remux, not a re-OCR.
- **OCR is slow — budget for it.** Measured: 315 VOBSUB images took **4m 46s** with Tesseract on an
  RTX 4060 laptop (it is CPU-bound; the GPU is irrelevant). A feature-length film runs 800–1500
  cues, so 10–25 minutes *per file*. A whole-library retro-fit is days of wall-clock, not hours —
  size the batches accordingly and run them when the encode lanes are otherwise idle.

