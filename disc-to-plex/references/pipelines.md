# BD and DVD pipeline details

## Running a batch: the four tracks, and keeping them full

A batch is four INDEPENDENT resources. Idle GPU is the expensive failure, and it happens because
nothing tells you a lane finished — you have to be told, not remember to look.

| Track | Resource | Concurrency |
|---|---|---|
| Encode | NVENC | **2 lanes** |
| Prefetch (source → NVMe) | one USB spindle | **1 stream, strictly sequential** |
| Publish (NVMe → NAS) | network + NAS spindles | **1 at a time, SERIAL** |
| OCR sidecars | CPU (Tesseract) | 1, runs behind the encodes |

- **Prefetch is one stream on purpose.** The source is a single USB spinning disk (~36 MB/s);
  parallel reads seek-thrash and reduce total throughput.
- **NAS copies must be SERIAL.** Several concurrent `robocopy` jobs contend on the same spindles
  and link and everything crawls — with five running on a degraded uplink, nothing completed for
  an hour. Queue works one after another inside a single job.
- **OCR is CPU-bound and does not compete with NVENC**, so it should always be running behind the
  lanes rather than treated as a separate phase. Publishing before it finishes strands the sidecar
  (`publish-work.ps1` now refuses).

### Watch for a free lane; don't poll for one

```powershell
pwsh -File _lanewatch.ps1 -Want 2      # prints only on transition, e.g. "LANE FREE: 1/2 busy"
```

Run it from a monitor on a ~45 s loop. It counts only ffmpeg processes reading from `_stage`, so
another agent's ffmpeg (e.g. subtitle sync against the NAS) is never mistaken for an encode lane.

### Launching a lane so its completion is reported honestly

Do **not** pipe a lane launch through a filter that can close early:

```powershell
... transcode.ps1 ... | Select-String 'OK |DONE' | Select-Object -First 3    # WRONG
```

`Select-Object -First N` closes the pipe once satisfied, so the task reports **completed** while
`transcode.ps1` keeps encoding. Lane state then reads as free when it is not, and the next
manifest over-subscribes the GPU. Either let the output through unfiltered, or filter without a
`-First` cap.


Both pipelines share the video encoder — `h264_nvenc -preset medium -rc vbr -cq 20 -b:v 0
-pix_fmt yuv420p` — and the audio matrix. They differ in source handling.

## Video encoder

CQ 20 with NVENC medium is a visually near-transparent "1080p HQ" tier that mirrors a common
HandBrake NVENC preset. `-b:v 0` makes `-cq` a true constant-quality target. No multipass.
SD sources stay SD (never upscale); HD stays HD.

## Audio matrix (both)

Per title, in this track order:

1. If the source's first audio track is 5.1 (6ch): **AAC 5.1 @160** (default track).
2. **AAC stereo @160** downmix (default if there was no 5.1).
3. A **passthru `copy` of every original audio track** (AC3/DTS/etc.), in source order.

Rationale: the AAC tracks are universal compatibility/direct-play tracks for any client; the
passthru preserves the original 5.1/mono/commentary bit-for-bit. Force `-ar 48000` on the AAC
encoders — some DVD AC3 streams don't propagate their sample rate and the encoder otherwise
errors with "sample rate not set". Tag commentary with `-disposition comment` and a title.

**Language selection (by the title's ORIGINAL language, set via the manifest `origLang`):**
- **English-original** (origLang eng/unset — e.g. West Wing): keep English audio (+ commentary/
  untagged) only; drop foreign-language *dubs* (e.g. the French dub). English subtitle track kept
  (not defaulted on).
- **Foreign-original** (origLang deu/jpn/… — e.g. Run Lola Run, Downfall): the goal is that an
  English viewer can watch it. Decide the DEFAULT track by what the disc actually has:
  1. **English subtitles present** → keep the **original-language audio as default**, add the
     **English dub as an alternative**, and **default the English subtitles ON**. (`Keep-AudioIdx`
     orders original-first; AAC default + `-disposition:s:0 default` follow.)
  2. **No English subtitles, but an English dub is present** → make the **English audio the DEFAULT**
     (so it's watchable in English), keep the original audio as an alternative, subtitles as-is.
     ("English audio if no English subs are available.")
  3. **Only a foreign audio track and NO subtitle stream** → before concluding anything, **check for
     BURNED-IN (hardcoded) subtitles**: grab a mid-film *dialogue* frame (`ffmpeg -ss <mid> …
     -frames:v 1`) and look for subtitle text in the picture. Many foreign releases (e.g. these
     Cinema Paradiso / Cyrano DVDs) carry permanent English subs burned into the video, so there's
     no sub *stream* to find — MakeMKV/dvdvideo correctly show only video + foreign audio. If burned
     in, just encode the feature as-is (foreign audio + the subs travel in the picture); it's fully
     watchable. Only if there are genuinely no burned-in subs either → flag it (wrong disc / needs an
     external SRT). (In practice this user owns no disc lacking BOTH English audio AND English subs —
     so "foreign audio, no sub stream" almost always means burned-in subs.)
  (Also: a foreign disc whose ONLY audio is an English dub — like the Water Margin DVDs — has no
  original track to keep; you just get the dub.) Confirm audio/subtitle tracks with **MakeMKV**
  (`SINFO`), since the dvdvideo demuxer sometimes under-reports VOBSUB subtitle streams.

## Blu-ray (BDMV / m2ts, H.264 1080p)

- **Crop**: per-item `cropdetect` sampled at 20/40/60/80 % of duration; take the largest-area
  box (dark scenes can over-crop); fall back to `1440:1080:240:0` (the standard 4:3-in-1080p
  pillarbox). Apply `"none"` for image galleries (stills — cropdetect would chase the picture),
  split-screen comparisons, and native-16:9 content.
- **PGS subtitles + crop**: cropping the video shifts subtitles unless the PGS canvas is moved
  too. `ffmpeg -c:s copy` does NOT reposition PGS. Extract the PGS to `.sup`, run
  `SupMover --crop L T R B` (L/T/R/B derived from the crop), and mux the fixed `.sup` back in.
  Uncropped BD subtitles just copy.

## DVD (MPEG-2 SD PAL) — via the ffmpeg `dvdvideo` demuxer

Read DVDs with `-f dvdvideo -title N [-chapter_start X -chapter_end Y] -i <dvd-root>`, NOT a
`concat:` of raw VOBs. The demuxer understands the DVD's title/PGC and chapter structure, which
is what makes every episode layout tractable:

- **one title per episode** → `-title N`
- **several episodes as separate titles in a VTS** → `-title N` each
- **several episodes as chapter RANGES inside one title** → `-title N -chapter_start X
  -chapter_end Y` (Plex needs one file per episode, so split the ranges into individual MKVs).

`<dvd-root>` is a decrypted `VIDEO_TS` parent folder, an ISO, or a live optical drive (`F:`);
with **libdvdcss** next to ffmpeg it decrypts a live CSS disc on the fly (harmless CSS warnings
appear when reading already-decrypted folders — ignore them). Enumerate titles by probing
`-title 1,2,3…` and reading each `Duration`.

- **Deinterlace**: `-vf "bwdif=mode=send_frame"` → clean 25p (DVDs are interlaced, `field_order=tt`).
- **Aspect — PRESERVE the source, never hard-code**: read the source `display_aspect_ratio` and
  pass `-aspect <that>`. DVD extras/featurettes are frequently **16:9 anamorphic** while the show
  itself is 4:3; forcing 4:3 on 16:9 content squishes it horizontally (a real bug that shipped
  once — see gotchas.md). Do NOT add `setsar`; let `-aspect` set the display aspect on the
  720×576 frame. Stays SD (no upscale).
- **Subtitles**: VOBSUB (`dvd_subtitle`) — `-c:s copy`, English only; set `subTrack` to the
  English index on multi-language discs.
- DVDs do **not** hit the Blu-ray libbluray crash — HandBrake reads them natively — but this
  path gives one consistent, title/chapter-accurate automated route for the whole library, and
  needs only MakeMKV for Blu-ray (AACS), not DVD.

### When the dvdvideo demuxer mis-reads a disc → MakeMKV intermediate (`kind:"MKV"`)

The dvdvideo demuxer reads only a title's **first cell**, so it truncates **multi-cell titles**
(e.g. an episode authored as a 20 s title-sequence cell + the 24 min body reads as 20 s). If
`scan-disc.ps1` / the episode-index menu / MakeMKV disagree on the episode count or you see
episode-length titles reported as tiny stubs (see gotchas.md), switch that disc to the MakeMKV route:

1. Enumerate/rip losslessly, **one disc at a time, foreground** (background `makemkvcon` yields 0
   files): `makemkvcon64.exe -r --minlength=1200 mkv "file:<VIDEO_TS parent>" all <outdir>`. Titles
   land as `<label>_tNN.mkv` in disc (broadcast) order.
2. Build a manifest with `kind:"MKV"`, `src` = each ripped `.mkv`. transcode.ps1 gives MKV the same
   SD treatment as DVD (bwdif deinterlace, preserve DAR, no crop, no bt709) but reads it as a file.
3. Map titles to Plex numbers in order (confirm against the episode-index menu). Delete the
   intermediate MKVs after the encodes verify.

This keeps the NVENC/audio pipeline identical; only the *source read* changes.
