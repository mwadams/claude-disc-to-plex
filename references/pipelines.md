# BD and DVD pipeline details

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
Keep English (and commentary); drop other languages.

## Blu-ray (BDMV / m2ts, H.264 1080p)

- **Crop**: per-item `cropdetect` sampled at 20/40/60/80 % of duration; take the largest-area
  box (dark scenes can over-crop); fall back to `1440:1080:240:0` (the standard 4:3-in-1080p
  pillarbox). Apply `"none"` for image galleries (stills — cropdetect would chase the picture),
  split-screen comparisons, and native-16:9 content.
- **PGS subtitles + crop**: cropping the video shifts subtitles unless the PGS canvas is moved
  too. `ffmpeg -c:s copy` does NOT reposition PGS. Extract the PGS to `.sup`, run
  `SupMover --crop L T R B` (L/T/R/B derived from the crop), and mux the fixed `.sup` back in.
  Uncropped BD subtitles just copy.

## DVD (VIDEO_TS / VOB, MPEG-2 SD PAL)

- **Concatenate** the title's VOB parts with the concat protocol:
  `-i "concat:VTS_02_1.VOB|VTS_02_2.VOB|..."` (every part, in order). `-map 0:v:0` / `-map 0:a:0`
  automatically drop the `dvd_nav_packet` data stream.
- **Deinterlace + anamorphic**: `-vf "bwdif=mode=send_frame,setsar=16/15"` plus `-aspect 4:3`.
  DVDs are interlaced (`field_order=tt`); `bwdif` outputs clean 25p and `setsar 16/15` + the DAR
  flag preserve the 4:3 display without upscaling the 720×576 frame.
- **Subtitles**: VOBSUB (`dvd_subtitle`) — `-c:s copy`, English only. DVD crop is ~0, so no
  SupMover. Selecting the English track among several may need `lsdvd`/IFO language info.
- DVDs do **not** hit the Blu-ray libbluray crash — HandBrake can read them natively — but this
  pipeline gives one consistent, automated path for the whole library.
