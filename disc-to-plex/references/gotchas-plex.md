# Plex gotchas

Matching, extras indexing, Season 00 specials, posters.

Part of the `disc-to-plex` gotchas set — see [gotchas.md](gotchas.md) for the full index.

## Contents

- [A section scan does NOT index local movie extras — force-refresh the ITEM](#a-section-scan-does-not-index-local-movie-extras-force-refresh-the-item)
- [TV extras go in Season 00 — the `Behind The Scenes/` folders are the MOVIE convention](#tv-extras-go-in-season-00-the-behind-the-scenes-folders-are-the-movie-convention)
- [Season 00 extras: match the AGENT'S canonical order, don't invent your own](#season-00-extras-match-the-agents-canonical-order-dont-invent-your-own)
- [A confident agent match can be the WRONG FILM — titles collide across markets](#a-confident-agent-match-can-be-the-wrong-film-titles-collide-across-markets)
- [Plex renames Season 00 extras to its own specials list](#plex-renames-season-00-extras-to-its-own-specials-list)

## A section scan does NOT index local movie extras — force-refresh the ITEM

After staging a movie folder containing `Behind The Scenes/`, `Deleted Scenes/` etc., a plain
`/library/sections/<key>/refresh` creates the movie but lists **only the agent's online extras**
(`trailer`, `sceneOrSample` fetched from Plex's servers). The local subfolders are ignored, which
looks exactly like "Plex didn't accept my extras layout".

They appear after a forced refresh of the movie itself:

```
PUT /library/metadata/<ratingKey>/refresh?force=1
```

Verify with `GET /library/metadata/<rk>/extras` — local ones carry a `Media/Part/file` and the
right subtype (`deletedScene`, `behindTheScenes`). On `An Education` this took the count from
9 (all remote) to 21 (12 local + agent's own). Don't restructure the folders before trying this.

## TV extras go in Season 00 — the `Behind The Scenes/` folders are the MOVIE convention

Plex has two different extras conventions and they are **not interchangeable**:

- **TV shows** → `Season 00/` as `<Show (Year)> - S00Exx - <Extra title>.mkv`
- **Movies** → local-extras subfolders inside the movie folder (`Behind The Scenes/`, `Featurettes/`,
  `Deleted Scenes/`, `Shorts/`, `Trailers/`, `Other/`)

Putting TV extras into `Other/` or `Shorts/` under the **show** folder **fails silently**: the library
scans without error, `useLocalAssets` is `true`, the files sit on disk with correct names — and the
show's `/extras` endpoint returns only Plex's own online trailer. Nothing anywhere reports a problem;
the extras are simply invisible in the UI. (Real incident 2026-08-13: nine Doctor Who extras and an
Outnumbered making-of were staged into `Other/`, `Shorts/` and `Behind The Scenes/`. The user spotted
that the extras never appeared. Because the wrongly-placed copies were already on the delete-protected
NAS, they had to be flagged to the user for manual removal, and one extra whose local copy had already
been reclaimed had to be re-ripped from the source disc.)

**The temptation to avoid:** a show like Doctor Who has a Specials season full of *canonical broadcast*
specials, so dropping DVD featurettes into `Season 00` looks wrong. It isn't — that is where they go.
Handle the collision the documented way instead: read the existing Season 00, **append from
`max(index)+1`** (never renumber), then run `fix-plex-extras.ps1 -FromIndex <first new index>` so only
the new entries get titles set+locked and the canonical earlier specials keep their agent metadata.

## Season 00 extras: match the AGENT'S canonical order, don't invent your own

The Plex series agent ships its own Specials list for many shows, and it assigns those titles
**by index** to whatever file lands in each slot. So if you number extras in the order you happen to
rip them, Plex will confidently mislabel every one — the interview shows up titled as the extended
episode, the gallery as the interview, and so on. The files are fine; the numbering is wrong.

**Before naming Season 00 files**, read what the agent already expects:

```powershell
$eps = Invoke-RestMethod -Uri "$b/library/metadata/<season0RatingKey>/children?X-Plex-Token=$t"
$eps.MediaContainer.Video | Sort-Object index | ForEach-Object {
  "E{0:D2} '{1}' dur={2}ms <- {3}" -f [int]$_.index,$_.title,$_.duration,(Split-Path $_.Media.Part.file -Leaf) }
```

Match your rips to those canonical entries **by content and runtime** (the agent's summaries often
name a runtime — e.g. "an untransmitted 75-minute version" pinned a 4508 s rip to E01), then number
your files to agree. Extras the agent doesn't know about go after the canonical ones, and only those
need `fix-plex-extras.ps1` to set+lock titles from filenames.

**Scope the fixer with `-FromIndex`** so it touches only the unknown extras: it clears summaries, and
the agent's canonical summaries (like a restoration note explaining *why* an extended cut exists)
are worth keeping. TMDB's own Specials page may be empty while the Plex agent still has entries —
trust what the server returns, not the metadata site.

## A confident agent match can be the WRONG FILM — titles collide across markets

`Now It Can Be Told` (1944, RAF Film Production Unit — a documentary about SOE agents, using the
real agents as its cast) matched cleanly to **`The House on 92nd Street` (1945)**, an American
studio thriller. Not a fuzzy match: that film was released in Britain *as* `Now It Can Be Told`, so
the agent had a genuine alias to match on. Nothing in the match looked broken — right title, right
era, plausible poster — and only the user noticing the wrong name in Plex surfaced it.

The tell is a **mismatch of kind**: an IWM/BFI archive documentary landing on a Hollywood feature,
or a 25-minute short landing on a 90-minute film. Whenever an obscure archive disc matches a
well-known title, read the agent's summary and compare it against the disc's own description before
accepting it.

Fixing it, in order:

1. Find the film under its *other* title — `/matches?manual=1&title=<alt>&language=en-GB`. Here the
   cinema release was `School for Danger` (1947); the disc's own notes said so, describing
   `Now It Can Be Told` as "a longer version, prepared for special release".
2. Apply it: `PUT /library/metadata/<rk>/match?guid=<guid>&name=<name>`.
3. Lock the title to what the film's **own title card** says, not the agent's preferred title:
   `PUT /library/metadata/<rk>?type=1&title.value=…&title.locked=1`.
4. Give it the disc's cover art with `set-poster-from-disc.ps1` — the agent's poster belongs to the
   other cut and misrepresents what is actually in the file.

The disc's `mymovies.xml` `<Description>` is the best evidence here: it routinely explains alternate
titles, which version this print is, and why the runtime differs.

## Plex renames Season 00 extras to its own specials list

After adding local `S00Exx` files, the TV agent matches them **by number** against whatever
specials list it holds for the show and overwrites your titles. It does not look at the content.
Reaper's S00E01 (a gag reel) came back as "Unaired Pilot"; The Prisoner's S00E01 (the Comic-Con
panel) came back as "Inside the Prisoner - Arrival", and 22 of its 23 extras were wrong.

Numbers past the end of the agent's list are left as bare "Episode 18", "Episode 19", … so a
partially-correct season is the normal outcome — which makes it easy to glance at the first few
rows, see plausible names, and miss that they belong to different pieces entirely.

Fix: after the section refresh, PUT an explicit locked title on **every** special, never just the
ones that look wrong:

```
PUT /library/metadata/<rk>?type=4&title.value=<urlencoded>&title.locked=1
```

Then read the season back and eyeball all of it against your own mapping. Do not skip this because
some titles already look right — matching titles are coincidence, not confirmation.

