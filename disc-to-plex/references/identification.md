# Identifying titles and getting the order right

The transcode is mechanical; the judgement is *what each title is* and *what number it gets*.
Get this wrong and the library is subtly broken. Confirm ambiguous cases with the user.

## Classify every title first — and exclude menu artifacts

Run `scripts/scan-disc.ps1` over the whole show (`-SrcRoot <parent> -Pattern "<Show> * Disk *"`)
before building a manifest. It probes every title on every disc and labels each EPISODE? / PLAYALL?
/ REVIEW / BOILERPLATE / ARTIFACT, and — because it sees all discs at once — flags repeated
copyright/promo reels as BOILERPLATE. **Every REVIEW row is a probable extra: look at a frame and
place it (Season 00) or exclude it as identified boilerplate. Do not skip a title just because it is
not episode-length** — that blind filter once dropped extras silently (see gotchas.md, "silent
extras drop"). The classifier is a starting point, not the final word: you confirm the REVIEW and
PLAYALL rows.

A disc's `STREAM`/`VIDEO_TS` folder mixes real content with menu/navigation clips. **Only real
content becomes an output.** Exclude menu artifacts explicitly and up front — do not discover
them by encode failure. Tells of a menu artifact:

- Very short (< ~30 s) or a handful of near-identical short clips (menu loops/transitions).
- LPCM audio on a tiny clip, or a **phantom/corrupt audio stream** (`ffprobe` → `sample_rate=0,
  channels=0`). These are animated menu backgrounds, not trailers.
- Duplicated 32-second stings, first-play logos, "press enter" bumpers.

Real content: episodes/features (the big ~equal-length titles), documentaries, alternate edits,
image galleries (long single-image slideshows, often with music), textless/archive material,
featurettes, and genuine trailers (~1 min of episode footage). When in doubt, extract a frame
(`ffmpeg -ss <mid> -i <src> -frames:v 1 out.jpg`) and look.

## Read the extra's OWN TITLE CARD before naming it from a packaging list

The fastest reliable way to name a featurette is to let it name itself. These discs put the title
on screen in the first ~10–45 seconds, and one sweep settles what a packaging list or a memory of
the release cannot:

```powershell
foreach($t in 3,8,14,20,22,24,26,28,30,45){
  ffmpeg -y -v error -ss $t -i $src -frames:v 1 "card-$t.png"
}
```

Stack them and look. On In the Line of Fire this turned two ~20-minute documentaries that both
*sounded* like "the Secret Service one" into a definitive answer: at 22–26 s the second one titles
itself **"In the Line of Fire: The Ultimate Sacrifice"**, over a lower-third reading *Jeff Maguire,
Screenwriter*. The first opens "SHOWTIME PRESENTS", which identifies it as the broadcast
documentary instead.

Two habits that follow:

- **A declared extras list is a hypothesis, not evidence.** Titles from packaging or memory
  routinely fail to match what is actually on the disc — Zulu's disc has two featurettes that match
  neither remaining declared name, and Run Lola Run's declared commentary is simply not present
  (MakeMKV lists seven audio tracks on the feature playlist, none of them a commentary).
- **When content cannot settle a name, use a descriptive one and say so.** A wrong confident title
  is worse than an accurate plain one, and the user can rename in seconds if they know the release.

## A "play-all" of deleted scenes hides duplicates — prove containment, then keep ONE

Discs commonly expose deleted scenes twice: individually, and as a single play-all reel. Shipping
both puts near-duplicate entries in Plex; shipping only the individuals can silently drop a scene
the play-all includes and the individual list does not.

Check by sampling the play-all near the END, not the start — the head always matches the first
scene, which proves nothing. In the Line of Fire's 5:01 reel opens on the same piano-bar dialogue
as the 2:32 individual scene, but at 4:30 it is playing the news-report scene from a *different*
individual title, which established that the reel is the superset. Keep the reel, drop the parts.

Beware the arithmetic shortcut: the individual scenes summed to 3:24 against a 5:01 reel, so the
reel held something not exposed separately at all.

## Episodes vs one-title-per-disc vs concatenated

- **One title per episode** (many Blu-rays, some DVDs): each episode is its own `.m2ts` or DVD
  title — straightforward (`-title N`).
- **Several episodes as separate DVD titles/PGCs in one VTS**: the file view shows one big
  `VTS_0x` but it holds multiple playable titles — a file-size probe can't see PGC boundaries.
- **A whole serial as chapter RANGES inside one title**: one title, episodes delimited by
  chapters (`-title N -chapter_start X -chapter_end Y` per episode → individual MKVs).

Enumerate DVD titles with the `dvdvideo` demuxer — no `lsdvd` needed. Probe each title index for
its duration and aspect:
`ffprobe -f dvdvideo -title N -i <dvd-root> -show_entries format=duration:stream=display_aspect_ratio -select_streams v:0`.
Walk N=1,2,3…; the durations reveal episodes (≈equal, long) vs extras (short) vs the whole-serial
title (very long). For a chapter-range title, probe its chapter list
(`-show_chapters`) and map chapter spans to episodes by runtime or the DVD's "episode selection"
menu.

## The correct order = Plex/TMDB, not IMDb, not on-disc

Plex's TV agent uses TMDB ordering. Fetch the show's TMDB season page and number by *that*
sequence. It frequently differs from IMDb and sometimes from the physical disc order. Note the
year for disambiguation (there may be remakes).

## Cross-checks that pin identity cheaply

- **Commentary-track positions**: box sets advertise "commentaries on episodes X, Y, Z". The
  titles whose audio-track count is one higher than their neighbours are those episodes — this
  alone often fixes a whole disc's mapping. (Count distinct numeric audio indices; see
  `gotchas.md` for the m2ts double-count.)
- **DVD "episode selection" menu screens**: the most reliable per-disc "which episodes are here"
  source, and the tie-breaker when the title probe looks short. Render it from the **menu domain**
  (flat `-ss` into `VIDEO_TS.VOB` only reaches some menu cells):
  `ffmpeg -f dvdvideo -menu 1 -menu_vts 0 -pgc <N> -i <disc> -frames:v 1 out.png` — sweep `-pgc 1..6`;
  one PGC is the index and lists every episode (`-menu 1` needs a non-zero `-pgc`). If the menu lists
  MORE episodes than the title probe found, suspect the dvdvideo multi-cell-truncation bug — confirm
  with MakeMKV and switch to the `kind:"MKV"` route (see gotchas.md, pipelines.md).
- **Distinctive frames**: one recognizable scene per title (a Western episode, a courtroom, a
  specific guest actor) confirms identity fast.
- **Runtime matching** against a known episode list for the tie-breakers.
- **`mymovies.xml` / packaging**: lists the box-set extras by name — use it to name featurettes,
  documentaries, and alternate edits.

## Validate content with the episode title card — do NOT assume disc order = broadcast order

**The single most important identification step for TV box sets.** TMDB/Plex numbering is the
*target* order, but the **physical disc is frequently authored in production order**, which differs
from broadcast order (e.g. DS9 S1 has "A Man Alone" on disc *before* "Past Prologue" — production
codes 403 vs 404 — so title 3 ≠ broadcast episode 3). If you number the disc's titles sequentially
and assume disc order = broadcast order, every affected episode gets the wrong `SxxEyy`, and Plex
then shows the wrong title/artwork for a correct-looking file. **This has bitten a real library.**
Neither the title-duration probe, `mymovies.xml`, nor TMDB tells you what's *actually inside* a
given disc title — they encode an *assumed* order. You must confirm against the video.

**The reliable, automatable check: read the on-screen episode title card.** Most series print the
episode title for a beat right after the main-title sequence (for Star Trek, just after the
"Created By ..." credit — typically 2:40–6:15 in, depending on teaser length). Run:

```
pwsh -File scripts/extract-title-cards.ps1 -Dir "<season folder of encoded MKVs>"
```

It tiles the title-card window into one contact sheet per episode; open each and confirm the
on-screen title (and the guest-star credits, a strong backup when the exact card lands between
frame samples) matches the filename. Any mismatch is fixed by renaming the `SxxEyy` token only —
**no re-encode** — swapping in descending order to avoid collisions. Do this **before** staging to
the NAS and before deleting local copies.

Why not the DVD menu? On some sets the "episode selection" menu render (above) works, but on
**Paramount/Star Trek R2 discs the flat `-menu` PGC render only exposes the language/copyright
reels** — the episode names live in subpicture *button* overlays that a menu-PGC frame grab won't
composite. The title-card method works regardless of menu authoring, so prefer it for these.

Note the API numbering check (`scripts/verify-plex-episodes.ps1`) is complementary but **cannot**
catch this class of error: it compares the agent title to the filename title, both of which agree
when the *number* is right but the *content* is swapped. Only the title card validates content.

`scripts/verify-title-cards.ps1` automates this: it OCRs the card and reports OK/MISMATCH per
episode. Two things it taught us the hard way:

- **The card does not land at a consistent time**, even within one series. *Survivors* series 1 puts
  it at 60s, 68s, 108s — and **276s** for *Corn Dolly*, which opens on a long teaser. A window that
  stops at 200s reports a confident MISMATCH on a correctly-named file. Widen, never narrow.
- **Binarise, don't just greyscale.** These are thin white titles laid over live footage; in plain
  greyscale tesseract returned *nothing* on most of an older transfer, which reads as "unidentifiable"
  when the card is perfectly legible to the eye. Keep only near-white pixels
  (`format=gray,lutyuv=y='if(gt(val,205),255,0)'`) and it reads reliably.
- **Strip stopwords before scoring.** "The Peacemaker" reduces to {the, peacemaker}; a frame
  containing only the word "the" scored **0.50** — a match on nothing.

### 🔴 The card identifies the PROGRAMME, never the VERSION — check the audio before calling it a duplicate

A disc routinely ships the **same episode twice**: once plain, once as a *commentary version*. Both
carry the identical title card, so card-reading alone says "these are the same thing" and invites the
conclusion that one is a misfiled duplicate to be deleted.

On *Survivors* this nearly destroyed genuine extras. `Season 00\Survivors S00E09.mkv` read as *LAW OF
THE JUNGLE* (a series 3 episode) and was logged as an episode misfiled into Specials — the user
corrected it: its **primary audio is a commentary** (cast reminiscing about the shoot), so it is an
extra, correctly placed and merely unnamed. The same was true of `S02E13.mkv` (*Lights of London (1)*
with commentary, filed as though it were episode 13).

**So: when two files carry the same title card, transcribe a:0 on both before concluding anything.**
Programme dialogue vs. people discussing the production is unmistakable in one 20-second sample —
and take two samples, because a commentary track carries programme audio underneath wherever the
participants fall silent, which makes a single quiet sample look identical to the plain version.
Name the survivor descriptively, e.g. `S00E09 - Law of the Jungle (with commentary)`.

## 🔴 Ask the provider for the SPECIALS list too, BEFORE naming any extra

`plex-season-map.ps1 -Season 0` returns the canonical specials with **names and runtimes**, exactly
as `-Season 1` does for episodes. Run it before naming extras, not after.

Rome (2026-08-20) is the cautionary case. The provider lists nine specials — *The Rise of Rome* 24
min, *When In Rome* 23, *Friends, Romans, Countrymen* 11, *Shot by Shot: Caesar's Triumph* 23,
*Shot by Shot: Gladiator* 23 … — and the season-1 box carries the first five. That list was never
consulted, so the extras were named descriptively from what was on screen, and `fix-plex-extras.ps1`
then LOCKED those invented titles over the agent's correct ones:

| canonical | shipped as | why the guess looked right |
|---|---|---|
| Friends, Romans, Countrymen | `Rome 52 B.C.` | "ROME 52 B.C." is a **scene caption inside** the featurette, not its title |
| The Rise of Rome | `Behind the Scenes` | generic placeholder; the piece has no title card |

Runtime matching against the specials list resolves these immediately: 11:03 → the 11-minute one,
23:38 → the 24-minute one. Two of the five were later confirmed outright by their own title cards
(*When In Rome*, *Shot by Shot: Caesar's Triumph*), which proves the provider's names are the real
ones and not an arbitrary catalogue.

The agent's Season 00 titles are usually WRONG for our files because it assigns them **by index** —
that is why `fix-plex-extras.ps1` exists. But the NAMES in that list are genuine. Use the list to
identify what each extra IS; use the filename to fix the ORDER.

## Extras → Season 00

Everything that isn't an episode/feature goes to `Season 00` (Plex "Specials"). Number them
`S00E01…` in a sensible order (documentary, alternate edits, galleries, behind-the-scenes,
textless, restoration comparisons, featurettes, trailers). Numbering is local per show and can
have gaps; reconcile if multiple discs feed one show over time.


## A disc does NOT always hold CONSECUTIVE episodes — check runtimes against canon

The Newsroom season 2 disc 2 holds **E03, E04 and E06**. It skips E05 entirely, because E05 is
absent from this copy of the set. Numbering its three titles in disc order as E03/E04/E05 — the
obvious reading, and the one that had worked on every disc of Spartacus, Chandler & Co and season 1
— shipped an episode one slot out. It encoded cleanly, verified against its source, OCR'd, and
published without a single structural complaint.

What caught it was the **canonical runtime list**, which the provider gives per episode:

```
canonical  E03 58:00  E04 58:00  E05 57:00  E06 50:00  E07 57:00  E08 47:00  E09 59:00
on disc 2  57:46      57:07      —          50:19
```

50:19 is E06, not E05. A seven-minute gap is not rounding.

**So before naming ANY multi-disc set: pull the canonical durations and match every title against
them.** Disc order tells you the sequence of what is present, not which episodes those are. This is
the same class of error as numbering a partial set sequentially, and it is invisible to every check
that does not know what the episodes are supposed to be:

```powershell
# season durations, in the ordering the server actually matches with
pwsh -File scripts/plex-season-map.ps1 -Show "<name>" -Season <n>
```

Content identification remains the arbiter when two canonical runtimes are close (Spartacus had
pairs 23 seconds apart); runtimes are what tell you *which pairs to worry about*.


## Canonical season/episode structure — ask Plex, do not infer it

`scripts/plex-season-map.ps1` fetches what Plex itself believes about a show and matches ripped
files to it. Run it BEFORE naming anything for a TV set.

```powershell
pwsh -File scripts/plex-season-map.ps1 -Show "Spartacus"                                  # seasons + INDEX numbers
pwsh -File scripts/plex-season-map.ps1 -Show "Spartacus" -Season 2                        # canonical titles + runtimes
pwsh -File scripts/plex-season-map.ps1 -Show "Spartacus" -Season 2 -MatchDir <rip folder> # match by runtime
```

Underneath: take the library item's `guid` (`plex://show/<id>`) and ask the provider —

```
GET https://metadata.provider.plex.tv/library/metadata/<id>/children?episodeOrder=<ord>&X-Plex-Token=...
```

which returns the seasons as `<Directory>` elements carrying `index`, `title`, `leafCount` and a
`key` to drill into episodes (title, `index`, `duration`, `originallyAvailableAt`). **Parse it as
XML** — it is not shaped like the local server's JSON, and asking for JSON yields empty fields.

### `episodeOrder` is not optional — the provider serves several different trees

Omit it and you get the `watch.plex.tv` catalogue tree, **which the scanner never matches against**.
The tree your server uses is the one for the section's `showOrdering` preference, read from
`GET /library/sections/<key>/prefs`. The pref spells TheTVDB as `aired`, but the provider wants
`tvdbAiring`. Measured on `plex://show/5d9c0833ba2e21001f18ea2b` (Spartacus):

| `episodeOrder` | seasons returned |
|---|---|
| *(none)* | 1=Blood and Sand 2=Gods of the Arena 3=Vengeance 4=War of The Damned |
| `tvdbAiring` | **0=Gods of the Arena** 1=Blood and Sand 2=Vengeance 3=War of the Damned |
| `tmdbAiring` | 0=Specials 1=Blood and Sand 2=Vengeance 3=War of the Damned |
| `aired` | *(empty — not a provider value, only a section-pref value)* |
| `tvdbDvd` | 1=Season 1 2=Season 2 3=Season 3 *(no titles)* |

Both orderings a library can actually use put **Vengeance at 2**; only the catalogue puts Gods of
the Arena there. Six episodes published as `S02E01–E04` were therefore matched to Vengeance's
episodes, with plausible-looking titles and summaries throughout.

### The binding is sticky — fix it before publishing, not after

Once an episode is matched, none of these move it: a forced item refresh, a forced show refresh,
re-applying the same match via `/match`, or changing the section's ordering. The episode keeps its
`plex://episode/...` guid. Only `PUT /library/metadata/<rk>/unmatch` clears it, and the season
object holds its own binding independently — a season bound to the wrong canonical season will
re-bind its children the same wrong way, so unmatch the SEASON too.

Check `parentIndex` on a matched episode to see which canonical season it really belongs to; when
that disagrees with the season it is filed under, the binding came from a different tree.

### Why this is a step and not an optimisation

- **Season NAMES are not season NUMBERS.** A box set labelled "Blood and Sand / Gods of the Arena /
  Vengeance / War of the Damned" says nothing about indices, and `watch.plex.tv` lists seasons in
  broadcast order with no numbers at all. Reading the order as the numbering is an inference.
- **A wrong title in Season 00 says nothing about where a real season lives.** Publishing extras as
  `S00E01..` on a show with no canonical season 0 makes the agent fill those invented slots from the
  nearest season's episode list — which looks exactly like evidence that the season lives at 0.
- **Runtime matching gets you the rest of the way, but only with the canonical runtimes in hand.**

### Read the matcher's flags honestly

`AMBIGUOUS` means two canonical episodes are within a minute of each other — common, and it means
runtime CANNOT decide. Gods of the Arena E01 and E04 are both 53 minutes. `NO CLOSE MATCH` means the
file is not an episode at all (an extra, a promo, a play-all). In both cases identify from content:
frames, dialogue, or commentary that names the episode.

If the show itself is matched to the wrong thing, `GET /library/metadata/<ratingKey>/matches?manual=1`
is the API behind the UI's "Fix Match" dialog — candidates with guids and scores.

## Blu-ray BD-J menus: the JAR carries the extras list

`BDMV/JAR/00000.jar` on a BD-J disc contains the menu classes, and their **button asset ids** name
the extras the menu offers. On Back to the Future Part II the classes enumerated the pages
directly: 7 deleted scenes plus a play-all, 5 galleries, 2 archival items, 8 Behind-the-Scenes
buttons. The deleted-scene ids were `oldtb, dads, pizza, jennifer, oldcar, burnedout, marty`.

This answers questions the streams cannot: which titles the disc considers extras, how they group,
and which play-all owns which components - without ripping anything.

**Validate it before leaning on it.** Those seven ids were matched one-for-one against the seven
on-screen white-on-black scene cards read from the rips. Only after that agreement was the
technique used for anything not otherwise evidenced. An id is a HINT about authoring, not a
reading of content.

**Expect ids without streams.** That disc's Behind-the-Scenes page had 8 buttons over 7 streams:
the 8th, `photo`, cross-links to the galleries page. A button count is not a title count.

**Ids are not titles.** They are short slugs (`makingTril`, `time`, `hoverboard`) and the visible
labels are rendered from font glyphs, not stored as text - so a menu asset id can tell you a title
EXISTS and roughly what it covers, but it cannot give you the name to ship. Where the name matters
and no card states it, mark the item uncertain rather than expanding a slug into a plausible title.

## DVD menu domain: count the menu PGCs to find an extra that has no title

A packaging list can name an extra that no title on the disc holds, because on DVD an extra can
live entirely in the **menu domain** — built from menu PGCs, with the interactivity *as* the
content. It has no linear playback, the demuxer never exposes it, and no amount of title
enumeration will find it. Left unexplained it reads forever as a missed extra.

The Grange Hill "Series 3 & 4" box declares a **Grange Hill Quiz** that appears on none of its six
discs by title. Counting menu PGCs found it immediately:

| disc | menu PGCs |
|---|---|
| S3 D2 | 12 |
| S3 D3 | 10 |
| S4 D1 | 12 |
| S4 D2 | 12 |
| **S4 D3** | **65** |

The 53 extra PGCs render as one subject page, **40 multiple-choice question stills** (A–D + Exit),
**6 "YOU ACHIEVED GRADE" cards A–F**, and 6 non-rendering navigation PGCs — matching the sleeve's
"Grange Hill boffin or dunce?" exactly. The demuxer exposes 8 titles on that disc and refuses a
ninth, so nothing ships; the finding is that there is correctly nothing to ship.

**Read `VTSM_PGCI_UT` at offset `0xD0` of `VTS_nn_0.IFO`.** Offset `0xC8` is `VTS_PTT_SRPT` and
yields garbage — an easy off-by-one that produces plausible nonsense rather than an obvious error.

**Menu VOB SIZE tells you nothing.** `VTS_02_0.VOB` runs 185–197 MB on every disc in that box,
quiz or not. A big menu VOB is not evidence of a hidden extra, and a small one is not evidence
against.

**A packaging claim is a lead, not an answer — and neither is a first reading of it.** The same
investigation first concluded from the back cover ("Take the quiz to find out! / www.grangehill.com")
that the quiz was a *website*, and wrote that into two dispositions files. The PGC count overturned
it and both were corrected and re-gated. Read the disc, not the box.

## Episode numbers printed on screen — check for them before doing harder work

Some series caption the episode number in the lower third of the opening titles. Grange Hill
Series 4 does, at roughly 33–38 s, just after the "GRANGE HILL / BY <writer>" card — legible on
every head strip, and decisive on its own. **Series 3 of the same show, in the same box, does not.**
So check each series rather than concluding from one that the show either has them or does not.

Where they exist they beat every indirect method. Where they do not, the writer card is a real test
rather than a tautology: a clean writer-block sequence (e.g. two Sandy Welch cards at positions 3
and 5, two Margaret Simpson cards bracketed by Alan Janes) is broken by any one-slot shift, so it
positively rules a shift out instead of merely failing to detect one. Beware that published writer
credits disagree with the cards — Wikipedia credited two co-written Grange Hill episodes to the
series creator alone, and named a co-writer the card omits. The card states what the programme
says; the credit list is a secondary source.

### The count works in BOTH directions — and a one-title disc is not necessarily under-enumerated

The Grange Hill case was an *outlier high* (65 against siblings' 10–12). The same count also explains
the opposite shape. BBC Shakespeare's **Henry VIII** enumerates as a **single title** with no VTS_02
or VTS_03 at all — which looks like a short enumeration, the failure mode this pipeline most fears.

It is not. That disc's boilerplate lives in the **menu domain**, inside a 27 MB `VIDEO_TS.VOB`.
Rendering all 8 VMGM PGCs accounted for every one: 2×29 s root menu, 4× 0.48 s black padding,
PGC 7 = the 23.20 s BBC Worldwide anti-piracy card, PGC 8 = the 10 s DD Home Entertainment ident.
Its total of 18 menu PGCs is *fewer* than any sibling (Part One 49, Part Three 51, Part Two 54) —
the opposite signature, and equally informative.

So: **render, do not merely count.** A count raises the question; the rendered pages answer it. On
Henry VIII the 9 scene-selection pages ran Act I "PROLOGUE" through Act V "SCENE v" with NEXT
greyed out, which independently confirmed that the single title spans the entire play — a check
that cost nothing and corroborated the runtime and the transcribed ending.

**Where a padding PGC lives decides how you record it.** On Hamlet the 0.48 s black pad is a whole
stub VTS that `TT_SRPT` DECLARES, so it needs an explicit `exclude` disposition (given an
out-of-band id so a re-sweep cannot collide). On Henry VIII the identical pads are menu PGCs, which
`TT_SRPT` never declares — nothing to disposition. Same artefact, different bookkeeping.

### DURATION DOES NOT IDENTIFY A PADDING PGC — measure the picture

An earlier note here recorded ~0.48 s black PGCs as this authoring house's navigation padding. That
is true but **not a test**, and using it as one would discard real content. BBC Shakespeare's
**Julius Caesar** renders its scene-selection pages at **0.40 s each** — the same order of duration
as the pads on its sibling discs — and they are genuine menu pages, running Act I sc i to Act V sc v
with 18 thumbnails for 18 chapters.

So a short PGC raises the question; only the PICTURE answers it. Render it and look.

For a LONG suspicious PGC, measure rather than eyeball. **King Lear**'s `VIDEO_TS.VOB` is 194 MB
against Henry VIII's 27 MB, and its VMGM PGC 5 declares **147.48 s** — the exact shape of a hidden
menu-domain extra. Passing every frame through `signalstats` settled it:

    3661 of 3687 frames at YMAX=16 (video black), chroma neutral, YAVG flat at 15.95

The only 8 bright frames were two 4-frame bursts rendering as single magenta scanlines — MPEG
decode artefacts, not content. It is 147 s of black CBR filler, and nothing ships. A 194 MB menu
VOB is not evidence of an extra any more than a small one is evidence against; **CBR filler is
large by construction.**

### The scene index can tell you WHICH TEXT of a play you have

King Lear's scene-selection index gives Act IV **six** scenes (I–VI) — the **Folio** text, which
lacks the Quarto's IV.iii. Corroborated independently by the closing speech being **Edgar's**, the
Folio attribution. Free provenance, from pages you are rendering anyway.

Note also that its chapter table is LONGER than the index — 30 chapters against 26 jump points, so
four marks are simply not exposed as menu buttons. That direction is harmless: **a chapter table
longer than the index cannot hide content.** The dangerous direction is the reverse.

### The menu-PGC offset DIFFERS between VIDEO_TS.IFO and VTS_nn_0.IFO

Two tables, two files, two offsets, and the wrong one yields plausible garbage rather than an error:

| file | table | offset | the trap next door |
|---|---|---|---|
| `VTS_nn_0.IFO` | `VTSM_PGCI_UT` | **0xD0** | `0xC8` is `VTS_PTT_SRPT` |
| `VIDEO_TS.IFO` | `VMGM_PGCI_UT` | **0xC8** | `0xC4` is `TT_SRPT` |

Note that `0xC8` is correct in one file and wrong in the other. Reading `VIDEO_TS.IFO` at `0xD0`,
or `VTS_nn_0.IFO` at `0xC8`, returns a number that looks like a menu-PGC count and is not.

**And a LOW count still hides extras.** Nanny Series 1 counts just **2** menu PGCs per disc — an
outlier low — yet Disc 1's single VTS menu PGC decodes to **nine distinct still pages**: a main
menu, four scene indexes, a Special Features page, and printed-text pages for "Wendy Craig
Filmography" and "A Brief History of the 1930s". One PGC is not one page. Those last two are real
declared extras with **no linear playback** — menu-domain only, nothing to ship — and they must be
written into the dispositions so their absence is never later read as a missed extra.

The absence of a button is evidence too: Disc 2 has no Special Features button at all, which is
exactly why it carries one fewer title than Disc 1. That explains the difference instead of merely
observing it.

Confirming the rule above from a third disc set: **every real menu page on these discs is 0.48 s** —
the same duration this authoring house uses for black navigation padding. Duration identified
nothing. Render.

### The title card is NOT at a fixed offset — a fixed-window sweep reads as "no card"

On Nanny Series 1 Disc 3, two episodes card at **40 s** and the third at **71 s**, because that one
opens on a long near-black thunderstorm before the titles resolve. A sweep that stops at 60 s finds
nothing on it and reports "no card" — which reads as a disc problem rather than as a sampling
problem, and invites identification by position instead.

Sweep a RANGE and OCR one binarised frame per second (38 s to 458 s worked here) rather than
probing a remembered offset. The offset that worked on the last disc, or on the last episode of the
same disc, is not a property of the series.

Related: do not assume the writer credit is stable either. This box's episodes are mostly Brady &
Bingham, but Disc 3 carries **Maggie Wadey** and **Carey Harrison** — a writer new to the box on two
of its three episodes. A writer-block sequence is strong evidence of ORDER (see above), and no
evidence at all about who else may appear.

### IFO playback times: check the frame byte's RATE BITS before trusting a duration

The BCD playback-time field ends in a frame byte whose top two bits give the frame rate: `11` = 25
fps, `01` = 29.97. Nanny Disc 3 carries `01`.

Decoding at the wrong rate does not fail loudly. It yields **plausible, slightly short durations**
and a uniform NEGATIVE cell-sum delta across every title — which looks exactly like multi-cell
truncation, the fault this pipeline most fears, and would send you re-ripping a disc that is
perfectly intact.

Prove the rate rather than assuming it: it is the one at which the IFO times equal ffprobe's
measured durations exactly. On that disc 25 fps gave delta 0.00 on all five PGCs; 29.97 gave a
consistent shortfall.

### The rate bits can be WRONG, not merely unread — agreement with ffprobe is the authority

The note above says to check the playback-time frame byte's rate bits. Othello goes further: **its
bits say `01` (29.97) and the disc is 25 fps.** They are not a field someone forgot to read — they
are incorrect on the disc itself.

Decoded at the rate the bits claim, the times look plausible and every title shows a small uniform
NEGATIVE cell-sum delta (−0.663 s, −0.166 s) — the exact signature of multi-cell truncation. At
25 fps all five PGC times equal ffprobe to four decimals and every cell sum matches its PGC exactly,
delta 0.000.

So treat the bits as a hint and **the agreement with ffprobe as the proof**. The right rate is the
one where IFO arithmetic reconciles; if neither rate reconciles, that is when to suspect the disc.

### A part can carry NO title card at all

Othello's third part opens mid-scene (already at IV.iii) and carries **no card whatsoever**. A
sweep looking for a card would return nothing and leave that part unnamed — and, worse, invite
naming it by position among its siblings.

Identify it the same way as any other title: from the TEXT. Transcribe the opening and check that
it continues exactly where the previous part stopped. On this disc each part began on the line
after the previous part's last line, with no gap and no overlap, which is what actually proves a
multi-part authoring rather than three separate works.

### Menu text pages can explain an anomaly in the disc's own index

Othello's menu carries two printed-text pages with no linear playback: one stating that **"Act II
Scene ii was not filmed by the BBC for this production"**, the other giving the Herald's
proclamation in full. They ship nothing — but they explain why that disc's Act II index has four
entries where the play has five scenes. An index that looks wrong may be documented inside the menu
domain; render it before treating the gap as a fault.
