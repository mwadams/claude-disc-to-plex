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

## Staging and the final copy

Stage into a working copy of the layout, let the user review, then copy to the final
target (NAS/library) **without overwriting anything already present** — this is how partial
series get completed as discs accumulate over time. Never clobber existing files on the target;
only add what's missing.
