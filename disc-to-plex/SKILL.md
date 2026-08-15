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

## Per-unit gate — re-read this at EVERY disc, not once per batch

Long runs are where units get skipped. After a stretch of TV box sets it is easy to carry
"the disc is just its episodes" onto a film disc and never sweep it for extras — that happened to
`Sherlock Holmes` (2009), whose ~20 featurette streams were missed because the job felt finished
once the feature playlist was found. Re-reading these steps costs seconds; re-staging a Blu-ray
costs half an hour.

If you abandon or supersede a launched run, **stop its waiter too**. A waiter polling a log that
will never print `MANIFEST DONE` loops forever and can fire a stale lane-free signal later, which
over-fills the encode lanes.

Before calling any unit done, confirm all five:

1. **Every title accounted for** — mapped to an episode/feature, kept as an extra, or excluded as
   *identified* boilerplate. On BDMV that means listing the streams NOT in the feature playlist.
2. **Identity verified from content**, not from the folder name, the disc label, or duration alone.
3. **Outputs size-checked** — a manifest can print `MANIFEST DONE` with failed or truncated items.
   For stream-copies, compare source and output duration.
4. **Local vs NAS byte-verified** (file count AND total bytes) before any reclaim.
5. **Plex read back** — episode/extra titles, and a poster for any `local://` item.

## The five steps

1. **Install the toolchain** — `pwsh -File scripts/install-tools.ps1`. Downloads a
   driver-compatible ffmpeg (BtbN n7.1) and SupMover, verifies NVENC works, and writes
   `tool-paths.json`. Do this first; the PATH ffmpeg is often too new for the installed
   NVIDIA driver. See `references/gotchas.md` (driver/ffmpeg pairing).

2. **Inspect the disc(s)** — enumerate titles and classify. For DVD, run
   `pwsh -File scripts/scan-disc.ps1 -SrcRoot <parent> -Pattern "<Show> * Disk *"` (or `-Root
   <one disc>`): it probes every title on every disc and labels each EPISODE?/PLAYALL?/REVIEW/
   BOILERPLATE/ARTIFACT, using cross-disc identical-duration to unmask copyright/promo reels. For
   BDMV, list `BDMV/STREAM/*.m2ts` by size/duration. **Account for every real title** — map it to an
   episode, keep it as an extra, or exclude it only as *identified* boilerplate. Each REVIEW row is a
   probable extra: look at a frame and place it (never drop a title just because it isn't
   episode-length — that once silently discarded real extras; see `references/gotchas.md`, "Silent
   extras drop"). Read any rip metadata (`mymovies.xml`, `*.dvdid.xml`) for the box-set identity and
   extras list.

3. **Identify & order content** — map each title to the right episode/feature and, for TV,
   the **Plex/TMDB episode number** (not IMDb, not on-disc order). See
   `references/identification.md` for the techniques (commentary-track positions, DVD menu
   "episode selection" screens, extracted frames, runtime matching). Confirm ambiguous cases
   with the user.

4. **Build a manifest and transcode** — for a multi-episode show, don't hand-write the JSON
   (error-prone at 26+ items): put the mapping in a pipe-delimited table (`disc|title|season|ep|name`,
   one row per output, a disc may straddle seasons) and run `scripts/make-manifest.ps1` to emit the
   manifest with correct Plex paths. For a handful of items (movies, extras) write the JSON directly.
   Then run `pwsh -File scripts/transcode.ps1 -Manifest items.json -LogDir <dir>` in the background.
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

6. **Confirm Plex matched it correctly (TV)** — file counts landing on the NAS is *not* proof the
   episodes are numbered right. Plex trusts the `SxxEyy` token against the library's **agent**, which
   can number differently from your source (feature-length pilots/finales often split into two slots —
   see `references/naming.md`, "Episode numbering follows the target library's Plex AGENT"). After the
   scan, run `pwsh -File scripts/verify-plex-episodes.ps1 -Show "<name>" -Season <n>`: it diffs each
   episode's agent title against the title in its matched filename and reports `MISMATCH` rows (exit 1).
   It reads `$env:PLEX_TOKEN` / `$env:PLEX_BASEURL` (owner token, User-scope env var — not in the repo).
   Fix a mismatch by renaming only the `SxxEyy` token (descending, no re-encode), re-scan, re-verify.

7. **Fix the Extras (Season 00) in Plex** — the agent almost always mislabels bonus features (wrong
   titles, summaries pasted from unrelated online items, wrong posters). Our filenames are authoritative.
   After Season 00 files are scanned, run `pwsh -File scripts/fix-plex-extras.ps1 -Show "<name>"
   -MediaDir "<folder with the S00 mkvs>"`: it sets+locks each title from the filename, clears+locks
   the summary, and uploads a real frame from the extra as its poster. Full process (validate on disc →
   apply+lock in Plex) is in `references/extras-fixup.md` — you will need it for almost every TV set.

8. **Give unmatched titles a real poster — this is a REQUIRED closing step, not an optional polish.**
   After staging any item, check its `guid`: a `guid` of `local://<rk>` means the agent found no
   match, and Plex will show a placeholder or a random video frame. That looks like a broken library
   entry to anyone browsing it, and it is easy to skip because the item otherwise appears complete.

   ```powershell
   (Invoke-RestMethod "$b/library/metadata/${rk}?X-Plex-Token=$t").MediaContainer.Video.guid
   ```

   Obscure archive discs (museum collections, BFI/IWM sets, regional-TV releases) get no match far
   more often than not. Re-check after any rebuild, too: deleting a movie's main file makes Plex drop
   and re-create the item with a NEW ratingKey, losing the uploaded poster and every locked field.
   The rip folder usually holds the retail cover art, so run
   `pwsh -File scripts/set-poster-from-disc.ps1 -Title "<name>" -Section <key> -DiscDir "<rip folder>"`.
   It prefers the full-resolution `mymovies-front.jpg` over the downscaled `folder.jpg`, never uses the
   rear cover, and uploads the art (uploaded posters auto-select and survive refreshes). `-WhatIf`
   reports the chosen file and its dimensions without changing anything.

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
- `kind` — `"BD"` (H.264 m2ts, 1080p), `"DVD"` (MPEG-2 VOB, SD PAL), or `"MKV"` (any
  already-demuxed file — also the right choice for SD extras sitting on a Blu-ray).
- `src` — BD: the `.m2ts`, or a `.txt` concat list for a seamless-branching disc.
  DVD: **the disc FOLDER** (the one containing `VIDEO_TS`), not a VOB path — `kind:"DVD"`
  drives ffmpeg's `dvdvideo` demuxer, which navigates the disc itself.
- `title` — DVD only, **required**: the 1-based dvdvideo title number from `scan-disc.ps1`.
  Omitting it emits an empty `-title` and ffmpeg fails instantly with
  `Error setting option title to value .` — a whole-manifest failure that still prints
  `MANIFEST DONE`. Handing `kind:"DVD"` a `concat:…VOB` path fails the same way.
  Always check the output duration against the scan: the dvdvideo demuxer reads only a
  title's first cell, so a multi-cell title comes back short (see `references/gotchas.md`).
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
