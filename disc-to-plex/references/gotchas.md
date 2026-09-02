# Gotchas — index

Non-obvious failure modes hit while building this pipeline. Each one cost a batch re-run, a
re-rip, or a wrong file shipped to the library; most of the fixes are baked into
`scripts/transcode.ps1` and the other scripts.

**This file is an index. Read the domain file that matches what you are about to do** — not all
of them, and not this one alone. The full set runs to ~1,100 lines, which is why it is split:
loading it whole crowds out the work, and a summary of it loses exactly the operative detail.

> **If a rule here can be expressed as a check, it belongs in a script, not in prose.**
> Two rules in this file were violated within hours of being written, one of them written in
> capitals. Documentation cannot enforce itself. See
> [gotchas-process.md](gotchas-process.md) → *Write the rule into the SCRIPT*.

## Which file do I need?

| Doing this | Read |
|---|---|
| Picking a Blu-ray title, playlist, or stream; cropping; PGS | [gotchas-bluray.md](gotchas-bluray.md) |
| Ripping a DVD, choosing titles, multi-episode discs | [gotchas-dvd.md](gotchas-dvd.md) |
| Choosing/labelling audio tracks, finding commentaries | [gotchas-audio.md](gotchas-audio.md) |
| Subtitle selection, language tags, OCR | [gotchas-subtitles.md](gotchas-subtitles.md) |
| Anything after the encode: matching, extras, posters | [gotchas-plex.md](gotchas-plex.md) |
| Staging, copying, gates, encode settings, killing jobs | [gotchas-pipeline.md](gotchas-pipeline.md) |
| Deciding whether you are *done*, or trusting a check | [gotchas-process.md](gotchas-process.md) |

## The six that cost the most

Read these before a batch even if you read nothing else. Each shipped wrong content to the
library, and none of them announced itself — every structural check passed.

0. **Get subtitles by OCRing the disc, never by downloading them.** A guarded, library-wide
   download pass put **~570 wrong-programme subtitles into 2,681** — one in five. Grange Hill
   had King of the Hill, Public Eye had Queer Eye, Lord Peter Wimsey had a Pablo Escobar
   documentary. No threshold separates them: the wrong matches score 0.50 while correct ones
   score 0.40 (DS9) and 0.00 (The Killing ← *Forbrydelsen*).
   → [subtitles](gotchas-subtitles.md#sourcing-ocr-the-disc-do-not-download--a-wash-up)

1. **Enumerate Blu-rays with MakeMKV, not by file size.** The biggest `.m2ts` is routinely not the
   feature: The Italian Job shipped a 95-minute cut of a 99.5-minute film, with two commentaries
   invisible to ffmpeg. → [bluray](gotchas-bluray.md)

2. **A `.mpls` need not contain the stream that shares its number.** Zulu's `00020.mpls` holds
   clips 00019+00021. Reading the length gap as truncation shipped two identical trailers and
   deleted the real teaser. Prove containment before "fixing" a length mismatch.
   → [bluray](gotchas-bluray.md)

3. **Identify audio by transcribing it, never from metadata order.** Disc metadata says which
   languages exist, never which ordinal each one is. Guessing produced two confident wrong answers
   on one disc; a sweep later found unlabelled commentaries on nine of eleven films.
   → [audio](gotchas-audio.md)

4. **Structural checks are not identity checks.** On Lovejoy every count, duration and slot check
   passed while a whole series sat one episode out. Read the episode's title off the screen.
   → [process](gotchas-process.md)
   **And the card identifies the PROGRAMME, not the VERSION** — a disc ships the same episode plain
   and as a *commentary version*, both with the identical card. Transcribe `a:0` before calling
   either a duplicate; on Survivors that mistake would have deleted genuine extras.
   → [identification](identification.md)

5. **Gate every rip on a byte-complete copy.** Enumerating a half-copied disc silently under-reports
   titles and invents partial sets — and rip-vs-encode duration checks agree with each other, so
   nothing catches it. → [pipeline](gotchas-pipeline.md)

## Guards that now enforce these

Prefer adding to this list over adding to the prose.

| Guard | In | Catches |
|---|---|---|
| Staging folder still growing, or short against source → **abort** | `assert-staged-complete.ps1` (run BEFORE enumerating) | **#5** — the half-copied disc. `_fetch-done.txt` does NOT cover this: it gates the FETCH, and enumeration is a separate command |
| On-screen episode title card OCR'd vs filename → **MISMATCH** | `verify-title-cards.ps1` | **#4** — a one-slot numbering shift that every count and duration check passes |
| Raw `.m2ts` vs a playlist that **contains** it → abort | `transcode.ps1` preflight | truncated extras, wrong cut |
| Untitled / duplicate-signature audio → report | `transcode.ps1` postflight | hidden commentaries, duplicate mixes |
| `.mkv` with `duration = N/A` → refuse to publish | `publish-work.ps1` | unfinalised partial encodes |
| ffmpeg live, or folder touched < 5 min ago → refuse | `prune-empty-folders.ps1` | deleting an active encode's output |
| OCR cue-count and junk-fraction floors → refuse | `ocr-subtitles.ps1` | failed recognition reported as success |
| Bitmap subs with no `.eng.srt` sidecar → refuse | `publish-work.ps1` | publishing AHEAD of the OCR pass |
| Exact `SxxEyy` no longer satisfies the title guard alone | `plex_subtitle_search.py` | another show's episode N |
| Resynced tracks keep the SOURCE name, not the library label | `plex_subtitle_resync.py` | a wrong-show sub disguised as correct |
| Anchor pinned to its search bound → treat as failed, not agreed | `plex_subtitle_resync.py` | confident shifts built on no measurement |


## `mappingAmbiguous: false` was not proof — greedy assignment can pick a losing permutation

`catalogue-dvd.ps1` maps MakeMKV titles onto dvdvideo titles by duration, taking the per-title
minimum one title at a time. That is **not an optimal assignment**, and until 2026-08-26 the
ambiguity flag only caught EXACT ties on a single title — never the case where a different pairing
gives the same TOTAL error.

`Out D1`: MakeMKV 0:50:31 and 0:50:30 against dvdvideo titles of 3035 s and 3032 s.

| pairing | deltas | total |
|---|---|---|
| chosen  `t01→3, t02→2` | 1 + 5 | **6** |
| swapped `t01→2, t02→3` | 4 + 2 | **6** |

Identical. At each individual step the minimum was unique, so nothing flagged — and the catalogue
recorded the **wrong** pairing with `mappingAmbiguous: false`. Its `t001` frames and speech sample
were dvdvideo title 3's content, filed against t01.

A subagent caught it by falling back to MakeMKV's per-title **size** (2.13 / 1.88 / 2.06 GiB), which
is not close. Had it trusted the flag, two episodes would have shipped swapped — structurally
perfect, content wrong.

Now fixed: after the greedy pass, every PAIR is tested for whether exchanging their assignments
leaves the total error equal or lower. If it does, both are marked ambiguous, which makes
`assert-accounted.ps1` refuse `card:`/`frame:`/`speech:` citations against them and forces
corroboration from a rip, a size, or the disc's own menu.

**When durations are within a few seconds of each other, SIZE is the tiebreak** — MakeMKV reports it
per title and equal-length episodes are rarely equal-weight.

### A second bug, introduced while fixing the first

The swap check originally logged with `Write-Output` — inside a function that RETURNS a value.
PowerShell appends it to the return, so the caller received an array of `[log strings + hashtable]`
and indexed strings by integer, getting a silent blank for every field. Use `Write-Host` for
progress inside a value-returning function.

It survived the first smoke test because the CONTROL case (well-separated durations) never reached
the logging line and so still worked. **A test that only exercises the path you did not change
proves nothing about the path you did.**

## `ffprobe -read_intervals` takes ABSOLUTE timestamps — and silently clamps

Blu-ray `.m2ts` clips routinely start at a large PTS base. Sherlock's carry **~36599 s**. Asking
for `-read_intervals 600%+120,2400%+120,4200%+120` therefore requests three intervals that are all
*before the stream begins*, and ffprobe does not error — it **clamps each to the start** and returns
**the same first 120 seconds three times**.

The damage is that the result looks right. Counting subtitle packets that way gave
`157 / 157 / 157` and `237 / 237 / 237`: a plausibly steady rate, three "samples" agreeing, and
entirely one sample repeated. The same shape would defeat any spot-check that samples a file at
several offsets — audio language, scene content, bitrate.

**Read `start_time` from the container first and offset every interval by it**, or use `-ss` on the
input, which is relative. And treat identical values across supposedly independent samples as a
symptom, not as corroboration.

## The commentary word-list is the weak link, not the measurement

On Sherlock's *The Great Game*, an ad-hoc `identify-audio.py` pass labelled the commentary track
**"dialogue"** at two of three offsets, because those windows happened to contain none of its stock
hint phrases — while the content was plainly production talk (*"this is actually based on a true
case… it happened in France"*).

`analyze-tracks.py` classified the same stream correctly, because it does not rely on the phrase
list alone: it measures **similarity against the primary** (0.14 here) and re-samples any `dub`
verdict at three further offsets before letting it stand.

So when the two disagree, believe the measurement. And do not use the hint list on its own to
decide a track's role — it is a tiebreak, not a test. This is the same lesson as the M fix, where a
commentary was nearly dropped because its sampled minute said "Uli Lomo's film" rather than "the
film".

## Never put `-ss` before `-i` on the dvdvideo demuxer

Its input seek is **approximate**: measured landing errors ran **0.8–10.5 s**, varying per seek
target and per title on the same disc, and `-preindex 1` does not fix it (identical −10.464 s at
one probe with and without). The error is **silent** — the output decodes normally, looks right,
and carries no hint of where it actually starts. To read a disc title at time T, put `-ss T`
**after** `-i` (output-side seek, verified sample-exact), or decode from the title's start and
index within the decoded stream. Input-side `-ss` on an indexed `.mkv` is fine — this is a
dvdvideo (and raw-VOB) problem, not an ffmpeg one.

What it manufactures is a **"drifting offset / different cut" finding**. Boston Legal S3 Disk 1
(2026-09-02): disc↔NAS audio windows cut with input-side `-ss` cross-correlated to lags of
−1.96 s at one landmark and −10.35 s at another on the same episode, different again on each of
the other three — recorded as fact, as "the NAS legacy encodes are cut differently", with a
per-episode resync or a re-encode as the consequence. A seek-free re-measure (both sides decoded
start-to-finish at 16 kHz mono, FFT xcorr at 6–11 probe points per episode) found a **constant**
+0.117–0.149 s on all four episodes, zero drift — and the input seek's landing errors reproduce
the false figures to 0.01 s. Same session, the "7 s longer" duration discrepancy that seemed to
corroborate the different-cut story came from the catalogue's `duration` field, which ran
**6–9 s short** on all four titles. So, to measure a disc↔published offset: decode **both** audio
streams start-to-finish at 16 kHz mono, cross-correlate windows at several probe points, and take
durations from decoded sample counts — never from the catalogue's `duration` field.

This was the **third** derivation of the same quirk. Babylon 5 S5 D5/D6 ("capture-evidence.py
seeks without `-preindex` and that offset is not constant on this set, so each title was decoded
FROM ITS START at 1 fps") and Harry Potter Azkaban ("NOT sought with -ss, whose offset is not
constant on these discs") had both already hit it and worked around it — but the knowledge lived
only inside those dispositions files, so the next agent re-derived the method wrongly and this
time recorded a false finding as fact. That is why the rule now lives here.

Related, from the same session — the second false alarm manufactured by a measurement *method*
rather than the media: `ffprobe ... 2>&1 | Select-Object -First N`. `-First` terminates the
pipeline once satisfied, which **kills the still-running native process**, and the truncated
output reads exactly like a tool failure — it manufactured a phantom "libdvdread cannot open any
disc" regression that cost hours. The lane-launch variant of the same defect (the pipe closing
early makes a live encode report *completed*) is in
[pipelines.md](pipelines.md#launching-a-lane-so-its-completion-is-reported-honestly); the rule is
one rule: **never filter a live pipe with an early-closing cap — capture first, filter after.**
