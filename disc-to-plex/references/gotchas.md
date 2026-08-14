# Gotchas — read before debugging a failed encode

These are the non-obvious failure modes hit while building this pipeline. Each cost a batch
re-run to diagnose; the fixes are baked into `scripts/transcode.ps1`.

## `crop: "auto"` cropped the SIDES off a letterboxed widescreen film

`Get-Crop` had two faults that combined to mangle a 2.35:1 Blu-ray (`An Education`, 2009):

1. It collected cropdetect candidates into a hashtable as `$crops[$v]=1` — **discarding frequency**
   — then chose the candidate with the largest *area*. One dark or close-up scene is enough to
   emit a bogus tight crop, and nothing outvoted it.
2. Its sanity check `if($w -lt 1400 -or $h -lt 1060){ return '1440:1080:240:0' }` **rejected every
   legitimate letterbox crop** (a 2.35:1 frame is 1920×816, so `h` is always < 1060) and replaced
   it with the hard-coded 4:3 pillarbox default.

Result: `crop=1440:1080:240:0` on a full-width letterboxed film — the black bars were **kept** and
the left and right thirds of the picture **thrown away**. It prints a plausible-looking
`crop=` line, so the only tell is reading that number and sanity-checking it against the film's
actual aspect ratio. **Always do that before letting a BD run to completion.**

Fixed in `transcode.ps1`: cropdetect now votes across 6 sample points and takes the **mode**, and
the guard accepts a frame that is full-width (letterbox) **or** full-height (pillarbox), rejecting
only crops inset on both axes. `crop` now also accepts an explicit `"W:H:X:Y"` string to override
auto entirely — the safest option when you have already measured it:

```
for t in 600 1500 2400 3300 4200; do
  ffmpeg -hide_banner -ss $t -i "$m2ts" -vf cropdetect=limit=24:round=2 -frames:v 200 -an -f null - 2>&1 \
    | grep -oE "crop=[0-9:]+" | sort | uniq -c | sort -rn | head -3
done
```

The dominant value across timestamps is the true frame. Batch-1 output was audited and is
unaffected — those BDs were all 4:3 or full-frame, so the bug never bit until batch 2.

## Title layout changes between SEASONS of the same show — re-probe every set

Boston Legal Seasons 2 and 4 put episode 1 at DVD **title 1** (4 episodes at titles 1–4). Season 5,
same show, same publisher, puts a **2h45m "play all" reel at title 1** and the episodes at titles
2–5. Carrying the earlier layout over would have encoded that reel as "S05E01" — a 2¾-hour file
sitting in an episode slot, on three separate discs.

Never reuse a title layout across sets, or even across discs within a set. Two cheap checks, both
worth doing:

- `mymovies.xml` marks it: the play-all entry is `ContainsEpisode="False"` while real episodes carry
  `TVEpisode="N"`. This is the fastest read of a disc's true structure.
- A duration probe makes it obvious — anything 2–3× episode length is a play-all or a
  feature-length special, never a normal episode.

The same applies to a **feature-length premiere or finale**, which is a real episode but may map to
one Plex slot or two. Compare the agent's own runtime for that slot before naming: Boston Legal
S04E01 is 62 min in both the file and the agent (one slot), whereas DS9's "Emissary" is one disc
title covering two agent slots and needs the `SxxE01-E02` filename form.

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

## A section scan does NOT index local movie extras — force-refresh the ITEM

After staging a movie folder containing `Behind The Scenes/`, `Deleted Scenes/` etc., a plain
`/library/sections/<key>/refresh` creates the movie but lists **only the agent's online extras**
(`trailer`, `sceneOrSample` fetched from Plex's servers). The local subfolders are ignored, which
looks exactly like "Plex didn't accept my extras layout".

They appear after a forced refresh of the movie itself:

```
PUT /library/metadata/<ratingKey>/refresh?force=1
```

Verify with `GET /library/metadata/<rk>/extras` — local ones carry a `Media/Part/file` and the
right subtype (`deletedScene`, `behindTheScenes`). On `An Education` this took the count from
9 (all remote) to 21 (12 local + agent's own). Don't restructure the folders before trying this.

## `mymovies.xml` `<AudioTracks>` names the commentary — don't guess it from loudness

Blu-ray audio streams usually carry **no language tags**, so a commentary is indistinguishable
from the film mix by probing alone. Waveform and spectrogram comparisons are inconclusive
(a commentary is mixed *over* ducked film audio, so it tracks the film's envelope), and mean
volume is only a weak hint. The disc's own `mymovies.xml` lists them in stream order:

```xml
<AudioTrack Language="English"    Type="DTS-HD Master" Channels="7.1" />
<AudioTrack Language="English"    Type="Dolby Digital" Channels="2.0" />
<AudioTrack Language="Commentary" Type="Dolby Digital" Channels="2.0" />
<AudioTrack Language="Other"      Type="Dolby Digital" Channels="2.0" />
```

Read it first: the `Commentary` entry's ordinal position is the 0-based `commentary` index for the
manifest (here: 2). `Language="Other"` is typically an audio-description track — real content,
worth keeping, but not the commentary.

## `HVDVD_TS` symlinks make robocopy copy every disc TWICE (and break the byte gate)

Some source drives run a `makelink.cmd` (`MKLINK /D HVDVD_TS VIDEO_TS`) in each disc folder so
media players that expect HD DVD layout still find the payload. `HVDVD_TS` is a **directory
symlink to `VIDEO_TS`**, not a real folder.

`robocopy /E` **follows it** and writes the whole payload a second time, while
`Get-ChildItem -Recurse -File` on the source does **not** traverse the reparse point. So the
byte-complete gate compares 33 source files against 64 destination files and reports
`INCOMPLETE` on a copy that is actually fine — the classic gate failure inverted, and it wastes
double the NVMe space per disc.

Fix both halves:
- Copy with **`/XJ`** (exclude junctions/symlinks): `robocopy "$src" "$dst" /E /XJ /R:3 /W:5`
- Gate on **`VIDEO_TS` only**, not the folder root, so a stray link can never skew the count:
  compare `Get-ChildItem "$src\VIDEO_TS" -File` vs `"$dst\VIDEO_TS"` for count **and** bytes.

Detect it up front with
`Get-ChildItem $src -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }`.
Never "fix" it by deleting the link on the source — it is the user's data and guard-protected.

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

## One-VTS discs: episodes hide inside a single title — read the MENU for the split points

Not every disc gives one VTS (or one title) per episode. A common BBC/ITV layout puts a whole
disc's worth of episodes in **one VTS**, exposed either as one long title or as PGCs that a ripper
may or may not separate. Symptoms: a single ~2.5-hour title where you expected three ~50-minute
ones, or a "programme VTS count" of 1 on a disc you know holds several episodes.

**The programme-VTS cross-check does not apply here** — it assumes one VTS per episode. Substitute:
the low-`--minlength` enumeration, the *expected* episode count for that disc, and total runtime
(3 × 52 min ≈ 2h36 of payload).

**Find the boundaries from the disc's own menu, not by guessing.** The episode-selection menu maps
each episode to a chapter/PGC entry, which is the authoritative split. Render the menu
(`ffmpeg -f dvdvideo -menu ...` or inspect the IFO's PGC/chapter table) and read the episode list
off it; `ffprobe -f dvdvideo -title N -show_chapters` then gives the chapter times to cut on.
Encode with `-chapter_start` / `-chapter_end` (transcode.ps1 supports both for `kind: "DVD"`), and
**verify each resulting file's runtime against the expected episode length** — a boundary that is
one chapter out shows up immediately as a 40-minute or 65-minute "episode".

Cross-check the split against the episode count before encoding: if the chapter table yields four
segments on a disc that should hold three episodes, one "episode" is really a recap or an extra.

## TV extras go in Season 00 — the `Behind The Scenes/` folders are the MOVIE convention

Plex has two different extras conventions and they are **not interchangeable**:

- **TV shows** → `Season 00/` as `<Show (Year)> - S00Exx - <Extra title>.mkv`
- **Movies** → local-extras subfolders inside the movie folder (`Behind The Scenes/`, `Featurettes/`,
  `Deleted Scenes/`, `Shorts/`, `Trailers/`, `Other/`)

Putting TV extras into `Other/` or `Shorts/` under the **show** folder **fails silently**: the library
scans without error, `useLocalAssets` is `true`, the files sit on disk with correct names — and the
show's `/extras` endpoint returns only Plex's own online trailer. Nothing anywhere reports a problem;
the extras are simply invisible in the UI. (Real incident 2026-08-13: nine Doctor Who extras and an
Outnumbered making-of were staged into `Other/`, `Shorts/` and `Behind The Scenes/`. The user spotted
that the extras never appeared. Because the wrongly-placed copies were already on the delete-protected
NAS, they had to be flagged to the user for manual removal, and one extra whose local copy had already
been reclaimed had to be re-ripped from the source disc.)

**The temptation to avoid:** a show like Doctor Who has a Specials season full of *canonical broadcast*
specials, so dropping DVD featurettes into `Season 00` looks wrong. It isn't — that is where they go.
Handle the collision the documented way instead: read the existing Season 00, **append from
`max(index)+1`** (never renumber), then run `fix-plex-extras.ps1 -FromIndex <first new index>` so only
the new entries get titles set+locked and the canonical earlier specials keep their agent metadata.

## MakeMKV has no `--maxlength`

Only `--minlength` exists. Passing `--maxlength` makes the run fail with no titles saved. To grab one
specific title, rip it by **0-based index among the selected titles**:
`makemkvcon64 -r --minlength=1000 mkv "file:<src>" 7 <outdir>` — note the enumeration prints 1-based
*disc* title numbers (`Title #9`), so an 8-title selection ending at `Title #9` is index `7`.

## Season 00 extras: match the AGENT'S canonical order, don't invent your own

The Plex series agent ships its own Specials list for many shows, and it assigns those titles
**by index** to whatever file lands in each slot. So if you number extras in the order you happen to
rip them, Plex will confidently mislabel every one — the interview shows up titled as the extended
episode, the gallery as the interview, and so on. The files are fine; the numbering is wrong.

**Before naming Season 00 files**, read what the agent already expects:

```powershell
$eps = Invoke-RestMethod -Uri "$b/library/metadata/<season0RatingKey>/children?X-Plex-Token=$t"
$eps.MediaContainer.Video | Sort-Object index | ForEach-Object {
  "E{0:D2} '{1}' dur={2}ms <- {3}" -f [int]$_.index,$_.title,$_.duration,(Split-Path $_.Media.Part.file -Leaf) }
```

Match your rips to those canonical entries **by content and runtime** (the agent's summaries often
name a runtime — e.g. "an untransmitted 75-minute version" pinned a 4508 s rip to E01), then number
your files to agree. Extras the agent doesn't know about go after the canonical ones, and only those
need `fix-plex-extras.ps1` to set+lock titles from filenames.

**Scope the fixer with `-FromIndex`** so it touches only the unknown extras: it clears summaries, and
the agent's canonical summaries (like a restoration note explaining *why* an extended cut exists)
are worth keeping. TMDB's own Specials page may be empty while the Plex agent still has entries —
trust what the server returns, not the metadata site.

## A high `--minlength` silently drops EXTRAS, not just episodes

Setting `--minlength` to just under the episode runtime (e.g. `3600` for ~70-min episodes) is a
tempting way to "filter to episodes" — but bonus features are *short by definition*, so that filter
throws away every extra on the disc without a word. MakeMKV reports "2 titles saved", exit 0.

Rip with a **low** minlength (e.g. `--minlength=100`, high enough to skip the ~30s colour-bars stub)
and classify by duration **afterwards**, in your own code: episode-length titles → `Season NN`,
short titles → `Season 00` extras. Never let the ripper do the filtering.

The tell is the **programme-VTS cross-check**: an extras disc has more programme VTS sets than
episodes. (Real incident: disc 15 of a 16-disc set reported 4 programme VTS sets but only 2 ripped
titles; the full `--minlength=1` enumeration revealed 2 episodes *plus four extras* of 11:31, 29:04,
3:08 and 2:28 that the 60-minute floor had discarded. Every earlier disc in the set had exactly
3 VTS sets and 3 episodes, which is why the discrepancy stood out.)

Corollary: **probe every disc's full title list before assuming it is episodes-only**, and give the
last discs of a box set extra scrutiny — that is where extras usually live.

## NEVER whole-folder stage while an encode is writing into that folder

Staging is a *copy of finished work*. If a `robocopy <seasonFolder> <nas>` runs while the encoder is
still writing episodes into `<seasonFolder>`, robocopy happily copies the **partially-written mkv**.
On a no-overwrite, delete-protected NAS those partials are then **stuck** — only the user can remove
them, and the season silently contains broken episodes that play short or fail.

**Two rules, both required:**

1. **Wait for `MANIFEST DONE` on every lane writing to that folder** before staging anything from it.
2. **Stage targeted per-file, never the folder** — pass the explicit filenames you just verified:
   `robocopy $src $dst "Show - S05E01 - A.mkv" "Show - S05E02 - B.mkv" /J /NP ...`
   A folder-level copy will pick up whatever else happens to be in there, including a 0-byte file
   the encoder created a second ago.

**Verify before you copy, not after**: compare each candidate's duration to its source, and treat a
still-growing or 0-byte file as proof an encode is live. (Real incident: a whole-folder stage during
an active encode put two partial episodes on the NAS; three finished ones copied fine, which made
the "3/6 matched" result look like a timing hiccup rather than data damage.)

## GATE every rip/encode on a BYTE-COMPLETE prefetch — never on "the folder exists"

A prefetch (USB→NVMe) launched with `run_in_background` keeps copying across later tool calls.
If the next step only checks `Test-Path <stage>\VIDEO_TS` before ripping, it reads a **half-copied
disc** — and the failure is silent and plausible-looking:

- **Whole titles disappear.** MakeMKV enumerates only the VTS sets copied so far. A 3-episode disc
  reports 2 titles and "2 titles saved" with exit 0. Nothing errors.
- **The titles you do get are short.** The last-copied VTS is truncated mid-VOB, so an episode comes
  out ~20-30s short of its true length.
- **A duration check against the rip cannot catch either problem** — the rip is the thing that's
  wrong, so encode-vs-rip agrees perfectly. (Real incident 2026-08-13: Thriller D4/D5 each lost one
  episode and had two more truncated ~27s; the encode==rip duration check passed on all of them.)

**The gate** (PowerShell; run it in the *same* step as the rip, not a previous one):

```powershell
$s=(Get-ChildItem $src -File).Count; $sb=(Get-ChildItem $src -File|Measure-Object Length -Sum).Sum
for($i=0;$i -lt 120;$i++){
  if(Test-Path $dst){ $d=(Get-ChildItem $dst -File).Count
    $db=(Get-ChildItem $dst -File|Measure-Object Length -Sum).Sum
    if($d -eq $s -and $db -eq $sb){ break } }
  Start-Sleep -Seconds 10
}
if($d -ne $s -or $db -ne $sb){ "GATE FAILED"; exit 1 }
```

**Independent cross-check** (because rip-vs-encode is self-consistent): count the disc's programme
VTS sets *from the source* and require one ripped title per set —
`Get-ChildItem $src -Filter "VTS_*_0.IFO"` (VTS_01 is usually the ~20 MB menu; the rest are
episodes, ~2-3 GB of VOB each). If MakeMKV saves fewer titles than there are programme VTS sets,
the stage was incomplete or a title was skipped — investigate before encoding.

**Rule: run every `robocopy` invocation — prefetch (USB→NVMe) *and* NAS staging — via the PowerShell
tool, NEVER the Bash tool.** The Bash tool is Git Bash / MSYS, whose argument converter rewrites
anything that looks like a POSIX path, corrupting robocopy in two independent ways:

1. **Switches** — MSYS treats a leading-slash flag as a path and appends a drive colon:
   `/E`→`E:/`, `/J`→`J:/`, `/MIR`→`MIR:/` etc. robocopy then rejects it with
   `ERROR : Invalid Parameter #N : "E:/"` and copies **nothing**. This bites even when every
   path argument is a plain local drive path (`E:\...`, `D:\...`), so it breaks **prefetch**, not
   just UNC staging.
2. **UNC / backslash paths** — `\\NAS\share` collapses to `\NAS\share`; robocopy treats that
   single-backslash path as **relative to the current drive** and copies to `D:\NAS\share\...`
   locally. The byte-verify passes too — it checks that same wrong local folder — so a broken
   stage looks VERIFIED and (worse) could gate a delete. Nothing reaches the NAS.

Symptom of (1): the copy "fails" instantly with an Invalid Parameter error and the stage dir stays
empty. Symptom of (2): the stage looks complete and verified but the NAS never receives the files.

**Avoid both:** issue robocopy from the **PowerShell tool**. For a long copy, use the tool's own
`run_in_background` (a PowerShell `Start-Job` dies when the shell session ends between calls, so its
log never appears). `stage-and-clean.ps1` hard-aborts when `$Target` starts with a single backslash,
and warns when the target resolves onto the source's own volume — but prefetch robocopy has no such
guard, so the PowerShell-only rule is the real protection. (If a raw `robocopy` line is ever needed
from bash, every switch and UNC path must be quoted/escaped to survive MSYS — not worth it; just use
PowerShell.)

## Operational

- **`-stats` spam**: ffmpeg writes ~1 progress line/second; a long encode log is thousands of
  lines. Monitor by grepping `OK|FAILED|DONE`, never by reading the whole file.
- **Source-drive contention**: probing/extracting frames from the same physical drive an encode
  is reading roughly halves its speed. Do all inspection before starting the batch.
- **Pipeline the copy: stage item N+1 to NVMe *while* item N encodes.** The rips live on a slow
  USB/external spinning disk (e.g. `E:` = a USB Iomega HDD, measured ~36 MB/s sequential). At CQ20
  a single 1080p encode only needs a few MB/s of source, so USB bandwidth is *not* what caps one
  encode — but it makes disk access the shared resource the moment anything else touches that disk.
  The win from staging is **overlap, not raw speed**: always point the manifest `src` at a local
  **NVMe (`D:`)** copy so the encoder reads NVMe, and copy the *next* item (the `.m2ts`, or a whole
  disc's `VIDEO_TS`) USB→NVMe **during** the current encode. Because the encoder reads `D:` and the
  copy reads `E:`/writes `D:`, there's **no disk contention** — the ~20-min USB copy hides entirely
  behind the previous item's encode, so the GPU never waits on USB. Prime the pipeline once (first
  item's copy is unavoidably serial), then it's copy-ahead from then on. Delete each local staging
  copy once its encode verifies.
  - ReFS gotcha: a freshly-created copy target shows its **full allocated size immediately**
    (reservation), so a half-copied 28 GB file already reports 28 GB and is **exclusively locked**
    (reads fail `Permission denied`) until the copy actually completes. Don't gauge copy progress by
    file size, and don't touch a staged file until its copy task reports done.
- **Resumability**: `transcode.ps1` skips outputs that already exist >5 MB. After fixing a bug,
  just re-run the same manifest — only the failed/missing items redo. Delete broken partials
  (<5 MB) first so they aren't mistaken for complete.
- **Laptop thermals**: sustained NVENC shares a power/thermal budget with the CPU; per-title
  encode times vary widely. Normal, not a fault.

## Concat lists, PowerShell URLs and manual matches

- **An apostrophe in a path breaks an ffmpeg `concat` list.** Entries are single-quoted
  (`file 'D:\...\x.mkv'`), so a title like `Wavell's 30,000` terminates the quote early and ffmpeg
  reports `Impossible to open 'D:\video\Movies\Wavells'`. Escape it the shell way when writing the
  list: `"file '" + ($path -replace "'","'\''") + "'"`.
- **PowerShell 7 parses `$var?` inside a string as the null-conditional operator**, so
  `"$b/library/metadata/$rk?X-Plex-Token=$t"` silently drops the `?…` and the request 404s — while
  the same URL with a *literal* rating key works fine. Always brace it: `${rk}?X-Plex-Token=…`.
  Symptom is a 404 on `/library/metadata/<rk>` when sibling endpoints like `/extras` succeed.
- **A US release title can beat the UK one in the agent's match.** `Close Quarters` (1943, Crown
  Film Unit) matched as `Undersea Raider (1943)` — the same film's US title, confirmed by the
  summary. The match is correct; just PUT `title.value` + `title.locked=1` back to the UK title
  rather than unmatching. Pass **`language=en-GB`** to `/matches?manual=1` to surface UK-specific
  candidates where the two clash (user tip, 2026-08-14).
- **An archive film's only TMDB entry may carry the DVD release year, not the production year.**
  `Wavell's 30,000` (1942) matched an entry dated 2002 with a typo'd title. Lock `title`, `year`
  and `originallyAvailableAt` rather than leaving the film filed under the wrong decade.
- **A DVD can list every episode twice.** The Edwardian Country House exposes t3==t4, t5==t6,
  t7==t8 with identical durations; a frame at the same offset proves the pairs are the same
  content. Take the odd titles only. Duplicate *durations* are the tell — check before assuming
  a disc holds twice as many episodes as it does.
