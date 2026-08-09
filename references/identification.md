# Identifying titles and getting the order right

The transcode is mechanical; the judgement is *what each title is* and *what number it gets*.
Get this wrong and the library is subtly broken. Confirm ambiguous cases with the user.

## Classify every title first — and exclude menu artifacts

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

## Episodes vs one-title-per-disc vs concatenated

- **One title per episode** (many Blu-rays, some DVDs): each episode is its own `.m2ts`/VTS —
  straightforward.
- **Several episodes per disc as separate DVD titles/PGCs in one VTS**: the file view shows one
  big `VTS_0x` but it holds multiple playable titles. Enumerate with `lsdvd` (or read the IFO) —
  a file-size probe cannot see PGC boundaries.
- **A whole serial concatenated into one title**: split by chapter markers / known runtimes into
  numbered episodes.

## The correct order = Plex/TMDB, not IMDb, not on-disc

Plex's TV agent uses TMDB ordering. Fetch the show's TMDB season page and number by *that*
sequence. It frequently differs from IMDb and sometimes from the physical disc order. Note the
year for disambiguation (there may be remakes).

## Cross-checks that pin identity cheaply

- **Commentary-track positions**: box sets advertise "commentaries on episodes X, Y, Z". The
  titles whose audio-track count is one higher than their neighbours are those episodes — this
  alone often fixes a whole disc's mapping. (Count distinct numeric audio indices; see
  `gotchas.md` for the m2ts double-count.)
- **DVD "episode selection" menu screens**: render the menu VOB frames and read them — the most
  reliable per-disc "which episodes are here" source for TV sets.
- **Distinctive frames**: one recognizable scene per title (a Western episode, a courtroom, a
  specific guest actor) confirms identity fast.
- **Runtime matching** against a known episode list for the tie-breakers.
- **`mymovies.xml` / packaging**: lists the box-set extras by name — use it to name featurettes,
  documentaries, and alternate edits.

## Extras → Season 00

Everything that isn't an episode/feature goes to `Season 00` (Plex "Specials"). Number them
`S00E01…` in a sensible order (documentary, alternate edits, galleries, behind-the-scenes,
textless, restoration comparisons, featurettes, trailers). Numbering is local per show and can
have gaps; reconcile if multiple discs feed one show over time.
