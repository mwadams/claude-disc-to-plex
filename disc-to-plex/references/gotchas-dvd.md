# DVD gotchas

The dvdvideo demuxer, cells, title numbering, and multi-episode VTS layouts.

Part of the `disc-to-plex` gotchas set — see [gotchas.md](gotchas.md) for the full index.

## Contents

- [Title layout changes between SEASONS of the same show — re-probe every set](#title-layout-changes-between-seasons-of-the-same-show-re-probe-every-set)
- [dvdvideo read errors truncate silently — ALWAYS verify output duration](#dvdvideo-read-errors-truncate-silently-always-verify-output-duration)
- [dvdvideo demuxer truncates multi-cell titles (looks like missing episodes)](#dvdvideo-demuxer-truncates-multi-cell-titles-looks-like-missing-episodes)
- [DVD aspect: never hard-code 4:3 (16:9 extras get squished)](#dvd-aspect-never-hard-code-43-169-extras-get-squished)
- [One-VTS discs: episodes hide inside a single title — read the MENU for the split points](#one-vts-discs-episodes-hide-inside-a-single-title-read-the-menu-for-the-split-points)
- [MakeMKV has no `--maxlength`](#makemkv-has-no---maxlength)
- [A high `--minlength` silently drops EXTRAS, not just episodes](#a-high---minlength-silently-drops-extras-not-just-episodes)
- [`mymovies.xml` title `Number`s are NOT ffmpeg `dvdvideo` title numbers — map by DURATION](#mymoviesxml-title-numbers-are-not-ffmpeg-dvdvideo-title-numbers-map-by-duration)
- [An INCOMPLETE RIP in the archive looks like a different edition of the disc](#an-incomplete-rip-in-the-archive-looks-like-a-different-edition-of-the-disc)

## An INCOMPLETE RIP in the archive looks like a different edition of the disc

`DIE_MUMINS_3` presented as a German-only release: ten titles, every one German, no English
anywhere. Its sibling `DIE_MUMINS_1` carried both languages. The natural reading — different discs
in the box carry different language options — was wrong.

The disc's own **VMG declares how many title sets exist**, at offset `0x3E` of `VIDEO_TS.IFO`:

```powershell
$b = [IO.File]::ReadAllBytes("$disc\VIDEO_TS\VIDEO_TS.IFO")
$declared = [int]$b[0x3E]*256 + [int]$b[0x3F]
$present  = @(Get-ChildItem "$disc\VIDEO_TS" -Filter 'VTS_*_0.IFO').Count
```

It declared **27** and held **11**. The copy had aborted: the last present set was missing its
`.BUP` and its VOB was 64 MB against ~430 MB siblings — truncated mid-write. Everything above it,
which happened to be the entire **English version**, was never copied.

Why it is dangerous: the folder mounts, enumerates and plays perfectly. Every duration agrees
between ffmpeg and MakeMKV, so a truncation check reports "safe". The only outward symptom was
**the user's player crashing** whenever the menu navigated into a title set that isn't there.

**Check integrity BEFORE the duration comparison** — `dvd-path-check.ps1` does both, integrity
first, because on an incomplete rip the durations are perfectly self-consistent. A set missing its
`.BUP` is the signature of a copy that stopped mid-set. The fix is to **re-rip the physical disc**,
not to work around the gap. Across the other 39 DVDs on that drive, none was affected — so this is
a per-disc accident, not a reason to distrust an archive.

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

## DVD aspect: never hard-code 4:3 (16:9 extras get squished)

A DVD's main feature may be 4:3 while its **extras/featurettes are 16:9 anamorphic** (modern
interviews, making-ofs). Forcing `-aspect 4:3` (or `setsar=16/15`) on a 16:9 source squishes it
horizontally — faces look too narrow/tall. This shipped once on three Prisoner featurettes.
**Fix:** read each source's `display_aspect_ratio` and pass `-aspect <that>`; add no `setsar`.
`transcode.ps1`'s `Get-DAR` does this. Verify outputs with
`ffprobe -select_streams v:0 -show_entries stream=display_aspect_ratio`.

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

## MakeMKV has no `--maxlength`

Only `--minlength` exists. Passing `--maxlength` makes the run fail with no titles saved. To grab one
specific title, rip it by **0-based index among the selected titles**:
`makemkvcon64 -r --minlength=1000 mkv "file:<src>" 7 <outdir>` — note the enumeration prints 1-based
*disc* title numbers (`Title #9`), so an 8-title selection ending at `Title #9` is index `7`.

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

## `mymovies.xml` title `Number`s are NOT ffmpeg `dvdvideo` title numbers — map by DURATION

`mymovies.xml` numbers every title on the disc including menu/stub entries, and its count of those
stubs does not have to match what the `dvdvideo` demuxer exposes. On Hi-de-Hi! Series 1 & 2 the
`mymovies` disc-1 list has **six** sub-two-second stubs before the content, while ffmpeg exposes
only **three** — so `mymovies` t7–t10 are ffmpeg t4–t7, a silent off-by-three. Discs 2 and 3 of the
*same set* list three stubs and line up exactly, which is precisely why this is easy to miss: the
mapping can be right on every disc you check and wrong on the one you don't.

The failure is loud only if you are lucky. Titles past the end simply don't exist, so ffmpeg
reports `libdvdread: Device <path> inaccessible, CSS authentication not available` — a misleading
message about *access*, on a byte-verified local copy, for what is really "no such title". If the
offset had been smaller, every episode would have encoded successfully under the wrong name.

**Always resolve titles by duration.** Enumerate what ffmpeg actually exposes and match each
against the `mymovies` runtimes:

```powershell
foreach($t in 1..14){
  $d = & $fp -v error -f dvdvideo -title $t -i $stage -show_entries format=duration -of csv=p=0 2>$null
  if($d){ "t$t = $([math]::Round([double]$d/60,2))m" }
}
```

Use `mymovies` for the *episode mapping* (`TVSeason`/`TVEpisode`) and for runtimes, but take the
title *numbers* from this enumeration.

**A short duration is not automatically the multi-cell truncation bug.** Here ffmpeg read 27:08
where `mymovies` claimed 29:50, which looks exactly like truncation — but MakeMKV independently
reported 27:08 (7 cells), so the disc is right and the metadata is wrong. Confirm with MakeMKV
before re-ripping:

```
makemkvcon64.exe -r --cache=1 info "file:<stage>"
```

It prints `Title #N was added (C cell(s), H:MM:SS)` per title. Agreement means the disc is simply
what it is.


## `dvd-path-check.ps1` IS BLIND WHEN BOTH TOOLS SHARE THE BUG (2026-08-28)

`dvd-path-check.ps1` clears the dvdvideo first-cell truncation risk by checking that **ffmpeg agrees
with MakeMKV**. That is a comparison, not a measurement — and a comparison cannot see a fault the
two share.

**The Saint Colour D13, dvdvideo title 8.** The VTS holds one PGC of **16:36 in 17 cells**, a 664 MB
VOB. MakeMKV reports **0:59 / 37.4 MB**; ffmpeg also stops at ~59 s. Both read only the first cell,
so they agree exactly — and the path check printed "dvdvideo path safe". Its counter-rule is
structurally incapable of catching this: agreement is its pass condition.

**What does catch it is the prover's byte comparison.** `prove-dvd-mapping.py` sums the VTS's title
VOBs and compares against MakeMKV's `TINFO,11`. 37 MB against a 664 MB VTS does not match anything,
so the title comes back **UNPROVEN** — an independent measurement against the disc's own structure
rather than against another tool's opinion.

So, on any DVD:

- **A green `dvd-path-check` is necessary, not sufficient.** Read the prover's output too, and treat
  a title whose MakeMKV size is a small fraction of its VTS VOB total as truncated until proven
  otherwise, whatever the path check says.
- The inverse case is the ordinary one and stays valid: a **2048-byte** (one-sector) shortfall is an
  authoring artefact, not truncation — Rivals S2 D4's VTS_03 was short by exactly one sector and was
  proven intact from TT_SRPT, chapter counts and MakeMKV's `TINFO,24`.
- ~~Recovering such a title is not simply "read the VOB directly": D13's 17 cells alternate between
  audio streams `0x80` and `0x81` (ending at 12:31 and 11:31 against 16:36 of video), so a flat read
  yields video with holes in the audio.~~
  **WRONG — corrected 2026-08-28, and left here because this belief is what caused the defect.** It
  sent the recovery down the per-program route, which is where the corruption came from. A flat read
  of `VTS_05_1.VOB` yields video AND audio complete: `0x80` carries **31,136 AC3 frames = 996.35 s**
  against 996.40 s of picture. `silencedetect` over it finds **6 silences totalling 8.27 s, longest
  1.58 s**, at the leader positions, aligning with the video's black segments to within ~0.2 s.
  The "12:31 / 11:31" figures came from `format=duration`, which for this source reports **57.936 s
  for both streams** — garbage. The alternation is real at the *cell* level; it does not put holes in
  the assembled stream. **Recovering such a title often IS simply "read the VOB directly".**

### The remedy: read each PROGRAM, not the title (SOLVED 2026-08-28)

`-preindex` and `-trim` still truncate. Reading the title one PROGRAM at a time does not:

```
ffmpeg -f dvdvideo -title M -chapter_start N -chapter_end N -i "<disc>" -map 0 -c copy pgN.mkv
```

Reading a program in isolation also resolves the per-cell `0x80`/`0x81` alternation — every program
then exposes both audio streams populated for its whole length. Concatenate the programs
(`-f concat`) into ONE item; do not ship N fragments (see the gallery rule in `naming.md`).

🔴 **`-pg` is an ENTRY point, not a selection — do not loop over it.** This section first
recommended `-pgc 1 -pg N`, which was wrong in the general case. ffmpeg documents `-pg` as "entry
PG number" and gives it no exit counterpart: it returns program N **and everything after it**.
Measured on a 625-frame / 4-program PGC (The Saint Monochrome D15, VTS_01): `-pg 1` = 625 frames,
`-pg 2` = 335, `-pg 3` = 155 — nested, not disjoint. `-chapter_start N -chapter_end N` on the same
PGC returns 290 and 180: disjoint, summing to the title exactly. The `-pg` loop only appeared to
work on D13 because that disc's read aborts after one cell anyway, so each read stopped where the
bug stopped it.

🔴 **A chapter RANGE is not reliable either — ask for ONE unit at a time and verify each.** The
290/180 measurement above stands, but on **The Saint Monochrome D10 title 6** (four programs across
seven cells, 212.8 s declared) a flat read stopped at **49.8 s**, `-preindex 1` returned the same
49.8 s, and **`-chapter_start 1 -chapter_end 4` also returned 49.8 s** — accepted and silently
ignored. Only reading one chapter at a time returned each program whole. A one-pass encode there
would have shipped a valid, plausible 49.8 s file that had **silently lost three extras**.

So neither `-pg` nor a chapter range can be trusted to honour the request. What survived on both
discs is: **request ONE unit, count its packets, and check the units sum to the title.**

**Two truncation signatures that are indistinguishable in a duration column** — both are "the read
stopped early", and neither announces itself:

| signature | example | looks like |
|---|---|---|
| stops at **cell 1**'s length | D13 title 8: **59 s** of 996 s | "the title is simply 59 s" |
| stops at **chapter 1**'s length | D10 title 6: **49.8 s** of 212.8 s | "the title is simply 49.8 s" |

In both cases `ffprobe` reports the title's **declared** time (996.4 s / 212.8 s) while the decode
yields the truncated length. **The declared figure has now misled us on two unrelated discs in one
day**, which makes it a pattern rather than an anecdote — see the `format=duration` entry below.

Measured on D13 title 8: 17 programs, **996.66 s total = the declared 00:16:36 exactly**, and
**24,910 frames — the same count a flat read of `VTS_05_1.VOB` produces**, so the programs tile the
reel with no gap and no overlap.

⚠ **But that identity is a completeness check, NOT an integrity check, and it was read as both.**
The frames were all present and ~269 of them were wrong: the shipped item
(`The Saint (1962) - S00E22 - Trailer Reel.mkv`) carries 8–29 frames of saturated green/red fill at
**every one of its 17 seams**, growing until the frame is solid. Frame count and duration cannot see
it — only the picture can.

To find it: `blackdetect` to locate the joins, `signalstats` over the ~2 s before each. Fill reads
`SATMAX` 109–130 with `UAVG`/`VAVG` 35–70 off neutral, against `SATMAX ~22` for the surrounding
picture. Leader black is not the defect — it sits at `U=V=128`, `SATMAX ~0`. **A fade desaturates;
fill saturates.** Or run `scripts/check-seam-integrity.ps1`.

🔴 **DO NOT assume the assembly caused it — on this disc it did NOT.** The obvious theory, and the
one written here first, was that reading a program in isolation leaves its final GOP incomplete so
the tail decodes from missing data. **That was wrong, and it was disproved by rebuilding.** A second
build taken from a single CONTINUOUS read of `VTS_05_1.VOB` — no `-pg`, no chapter arguments, no
concatenation, no joins of any kind — reproduced the defect **exactly**: the same 17 seams, the same
269 frames, the same per-seam counts and the same worst chroma values as the `-pg` build. Two
independent demux routes, byte-identical defect maps.

What it actually is: decoding the whole stream at `-v warning` reports **zero** decoder messages, and
a full-size frame shows the picture **sliding horizontally** with green filling the vacated area —
sharp, complete picture content being displaced, with film grain and dirt visible in the green. That
is a **picture slip baked into the disc's own master**, faithfully encoded. No re-read, re-demux or
re-encode can remove it, because there is nothing missing to recover.

### METHOD RULE: look at ONE FRAME FULL-SIZE before forming a theory

**A tiled contact sheet is for LOCATING a defect. It is never evidence for CHARACTERISING one.**

Scaled to 240 px and butted against its neighbours, this defect read as "green bars intruding and
growing" — which sounds like progressive data loss, which suggested incomplete GOPs, which pointed
at the per-program assembly. Every step followed from the previous one and the whole chain was
wrong. What the tiling actually showed was one frame's green edge abutting the next frame's, plus
the slip itself. **One full-size frame ended the theory immediately**: sharp, complete picture
sliding sideways, with grain and dirt in the green.

Cost of the rule: one `-frames:v 1` extraction. Cost of skipping it: a re-fetch off a slow USB disk,
a full rebuild, and a wrong cause written into three files.

```
ffmpeg -ss <t> -i "<file>" -frames:v 1 -y frame.png      # full size, no scale, no tile
```

**The discriminator, once you are looking at the frame:**

| | decoder fill (data genuinely missing) | transfer / master fault (faithfully encoded) |
|---|---|---|
| shape | flat, macroblock-aligned edges | arbitrary edges; picture displaced or distorted |
| texture | uniform — nothing was decoded there | carries **grain, dust, hairs, scratches** |
| picture | degraded, smeared, propagating | **sharp and complete**, just in the wrong place |
| decoder | emits concealment warnings | **zero** messages |

And the ordering rule that follows from it: when a defect sits at the joins, it *looks* like a defect
caused by joining. **Before rebuilding anything, take a continuous read, stream-copy it losslessly,
and run the check on THAT.** Minutes, and it separates "our assembly broke it" from "the source is
like this" — which is the difference between a fix and a detour.

This is per-disc and must be measured, not assumed: on the D15 control the single-program read was
**bit-identical** to the continuous read across all 290 frames (`psnr=inf`, `mse 0.00`).

### A SOURCE title's `format=duration` is METADATA, not a measurement — count packets

This is the one to carry off this page, because it is not specific to this disc and it puts a hole
in a check the project uses constantly.

```
ffprobe -f dvdvideo -title 8 -i "<disc>" -show_entries format=duration    ->  996.400000
```

That is the full 16:36, and it is **wrong**. The same title DECODES **1,480 packets (~59 s)**, against
**24,910** from a flat read of its VOB. The reported figure is the **IFO's declared PGC time**, copied
out of the disc's own structure — the demuxer never decoded anything to produce it. A duration check
on that title says "fine".

Hold the distinction explicitly:

- **Duration of an ENCODED OUTPUT is trustworthy.** It comes from a real decode, so output-vs-MakeMKV
  comparisons — and `transcode.ps1`'s own duration checks — stay valid.
- **Duration of a SOURCE title read through `-f dvdvideo` is metadata**, and can be perfectly correct
  while the title decodes to a fraction of it.

**To measure a SOURCE, count packets:**

```
ffprobe -v error -f dvdvideo -title N -i "<disc>" -select_streams v:0 -count_packets \
        -show_entries stream=nb_read_packets -of csv=p=0
```

or let the guard do it, over every stream at once, with the zero-packet check as well:

```
pwsh -File scripts/assert-stream-packets.ps1 -Disc "<disc>" -Title N
pwsh -File scripts/assert-stream-packets.ps1 -Path "<file>"
```

**This is why the D13 reel passed every structural check it was given.** Declared duration right
(996.4 s, from the IFO). Frame count right after the `-pg` loop (24,910, matching the disc). Size
plausible. Picture wrong. Each check was answered by a number that never came from looking at the
frames.

**The pattern, which is not about DVDs at all:** of the defects found on 2026-08-28 — this
truncation, a `-pg` program that declared an audio stream and shipped zero packets, an extra that
shipped two zero-packet audio tracks because `audioTracks: []` read as absent, and the seam
corruption itself — **every one was invisible to durations, sizes and stream declarations, and every
one was caught by counting packets.** A declaration is a promise; a packet count is delivery. When
the two can disagree, only one of them is evidence.

### Encoding from a flat VOB drops frames at the cell joins (`drop=` in the progress line)

A DVD's program stream carries a **timestamp discontinuity at every cell boundary**. Feed that to an
encoder and ffmpeg's constant-frame-rate conversion silently discards frames around each one.

Rebuilding the D13 reel from a `-fflags +genpts` remux of `VTS_05_1.VOB` produced **24,885 frames
against the source's 24,910 — 25 lost**, one or two per cell join. The only visible sign at the time
was `drop=25` drifting up in the ffmpeg stats line. The output was otherwise flawless and, crucially,
**internally consistent**: it declared 995.40 s and decoded 995.40 s, so `assert-stream-packets.ps1`
passed it. Nothing inside the file disagreed with anything else inside the file.

Extracting the audio the same way is noisy in a useful way — the remux prints
`non monotonically increasing dts` **once per internal join** (16 for a 17-cell PGC), which is the
discontinuity announcing itself.

**Fix: strip the timestamps and impose a clean rate**, rather than trying to repair them:

```
ffmpeg -i VTS_05_1.VOB -map 0:v:0 -c copy -f mpeg2video reel.m2v      # elementary streams,
ffmpeg -i VTS_05_1.VOB -map 0:a:1 -c copy -f ac3        reel.ac3      #   no timestamps at all
ffmpeg -fflags +genpts -r 25 -i reel.m2v -fflags +genpts -i reel.ac3 \
       -map 0:v:0 -map 1:a:0 -c copy reel-cfr.mkv                     # clean 25 fps CFR
```

`genpts` over a raw ES generates exact 40 ms intervals; `genpts` over the VOB inherits the
discontinuities, which is the whole difference. The re-encode then reports no `drop=` at all and
returns all 24,910 frames. MPEG-2 keeps its aspect flags in the sequence header, so DAR 4:3 and
SAR 16:15 survive the round trip — verify rather than assume.

**Two things to carry:** watch `drop=` on any DVD-sourced encode, and when you know the source's
frame count, gate on it — `assert-stream-packets.ps1 -ExpectVideoPackets <n>`.

#### The general principle, which outlives this bug

**Internal consistency is not evidence of completeness — it only ever proves a file agrees with
itself.** Uniform loss shrinks every number together: duration, frame count and declarations all
move down in step, so nothing inside the file disagrees with anything else inside it and every
self-check passes. Detecting that requires an **external reference** — the source's own count.
This is the general form of half the defects found on 2026-08-28; the frame-drop is just its
instance. Whenever you can obtain a source-side number, gate on it rather than on self-agreement.

#### MEASURED: the ordinary `-f dvdvideo` path is NOT affected — the flat VOB read was the special case

Checked 2026-08-28 rather than assumed, because if the normal path shared the fault then every
multi-cell DVD episode already shipped would be short:

| test | result |
|---|---|
| **4-cell title encoded through `transcode.ps1`** (D15 title 1, 25 s, 3 internal joins) | source **625** packets → output **625**. Exact. No `drop=` at all |
| **10-cell title stream-copied via `-f dvdvideo`** (D15 title 2, 48:10) | **0** dts-discontinuity warnings; **72,255** packets = 2890.20 s = the declared duration exactly |
| **flat VOB read of the same shape** (D13 `VTS_05_1.VOB`, 17 cells) | **16** `non monotonically increasing dts` warnings — one per internal join — and 25 frames dropped on encode |

**The `dvdvideo` demuxer normalises cell timestamps; a flat VOB read does not.** So the exposure is
confined to routes that bypass the demuxer and read the VOB directly — which is exactly the recovery
route this page recommends for a first-cell-truncated title. Use it, but re-time the elementary
streams as above and gate the result on the source count.

⚠ Verify EVERY program before concatenating, not a sample. On D13, program 6 declares its second
audio stream but ships **zero packets** on it, so an item keeping that ordinal would carry a silent
minute — invisible to any duration or size check. The two streams there are the same narration
offset by about a second (`analyze-tracks.py` roles: `primary` / `alternateMix`), so keeping the
stream that is populated everywhere costs nothing.

The general rule, which is not specific to DVDs: **when two tools agree, ask whether they share an
implementation or a bug before treating the agreement as corroboration.** Independent corroboration
has to come from a different KIND of evidence — here, bytes on disk against the disc's own tables.

## Two PGCs over IDENTICAL cells = ONE item with two doors — but do NOT assume WHY (2026-08-29)

> **CORRECTED the same day.** This entry first said identical cell ranges mean a *"play with
> commentary"* entry point. That was true on the disc it was written from and **false on its
> sibling**, and acting on it would have invented four commentaries. The reliable half is that the
> two PGCs are ONE item; the PURPOSE of the second door varies per disc and must be measured.
>
> **Farscape S1 D2**: second door is the commentary entry — those VTSs declare a second audio
> stream and the menu offers `PLAY WITH COMMENTARY`.
> **Farscape S1 D5**: same identical-cell structure, but every VTS declares `audio=1`, there is no
> commentary button, and both doors probe identically. Comparing the PGCs field by field —
> cell_playback, cell_position, audio_control, next/prev/goup, still-time, mode, post-commands —
> they differ in **one bit of one pre-command** (`GPRM 6 := 0xC100` vs `0xC180`), most likely a
> breadcrumb recording which route the viewer took. Recorded as a hypothesis; not load-bearing,
> because both doors provably carry identical bytes.
>
> **So: identical cells ⇒ one item. What the extra door is FOR ⇒ check the audio stream count and
> the menu, on that disc.** Two discs of the same set differed here.

`prove-dvd-mapping.py` reports UNPROVEN where a VTS holds several titles, because they share one VOB
set and byte totals cannot separate them. That refusal is correct — but the disc often answers it
anyway, one level down, and the answer is worth recognising on sight.

Farscape S1 D2, VTS_02 and VTS_03, read from the PGC cell tables in each VTS IFO:

```
VTS_02  title 1 -> PGC 1   cells 0-230149  230150-534226  534227-735887  735888-1006960
VTS_02  title 2 -> PGC 2   cells 0-230149  230150-534226  534227-735887  735888-1006960
```

**Byte-identical cell ranges, and their total is the whole VTS with no remainder.** So it is ONE
episode authored twice, differing only in which PGC you enter by — a *"play with commentary"* entry
point, not an alternate cut. The corroboration is that exactly those two VTSs carry an extra AC3 2.0
stream beside the 5.1, and `ffprobe` shows **either** ordinal exposes **both** audio streams.

Two consequences:

- **The choice of ordinal cannot ship different content**, so the mapping ambiguity is harmless here
  — and `mappingProvenBy` can say so in terms a reader re-derives from the disc, rather than as a
  plausible sentence.
- **Do not ship the pair as two items.** Two titles of identical length in one VTS look like a real
  duplicate or an alternate version; the cell table is what tells them apart from a genuine
  two-episode VTS, where the cell ranges are disjoint and sum to the VTS between them.

Where the ranges are DISJOINT and sum to the VTS, it is genuinely two titles and the per-title
cell-sector totals prove the mapping (see `vts_title_bytes()`). Identical ranges mean one title with
two doors.
