# Extras: validate on disc, then force Plex to match (Season 00 fix-up)

You will do this for **almost every TV set** with a bonus-features disc. The Plex TV
agent reliably mislabels extras — it invents titles ("Episode 5"), pastes summaries
from unrelated online items (a DragonCon panel synopsis onto a making-of), and picks
posters from the wrong thing entirely. Our **filenames are the source of truth**
(named from the disc's own title cards + `mymovies.xml`). This process makes Plex agree
and locks it so a later library refresh can't silently undo it.

Two phases: **(1) validate & name on the disc**, then **(2) apply & lock in Plex**.

---

## Phase 1 — Validate and name the extras (before they go to Plex)

Bonus discs are unlabelled title-wise: the DVD `-menu` flat render does NOT expose
extra names on Paramount/Trek-style discs (they're subpicture button overlays). So
identify each extra by **content**, exactly like episodes:

1. **Enumerate titles** on the stage: `ffprobe -f dvdvideo -title N` for durations.
   Episode titles are the ~43-min ones; the shorter ones (1–18 min) are the extras.
2. **Cross-reference `mymovies.xml`** in the disc folder — its `<ExtraFeatures>` list
   names the *named* features (making-of, crew dossiers, sketchbooks, etc.). The count
   rarely matches the title count: short in-universe clips (e.g. "Section 31 – Hidden
   File 01–10") are usually NOT in mymovies and must be inferred.
3. **Contact-sheet each extra** to read its on-screen title / content:
   `extract-title-cards.ps1 -Dir "<stage or Season 00 folder>" -Filter "<glob>"`
   (or extract inline — `-Filter` uses Get-ChildItem wildcards, NOT regex char classes).
   Match longest→named features in mymovies order; group the short repeated clips.
4. **Name files** as Season 00 episodes, numbered in a stable order (named features
   first, then the short clip series): `<Show> (Y) - S00Exx - <Extra Title>.mkv`.
   Keep EVERY genuine extra (galleries, shorts, trailers, intros) — see
   [capture-all-real-extras]. Encode them like episodes (English audio only, etc.).

The filename `<Extra Title>` you settle on here is what Phase 2 pushes into Plex.

## Phase 2 — Apply and lock in Plex, then fix posters

After the files are on the server and Plex has scanned them, run **one script**:

```powershell
pwsh -File D:\video\.claude\skills\disc-to-plex\scripts\fix-plex-extras.ps1 `
  -Show "Deep Space" `
  -MediaDir "\\NAS\media\Television Shows\Star Trek Deep Space Nine (1993)\Season 00"
```

It matches each Plex Season-00 episode to a file in `-MediaDir` **by basename** and, per item:

- **Title**  → parsed from the filename (` - S00Eyy - <Title>.mkv`), set and `title.locked=1`.
- **Summary** → cleared and `summary.locked=1` (our extras have no canonical synopsis;
  clearing kills the wrong agent text and the lock stops re-injection). `-KeepSummaries`
  to skip; edit `summary.value=<text>` by hand for the rare extra that deserves a blurb.
- **Poster** → a frame ~40% through the extra is extracted with ffmpeg and uploaded.
  Uploaded posters **auto-select and are sticky** across refreshes — no separate lock.
  Pass `-NoPosters` to leave art alone. Verify a couple of frames aren't black by
  eye before trusting a batch (Read the jpg); a low-KB frame can still be a perfect
  dark close-up, so judge by looking, not by file size.

Flags: `-NoTitles`, `-KeepSummaries`, `-NoPosters`, `-Season <n>` (default 0),
`-Section <id>` (default 5 = "TV programmes"), `-PosterAt <0..1>`.

### Why match by basename, not Plex's file path
`Media[0].Part[0].file` is the **server's** path (e.g. `/volume1/...` on the NAS), not a
path this machine can open. We take the leaf and look it up under `-MediaDir`, which you
point at the real files (local D: staging *or* the NAS UNC).

### Env-var gotcha
`PLEX_TOKEN` / `PLEX_BASEURL` live in the **User** environment. Shells launched before
those vars existed inherit a stale (empty) process env, so the script (and any ad-hoc
call) reads them from User scope as a fallback:
`[Environment]::GetEnvironmentVariable('PLEX_TOKEN','User')`. Never write the token to a
file or echo it.

## Verify
Re-query the season and confirm: titles = our filenames, `summary` empty, and the `thumb`
timestamps have all changed to the new uploads (old agent thumb id gone). For one item,
`GET /library/metadata/<rk>/posters` should show the uploaded poster `selected=1`.
`verify-plex-episodes.ps1` covers the numbered seasons; this doc covers Season 00, which
that script doesn't police.

## Related
- `lock-plex-titles.ps1` — the older titles-only tool; `fix-plex-extras.ps1` supersedes
  it for extras (titles + summaries + posters in one pass).
- Episode-side content validation: see identification.md "Validate content with the
  episode title card".
