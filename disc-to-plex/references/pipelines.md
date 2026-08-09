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

**Language selection (by the title's ORIGINAL language, set via the manifest `origLang`):**
- **English-original** (origLang eng/unset — e.g. West Wing): keep English audio (+ commentary/
  untagged) only; drop foreign-language *dubs* (e.g. the French dub). English subtitle track kept
  (not defaulted on).
- **Foreign-original** (origLang deu/jpn/… — e.g. Run Lola Run, Downfall): keep the **original-
  language audio as the default track**, add the **English dub as an alternative**, and **default
  the English subtitles ON** — so it plays in the original language with English subs, dub
  available. `Keep-AudioIdx` orders original-first; the AAC default + `-disposition:s:0 default`
  follow. (Note: a foreign disc whose only audio is an English dub — like the Water Margin DVDs —
  has no original track to keep; you just get the dub.)

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
