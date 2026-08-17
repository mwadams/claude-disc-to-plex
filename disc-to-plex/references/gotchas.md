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

## The five that cost the most

Read these before a batch even if you read nothing else. Each shipped wrong content to the
library, and none of them announced itself — every structural check passed.

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

5. **Gate every rip on a byte-complete copy.** Enumerating a half-copied disc silently under-reports
   titles and invents partial sets — and rip-vs-encode duration checks agree with each other, so
   nothing catches it. → [pipeline](gotchas-pipeline.md)

## Guards that now enforce these

Prefer adding to this list over adding to the prose.

| Guard | In | Catches |
|---|---|---|
| Raw `.m2ts` vs a playlist that **contains** it → abort | `transcode.ps1` preflight | truncated extras, wrong cut |
| Untitled / duplicate-signature audio → report | `transcode.ps1` postflight | hidden commentaries, duplicate mixes |
| `.mkv` with `duration = N/A` → refuse to publish | `publish-work.ps1` | unfinalised partial encodes |
| ffmpeg live, or folder touched < 5 min ago → refuse | `prune-empty-folders.ps1` | deleting an active encode's output |
| OCR cue-count and junk-fraction floors → refuse | `ocr-subtitles.ps1` | failed recognition reported as success |
| Bitmap subs with no `.eng.srt` sidecar → refuse | `publish-work.ps1` | publishing AHEAD of the OCR pass |

