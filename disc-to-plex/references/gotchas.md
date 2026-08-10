# Gotchas — read before debugging a failed encode

These are the non-obvious failure modes hit while building this pipeline. Each cost a batch
re-run to diagnose; the fixes are baked into `scripts/transcode.ps1`.

## Driver / ffmpeg pairing (NVENC won't open)

`Driver does not support the required nvenc API version` — the ffmpeg build is newer than the
installed NVIDIA driver. A ~59x driver supports the NVENC SDK that **ffmpeg 7.x** targets, not
ffmpeg 9.x/master. Use the BtbN **n7.1** win64 build (what `install-tools.ps1` fetches). The
GPU/driver themselves are fine — HandBrake's bundled NVENC keeps working; it's only a
standalone-ffmpeg version mismatch.

## m2ts audio streams are double-counted by ffprobe

On MPEG-TS/m2ts, `ffprobe -select_streams a -show_entries stream=index` lists each audio stream
**twice** and emits a blank line (e.g. `1,2,,1,2`). A naive count gives 2× and produces an
invalid `-map 0:a:N`. Count **distinct numeric** indices:
`... | Where-Object {$_ -match '^\d+$'} | Sort-Object -Unique | Measure`. DVD VOB does not
double-count.

## No-audio titles

Textless material, some behind-the-scenes reels, and image galleries can have **zero** audio.
The audio-map loop must be skipped entirely — mapping `0:a:0` on a source with no audio fails
with "matches no streams" (a 0-second failure). Map video (and subs) only.

## Phantom/corrupt audio stream (menu artifacts)

Some tiny DVD titles carry an AC3 stream with `sample_rate=0, channels=0`. The AAC encoder then
dies with "sample rate not set", and even passthru fails. These are menu/navigation artifacts —
**exclude them** (see `identification.md`), don't try to encode them.

## dvdvideo read errors truncate silently — ALWAYS verify output duration

libdvdnav can hit a bad/unreadable block mid-title and stop: the log shows
`dvdnav error (...): Error reading NAV packet` / `Unable to read next block of PGC`,
ffmpeg ends the demux there, and `transcode.ps1` still prints `OK` because the
(partial) output exists. Result: a film/episode silently **cut short** (e.g. a
119-min feature encoded to 101 min when cell 12 wouldn't read). This is a disc/rip
read snag on THAT disc — NOT a reason to abandon the dvdvideo path, which is correct
for clean discs.

**Defence: verify every output's duration against the expected length** —
`mymovies.xml` `<RunningTime>` (minutes) or the per-title `Minutes/Seconds`, or the
MakeMKV title length. If the output is materially shorter, the rip read-errored.
**Fall back to MakeMKV for that disc** (`makemkvcon64.exe … mkv "file:<parent>" all
<out>`) — its demuxer tolerates the bad block and recovers the full title; then
transcode with `kind:"MKV"`. (`mymovies.xml`, present on these rips, is also the best
per-disc source for the episode↔title map and extras names.)

## dvdvideo demuxer truncates multi-cell titles (looks like missing episodes)

`ffmpeg -f dvdvideo -title N` reads only the **first cell/PGC** of a title. When a DVD authors an
episode as 2+ cells — e.g. a ~20 s TIMESLIP title-sequence cell followed by the ~24 min episode body
— `ffprobe -f dvdvideo` reports the title as **20 seconds**, and an encode would ship a 20-second
"episode". This is what made two complete Timeslip episodes look *missing / partial* (a mid-story
"gap" and a "10-minute colour fragment") when the disc was in fact complete. `scan-disc.ps1`
enumerates via the same demuxer, so it inherits the bug: multi-cell episodes surface as tiny
stub/REVIEW titles and the episode count comes out short.

**Never conclude episodes are missing from a low title count.** Cross-check two authoritative sources:
- **The disc's own EPISODE INDEX menu** — render it from the menu domain:
  `ffmpeg -f dvdvideo -menu 1 -menu_vts 0 -pgc <N> -i <disc> -frames:v 1 out.png` (sweep `-pgc 1..6`;
  one PGC is the index and lists every episode). Flat `-ss` into `VIDEO_TS.VOB` only reaches some
  menu cells, so use the menu domain. `-menu 1` requires a non-zero `-pgc`.
- **MakeMKV**, which parses cells correctly: `makemkvcon64.exe -r --cache=1 info "file:<VIDEO_TS
  parent>"` → `TCOUNT` + `Title #N was added (K cell(s), H:MM:SS)`. A **2-cell** title of full episode
  length is exactly the case the dvdvideo demuxer truncates.

**Fix / extraction:** for such a disc, don't use the `DVD` path. **Rip the episode titles with
MakeMKV** (`makemkvcon64.exe -r --minlength=1200 mkv "file:<parent>" all <outdir>` — lossless), then
transcode with `kind:"MKV"` (see transcode.ps1; same SD deinterlace + DAR treatment as DVD, file
input). Run MakeMKV **one disc at a time in the foreground** — back-to-back/background invocations of
`makemkvcon` silently produce 0 files. See `pipelines.md` and `identification.md`.

## Silent extras drop — the episode-length filter is not a classifier

A build shortcut that auto-selected titles by an absolute duration window (e.g. "keep 2000–3600 s
titles as episodes") shipped once and **silently discarded every other title** — including any real
featurette/documentary — with no report and no failure. It happened to be safe on that show (the
only sub-episode title was a copyright reel), but on the next disc it would have thrown away genuine
bonus content that can't be re-derived. Two things went wrong: the window doubles as the artifact
filter (so anything outside it just vanishes), and nothing forced a human to look at what was
dropped.

**Rule: account for every real title.** Enumerate the whole disc with `scripts/scan-disc.ps1`
(cross-disc-aware) and classify each title EPISODE / PLAYALL / extra / boilerplate / artifact. Every
non-artifact title must become an episode, a `Season 00` extra, or an *identified* exclusion
(boilerplate: a short title whose exact duration repeats across ≥3 discs — a copyright/anti-piracy
or promo reel, e.g. the 273.000 s Warner "SCHWEIZ" warning on the West Wing DVDs). Never let a title
disappear because it fell outside an episode-length window. When unsure what a title is, extract a
frame and look. See `identification.md` → "Extras → Season 00".

## DVD aspect: never hard-code 4:3 (16:9 extras get squished)

A DVD's main feature may be 4:3 while its **extras/featurettes are 16:9 anamorphic** (modern
interviews, making-ofs). Forcing `-aspect 4:3` (or `setsar=16/15`) on a 16:9 source squishes it
horizontally — faces look too narrow/tall. This shipped once on three Prisoner featurettes.
**Fix:** read each source's `display_aspect_ratio` and pass `-aspect <that>`; add no `setsar`.
`transcode.ps1`'s `Get-DAR` does this. Verify outputs with
`ffprobe -select_streams v:0 -show_entries stream=display_aspect_ratio`.

## PGS subtitles drift when you crop

Cropping the video without moving the PGS canvas leaves subtitles offset (or distorted,
player-dependent). Reposition with SupMover — see `pipelines.md`. Symptom if skipped: subtitles
shifted toward one side on the cropped frame.

## Mangled UNC target — copy silently lands on a local drive

Staging to a NAS with a UNC target (`\\NAS\share\...`) can go wrong before the script even runs:
if the path is passed through a **bash/POSIX shell**, `\\` collapses to `\`, so `\\NAS\share`
becomes `\NAS\share`. robocopy then treats that single-backslash path as **relative to the current
drive** and copies to `D:\NAS\share\...` locally. The byte-verify passes too — it checks that same
wrong local folder — so a broken stage looks VERIFIED and (worse) could gate a delete. Nothing
reaches the NAS.

**Avoid it:** pass Windows UNC/backslash paths via the **PowerShell tool**, not the bash tool
(bash eats one backslash). `stage-and-clean.ps1` now hard-aborts when `$Target` starts with a single
backslash, and warns when the target resolves onto the source's own volume. Also: run long background
jobs with the tool's own backgrounding (`run_in_background`) — a PowerShell `Start-Job` dies when the
tool's shell session ends between calls, so its log never appears.

## Operational

- **`-stats` spam**: ffmpeg writes ~1 progress line/second; a long encode log is thousands of
  lines. Monitor by grepping `OK|FAILED|DONE`, never by reading the whole file.
- **Source-drive contention**: probing/extracting frames from the same physical drive an encode
  is reading roughly halves its speed. Do all inspection before starting the batch.
- **Resumability**: `transcode.ps1` skips outputs that already exist >5 MB. After fixing a bug,
  just re-run the same manifest — only the failed/missing items redo. Delete broken partials
  (<5 MB) first so they aren't mistaken for complete.
- **Laptop thermals**: sustained NVENC shares a power/thermal budget with the CPU; per-title
  encode times vary widely. Normal, not a fault.
