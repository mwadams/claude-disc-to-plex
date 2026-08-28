# Process gotchas

How this pipeline goes wrong at the level of judgement, not code.

Part of the `disc-to-plex` gotchas set — see [gotchas.md](gotchas.md) for the full index.

## Contents

- [Silent extras drop — the episode-length filter is not a classifier](#silent-extras-drop-the-episode-length-filter-is-not-a-classifier)
- [Structural checks are NOT identity checks — ALWAYS verify identity from the content](#structural-checks-are-not-identity-checks-always-verify-identity-from-the-content)
- ["Same size" is not "same file" — and "it finished" is not "it finished"](#same-size-is-not-same-file-and-it-finished-is-not-it-finished)
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

## "Same size" is not "same file" — and "it finished" is not "it finished"

Two variants of one habit: reaching for a signal that is *easy to test* instead of the one that
means what you need it to mean. Both happened on Pulling (2026-08-20), neither shipped a bad file,
and both would have if the next step had trusted them.

**Identity from a rounded size.** Series 2's two idents displayed as `32.1 MB` / `11.7 MB`, exactly
matching series 1's, and were reported as *byte-for-byte identical*. **The MD5s differ.** What
actually matched was the DURATION, to the millisecond (33.000 s / 10.720 s) — the same boilerplate
encoded separately per disc. The conclusion happened to hold; the evidence never supported it.
`Get-FileHash` costs a second, and a frame grab settles what the thing *is*.

**Completion from the wrong signal.** Three consecutive waits for "the encode finished" were built
on signals never verified to mean that:

| waited on | why it fired early / never |
|---|---|
| `_queue/done` being non-empty | it already held ~50 manifests from earlier in the batch |
| `pulling-s1.json` appearing in `_queue/done` | **lane-runner moves the manifest there when it CLAIMS the job**, not when it completes |
| `MANIFEST DONE` in `_logs/<name>/*.log` | `transcode.ps1` writes nothing to `-LogDir` here — every prior run's log dir is empty too |

The second one produced a confident "21 items done" report while ffmpeg was still writing item 1,
whose duration read `N/A`. What actually settled it: **ffprobe every output against its source** —
count, duration delta, stream layout. That is the gate step, and it is cheap.

**Before waiting on a signal, confirm it exists and fires at the moment you think.** `ls` the log
dir, check whether the marker has ever been written, or skip the proxy and measure the artefacts.

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


## A loop must log for ITSELF, not rely on how it was launched (2026-08-27)

Two of the seven pipeline loops — publish and OCR — had been running for days started as
`pwsh -NoProfile -File _<name>-loop.ps1` with **no redirection**. Every line they printed went to a
console nobody was attached to. There was no `_ocr-loop.log` at all, and `_publish-loop.log` was two
days old.

**The cost is not the missing log, it is what you conclude from the stale one.** On 2026-08-27 I
read a two-day-old `_publish-loop.log` as current, saw it repeating
`Goodnight Sweetheart (1993)  verified 51/52, 1 MISMATCHED`, and announced the publish loop was
jammed. It was idling correctly — Goodnight Sweetheart had published cleanly and been reclaimed days
earlier, and the only works pending were two correctly refused because a file was still encoding.
An invisible loop gets misdiagnosed, and a misdiagnosis is what leads to killing healthy pipeline
processes — which this project has already paid for once.

**So every loop opens its own transcript immediately after taking its mutex:**

```powershell
$logDir = 'D:\video\_logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
try { Start-Transcript -Path (Join-Path $logDir '_<name>-loop.log') -Append | Out-Null } catch { }
Write-Output ("=== <name> loop up {0} ===" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
```

Transcript, not a launcher redirect: it survives however the loop is started, and it captures a
terminating error, which `> log` from the caller does not. The `up` banner is what tells you the log
you are reading belongs to the process now running — the absence of a recent banner is exactly the
signal that was missing.

**Corollary — check a log's mtime before believing it.** `stat`/`LastWriteTime` costs nothing, and
"the newest file in `_logs` is two days old while the loop holds its mutex" is a complete diagnosis
on its own: the loop is alive and its output is going nowhere.

### The related fault in the same place: matching the message and getting the SOURCE LINE

`_publish-loop.ps1` picked its log line with `$out | Select-String 'verified|REFUSING'`. When
`_publish.ps1` throws, PowerShell renders the error with the offending **source line** attached —
and that line contains the word `REFUSING`, because it is the `throw` itself. So every refusal
logged as:

```
Goodnight Sweetheart (1993)     53 | . eq 'N/A') { throw "REFUSING: $($f.Name) has no duration - it is a par .
```

— the code, truncated, with the filename still an unexpanded `$($f.Name)`. The log could not answer
the one question it exists to answer: *which* file, and *why*. Filter out PowerShell's source echoes
(`^\s*\d+\s*\|`) and its continuation pipe (`^\s*\|\s*`) before matching. Same defect family as
grepping a tool's output for anticipated strings: the filter matched something *shaped* like the
answer.

## The idle-monitor's status lines are HINTS, not state (2026-08-27)

The background monitor that reports "lanes idle / OCR idle / NAS idle / staged and awaiting a
manifest" is useful for waking you up, and unreliable as a description of what is true. Observed
false signals in a single day:

| it said | what was actually true |
|---|---|
| `staged and awaiting a manifest: Sword Divided d1..d4` | all four encoded, published and verified; staging held only for the reclaim gate |
| `OCR IDLE with 5 file(s) awaiting a sidecar` | OCR was mid-file; it runs ONE file at a time by design, so a queue is normal throughput |
| `NOTHING staged; the source track is the constraint` | two discs were staged, one of them mid-encode |
| `staged and awaiting a manifest: The Bill S3 D1` | published; `verified 28/28` in the publish log |
| `restart _fetch-one.ps1` | the fetch loop had already resumed on its own |

The pattern: it infers state from cheap proxies (is a process visible right now, does a staged
folder have a queued manifest) and cannot distinguish "not started" from "finished". Acting on it
means hand-running a stage the pipeline already owns - which is how duplicate work gets created.

**Treat every monitor line as "go and look".** The authorities are, in order: the artefact itself
(is the file on the NAS, does it have a duration), then `_whatsrunning.ps1` (which enumerates ALL
queue states from one list), then the loops' own logs. Never the notification.

### And read a loop log WITH its timing, not just its tail

Three separate mis-readings in one day, all from `tail`-ing a log and treating the last line as the
current state:

- a mid-encode `REFUSING: ... has no duration` read as a truncated output that nothing would retry;
  the file was finished minutes later and published `verified 12/12`
- a two-day-old `_publish-loop.log` read as live, producing a confident "the publish loop is jammed"
  about a loop that was idling correctly
- a `WARNING: 2 equal-duration titles` attributed to the disc I was working on; it belonged to the
  disc catalogued in the next block

A loop log is a stream of past moments. Before concluding anything from its tail, check the file's
mtime, and check which unit's block the line sits in. **Better still, ask the artefact**: "is it on
the NAS?" answered in one call what three log reads could not.

## DIAGNOSTICS COUNT AS MEDIA LOAD — "just checking" is not free (2026-08-28)

Reading a log is free. **Opening media is not**, and a diagnostic that opens media competes with the
pipeline exactly as another job would. Called out by the user after a stretch of slow running.

The offences, in descending order of how wrong each was:

- **Running `mkvextract` on the very file the OCR loop was already extracting.** I had decided the
  loop's copy was "hung" (1 s CPU over 40 min) and ran a second extraction to test it. It was not
  hung, it was slow — and I had just made it slower by putting a third concurrent reader on a 2.6 GB
  file while two NVENC lanes and a whisper analysis were running. Both copies completed.
- **Four `makemkvcon info` disc scans** while testing `prove-dvd-mapping.py`. Each one scans the disc.
- **A library-wide `ffprobe` sweep** over every `.mkv` to find files missing a sidecar.
- **Recursive directory walks** over `_stage` and the library for space accounting.

The rule the subtitle skill already states for its workers — *"this budget covers everything touching
the media, not just workers"* — is general. It applies to investigation, not merely to jobs.

So, before opening media to check something:

1. **Can a log answer it?** `_logs/*.log`, the catalogue JSON, a manifest, `Get-Item` for a size, a
   process's CPU or `WriteTransferCount`. All free. Prefer them.
2. **Is the pipeline busy?** If lanes, OCR, whisper or a rip are running, a media-touching diagnostic
   is a fifth job. Defer it, or accept that you are slowing the thing you are measuring.
3. **NEVER duplicate work already in flight.** If a loop is doing X, do not also do X to find out how
   X is going. Measure the running copy instead — CPU delta and bytes-written delta over a short
   sample distinguish "slow" from "stalled" without opening anything.

That last one is also the correct stall test, and it is what I should have run first: a process with
advancing CPU or a growing output is progressing, however slowly. **Do not conclude "hung" from
elapsed time alone.**

## THE SKILL'S SCRIPT AND THE PIPELINE'S SCRIPT ARE DIFFERENT FILES (2026-08-28)

`SKILL.md` documents **`scripts/publish-work.ps1`**. The running pipeline calls
**`D:/video/_publish.ps1`**. They are separate files that have diverged, and `_publish-loop.ps1`
invokes the second one.

Fixing the partial-file guard, I edited the documented script, confirmed it parsed, confirmed there
was only one copy of *that name* on the disk — and the running loop went on using the old logic. The
tell was the log still printing the OLD message (`REFUSING`) after the edit, when the new code says
`SKIPPING`. Had the wording been unchanged, nothing would have revealed it.

So, before editing any pipeline behaviour:

- **Find out what the LOOP calls**, not what the skill documents. `grep` the `_*-loop.ps1` for the
  script name; do not assume the documented one is the live one.
- **Change a message string as well as the logic** when you can. A behaviour change is invisible in
  a log; a wording change is not, and it is what proves your edit is the code being run.
- **Apply the fix to BOTH** if both are real, or the next reader inherits two behaviours with one
  name. Same reasoning as the control-char hook: a guard protects the file it is wired to, not the
  one you meant.

This is the same shape as the 2026-08-23 mangled-path incident, where a guard script could not load
its config and so **the guard it implements silently never ran**. Editing an unused copy has exactly
that signature: everything reports success and nothing changes.
