# The identity register — disc → title/chapter → published file

Working out which episode a disc title actually contains is the most expensive step in this
pipeline, and it was being paid for repeatedly because the answer was never written down.
The register makes it a one-time cost.

**Store:** `\\NASTEAMV\Multimedia\_disc-identity\<discId>.json`, a sibling of the two Plex
library roots so Plex never indexes it. Working mirror: `D:\video\_disc-identity`.
**Tool:** `scripts/disc-identity.ps1`.

## Why the cheap sources are not enough

**mymovies.xml numbering and the Plex agent often disagree** (user, 2026-08-31). Neither is
authoritative. Settling it has meant on-screen title sniffing and audio matching, and that is
exactly the effort worth recording.

**Runtime cannot break the tie where episodes share a length.** All four Babylon 5 episodes on a
disc run ~42:00, so a mymovies episode number cannot be attached to a MakeMKV title id by duration
at all: across the whole media2 drive only 70 of 292 episode-bearing titles matched unambiguously.

**Folder names lie.** `E:\Movies\The Hound of the Baskervilles` holds the 1968 Peter Cushing
*Sherlock Holmes Collection*, which is neither of the two library works of that name.

## The key

The MyMovies disc ID from `<disc>.dvdid.xml` (`MMDISCID-KYCP972J`). It is derived from the disc,
so it survives the folder being renamed and the disc moving to another drive — a folder name
survives neither. On media2, 199 of 201 discs carry one and all 199 are distinct.

- No `dvdid.xml` → `FP-<sha1 of sorted title runtimes>`. Two discs on media2 need this.
- **Sanitise the FILENAME only.** At least one real ID contains `|` (`MMDISCID|9H8H4L1J`), which
  is illegal in a Windows filename; `discId` inside the record keeps the true value.

## Claims vs outputs — the distinction the file exists to preserve

A **claim** is what a metadata source asserts. `claims.mymovies` and `claims.plex` sit side by side
and **neither is promoted to the answer**. An **output** is what was actually produced, and it is
written only after the content was examined.

Recording an output that contradicts a claim files a `disagreements` entry automatically, so the
conflict is preserved instead of being quietly resolved and forgotten:

```
DISAGREEMENT FILED: plex claimed t0 = S01E02, recorded as S01E01 by title-card-ocr
```

`-Method title-card-ocr|audio-match` **refuses to write without `-Evidence`** — a resolution with
no evidence is an assertion.

## Schema (disc-identity/2)

```
discId, discIdSource, discFolder, sourceDrive, discTitle, discYear, fingerprint
titles[]   { makemkvTitle, dvdTitle, clip, runtimeSec, sizeBytes,
             audioStreams, subStreams, subLangs, claims:{mymovies, plex} }
outputs[]  { outFile, kind, work, season, episode, name,
             sources[] { makemkvTitle, chapterStart, chapterEnd, dvdTitle, clip },
             method, evidence, confidence, resolvedOn }
disagreements[], notes[]
```

Three things the schema is careful about, each because a simpler shape breaks a real case:

- **`sources` is a LIST.** Several titles legitimately become one file — a stills gallery ships as
  a single item, and compilation discs concat several shorts. One title-id field cannot say that.
- **Chapters are first-class.** Some discs author a whole side as ONE title and episodes are cut
  from it by chapter range: Queer as Folk disc 1 is a single 129.63-minute title holding four
  episodes totalling 129.81. Without `chapterStart`/`chapterEnd` the record cannot express which
  episode came from where.
- **`makemkvTitle` and `dvdTitle` are different numbering.** A DVD is encoded with
  `-f dvdvideo -title N`, where N is the **PGC** number, not the MakeMKV title id. Storing one
  integer called "title" silently conflates two schemes.

## Usage

```powershell
# ALWAYS first - a resolved disc needs no identification at all
pwsh -File scripts/disc-identity.ps1 -Action Lookup -Disc 'E:\Movies\<disc>'

# record what a source asserts, without endorsing it
pwsh -File scripts/disc-identity.ps1 -Action Claim -Disc '<disc>' -Title 0 `
     -ClaimSource plex -Season 1 -Episode 2

# record what you established, and from exactly what
pwsh -File scripts/disc-identity.ps1 -Action Record -Disc '<disc>' `
     -OutFile '\\NASTEAMV\Multimedia\Television Shows\Babylon 5\Season 01\... .mkv' `
     -Source t0 -Kind DVD -Work 'Babylon 5' -Season 1 -Episode 1 `
     -Name 'Midnight on the Firing Line' `
     -Method title-card-ocr -Evidence 'card at 00:01:12'

# reverse lookup: published .mkv -> disc, titles, chapters
pwsh -File scripts/disc-identity.ps1 -Action Index -Disc '<any disc>'
```

`-Source` accepts `t<makemkvTitle>[:<chapStart>-<chapEnd>][/pgc<N>][/clip<name>]` and takes several:
`-Source @('t5:1-3','t6')` records one output built from a chapter range of t5 plus all of t6.

⚠ **Pass multiple sources with `&`, not `pwsh -File`** — `-File` flattens an array argument into a
single string, which the parser then rejects (correctly, but confusingly).

`-Source t99` is refused when the disc's record has no such title, so a typo cannot invent
provenance.

## What good output looks like

```
MMDISCID-KYCP972J  Babylon 5: The Complete First Season [Babylon 5 Season 1 Disk 1]
  t0      42.0 min  Babylon 5 - S01E01 - Midnight on the Firing Line.mkv  plex S01E02 [confirmed]
  t5       0.9 min  Babylon 5 - S00E01 - Gallery.mkv                      [confirmed]
  t6       0.2 min  Babylon 5 - S00E01 - Gallery.mkv                      [confirmed]
  OUTPUTS PRODUCED FROM THIS DISC:
    ...\Season 00\Babylon 5 - S00E01 - Gallery.mkv
        <- t5 ch1-3 + t6  [operator, confirmed]
  DISAGREEMENTS ON RECORD:
    t0: plex claimed t0 = S01E02, recorded as S01E01 by title-card-ocr
```
