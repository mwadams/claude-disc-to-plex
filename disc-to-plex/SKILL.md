---
name: disc-to-plex
description: >-
  Transcode ripped Blu-ray (BDMV/m2ts) and DVD (VIDEO_TS/VOB) discs into Plex-ready MKVs
  with NVIDIA NVENC — episodes, movies, and bonus features — then publish them into a Plex
  library layout. Use this whenever the user wants to rip/convert/re-encode discs, box sets,
  or ISOs for Plex/Jellyfin/Emby; mentions HandBrake crashing on a disc; asks about m2ts,
  VOB, BDMV, VIDEO_TS, MakeMKV, PGS/VOBSUB subtitles, pillarbox cropping, anamorphic DVD,
  deinterlacing, audio commentaries, or "Season 00" extras; or wants a batch/hands-off
  conversion of a TV series or film collection. Prefer this over ad-hoc ffmpeg for any
  disc→library job.
---

# Disc → Plex transcoding

Convert disc rips (Blu-ray BDMV or DVD VIDEO_TS) into Plex-named MKVs, GPU-encoded with NVENC,
keeping the right audio tracks, English subtitles, and the correct aspect ratio. Works for
episodes, movies, and bonus features in one manifest-driven pass. It exists because HandBrake's
libbluray reader crashes on some discs (PGS subtitle timestamp discontinuities), and because
driving a repeatable, correctly-named batch by hand is error-prone.

## Scope: decrypted rips only

This skill transcodes **already-decrypted** disc rips — plain `BDMV/` (m2ts) or `VIDEO_TS/` (VOB)
folders that open directly in ffmpeg. Decryption of copy-protected discs (AACS on Blu-ray, CSS on
DVD) is a separate **rip-stage** concern handled by dedicated ripping software (e.g. MakeMKV, or
libdvdcss for DVD CSS), subject to the user's rights in the disc and applicable law. If a source
still shows protection (e.g. an `AACS/` directory with keys, or ffmpeg can't read the streams), it
hasn't been decrypted yet — that's upstream of here. This skill does not perform or assist DRM
circumvention.

## What actually goes wrong

Encodes rarely fail loudly. The expensive failures all ship a *plausible* file — the wrong cut, a
truncated extra, a commentary a viewer lands on by accident, an episode one slot out — and every
structural check passes. So the working rule for this pipeline is:

> **Verify identity and completeness from the CONTENT, and let a script enforce it where it can.**

`references/gotchas.md` indexes the failure modes by domain; read the one matching what you are
about to do. The five most expensive are summarised at the top of that index — read those before a
batch even if you read nothing else.

## Per-unit gate — re-read this at EVERY disc, not once per batch

Long runs are where units get skipped. After a stretch of TV box sets it is easy to carry "the disc
is just its episodes" onto a film disc and never sweep it for extras — that happened to
`Sherlock Holmes` (2009), whose ~20 featurette streams were missed because the job felt finished
once the feature playlist was found.

If you abandon or supersede a launched run, **stop its waiter too**. A waiter polling a log that
will never print `MANIFEST DONE` loops forever and can fire a stale lane-free signal later.

Before calling any unit done, confirm all six:

1. **Every title accounted for** — mapped to an episode/feature, kept as an extra, or excluded as
   *identified* boilerplate. On BDMV that means listing the streams NOT in the feature playlist.
2. **Identity verified from content** — not from the folder name, the disc label, or duration alone.
3. **Audio identified** — every track named, no unlabelled commentary, no duplicate mixes.
   The postflight report flags candidates; confirm with `identify-audio.py` before acting.
4. **Outputs size- and duration-checked** — a manifest can print `MANIFEST DONE` with failed or
   truncated items. For stream-copies, compare source and output duration.
5. **Local vs NAS byte-verified** (file count AND total bytes) before any reclaim.
6. **Plex read back** — episode/extra titles, and a poster for any `local://` item.

## The steps

### 1. Install the toolchain

`pwsh -File scripts/install-tools.ps1` downloads a driver-compatible ffmpeg (BtbN n7.1) and
SupMover, verifies NVENC works, and writes `tool-paths.json`. Do this first: the PATH ffmpeg is
often too new for the installed NVIDIA driver (`references/gotchas-pipeline.md`).

### 2. Enumerate the disc — with the right tool for its type

**First, prove the copy finished.** MakeMKV enumerates the stream files that are PRESENT, so a
half-copied folder yields a shorter, wholly plausible title list with no error — and that list
becomes the episode mapping. On *The Newsroom* S2 D1 it reported 6 titles of 13; the disc shipped
two episodes instead of three and none of its six extras, and the gap was rationalised for two days
as "the episode isn't in this set" because the remaining runtimes still fitted a story.

```powershell
pwsh -File scripts/assert-staged-complete.ps1 -StageDir "D:\video\_stage\<DISC>"
```

It throws if the folder is still growing, or if it is short against the source. `_fetch-done.txt`
does **not** cover this — that gate protects the fetch, and enumeration is a separate command.

**Blu-ray: use MakeMKV, never file size.** The largest `.m2ts` is routinely not the feature, and
ffmpeg cannot see secondary-audio commentaries at all.

```
makemkvcon64.exe -r --cache=1 info "file:<disc folder>"
   TINFO:<id>,9,0,"H:MM:SS"     title runtime
   TINFO:<id>,16,0,"00033.mpls" its source playlist
   SINFO:<id>,<n>,30,0,"..."    per-stream description
```

Rip the chosen title and transcode from the resulting `.mkv` with `kind: "BD"` (**not** `"MKV"`,
which applies the SD deinterlace path). MakeMKV writes proper language tags, so `subTrack: "eng"`
and `audioLangs` resolve on their own instead of by inference.
`scripts/audit-bd-titles.ps1` runs this comparison across a whole drive.

🔴 **A title id is not a property of the disc — it is a position in a list MakeMKV rebuilds on
every invocation, and `--minlength` decides what is in that list.** Any title shorter than the
floor is omitted and everything after it shifts up. So **the rip must use the same `--minlength`
as the `info` that produced the ids**, or you rip different content under the right name.

Enumerating For Your Eyes Only's extras with `--minlength=60` and then ripping with the default
120 s dropped five sub-2-minute titles and renumbered the rest: the file written as `_t05` was the
29:48 documentary (4.70 GB) instead of the 2:04 clip (9.9 MB). Nothing errored, every filename
looked right, and every file was wrong.

Cheapest guard: **`info` reports each title's size (`TINFO:<id>,10`) — check what landed against
it.** A mismatch means the numbering moved under you.

**Use `--minlength=10`** whenever a disc's extras matter — not 60. MakeMKV's default (120 s) hides
short items entirely; they show up only as `MSG:3025` "…was therefore skipped" lines. Cloud Atlas
had three real extras below the 120 s floor.

60 s is NOT low enough, and reads as safe when it is not. A whole batch was enumerated at 60
before anyone noticed that the per-unit gate's "every title accounted for" was being checked
against an already-filtered list — the floor decides what you are even able to account for. A
10 s floor surfaces the sub-minute material; what it then turns up is usually a 10-20 s logo sting
you exclude as an artefact, which costs one line to dismiss and is the whole point of seeing it.

⚠ This still only finds what MakeMKV exposes as a TITLE. Extras authored as chapters inside another
title, or reachable only down a menu path, will not appear however low the floor goes — for those,
render the menu (`-f dvdvideo -menu 1`) and read what it offers.

**DVD: `pwsh -File scripts/scan-disc.ps1 -SrcRoot <parent> -Pattern "<Show> * Disk *"`** (or
`-Root <one disc>`). It probes every title and labels each EPISODE?/PLAYALL?/REVIEW/BOILERPLATE/
ARTIFACT, using cross-disc identical durations to unmask copyright/promo reels.

**Enumerate only a COMPLETE copy.** A disc still being staged enumerates perfectly happily and
returns a plausible, wrong answer: mid-copy, a 4-disc Spartacus set reported ONE episode on disc 1,
which reads like a genuine box-set quirk rather than a truncated folder. Nothing in MakeMKV's output
says "incomplete". Gate on whatever your fetch step writes only after it verifies the copy (here,
`_fetch-done.txt`), not on the folder existing or on its size looking about right.

**Account for every real title.** Map it to an episode, keep it as an extra, or exclude it only as
*identified* boilerplate. Each REVIEW row is a probable extra: look at a frame and place it. Never
drop a title for being the wrong length — that once silently discarded real extras
(`references/gotchas-process.md`). Read any rip metadata (`mymovies.xml`, `*.dvdid.xml`) for the
box-set identity and extras list.

### 3. Identify content — from what it contains

Map each title to the right episode/feature and, for TV, the **Plex/TMDB episode number** (not
IMDb, not on-disc order). See `references/identification.md` for the techniques (DVD menu "episode
selection" screens, extracted frames, runtime matching, on-screen episode titles).

**For TV, get the canonical structure from Plex FIRST — before naming anything:**

```powershell
pwsh -File scripts/plex-season-map.ps1 -Show "<name>"                      # seasons WITH index numbers
pwsh -File scripts/plex-season-map.ps1 -Show "<name>" -Season <n>          # canonical episode titles + runtimes
pwsh -File scripts/plex-season-map.ps1 -Show "<name>" -Season <n> -MatchDir <ripped folder>
```

It asks Plex's own metadata provider what the show actually looks like, then matches your ripped
files to it by runtime. Renaming 40 episodes after the fact is the alternative.

**There is no single canonical structure — the provider serves a different season tree per episode
ordering, and only ONE of them is what your server matches against.** The script reads the
section's `showOrdering` preference and queries with the matching `episodeOrder`, then warns when
the catalogue disagrees. Do not query `/children` without that parameter and treat the answer as
authoritative — that returns the `watch.plex.tv` tree, which the scanner never uses. For Spartacus
the two disagree about where a whole six-episode prequel lives:

```
(no param)   1=Blood and Sand  2=Gods of the Arena  3=Vengeance  4=War of the Damned
tvdbAiring   0=Gods of the Arena  1=Blood and Sand  2=Vengeance  3=War of the Damned
tmdbAiring   0=Specials           1=Blood and Sand  2=Vengeance  3=War of the Damned
```

The section pref spells TheTVDB as `aired`; the provider wants `tvdbAiring` for that same tree.

Three things that have already caused this to be got wrong:

- **Box-set season NAMES are not season NUMBERS**, and `watch.plex.tv` lists seasons in broadcast
  order with no indices — so reading the order as the numbering is an inference, not a fact.
- **A wrong title in Season 00 says nothing about where a real season lives.** A show with no
  canonical season 0 will have the agent fill the specials slots you invented using the nearest
  season's episode list.
- **A miniseries or prequel is often season 0 in the matching tree** even though the catalogue
  presents it as a numbered season. Publishing it to the catalogue's number silently binds every
  episode to a different season's titles. Once bound, neither a forced refresh, a re-match, nor
  changing the ordering will move it — the binding is sticky, and only unmatching clears it. If
  season 0 is occupied by real episodes, put the extras in a high season (e.g. `Season 90`) and
  lock its title, rather than displacing the episodes.

The matcher flags `AMBIGUOUS` when two canonical episodes share a runtime, which is common — treat
runtime as corroboration and settle those from content. If the show itself is matched to the wrong
thing, `GET /library/metadata/<ratingKey>/matches?manual=1` is the API behind the UI's "Fix Match".

**Identify audio tracks by transcribing them:**

```
python scripts/identify-audio.py "<source>" --tracks 0 1 2 3 --start 2700
```

It reports each track's language and its text, which separates dubs from the original and an
English commentary from English dialogue. Disc metadata order does **not** map onto ffprobe
ordinals — inferring it has produced confident wrong answers repeatedly
(`references/gotchas-audio.md`). Confirm ambiguous cases with the user.

**But transcription cannot tell a commentary from a DUPLICATE — hash the audio for that:**

```powershell
pwsh -File scripts/audio-dup-check.ps1 -Path "<file or folder of rips>"
```

Discs often give every title the same two-stream layout and fill the unused slot with a **byte-identical
copy** of the programme audio, so "it has two English tracks" means nothing. Transcription can't
resolve it either way: a commentary carries the programme audio underneath and the commentators fall
silent for long stretches, so a sample taken in a gap transcribes as the dialogue and reads as a copy.
Both errors happened on Gangsters (2026-08-20) — a real commentary written off as a duplicate from one
transcript, and `commentary:1` applied to a whole series after checking a single episode. The script
decodes both tracks at several offsets and compares hashes: identical everywhere = duplicate (keep one),
different anywhere = real commentary (keep both, set `commentary`).

**Decide PER TITLE.** Commentary is commonly recorded only for a pilot and each series
opener/finale — on Gangsters exactly the film, S01E01, S01E06, S02E01 and S02E06.

### 4. Build a manifest and transcode

For a multi-episode show, don't hand-write the JSON (error-prone at 26+ items): put the mapping in
a pipe-delimited table (`disc|title|season|ep|name`, one row per output — a disc may straddle
seasons) and run `scripts/make-manifest.ps1`. For a handful of items write the JSON directly.

```powershell
pwsh -File scripts/transcode.ps1 -Manifest items.json -LogDir <dir>
```

**Always launch it in the background** — a foreground run killed by a tool timeout leaves an
unfinalised mkv that the resume check mistakes for a finished one. Monitor by grepping the log for
`OK|FAILED|DONE`; never read the whole log (ffmpeg writes ~1 progress line/second).

The script handles BD vs DVD, cropping, subtitles and the audio matrix, and runs two guards:

- **Preflight (aborts)** — a BD item reading a raw `.m2ts` is rejected if a playlist on that disc
  *contains* the clip and runs materially longer, i.e. the encode would be truncated. Override a
  false positive with `"allowRawStream": true` on the item.
- **Postflight (reports)** — untitled and duplicate-signature audio tracks. Identify them before
  labelling or dropping anything; the fix is a lossless remux, not a re-encode.

### 5. OCR the subtitles to a sidecar — before publishing

Disc subtitles are BITMAPS (PGS on Blu-ray, VOBSUB on DVD): pictures of text baked at a fixed size.
Plex's subtitle size/font/colour settings apply only to TEXT subtitles, so for bitmaps the player
can only scale the image — which is why DVD subs read as oversized and blocky. Users notice.

```powershell
pwsh -File scripts/ocr-subtitles.ps1 -Path "<file or folder>"
```

It writes `<name>.eng.srt` **alongside** the media, leaving the bitmap track as a fallback.

**Always sidecar; do not mux.** OCR errors only surface when somebody watches the film, so what
matters is how cheaply they can be undone. A sidecar is a text file you fix in seconds; a muxed
track means rewriting a multi-GB mkv. `-Mode Mux` still exists — prefer the default.

**A sidecar is a separate file — publish it too.** A `robocopy` filter naming only `*.mkv` drops it.

The script gates its own output (cue-count floor, junk-fraction, English-content check) because
`seconv` reports SUCCESS even when recognition has completely failed. Do not remove those gates.

### 6. Publish — immediately — then reclaim only when confirmed

The user cannot confirm a unit is in Plex until it is *on* the NAS for Plex to scan, so holding the
copy back stalls the pipeline. Two separate steps, only the second gated:

- **Publish (ungated)** — copy the moment the encode verifies, trigger a library refresh, and tell
  the user it is ready to check.
- **Reclaim (gated)** — delete the local copy ONLY after the user confirms that unit is in Plex.

```powershell
pwsh -File scripts/publish-work.ps1 -Work "<work folder name>" -Kind Movies|TV [-Overwrite]
```

It copies the **whole work folder** (a named-file filter drops sidecars, artwork and extras),
refuses any `.mkv` whose header has no duration, and needs `-Overwrite` to replace a NAS copy.

Place files per `references/naming.md`. For local movie extras, force an **item** refresh after the
publish verifies — a section scan does not index them (`references/gotchas-plex.md`):

```
PUT /library/metadata/<ratingKey>/refresh?force=1
```

### 7. Verify in Plex, then fix what the agent got wrong

- **TV numbering** — `pwsh -File scripts/verify-plex-episodes.ps1 -Show "<name>" -Season <n>` diffs
  each episode's agent title against its filename and reports `MISMATCH` rows. File counts are not
  proof of correct numbering.
- **Season 00 extras** — the agent relabels these by index against its own specials list, so it
  confidently mislabels most of them. `pwsh -File scripts/fix-plex-extras.ps1 -Show "<name>"
  -MediaDir "<folder>"` sets+locks titles from filenames and uploads a real frame as the poster.
  Full process in `references/extras-fixup.md`.
- **Posters for unmatched items** — a `guid` of `local://<rk>` means no match, and Plex shows a
  placeholder or a random frame. `pwsh -File scripts/set-poster-from-disc.ps1 -Title "<name>"
  -Section <key> -DiscDir "<rip folder>"`. Re-check after any rebuild: deleting a movie's main file
  makes Plex re-create the item with a NEW ratingKey, losing the poster and every locked field.

## Manifest format

`transcode.ps1` reads a JSON array. Each object:

```json
{
  "out": "D:/video/Television Shows/Show (1967)/Season 01/Show (1967) - S01E01 - Title.mkv",
  "kind": "BD",
  "src": "D:/stage/Show Disk 1/BDMV/STREAM/00000.m2ts",
  "crop": "auto",
  "subTrack": "eng",
  "audioTracks": [0, 7, 8],
  "audioLangs": ["eng", "eng", "fra"],
  "commentary": 2
}
```

| Field | Meaning |
|---|---|
| `out` | final Plex-named path (created if missing). Skipped if it already exists >5 MB, which makes batches **resumable** |
| `kind` | `"BD"` (HD), `"DVD"` (MPEG-2 VOB, SD PAL), `"MKV"` (already-demuxed SD file — applies the SD deinterlace path) |
| `src` | BD: the `.m2ts`, a MakeMKV `.mkv`, or a `.txt` concat list for a seamless-branching disc. DVD: **the disc FOLDER** containing `VIDEO_TS`, not a VOB path |
| `title` | DVD only, **required** — the 1-based dvdvideo title number from `scan-disc.ps1` |
| `crop` | BD only. `"auto"` = cropdetect, `"none"` = full frame (galleries, split-screen, native 16:9), or an explicit `"W:H:X:Y"` |
| `subTrack` | **state it on every item.** A language tag (`"eng"`), a 0-based ordinal, or `"none"` when the source has no English subs. Prefer the tag to an ordinal: subtitle order is arbitrary and often alphabetical. Omitting it now behaves as `"eng"` and **aborts** rather than falling back to `s:0` — because the encoder stamps `language=eng` on whatever it keeps, so a silent fallback ships a foreign subtitle labelled English (it did: 14 Band of Brothers extras, Spanish, 2026-08-19) |
| `audioTracks` | explicit 0-based ordinals to keep, in order (first = default). Overrides the automatic pick |
| `audioLangs` | language tag per kept track, when the source has none |
| `commentary` | 0-based **source** audio index to tag as "Audio Commentary" |
| `chapterStart` / `chapterEnd` | DVD only — split a one-VTS disc into episodes |
| `allowRawStream` | skip the preflight playlist check for this item (use only when you have proved the longer playlist is a different item) |

## Encode settings (baked into transcode.ps1)

- Video: `h264_nvenc -preset medium -rc vbr -cq 20 -b:v 0`. SD stays SD (no upscaling).
- BD: per-item cropdetect; PGS repositioned with SupMover when cropped. DVD: `bwdif` deinterlace,
  per-source display aspect ratio (never hard-coded 4:3), VOBSUB copied.
- Audio: an AAC stereo downmix (default) + AAC 5.1 if the source's first track is 5.1 + passthru of
  kept originals. Commentaries tagged. See `references/pipelines.md`.

**Do not raise the bitrate to "improve" a soft transfer.** Measured against a lossless reference
with VMAF, five configurations — including CPU x264 at 3.5× the time — landed within 0.5 VMAF of
each other; +54% storage bought +0.06. Grainy material is at the encoder's ceiling, not
under-provisioned. Full numbers in `references/gotchas-pipeline.md`.

## Scripts

Core pipeline, in the order you use them:

| Script | Purpose |
|---|---|
| `install-tools.ps1` | fetch a driver-compatible ffmpeg, SupMover, mkvextract, seconv |
| `assert-staged-complete.ps1` | **run BEFORE enumerating** — throws if the staging folder is still growing or short against source |
| `scan-disc.ps1` | enumerate and classify DVD titles across a set of discs |
| `audit-bd-titles.ps1` | compare MakeMKV's title list against what was shipped |
| `identify-audio.py` | transcribe each audio track to identify language and commentary |
| `audio-dup-check.ps1` | hash decoded audio to tell a REAL commentary from a duplicate copy |
| `make-manifest.ps1` | build a manifest from a pipe-delimited episode table |
| `transcode.ps1` | the encoder — BD/DVD/MKV, crop, audio matrix, subtitles, guards |
| `ocr-subtitles.ps1` | bitmap subtitles → SRT sidecar |
| `publish-work.ps1` | copy a finished work to the NAS and verify every file |
| `prune-empty-folders.ps1` | tidy folders left behind by reclaims |

Plex fix-ups, after the scan:

| Script | Purpose |
|---|---|
| `verify-title-cards.ps1` | **OCR each episode's on-screen title card** and report OK/MISMATCH against the filename — the check that catches a one-slot numbering shift |
| `verify-plex-episodes.ps1` | diff each episode's agent title against its filename |
| `fix-plex-extras.ps1` | set+lock Season 00 titles, clear wrong summaries, upload posters |
| `lock-plex-titles.ps1` | set+lock titles generally |
| `set-poster-from-disc.ps1` | upload the disc's own cover art for `local://` items |
| `extract-title-cards.ps1` | pull frames for identifying unlabelled titles |

Library-wide maintenance:

| Script | Purpose |
|---|---|
| `audit-audio-tracks.ps1` | transcribe every audio track of every shipped film |
| `survey-subtitles.ps1` | audit which items still carry bitmap-only subtitles |
| `ocr-library-batch.ps1` | resumable OCR campaign over that audit |
| `fix-srt-pipes.ps1` | repair the `\|`→`I` artefact in published sidecars |
| `inventory-mp4s.ps1` | inventory every mp4 with copy date; flag broken stubs |

## References

- `references/gotchas.md` — **index** of failure modes, split by domain. Read the relevant one.
- `references/pipelines.md` — BD vs DVD pipeline details, crop policy, audio matrix, subtitles.
- `references/naming.md` — Plex naming, library and Season-00 conventions.
- `references/identification.md` — identifying episodes/features and the correct Plex order.
- `references/extras-fixup.md` — the full Season 00 validate-then-lock process.

## Notes for a clean run

- **Don't read the source drive while an encode runs from it** — I/O contention roughly halves
  throughput. Do all probing and frame extraction before starting the batch.
- **Stage item N+1 while item N encodes.** The encoder reads NVMe while the copy reads USB, so the
  copy hides entirely behind the previous encode.
- NVENC on a laptop shares a thermal budget with the CPU; sustained batches pace unevenly.
- A phantom audio stream (`sample_rate=0, channels=0`) is a broken menu artifact — skip it.
