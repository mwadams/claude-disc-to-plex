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
```

Seasons are two-digit (`Season 00`, `Season 01`, …).

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
