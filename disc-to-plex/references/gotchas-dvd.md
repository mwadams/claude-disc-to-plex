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
- Recovering such a title is not simply "read the VOB directly": D13's 17 cells alternate between
  audio streams `0x80` and `0x81` (ending at 12:31 and 11:31 against 16:36 of video), so a flat read
  yields video with holes in the audio.

### The remedy: read each PROGRAM, not the title (SOLVED 2026-08-28)

`-chapter_start`/`-chapter_end`, `-preindex` and `-trim` all still truncate. **The demuxer's program
option does not:**

```
ffmpeg -f dvdvideo -pgc 1 -pg N -title M -i "<disc>" -map 0 -c copy pgN.mkv
```

Each program is returned IN FULL, and the per-cell `0x80`/`0x81` alternation resolves when a program
is read in isolation — every program then exposes both audio streams populated for its whole length.
Concatenate the programs (`-f concat`) into ONE item; do not ship N fragments (see the gallery rule
in `naming.md`).

Measured on D13 title 8: 17 programs, **996.66 s total = the declared 00:16:36 exactly**, and
**24,910 frames — the same count a flat read of `VTS_05_1.VOB` produces**, so the programs tile the
reel with no gap and no overlap. That frame-count identity is the check worth copying: it proves
completeness against the disc rather than against the tool that was wrong.

⚠ Verify EVERY program before concatenating, not a sample. On D13, program 6 declares its second
audio stream but ships **zero packets** on it, so an item keeping that ordinal would carry a silent
minute — invisible to any duration or size check. The two streams there are the same narration
offset by about a second (`analyze-tracks.py` roles: `primary` / `alternateMix`), so keeping the
stream that is populated everywhere costs nothing.

The general rule, which is not specific to DVDs: **when two tools agree, ask whether they share an
implementation or a bug before treating the agreement as corroboration.** Independent corroboration
has to come from a different KIND of evidence — here, bytes on disk against the disc's own tables.
