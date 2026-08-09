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
