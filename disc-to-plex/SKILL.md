---
name: disc-to-plex
description: >-
  Transcode ripped Blu-ray (BDMV/m2ts) and DVD (VIDEO_TS/VOB) discs into Plex-ready MKVs
  with NVIDIA NVENC — episodes, movies, and bonus features — then stage them into a Plex
  library layout. Use this whenever the user wants to rip/convert/re-encode discs, box sets,
  or ISOs for Plex/Jellyfin/Emby; mentions HandBrake crashing on a disc; asks about m2ts,
  VOB, BDMV, VIDEO_TS, PGS/VOBSUB subtitles, pillarbox cropping, anamorphic DVD, deinterlacing,
  audio passthrough, or "Season 00" extras; or wants a batch/hands-off conversion of a TV
  series or film collection. Prefer this over ad-hoc ffmpeg for any disc→library job.
---

# Disc → Plex transcoding

Convert disc rips (Blu-ray BDMV or DVD VIDEO_TS) into Plex-named MKVs, GPU-encoded with
NVENC, keeping every audio track plus a compatibility downmix, English subtitles, and the
correct aspect ratio. Works for episodes, movies, and bonus features in one manifest-driven
pass. It exists because HandBrake's libbluray reader crashes on some discs (PGS subtitle
timestamp discontinuities), and because driving a repeatable, correctly-named batch by hand
is error-prone.

## Scope: decrypted rips only

This skill transcodes **already-decrypted** disc rips — plain `BDMV/` (m2ts) or `VIDEO_TS/`
(VOB) folders that open directly in ffmpeg. Decryption of copy-protected discs (AACS on
Blu-ray, CSS on DVD) is a separate **rip-stage** concern handled by dedicated ripping software
(e.g. MakeMKV, or libdvdcss for DVD CSS), subject to the user's rights in the disc and
applicable law. If a source still shows protection (e.g. an `AACS/` directory with keys, or
ffmpeg can't read the streams), it hasn't been decrypted yet — that's upstream of here. This
skill does not perform or assist DRM circumvention.

## The five steps

1. **Install the toolchain** — `pwsh -File scripts/install-tools.ps1`. Downloads a
   driver-compatible ffmpeg (BtbN n7.1) and SupMover, verifies NVENC works, and writes
   `tool-paths.json`. Do this first; the PATH ffmpeg is often too new for the installed
   NVIDIA driver. See `references/gotchas.md` (driver/ffmpeg pairing).

2. **Inspect the disc(s)** — enumerate titles and classify. For BDMV, list
   `BDMV/STREAM/*.m2ts` by size/duration. For DVD, list `VIDEO_TS/VTS_*_1.VOB` sets.
   The big ~equal-length titles are episodes/features; smaller ones are extras. Get durations
   and audio-track counts with `ffprobe`. Read the metadata files that often ship with a rip
   (`mymovies.xml`, `*.dvdid.xml`) for the box-set identity and extras list.

3. **Identify & order content** — map each title to the right episode/feature and, for TV,
   the **Plex/TMDB episode number** (not IMDb, not on-disc order). See
   `references/identification.md` for the techniques (commentary-track positions, DVD menu
   "episode selection" screens, extracted frames, runtime matching). Confirm ambiguous cases
   with the user.

4. **Build a manifest and transcode** — write a JSON manifest (one object per output) and run
   `pwsh -File scripts/transcode.ps1 -Manifest items.json -LogDir <dir>` in the background.
   The script handles BD vs DVD, cropping, subtitles, and the audio matrix automatically.
   Monitor by grepping the log for `OK|FAILED|DONE` — never read the whole log (ffmpeg's
   `-stats` writes ~1 line/second).

5. **Verify & stage** — `ffprobe` a sample of outputs (resolution, **display aspect ratio**,
   audio track order, subtitle canvas) and confirm counts. Place files in the Plex layout in
   `references/naming.md`. After the user is happy, publish to the final target (NAS) and free
   the local staging space with `scripts/stage-and-clean.ps1 -Src <staged> -Target <nas>
   [-DeleteAfter]`: it copies WITHOUT overwriting anything already there, verifies every file
   byte-for-byte, and only deletes the local copy if that verification passes — the verify is a
   hard gate, so a bad/partial copy never costs you the local original.

## Manifest format

`transcode.ps1` reads a JSON array. Each object:

```json
{
  "out": "D:/video/Television Shows/Show (1967)/Season 01/Show (1967) - S01E01 - Title.mkv",
  "kind": "BD",
  "src": "E:/rip/Show Disk 1/BDMV/STREAM/00000.m2ts",
  "crop": "auto",
  "commentary": 2
}
```

- `out` — final Plex-named path (created if missing). Skipped if it already exists >5 MB
  (makes batches **resumable** — a re-run after a fix only redoes failed/missing items).
- `kind` — `"BD"` (H.264 m2ts, 1080p) or `"DVD"` (MPEG-2 VOB, SD PAL).
- `src` — BD: the `.m2ts`. DVD: a concat of the title's parts,
  `"concat:VTS_02_1.VOB|VTS_02_2.VOB|..."` (list every part in order).
- `crop` — BD only. `"auto"` = cropdetect (use for pillarboxed 4:3 footage → ~1440×1080).
  `"none"` = keep full frame (use for image galleries/stills, split-screen comparisons,
  native-16:9). DVD ignores this (no crop; SD is already framed).
- `commentary` — optional 0-based **source** audio index to tag as "Audio Commentary".

## Encode settings (baked into transcode.ps1)

- Video: `h264_nvenc -preset medium -rc vbr -cq 20 -b:v 0` (matches a HandBrake "1080p HQ
  NVENC" CQ 20 preset). SD stays SD (no upscaling); 1080p stays 1080p.
- BD: per-item cropdetect; PGS subtitles repositioned with SupMover when cropped so they stay
  aligned. DVD: `bwdif` deinterlace + `setsar=16/15` + `-aspect 4:3` (anamorphic), VOBSUB copied.
- Audio matrix per title: an AAC stereo @160 downmix (default track) — plus an AAC 5.1 @160 if
  the source's first track is 5.1 — **plus a passthru copy of every original track**. English
  only. Commentary tracks tagged. See `references/pipelines.md` for the full rationale.

## References

- `references/pipelines.md` — BD vs DVD pipeline details, crop policy, audio matrix, subtitles.
- `references/naming.md` — Plex naming, library/Season-00 conventions, matching an existing show.
- `references/identification.md` — identifying episodes/features and the correct Plex order.
- `references/gotchas.md` — the non-obvious failure modes and fixes (read before debugging).

## Notes for a clean run

- **Don't read the source drive while an encode runs from it** — I/O contention roughly halves
  throughput. Do all probing/frame-extraction before starting the batch.
- NVENC on a laptop shares a thermal/power budget with the CPU; sustained batches pace unevenly.
  That's normal, not a fault.
- If a title has a phantom/corrupt audio stream (`ffprobe` shows `sample_rate=0, channels=0`),
  it's usually a broken menu artifact — skip it rather than fight it.
