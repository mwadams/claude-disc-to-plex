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
