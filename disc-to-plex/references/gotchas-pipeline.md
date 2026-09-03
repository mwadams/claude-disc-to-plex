# Pipeline & tooling gotchas

Staging, gates, robocopy, encode settings, process control.

Part of the `disc-to-plex` gotchas set — see [gotchas.md](gotchas.md) for the full index.

## Contents

- [`HVDVD_TS` symlinks make robocopy copy every disc TWICE (and break the byte gate)](#hvdvd_ts-symlinks-make-robocopy-copy-every-disc-twice-and-break-the-byte-gate)
- [Driver / ffmpeg pairing (NVENC won't open)](#driver-ffmpeg-pairing-nvenc-wont-open)
- [NEVER whole-folder stage while an encode is writing into that folder](#never-whole-folder-stage-while-an-encode-is-writing-into-that-folder)
- [GATE every rip/encode on a BYTE-COMPLETE prefetch — never on "the folder exists"](#gate-every-ripencode-on-a-byte-complete-prefetch-never-on-the-folder-exists)
- [A foreground encode killed by a tool timeout leaves an UNFINALISED mkv that passes the resume check](#a-foreground-encode-killed-by-a-tool-timeout-leaves-an-unfinalised-mkv-that-passes-the-resume-check)
- [Raising the encode bitrate does NOT improve these transfers — measured, don't re-litigate](#raising-the-encode-bitrate-does-not-improve-these-transfers-measured-dont-re-litigate)
- [Operational](#operational)
- [Concat lists, PowerShell URLs and manual matches](#concat-lists-powershell-urls-and-manual-matches)
- [`ffmpeg -f concat -c copy` silently keeps only ONE stream per type — always `-map 0`](#ffmpeg--f-concat--c-copy-silently-keeps-only-one-stream-per-type-always--map-0)
- [Never stage a whole show folder while ANOTHER disc of that show is still encoding into it](#never-stage-a-whole-show-folder-while-another-disc-of-that-show-is-still-encoding-into-it)
- [NEVER enumerate titles before the byte gate says COMPLETE — a partial copy invents partial sets](#never-enumerate-titles-before-the-byte-gate-says-complete-a-partial-copy-invents-partial-sets)
- [Killing a bad encode: kill the right PID, and delete the partial](#killing-a-bad-encode-kill-the-right-pid-and-delete-the-partial)
- [Remuxing AVI to MKV silently produces a 0.4-second stub](#remuxing-avi-to-mkv-silently-produces-a-04-second-stub)
- [An 8x slowdown from `-color_*` output options on untagged sources](#an-8x-slowdown-from--color_-output-options-on-untagged-sources)
- [A STILL HELD UNDER AUDIO decodes to 0.04 s and ships as a plausible small file](#a-still-held-under-audio-decodes-to-004-s-and-ships-as-a-plausible-small-file)

## A STILL HELD UNDER AUDIO decodes to 0.04 s and ships as a plausible small file

**Middlemarch Disk 1, dvdvideo title 5 — "The Music of Middlemarch", 2026-09-03.** The title emits
**ONE video packet** against **54,969 AC3 5.1 packets (1759.01 s)**. It is a single MPEG-2 still
card — MIDDLEMARCH / MUSIC COMPOSED BY STANLEY MYERS AND CHRISTOPHER GUNNING — held for the whole
29:20 score suite. That is the disc, not a truncation.

**Why it is dangerous rather than merely odd.** `transcode.ps1`'s default DVD read path encodes it
faithfully: exit 0, finalised container, one frame, **0.04 seconds**. Measured. Nothing in the
pipeline objects — `Finalised-Output` asks the container for a duration and gets one, and the
byte-size floor was already removed for being wrong in both directions. It is not a small file that
looks broken; it is a small file that looks *small*, which is a shape a video-only extra legitimately
has. The failure ships.

**How to recognise it before you build.** `assert-stream-packets.ps1` is the check that names it: a
video stream whose **declared** duration is minutes and whose **packet count is 1**. The declaration
and the emission disagree by three orders of magnitude — the same class as the under-declaring
`dvdvideo 4` on that disc, in the other direction.

**How to build it.** `stillsHold` — documented for N-frame galleries — covers this case too, and is
the whole fix:

```json
{ "kind": "DVD", "title": 5, "src": "D:/video/_stage/<disc>",
  "stillsHold": 1759.01, "subTrack": "none",
  "expectSeconds": 1759.01, "expectFrames": 43975 }
```

With one input frame the `setpts=N*HOLD/TB` gives that frame a HOLD-second duration and `fps` fills
the span, so the still is held for the whole suite.

Three things to get right, each of which has its own way of shipping something plausible:

- **`stillsHold` is the AUDIO length, packet-counted — not the video's declared duration.** Here
  the PGC declares 1760.00 s and the audio emits 1759.01 s. State `expectSeconds` against the audio.
- **The frame rate is not 24.** It was hard-coded `fps=24` in the gallery path, which is fine for a
  silent Blu-ray gallery and **wrong for a 25 fps PAL DVD** — a 24 fps item would be the only file
  in the show at another rate. `stillsFps` now states it and, omitted, it is derived from the
  source's `r_frame_rate` (clamped 10–60 fps, falling back to 24). Check the log line on a PAL item.
- **A DECLARED subtitle stream that ships ZERO packets must be dropped, not copied.** VTS_02
  declares `VTS_SPST_Ns=1`, ordinal 0, lang `en`; it emits nothing, and a stream-copy of it muxes
  to an empty file. `subTrack: "none"`. Keeping it would stamp `language=eng` on nothing and route
  the file to the OCR queue to OCR an empty stream.

**And it is not a subtitle failure.** The item has audio, so it is transcribable in principle — but
it is a music suite with no speech, and the transcribe track's own 4-cues-per-minute floor is what
should withhold it as `not-applicable`. Do not pre-empt that by hand-writing an empty sidecar.

## `HVDVD_TS` symlinks make robocopy copy every disc TWICE (and break the byte gate)

Some source drives run a `makelink.cmd` (`MKLINK /D HVDVD_TS VIDEO_TS`) in each disc folder so
media players that expect HD DVD layout still find the payload. `HVDVD_TS` is a **directory
symlink to `VIDEO_TS`**, not a real folder.

`robocopy /E` **follows it** and writes the whole payload a second time, while
`Get-ChildItem -Recurse -File` on the source does **not** traverse the reparse point. So the
byte-complete gate compares 33 source files against 64 destination files and reports
`INCOMPLETE` on a copy that is actually fine — the classic gate failure inverted, and it wastes
double the NVMe space per disc.

Fix both halves:
- Copy with **`/XJ`** (exclude junctions/symlinks): `robocopy "$src" "$dst" /E /XJ /R:3 /W:5`
- Gate on **`VIDEO_TS` only**, not the folder root, so a stray link can never skew the count:
  compare `Get-ChildItem "$src\VIDEO_TS" -File` vs `"$dst\VIDEO_TS"` for count **and** bytes.

Detect it up front with
`Get-ChildItem $src -Force | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }`.
Never "fix" it by deleting the link on the source — it is the user's data and guard-protected.

## Driver / ffmpeg pairing (NVENC won't open)

`Driver does not support the required nvenc API version` — the ffmpeg build is newer than the
installed NVIDIA driver. A ~59x driver supports the NVENC SDK that **ffmpeg 7.x** targets, not
ffmpeg 9.x/master. Use the BtbN **n7.1** win64 build (what `install-tools.ps1` fetches). The
GPU/driver themselves are fine — HandBrake's bundled NVENC keeps working; it's only a
standalone-ffmpeg version mismatch.

## NEVER whole-folder stage while an encode is writing into that folder

Staging is a *copy of finished work*. If a `robocopy <seasonFolder> <nas>` runs while the encoder is
still writing episodes into `<seasonFolder>`, robocopy happily copies the **partially-written mkv**.
On a no-overwrite, delete-protected NAS those partials are then **stuck** — only the user can remove
them, and the season silently contains broken episodes that play short or fail.

**Two rules, both required:**

1. **Wait for `MANIFEST DONE` on every lane writing to that folder** before staging anything from it.
2. **Stage targeted per-file, never the folder** — pass the explicit filenames you just verified:
   `robocopy $src $dst "Show - S05E01 - A.mkv" "Show - S05E02 - B.mkv" /J /NP ...`
   A folder-level copy will pick up whatever else happens to be in there, including a 0-byte file
   the encoder created a second ago.

**Verify before you copy, not after**: compare each candidate's duration to its source, and treat a
still-growing or 0-byte file as proof an encode is live. (Real incident: a whole-folder stage during
an active encode put two partial episodes on the NAS; three finished ones copied fine, which made
the "3/6 matched" result look like a timing hiccup rather than data damage.)

## GATE every rip/encode on a BYTE-COMPLETE prefetch — never on "the folder exists"

A prefetch (USB→NVMe) launched with `run_in_background` keeps copying across later tool calls.
If the next step only checks `Test-Path <stage>\VIDEO_TS` before ripping, it reads a **half-copied
disc** — and the failure is silent and plausible-looking:

- **Whole titles disappear.** MakeMKV enumerates only the VTS sets copied so far. A 3-episode disc
  reports 2 titles and "2 titles saved" with exit 0. Nothing errors.
- **The titles you do get are short.** The last-copied VTS is truncated mid-VOB, so an episode comes
  out ~20-30s short of its true length.
- **A duration check against the rip cannot catch either problem** — the rip is the thing that's
  wrong, so encode-vs-rip agrees perfectly. (Real incident 2026-08-13: Thriller D4/D5 each lost one
  episode and had two more truncated ~27s; the encode==rip duration check passed on all of them.)

**The gate** (PowerShell; run it in the *same* step as the rip, not a previous one):

```powershell
$s=(Get-ChildItem $src -File).Count; $sb=(Get-ChildItem $src -File|Measure-Object Length -Sum).Sum
for($i=0;$i -lt 120;$i++){
  if(Test-Path $dst){ $d=(Get-ChildItem $dst -File).Count
    $db=(Get-ChildItem $dst -File|Measure-Object Length -Sum).Sum
    if($d -eq $s -and $db -eq $sb){ break } }
  Start-Sleep -Seconds 10
}
if($d -ne $s -or $db -ne $sb){ "GATE FAILED"; exit 1 }
```

**Independent cross-check** (because rip-vs-encode is self-consistent): count the disc's programme
VTS sets *from the source* and require one ripped title per set —
`Get-ChildItem $src -Filter "VTS_*_0.IFO"` (VTS_01 is usually the ~20 MB menu; the rest are
episodes, ~2-3 GB of VOB each). If MakeMKV saves fewer titles than there are programme VTS sets,
the stage was incomplete or a title was skipped — investigate before encoding.

**Rule: run every `robocopy` invocation — prefetch (USB→NVMe) *and* NAS staging — via the PowerShell
tool, NEVER the Bash tool.** The Bash tool is Git Bash / MSYS, whose argument converter rewrites
anything that looks like a POSIX path, corrupting robocopy in two independent ways:

1. **Switches** — MSYS treats a leading-slash flag as a path and appends a drive colon:
   `/E`→`E:/`, `/J`→`J:/`, `/MIR`→`MIR:/` etc. robocopy then rejects it with
   `ERROR : Invalid Parameter #N : "E:/"` and copies **nothing**. This bites even when every
   path argument is a plain local drive path (`E:\...`, `D:\...`), so it breaks **prefetch**, not
   just UNC staging.
2. **UNC / backslash paths** — `\\NAS\share` collapses to `\NAS\share`; robocopy treats that
   single-backslash path as **relative to the current drive** and copies to `D:\NAS\share\...`
   locally. The byte-verify passes too — it checks that same wrong local folder — so a broken
   stage looks VERIFIED and (worse) could gate a delete. Nothing reaches the NAS.

Symptom of (1): the copy "fails" instantly with an Invalid Parameter error and the stage dir stays
empty. Symptom of (2): the stage looks complete and verified but the NAS never receives the files.

**Avoid both:** issue robocopy from the **PowerShell tool**. For a long copy, use the tool's own
`run_in_background` (a PowerShell `Start-Job` dies when the shell session ends between calls, so its
log never appears). `stage-and-clean.ps1` hard-aborts when `$Target` starts with a single backslash,
and warns when the target resolves onto the source's own volume — but prefetch robocopy has no such
guard, so the PowerShell-only rule is the real protection. (If a raw `robocopy` line is ever needed
from bash, every switch and UNC path must be quoted/escaped to survive MSYS — not worth it; just use
PowerShell.)

## A foreground encode killed by a tool timeout leaves an UNFINALISED mkv that passes the resume check

Running `transcode.ps1` in the foreground risks the agent harness's 2-minute command timeout killing
it mid-write. Matroska is finalised at the end, so the result is a plausible-looking file with **no
duration in its header**:

```
format duration: 'N/A'
[matroska,webm @ ...] File ended prematurely
```

The trap is `transcode.ps1`'s resume rule — it skips any output that already exists **>5 MB**. An
80 MB partial therefore looks "done" forever: re-running the manifest silently does nothing, and a
size check sees a perfectly reasonable number. (Real incident: a 4.28-min Being Human extra came out
at 80 MB with `nb_read_packets=5368` and no duration.)

**Always launch encodes with `run_in_background`**, never in the foreground. And when a file's
`format=duration` reads `N/A`, treat it as a partial and delete it before re-running — do not trust
its size.

## Raising the encode bitrate does NOT improve these transfers — measured, don't re-litigate

The settings (`h264_nvenc -preset medium -rc vbr -cq 20`) look conservative, and the obvious
instinct when a transfer seems soft is to spend more bits. Measured against a **lossless reference
of the same segment**, scored with VMAF, that instinct is wrong:

Clean live-action (The Italian Job, 60 s):

| config | size | VMAF |
|---|---|---|
| current, cq 20 | 75.7 MB | **99.41** |
| p6 + AQ + lookahead + B-refs, cq 19 | 88.4 MB (+17%) | 99.14 |
| p7 + multipass + all tools, cq 17 | 111.2 MB (+47%) | 99.35 |

Grain-heavy (Zulu, 45 s) — the hard case, where more bits should pay:

| config | size | time | VMAF |
|---|---|---|---|
| **current, cq 20** | 54.3 MB | **38 s** | **77.75** |
| NVENC h264 p7 cq 17 + all tools | 83.7 MB (+54%) | 36 s | 77.81 |
| NVENC hevc cq 20 + all tools | 49.6 MB (−9%) | 38 s | 77.26 |
| x264 CRF 18 slow (CPU) | 50.8 MB | 134 s (3.5x) | 77.40 |
| x264 CRF 18 tune film + aq-mode 3 | 59.3 MB (+9%) | 138 s (3.6x) | 77.49 |

**Every configuration lands within 0.5 VMAF.** +54% storage buys +0.06. CPU x264 costs 3.5x the
wall-clock and scores *lower*. The current settings are the fastest, among the smallest, and tied
for the best score.

The 99 → 77 drop between clean and grainy material is the CONTENT, not the encoder: fine grain is
imperfectly reproduced by every encoder at sane bitrates, and VMAF penalises it heavily. A soft-
looking grainy transfer is at the ceiling, not under-provisioned.

**Method note if this is ever retested:** compare against a LOSSLESS extract of the segment, and
encode from that same file. Seeking two inputs to "the same" timestamp does not give the same
frames — a first attempt that way scored a CQ-20 Blu-ray at VMAF 50, which is a misalignment
artefact, not a quality reading. Also, `libvmaf`'s `log_path` breaks on Windows paths because the
filter parser treats the drive-letter colon as an option separator; read the score from stderr.

## Operational

- **`-stats` spam**: ffmpeg writes ~1 progress line/second; a long encode log is thousands of
  lines. Monitor by grepping `OK|FAILED|DONE`, never by reading the whole file.
- **Source-drive contention**: probing/extracting frames from the same physical drive an encode
  is reading roughly halves its speed. Do all inspection before starting the batch.
- **Pipeline the copy: stage item N+1 to NVMe *while* item N encodes.** The rips live on a slow
  USB/external spinning disk (e.g. `E:` = a USB Iomega HDD, measured ~36 MB/s sequential). At CQ20
  a single 1080p encode only needs a few MB/s of source, so USB bandwidth is *not* what caps one
  encode — but it makes disk access the shared resource the moment anything else touches that disk.
  The win from staging is **overlap, not raw speed**: always point the manifest `src` at a local
  **NVMe (`D:`)** copy so the encoder reads NVMe, and copy the *next* item (the `.m2ts`, or a whole
  disc's `VIDEO_TS`) USB→NVMe **during** the current encode. Because the encoder reads `D:` and the
  copy reads `E:`/writes `D:`, there's **no disk contention** — the ~20-min USB copy hides entirely
  behind the previous item's encode, so the GPU never waits on USB. Prime the pipeline once (first
  item's copy is unavoidably serial), then it's copy-ahead from then on. Delete each local staging
  copy once its encode verifies.
  - ReFS gotcha: a freshly-created copy target shows its **full allocated size immediately**
    (reservation), so a half-copied 28 GB file already reports 28 GB and is **exclusively locked**
    (reads fail `Permission denied`) until the copy actually completes. Don't gauge copy progress by
    file size, and don't touch a staged file until its copy task reports done.
- **Resumability**: `transcode.ps1` skips outputs that already exist >5 MB. After fixing a bug,
  just re-run the same manifest — only the failed/missing items redo. Delete broken partials
  (<5 MB) first so they aren't mistaken for complete.
- **Laptop thermals**: sustained NVENC shares a power/thermal budget with the CPU; per-title
  encode times vary widely. Normal, not a fault.

## Concat lists, PowerShell URLs and manual matches

- **An apostrophe in a path breaks an ffmpeg `concat` list.** Entries are single-quoted
  (`file 'D:\...\x.mkv'`), so a title like `Wavell's 30,000` terminates the quote early and ffmpeg
  reports `Impossible to open 'D:\video\Movies\Wavells'`. Escape it the shell way when writing the
  list: `"file '" + ($path -replace "'","'\''") + "'"`.
- **PowerShell 7 parses `$var?` inside a string as the null-conditional operator**, so
  `"$b/library/metadata/$rk?X-Plex-Token=$t"` silently drops the `?…` and the request 404s — while
  the same URL with a *literal* rating key works fine. Always brace it: `${rk}?X-Plex-Token=…`.
  Symptom is a 404 on `/library/metadata/<rk>` when sibling endpoints like `/extras` succeed.
- **A US release title can beat the UK one in the agent's match.** `Close Quarters` (1943, Crown
  Film Unit) matched as `Undersea Raider (1943)` — the same film's US title, confirmed by the
  summary. The match is correct; just PUT `title.value` + `title.locked=1` back to the UK title
  rather than unmatching. Pass **`language=en-GB`** to `/matches?manual=1` to surface UK-specific
  candidates where the two clash (user tip, 2026-08-14).
- **An archive film's only TMDB entry may carry the DVD release year, not the production year.**
  `Wavell's 30,000` (1942) matched an entry dated 2002 with a typo'd title. Lock `title`, `year`
  and `originallyAvailableAt` rather than leaving the film filed under the wrong decade.
- **A DVD can list every episode twice.** The Edwardian Country House exposes t3==t4, t5==t6,
  t7==t8 with identical durations, and each pair is genuinely the same content — take the odd
  titles only, or you stage six duplicates.
  **But matching durations are only a PROMPT TO CHECK, never proof** (user, 2026-08-14: "sometimes
  there *are* two episodes with identical duration — I have been caught by that in the past").
  Episodes of a series are cut to the same slot length, so identical runtimes are entirely normal
  between *different* episodes. **Frame-match EVERY suspected pair** — one frame from each at the
  same offset, hstacked — and never extrapolate from one confirmed pair to the rest of the disc.
  Getting this wrong silently DROPS episodes, which no later step catches: the agent only ever
  shows the slots you gave it files for, so a half-length season looks perfectly consistent.

## `ffmpeg -f concat -c copy` silently keeps only ONE stream per type — always `-map 0`

The concat demuxer applies ffmpeg's **default stream selection**: one video, one audio, one
subtitle — the "best" of each. With `-c copy` and no `-map`, everything else is dropped without a
warning, and the output plays perfectly, so nothing looks wrong. On a compilation main file built
from parts that each carried AAC 5.1 + AAC stereo + a lossless passthrough + PGS subtitles, the
result was **AAC stereo only** — the passthrough track and the subtitles were gone.

Always map every stream explicitly:

```
ffmpeg -v error -f concat -safe 0 -i list.txt -map 0 -c copy "out.mkv" -y
```

Then **probe the result, not just its duration**. Duration arithmetic is the check everyone
remembers and it passes cleanly here — the join is fine, the length is exact, only the stream
count is wrong. Compare `ffprobe … | grep 'Stream #'` on the concat against one of its parts;
they should match stream for stream.

Related, and worse because it survives a stream census too: **never append subtitle tracks on
their own** to work around a part that has none. A subtitle-only file's timeline ends at its LAST
CUE, not at its video length, so the deficit accumulates part by part — cue count, byte total,
duration and chapter marks all still check out. See
[Appending subtitle tracks ALONE makes the drift accumulate](gotchas-subtitles.md#appending-subtitle-tracks-alone-makes-the-drift-accumulate--re-time-from-the-chapter-marks).

## Never stage a whole show folder while ANOTHER disc of that show is still encoding into it

Staging is normally "copy the finished folder", but a multi-disc set breaks that: disc N's episodes
and disc N+1's encodes share one show folder. A whole-folder `robocopy` therefore sweeps up
half-written `.mkv` files from the lane that is still running, and they land on the NAS as valid but
truncated episodes. Lovejoy S2E02 went across at 460 MB against a finished size of ~1.2 GB.

Worse, the usual staging flags make it permanent: `/XC /XN /XO` mean "skip changed, newer and older
files", so a later re-run **skips the very files that need replacing** and the truncated copies
survive every subsequent stage. The byte gate catches the mismatch, but only if you compare — and a
DIFF here looks like a transient network problem rather than a partial file.

Two ways to avoid it, both cheap:

- Stage with an explicit per-season or per-file filter, so in-flight files are never candidates:
  `robocopy "<src>\Season 01" "<dst>\Season 01" "*S01E*.mkv" /R:2 /W:5`
- Or simply wait for every lane targeting that show to print `MANIFEST DONE` before staging.

To repair partials already on the NAS, re-copy **without** the exclusion flags so the complete file
overwrites the truncated one (a copy, not a delete — it does not need the NAS protection lifted):
`robocopy "<src>" "<dst>" "<file>.mkv" /R:2 /W:5`. Then re-verify sizes.

## NEVER enumerate titles before the byte gate says COMPLETE — a partial copy invents partial sets

Enumerating a disc whose prefetch is still running silently **under-reports titles**: the demuxer
only sees the VOBs that have arrived. It does not error, it just lists fewer titles, and every
downstream conclusion inherits the mistake.

On Public Eye's 1972/3 disc 2 this produced a completely wrong finding: ffmpeg listed two episodes
where the disc holds three, the season came to 12 against the agent's 13, and it was reported as a
partial set missing `S06E06 Horse and Carriage`. The episode was on the disc the whole time. The
user knew the set was complete and said so, which is the only reason it was caught.

Two cheap defences:

- **Order matters.** Wait for the prefetch's count+bytes gate to print COMPLETE, *then* enumerate.
  Never chain "prefetch … ; ffprobe titles" in one command, and never enumerate off the back of a
  task notification without re-checking the gate — a robocopy that exits non-zero (it often does,
  exit 1 just means "files copied") can still be mid-flight from an earlier invocation.
- **Cross-check the count.** `mymovies.xml` lists the disc's own titles with runtimes. If the
  demuxer shows fewer titles than `mymovies` does, the copy is incomplete or the demuxer is
  under-reporting — confirm with `makemkvcon64.exe -r --cache=1 info "file:<stage>"` before
  concluding anything is missing.

A genuine partial set is normal in this collection (discs live on other drives), which is exactly
why a false one is dangerous: it looks entirely plausible.

## Killing a bad encode: kill the right PID, and delete the partial

Two ffmpeg processes exist during a BD item — the cropdetect pass and the encode. Killing the
first-listed one leaves the encode running, still holding its output file open, so the follow-up
`Remove-Item` fails with "being used by another process" and the relaunch then reports
`skip (exists)` and does nothing (the skip test only asks whether the file is larger than 5 MB).
Net effect: you "restarted" the job three times and never re-encoded anything.

Check `Get-Process ffmpeg` for what is actually still alive, kill that, confirm the count is zero,
then delete the partial and verify it is gone before relaunching.

## Remuxing AVI to MKV silently produces a 0.4-second stub

Old DivX/XviD `.avi` rips (VHS captures, TV rips) often carry **no presentation timestamps**.
Matroska requires them, so `ffmpeg -i x.avi -map 0 -c copy x.mkv` writes a fraction of a second and
stops:

```
[matroska] Can't write packet with unknown timestamp
[out#0/matroska] Error muxing a packet
```

The output file exists and looks plausible in a directory listing, so any "did the file get
created?" check passes. 51 files were "remuxed" this way in one pass before a duration comparison
caught it.

Fix: add `-fflags +genpts` before `-i` so ffmpeg generates the timestamps.

More generally: **verify a stream-copy by comparing source and output duration**, not by existence
or exit code. The same discipline catches the `-map 0` stream-dropping trap (see the concat entry) —
both failures produce a file that only a duration or stream-count check exposes.

These pre-compressed files should be remuxed, never re-encoded: the source is already lossy SD, so
a second generation only loses quality and burns GPU time for a larger file.

## An 8x slowdown from `-color_*` output options on untagged sources

Symptom: a Blu-ray encode runs at ~0.5x realtime while other discs on the same machine run 2-3x.
NVENC is not the limit and neither, mostly, is decode.

Cause: `-color_primaries/-color_trc/-colorspace/-color_range` are **output** options. If the source
declares different — or `unknown` — colour properties, ffmpeg inserts a full software colour
conversion and every 1080p frame goes through swscale on one CPU core. Nothing in the log says so.

VC-1 Blu-rays are routinely untagged (`color_space=unknown` on every field), which is why
`Sherlock Holmes` and `Superman Returns` crawled while properly-tagged H.264 discs did not.

Measured on one 3-minute VC-1 clip:

| variant | time |
|---|---|
| base encode, no colour flags | 49s |
| base + the four `-color_*` flags | 397s |
| full pipeline before the fix | 456s |
| full pipeline after `setparams` | **59s** |

Fix: when the source's `color_space` is empty/`unknown`, prepend
`setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv` to the filter chain.
That TAGS the frames rather than converting them, the output options then match, and no scaler is
inserted. HD Blu-ray is bt709 by definition so tagging is correct, not a guess — verify the output
still reports `tv, bt709`.

Two lessons beyond the fix:

- **Benchmark the real command, not a simplified one.** The first measurement here omitted the
  colour flags and pointed confidently at decode; it took an argument-level bisect against the
  actual pipeline command to find the true cost. `TRANSCODE_DEBUG=1` prints that command.
- **Always check the output duration when timing an encode.** A "fast" run can simply be one that
  stopped early, and a wall-clock number alone cannot tell the difference.

Decode is worth fixing too, but it is the smaller effect: `-hwaccel cuda` is ~2.3x on VC-1, whose
ffmpeg decoder has no frame-level threading and pegs a single core.


## A DARK SCENE can hand you a plausible, WRONG crop (2026-08-29)

Withnail and I (1987): cropdetect voted `1920:1080:0:0` unanimously across the six sample points
`transcode.ps1` uses — 888 votes, no runner-up, i.e. a full-frame 1.78:1 transfer with no bars.

But a single 20 s probe taken in a **dark scene at 3600 s** returned `1806:1080:0:0`. That would have
sliced **114 px off the right of the picture**, and it would have **passed `Get-Crop`'s sanity test**
had it won the vote — it is a well-formed crop of a plausible width, not obvious garbage.

Two things follow:

- **The multi-point vote is the protection, not the sanity test.** A single probe is a sample of one
  scene's luminance, and a dark or letterboxed-within-frame scene reads as bars.
- **When the vote is unanimous at full frame, ship `crop: "none"`** rather than an explicit
  `W:H:X:Y` — an explicit value can encode exactly this artefact, and `"none"` cannot.

Never settle a crop from one probe, and treat a lone dissenting sample as evidence about the SCENE,
not about the transfer.
