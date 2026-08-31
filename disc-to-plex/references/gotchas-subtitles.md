# Subtitle gotchas

Track selection, wrong language tags, bitmap subs and OCR.

Part of the `disc-to-plex` gotchas set — see [gotchas.md](gotchas.md) for the full index.

## Contents

- [Subtitle order is arbitrary — select English by TAG, never by position](#subtitle-order-is-arbitrary-select-english-by-tag-never-by-position)
- [PGS subtitles drift when you crop](#pgs-subtitles-drift-when-you-crop)
- [A disc's subtitle LANGUAGE TAG can simply be wrong — verify by rendering a cue](#a-discs-subtitle-language-tag-can-simply-be-wrong-verify-by-rendering-a-cue)
- [Bitmap subtitles look oversized and blocky, and no Plex setting fixes it](#bitmap-subtitles-look-oversized-and-blocky-and-no-plex-setting-fixes-it)
- [Appending subtitle tracks ALONE makes the drift accumulate — re-time from the chapter marks](#appending-subtitle-tracks-alone-makes-the-drift-accumulate--re-time-from-the-chapter-marks)
- [SOURCING: OCR the disc, do not download — a wash-up](#sourcing-ocr-the-disc-do-not-download--a-wash-up)

## SOURCING: OCR the disc, do not download — a wash-up

**Decided 2026-08-17, after auditing a completed download pass. Roughly one
subtitle in five was the wrong programme.**

A library-wide pass downloaded 2,681 English SRTs through Plex's OpenSubtitles
provider, guarded on title similarity, episode number and runtime coverage. An
audit found **~570 of them wrong** and removed them:

| What was in the library | What it actually was |
|---|---|
| Grange Hill (110 episodes) | King of the Hill |
| Danger Man (51) | Henry Danger |
| Public Eye (37) | Queer Eye, Private Eyes, Blue Heelers, Walker Texas Ranger |
| Special Branch (24) | Special Ops |
| Ace of Wands (20) | Record of Ragnarok, Blood of Zeus, Elena of Avalor |
| Man in a Suitcase (14) | The Man in the High Castle |
| Lord Peter Wimsey (8) | Drug Lords (Pablo Escobar) |
| Behind the Planet of the Apes | Dawn of the Planet of the Apes |

Every one matched an episode number and a plausible runtime, and nothing else.

### Why guard-tuning cannot fix this

The scores of the wrong matches and the right ones **overlap**, so no threshold
separates them:

| | score |
|---|---|
| Grange Hill ← King of the Hill | 0.50 |
| Danger Man ← Henry Danger | 0.50 |
| Public Eye ← Queer Eye | 0.50 |
| *Star Trek: DS9 ← Star.Trek.DS9* (**correct**) | 0.40 |
| *The Killing ← Forbrydelsen* (**correct**) | 0.00 |

Nearly every wrong match shares exactly one word of two. Meanwhile a correct
match can share none at all, because *Forbrydelsen* is the original title of
*The Killing*. A threshold that blocks all the known-wrong also throws away
DS9, Buffy and The Killing.

### Three traps that made the wrong ones look right

1. **An exact `SxxEyy` is not identity.** It was allowed to satisfy the title
   guard on its own, so any show with the same episode number and a believable
   runtime got in. That single allowance caused most of the 570.
2. **Resyncing renamed the evidence away.** The aligner titled its output
   `<library label> (synced)`, so a wrong-show subtitle then appeared in Plex
   as a correctly-named English SRT. `Public Eye S5E1 A Mug Named Frank
   (synced)` contained Queer Eye. Fixed — output now keeps the source name.
3. **A restored backup can still be wrong.** Rolling a bad *shift* back
   restores the original subtitle faithfully, including when the original was
   the wrong *programme*. Two restores were themselves wrong shows.

### What to do instead

**OCR the disc's own VOBSUB/PGS** with `scripts/ocr-subtitles.ps1`. A disc's
subtitle cannot be the wrong programme, cannot be timed to a different cut, and
is already in sync — which removes wrong-show, wrong-cut and alignment as
categories, along with the provider quota and any reliance on ffsubsync.

If a subtitle must be downloaded anyway, **verify it by reading its dialogue**
against something that identifies the episode. That is the only check that
worked: it saved DS9, Buffy, The Avengers, Studio 60 and The Killing, all of
which score badly on name and would have been deleted by a name-based sweep.

### Alignment, if you ever need it again

- ffsubsync reports failure by returning a value **pinned to its search bound**.
  Two failed anchors both railed at `-14.99` *agree perfectly*, and were
  accepted as corroboration — applying `+37.6s` to one episode on no evidence.
  Reject any anchor within a margin of the bound before comparing them.
- To judge sync, measure the error at **two landmarks pinned in the video** by
  frame-scanning. Both near zero = correct; both off by the same amount = a
  fixable shift; **errors that differ = the subtitle is for a different cut**,
  and no shift or scale will ever fix it.

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

## Appending subtitle tracks ALONE makes the drift accumulate — re-time from the chapter marks

**A part contributes as much timeline as its LAST CUE, not as much as its video.** So the moment
you append subtitle-only files, every part after the first lands early, and the deficit is
*cumulative*. This is not a constant offset that a delay can fix.

Found on **Mugaritz Experiences (2011)** (2026-08-31), a Spanish cookery DVD shipped as one film of
61 named chapters built from 61 separately-encoded parts. Chapter 1 (the sponsor reel) has no
subtitles on the disc, and appending a file that lacks a track is awkward — so the 60 recipe parts'
subtitle tracks were appended *on their own* and the result merged back delayed by chapter 2's
start. That delay was correct, and chapter 2 checked out perfectly, which is exactly why it
shipped. What actually happened:

| | |
|---|---|
| chapter 2 | correct — first cue at 70.207 + 0.560 = **70.767**, matching the index |
| chapter 29 (*Black Quinoa – Praline*) | on screen: the **Kaolin + Lactose** ingredient panel, i.e. chapters **44–45's** |
| chapters 44–61 | **no subtitles at all** — the track ended at 4415.8 s against a 6339.7 s film |

Nothing was lost, only mistimed: broken and rebuilt tracks hold the same 460 cues and the same
2,177,024 bytes of subpicture data. **A truncated track is the visible end of a drift**, not a
separate fault — if the subtitles stop early, suspect the accumulation before you suspect the rip.

### Why it survives every structural check

Cue count is right. Byte total is right. Duration, chapter count and chapter names are right. The
first chapter after the join is right, because the drift has not accumulated yet. A spot-check of
"do subtitles appear near the start" passes. Only a **per-chapter cue census** or a rendered frame
from *late* in the film shows it.

### The fix: re-time from the chapter marks, do not re-append

The chapter marks are the real append joins, and the part durations sum to them (within 1 ms), so
they are the authoritative per-part offsets. VOBSUB is trivially re-assemblable — the `.sub` is
2 KB-sector-aligned MPEG-PS and the `.idx` is a text index of `timestamp:`/`filepos:` pairs:

1. `mkvextract tracks p<NN>.mkv <id>:s<NN>.idx` for each part (ffmpeg cannot write VOBSUB — see
   the toolchain traps below).
2. Concatenate the `.sub` payloads; for each part add its **chapter start** to every timestamp and
   its byte offset in the concatenation to every `filepos`.
3. `mkvmerge -o out.mkv --no-subtitles <film>.mkv --language 0:eng --track-name 0:English merged.idx`
   — video, audio and chapters are untouched (verify: byte counts, frame counts, chapter marks all
   identical), and `mkvpropedit --edit track:s1 --set flag-default=0` restores the flag mkvmerge
   sets on a fresh track.

**Verify by reading the picture, not by whether OCR's score improves** — the score cannot see
timing at all. It re-ran on the rebuilt Mugaritz file at exactly the same 70.4%, because the
bitmaps had not changed. What proved the rebuild was: every recipe chapter opening with a cue at
exactly +0.560 s, no cue crossing a chapter boundary, all 460 cue times matching the source parts
(max delta 0.0000 s), and the title cards rendered at chapters 29/44/56/61 reading
*Praline* / *Moss…* / *Candy* / *Ice cream* — matching the names independently proved from the
disc's own DVD-VM navigation commands.

### Check for it whenever a unit is assembled from parts

Cheap census, no re-encode:

```powershell
# every chapter after the first should hold cues, and none should start suspiciously late
$f = '<film>.mkv'
$ch = & $ffprobe -v error -show_chapters -print_format json $f | ConvertFrom-Json
$t  = @(& $ffprobe -v error -select_streams s:0 -show_entries packet=pts_time -of csv=p=0 $f) |
        ForEach-Object { [double]$_ }
foreach ($c in $ch.chapters) {
  $a = [double]$c.start_time; $b = [double]$c.end_time
  $n = @($t | Where-Object { $_ -ge $a -and $_ -lt $b }).Count
  '{0,-46} {1,8:N2} cues={2}' -f $c.tags.title, $a, $n
}
```

A run of trailing chapters with `cues=0`, or a first-cue offset that grows chapter by chapter, is
this bug.

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

