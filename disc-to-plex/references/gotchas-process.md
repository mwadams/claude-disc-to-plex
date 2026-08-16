# Process gotchas

How this pipeline goes wrong at the level of judgement, not code.

Part of the `disc-to-plex` gotchas set — see [gotchas.md](gotchas.md) for the full index.

## Contents

- [Silent extras drop — the episode-length filter is not a classifier](#silent-extras-drop-the-episode-length-filter-is-not-a-classifier)
- [Structural checks are NOT identity checks — ALWAYS verify identity from the content](#structural-checks-are-not-identity-checks-always-verify-identity-from-the-content)
- [Write the rule into the SCRIPT, not just into this file](#write-the-rule-into-the-script-not-just-into-this-file)

## Silent extras drop — the episode-length filter is not a classifier

A build shortcut that auto-selected titles by an absolute duration window (e.g. "keep 2000–3600 s
titles as episodes") shipped once and **silently discarded every other title** — including any real
featurette/documentary — with no report and no failure. It happened to be safe on that show (the
only sub-episode title was a copyright reel), but on the next disc it would have thrown away genuine
bonus content that can't be re-derived. Two things went wrong: the window doubles as the artifact
filter (so anything outside it just vanishes), and nothing forced a human to look at what was
dropped.

**Rule: account for every real title.** Enumerate the whole disc with `scripts/scan-disc.ps1`
(cross-disc-aware) and classify each title EPISODE / PLAYALL / extra / boilerplate / artifact. Every
non-artifact title must become an episode, a `Season 00` extra, or an *identified* exclusion
(boilerplate: a short title whose exact duration repeats across ≥3 discs — a copyright/anti-piracy
or promo reel, e.g. the 273.000 s Warner "SCHWEIZ" warning on the West Wing DVDs). Never let a title
disappear because it fell outside an episode-length window. When unsure what a title is, extract a
frame and look. See `identification.md` → "Extras → Season 00".

## Structural checks are NOT identity checks — ALWAYS verify identity from the content

The most expensive mistake in this pipeline so far was not a crash, it was **not looking at the
picture**. On Lovejoy every structural check passed and the result was still wrong:

- duplicate title groups frame-verified (each episode listed 3× on the disc) — correct
- durations matched the disc metadata exactly — correct
- episode counts matched the agent per season — correct
- two-parters landed on the disc that held exactly two titles — correct
- `verify-plex-episodes.ps1` reported `MISMATCH=0` — because it only checks the **slot**, and the
  files carried no title token, so every episode came back `NOTITLE`

…and yet every Series 4 file was one slot out, because the 93-minute opener was **The Prague Sun**,
which the agent numbers as **S03E14** — not a Series 4 episode at all. Disc order and agent order
simply are not the same sequence, and nothing structural can reveal that.

**Verifying identity means reading the episode's own title off the screen** (or a VTR clock, or a
plot detail that pins it) and matching it to the agent's title for that slot. Do it for EVERY
episode, not a sample — a one-slot shift looks perfectly consistent from any sample.

Finding the caption takes one sweep, and its position varies **within the same show**:

- Lovejoy Series 2–6: over the opening titles, ~40–50 s in, on screen ~2 s
- Lovejoy Series 1: **after a cold open**, ~3:43 — nothing in the titles at all

So "no caption in the first minute" does not mean "this show has no captions". Sweep wider (and
full-frame, not a cropped band) before concluding one doesn't exist. If a show genuinely has none
(sitcoms often don't), say so explicitly and record that ordering is the only evidence — do not
let silence pass as verification.

## Write the rule into the SCRIPT, not just into this file

This document is >1,000 lines. Reading it end-to-end costs more than a single tool call allows, and
after a context compaction it is a summary that survives, not the detail. That is why the same
mistakes recurred **hours after being documented in capitals**: the Zulu extras were enumerated
correctly with MakeMKV and then encoded from raw `.m2ts` anyway, which is precisely what the
"ENUMERATE BLU-RAYS WITH MakeMKV" entry forbids.

Knowing a rule and applying it are different things, and prose cannot enforce itself. When a lesson
here can be expressed as a check, **put it in the code and make it abort or report**:

- raw-`.m2ts` vs containing-playlist length → preflight abort (`Preflight-BDStreams`)
- untitled / duplicate audio → postflight report
- ffmpeg running / recently-touched folder → `prune-empty-folders.ps1` refuses
- `.mkv` with `duration = N/A` → `publish-work.ps1` refuses

A guard also catches what recall cannot: the containment check above **failed my own "fix"** and
exposed the duplicate trailers within a minute of being written. Prefer a noisy guard to a
remembered rule — but make it precise, or it gets ignored. The first version of this preflight
compared lengths only, so it flagged every extra against the feature playlist; useless noise. It
became useful once it proved containment.

