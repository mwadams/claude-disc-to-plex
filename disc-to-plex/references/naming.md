# Plex naming and library layout

Plex matches by the `SxxEyy` token (TV) and folder/year (movies); titles in filenames are
cosmetic but worth getting right. The single most important rule when adding to a library that
already exists: **match the existing entry's convention exactly**, because the goal is usually a
later *merge without overwriting* into a shared target (e.g. a NAS that fills in seasons over
time).

## Layout

```
<library root>/
  Television Shows/
    <Show (Year)>/
      Season 00/                      # Plex "Specials" = bonus features
        <Show (Year)> - S00E01 - <Extra title>.mkv
      Season 01/
        <Show (Year)> - S01E01 - <Episode title>.mkv
  Movies/
    <Movie (Year)>/
      <Movie (Year)>.mkv
      Behind The Scenes/              # movie extras: Plex local-extras subfolders
        <descriptive name>.mkv
      Featurettes/
      Deleted Scenes/
      Shorts/
      Trailers/
        <descriptive name>.mkv
```

Seasons are two-digit (`Season 00`, `Season 01`, …).

## Movie extras — where TV uses Season 00, movies use local-extras subfolders

Plex has two equally-valid ways to attach movie extras; **this library uses the subfolder form**
(chosen because it scales when a disc carries several of one kind — e.g. a classic-film disc with
six trailers). Inside the movie's folder, create the Plex-recognised subfolders and drop each extra
in the matching one, with a human-readable filename:

- `Behind The Scenes/` — making-of / on-set featurettes
- `Featurettes/` — promotional or documentary featurettes
- `Deleted Scenes/`
- `Shorts/` — vintage shorts bundled on classic-film discs ("Warner Night at the Movies": comedy
  short, musical short, cartoon, newsreel)
- `Trailers/` — theatrical trailers (the film's own and any series/companion trailers on the disc)
- `Interviews/`, `Scenes/`, `Other/` as needed

(The suffix alternative — `<Movie (Year)>-trailer.mkv`, `-behindthescenes.mkv`, `-featurette.mkv`,
`-short.mkv`, `-deleted.mkv` in the movie root — is what Plex also accepts; don't mix the two in one
library.) **Exclude** Warner/studio DVD-advert promos (short modern clips advertising *other*
releases) and copyright/anti-piracy reels — those are boilerplate, not extras. Identify borderline
titles from a frame before keeping or dropping (see `identification.md`, `scan-disc.ps1`).

## Multiple editions — each edition needs its OWN folder, or the local extras disappear

When a disc yields more than one cut of the same film — e.g. the feature plus a **director's-commentary
version**, a theatrical vs extended cut, etc. — Plex supports `{edition-<Name>}` tags. **Do NOT put two
edition files loose in one movie folder.** There is a known Plex bug: as soon as a movie folder contains
multiple editions, Plex stops detecting that movie's **local extras** (`Behind The Scenes/`, `Featurettes/`,
`Trailers/`, …) and they silently vanish from the UI.

**Fix: give each edition its own top-level movie folder** (siblings under `Movies/`), with the
`{edition-<Name>}` tag in the **folder** name and the file named to match. The primary (untagged) folder
holds the feature **and** the extras subfolders; every additional edition is a sibling folder that
contains only its one `.mkv`. Plex still groups them as editions of the same film (matched on title +
year), and the extras keep working:

```
Movies/
  Who Dares Wins (1982)/                                           # primary edition + ALL local extras
    Who Dares Wins (1982).mkv
    Behind The Scenes/ …
    Featurettes/ …
    Trailers/ …
  Who Dares Wins (1982) {edition-Director's Commentary}/           # each extra edition = its own sibling folder
    Who Dares Wins (1982) {edition-Director's Commentary}.mkv
```

So: emit the extra edition to `Movies/<Title (Year)> {edition-<Name>}/<Title (Year)> {edition-<Name>}.mkv`,
never as a second file inside the main folder. (The commentary itself is still tagged inside its file with
`-disposition:a:N comment`; see transcode.ps1 `commentary`.)

## Episode numbering follows the target library's Plex AGENT, not raw TMDB

Plex matches TV by the `SxxEyy` token in the filename, then looks up **that number** in whatever
metadata **agent the target library uses** to fetch the title, artwork, summary, etc. It does *not*
verify that the file's actual content matches — it trusts the number. So if you number by one source
(say TMDB broadcast order) but the library's agent numbers differently, every file shows the *wrong
neighbour's* metadata even though the video is correct. Check the library's agent first:

```
GET http://<server>:32400/library/sections            # find the section, read its "agent"
```

The modern default **`tv.plex.agents.series`** mostly follows TMDB, **but it splits feature-length
pilots/finales into two episode numbers** even though the disc ships them as a single title. The
classic example: DS9 **"Emissary"** (feature-length pilot) is `E01+E02` under the Plex agent, but a
*single* `E01` under TMDB. Number by TMDB and you get a clean **off-by-one shift** for the whole
season from that point on (E02→shows as "Emissary (2)", … last episode falls off the end into a
missing slot). A *uniform* one-slot shift across a whole season is the fingerprint of exactly this:
a feature-length multi-parter counted as N episodes upstream.

**Represent one physical file that spans two episode numbers with the combined-episode filename**
`<Show (Year)> - S01E01-E02 - <Title>.mkv`. Plex maps the single file to both slots — no gap, no
"missing episode", plays for either. Apply the same to feature-length season premieres/finales
(e.g. DS9 S4 "The Way of the Warrior", S7 "What You Leave Behind" — **verify each season**, don't
assume which ones split).

**Verify against the live library, don't trust your own numbering.** After staging a season (or when
a mismatch is reported), query the agent's actual mapping and diff title-vs-filename:

```
GET /library/sections            → section key + agent
GET /library/sections/<k>/all?type=2         → find show ratingKey
GET /library/metadata/<show>/children        → season ratingKey (index == season no.)
GET /library/metadata/<season>/children      → episodes: .index, .title, .Media.Part.file
```

Compare each episode's `.title` to the title embedded in its matched filename; any row where they
differ (other than the deliberate combined-file slot) is a numbering error. Fix by **renaming only
the `SxxEyy` token** (no re-encode), shifting in *descending* order to avoid collisions, then trigger
a scan (`GET /library/sections/<k>/refresh`) and re-query to confirm. The owner `X-Plex-Token` is
required for all of the above and is **not stored** — ask the user (see the `plex-defaults` skill).

## Conventions (confirm the user's preference; these are common defaults)

- **New TV show**: include year + episode title —
  `The Prisoner (1967) - S01E01 - Arrival.mkv`. Add `(Year)` when it disambiguates
  (remakes/duplicates); many titles need it.
- **Adding seasons to a show already in the target**: mirror that show's *existing* filenames
  exactly — even if that means no year and no title (e.g. `The West Wing S04E01.mkv`). Inspect
  the target folder first and copy its pattern; do not impose a different style.
- **Movies**: `<Title (Year)>/<Title (Year)>.mkv`. Add the year where it disambiguates (many
  films share a title). Match the target library's movie convention if it already has similar
  entries.
- **Subtitles**: English only across the board unless told otherwise.

## Merging extras into a show already in the library (partial Season 00)

A show is often delivered in rounds — earlier seasons (and their bonus features) land first, later
seasons arrive on a subsequent batch of discs. **Bonus features accumulate the same way episodes do,
and Season 00 is almost never empty when you return to a show.** Before adding extras from a new
batch of discs, treat Season 00 as a *merge target*, not a fresh start:

1. **Inspect the existing Season 00 on the target** and find the highest `S00Eyy` already present
   (e.g. the West Wing already has `S00E01`…`S00E14` from the Seasons 1–3 delivery). Note the exact
   filename convention in use (the West Wing specials are `The West Wing S00Eyy.mkv` — no year, no
   title, matching its episodes).
2. **Append, don't renumber.** Number the new batch's extras continuing from `max+1` (`S00E15`,
   `S00E16`, …). Never reuse or shift an existing specials number — Plex identity and any watch state
   are tied to it, and `stage-and-clean.ps1`'s no-overwrite copy will *skip* a colliding number
   rather than replace it, so a reused number silently drops your new file. Order the new batch
   sensibly among itself (documentary, featurettes, deleted scenes, galleries, trailers).
3. **Match TMDB specials numbering only if the whole Season 00 already follows it**; otherwise a
   local append is correct and safe. Extras have no canonical global numbering the way episodes do.
4. **Stage with `stage-and-clean.ps1`** (no-overwrite + byte-verify). It adds only the new
   `S00Eyy` files and leaves the existing specials untouched — the same mechanism that merges new
   *seasons* into a partial show. Verify the target afterwards shows the union (old + new), not a
   replacement.

The same merge discipline applies to **movie extras**: if a film's folder already has a `Trailers/`
or `Featurettes/` with items, add new files alongside them with distinct names — don't overwrite.
And note the corollary: **run the extras sweep (`scan-disc.ps1`) on every new batch of discs**, not
just the first — later-season discs carry their own featurettes, and skipping the sweep on "just the
episodes" batch is exactly how bonus features get lost.

## Staging and the final copy

Stage into a working copy of the layout, let the user review, then copy to the final
target (NAS/library) **without overwriting anything already present** — this is how partial
series get completed as discs accumulate over time. Never clobber existing files on the target;
only add what's missing. Pass Windows UNC targets (`\\NAS\share\…`) through **PowerShell, not a
bash shell** — bash eats a backslash and the copy lands on a local drive (see gotchas.md, "Mangled
UNC target"); `stage-and-clean.ps1` now aborts if it detects that corruption.

## Gallery stills: ship ONE item, not N fragments

A disc's photo/stills gallery is often authored as MANY short titles - one per still or per small
group, 10-90 s each. Ship them as a **single** extra ("Photo Gallery", "Stills Gallery"), built by
concatenating the parts with a sensible dwell between transitions. The manifest already supports
this: `src` accepts a **`.txt` concat list**, so N titles produce one output.

The library is consistent about this - `Diamonds Are Forever/Other/Photo Gallery.mkv` (57.6 MB),
`The Princess Bride/Other/Photo Gallery.mkv` (155.3 MB), `The Life and Death of Colonel Blimp/Other/
Stills Gallery.mkv` (65.1 MB), `Public Eye - Photo Gallery - Series One to Four` (152.3 MB).

**Why this is written down.** On 2026-08-23 You Only Live Twice shipped `Gallery 01` … `Gallery 25`,
25 separate 1-4 MB items. Nothing was *wrong* by the recorded rules: they are genuine extras, not
boilerplate, so "keep every genuine extra" was followed correctly. The combining practice existed
only as habit from earlier sessions and appeared nowhere in this skill, so reasoning from the
written rules alone reproduced the fragmentation. A convention that lives only in someone's head is
one context compaction away from being lost.

Do NOT combine: galleries the disc already authors as one slideshow reel, and items with distinct
identities (a trailer, a featurette) merely because they are short.

## TV numbering: PROVE the scheme with one file before numbering a set

Plex's own metadata provider can disagree with the numbering its EPISODE MATCHER uses, and the
provider is the more visible source - so it is the easy way to get a whole box set wrong.

**BBC Television Shakespeare, 2026-08-23.** Every accessible source said ONE season of 37 episodes:
`watch.plex.tv/show/bbc-television-shakespeare` ("37 Episodes"), the provider API
(`metadata.provider.plex.tv/library/metadata/<season>/children` → `totalSize 37`, a single season
of index 1), and that list even named the right plays at the right flat positions - All's Well 15,
Antony 18, Midsummer 21. Wikipedia's broadcast order agreed. The DISCS' OWN `mymovies.xml` agreed
("Shakespeare Collection 15/18/21"). Four independent sources, all consistent, all useless: files
named `S01E15` etc. landed as `local://` items titled "Episode 15", and
`/library/metadata/<rk>/matches` returned ZERO candidates.

TVDB divides the same series into **7 seasons**, and the server matches on that:
`S03E03`, `S03E06`, `S04E03` matched instantly, with correct titles and `plex://episode/...` guids.

The first three episodes already in the library (Romeo & Juliet, Richard II, As You Like It) were
S01E01-03 under BOTH schemes, so they matched and proved nothing. **A set's early episodes often
cannot discriminate between numbering schemes - the first file that CAN is the one to test.**

### The rule

Before numbering a multi-disc set, publish ONE episode whose position differs between the candidate
schemes, scan, and read back its guid:

    plex://episode/...   -> matched; the scheme is right
    local://<ratingKey>  -> NOT matched; the scheme is wrong, whatever the metadata says

Do that BEFORE the rest of the set is encoded. Fixing it afterwards means republishing every file
under new names and handing the user a delete list for the originals, because a wrong name cannot
be deleted from the NAS by this pipeline.

`leafCount` on the server's season counts only what is PRESENT locally, so it never reveals the
scheme. And do not trust a matched SHOW to imply matched EPISODES: the show matched correctly here
the whole time.

## One episode split across TWO files — stack it, don't invent an episode number

The inverse of the combined-episode case above. A disc sometimes carries a single episode as two
titles, because the programme was authored in two parts. **BBC Television Shakespeare's Henry VI
Part One** is one 188-minute episode (`S05E03`) held as two titles of 89:14 and 97:50.

Name them as Plex stack parts under ONE episode number:

```
BBC Television Shakespeare - S05E03 - The First Part of Henry the Sixt - pt1.mkv
BBC Television Shakespeare - S05E03 - The First Part of Henry the Sixt - pt2.mkv
```

**Verified on this server, not assumed** — after publishing, the episode read back as a single
matched item with `plex://episode/...` and **two parts**:

```
S05E03  The First Part of Henry the Sixt   MATCHED   parts=2
```

Check `parts` explicitly. Two files landing as two episodes, or as one episode with a missing
sibling, both look plausible in a folder listing and are only visible in the read-back. It is a
rename to fix, not a re-encode — but only if you look.

**Do NOT give the second half its own episode number.** That would shift every later episode in the
season by one, which is the same off-by-one this file warns about from the other direction.

### The disc's own part card can name the wrong PLAY

Henry VI Part One's second title carries the card **"The Second Part of / Henry The Sixt / Part I"**
— which reads as *2 Henry VI* and is not. It means "the second part of the programme *Henry the
Sixt Part I*". The content settled it: title 3 runs I.i to the end of III.i, title 4 picks up at
III.ii ("the gates of Rouen") and ends at V.v, and the two sum to 187.1 min against a canonical 188.

So identify the play from its TEXT — match the opening and closing speeches to act and scene — and
treat the part card as a label whose grammar is ambiguous. `transcode.ps1`'s DVD path takes exactly
one 1-based title and has no concat form, so two titles means two files; stacking is how they
become one episode.
