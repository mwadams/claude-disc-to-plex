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

## Extras → Season 00

Everything that isn't an episode/feature goes to `Season 00` (Plex "Specials"). Number them
`S00E01…` in a sensible order (documentary, alternate edits, galleries, behind-the-scenes,
textless, restoration comparisons, featurettes, trailers). Numbering is local per show and can
have gaps; reconcile if multiple discs feed one show over time.


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
