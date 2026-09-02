<#
.SYNOPSIS
Publish an OCR'd .srt beside an ALREADY-PUBLISHED .mkv, sourced from the disc - no re-encode.

.DESCRIPTION
WHY THIS EXISTS
---------------
The OCR campaign (`ocr-library-batch.ps1`) reads a subtitle track out of a file that is ALREADY ON
THE NAS. That covers the normal case and cannot cover this one: Boston Legal Seasons 1 and 3 were
published by a legacy encode that muxed NO SUBTITLE STREAM AT ALL (h264 + aac + ac3, nothing
else), so 41 episodes have no subtitles and the campaign had nothing to work on. Season 2 has 27
.srt for exactly the opposite reason - its files do carry the track.

That is a MUXING OMISSION, not a content defect. The picture on the NAS is correct and, checked at
two landmarks 38 minutes apart, is time-aligned with the disc. So the fix is a text file, not a
re-encode: OCR the disc's English stream and drop the .srt beside the existing .mkv. Re-encoding 41
episodes would re-derive audio layout and repeat the whole encode/publish/verify/reclaim cycle to
fix something a sidecar fixes, and would burn disk this pipeline does not currently have.

Decided by the user 2026-09-02, with the same choice made for the 17 Season 00 items whose
embedded track is Danish mislabelled `eng` - a defect OUR OWN encode introduced by taking
`subTrack: 0`, Danish being first alphabetically. A correct sidecar wins in Plex; the mislabelled
embedded stream stays and is not worth a re-encode.

WHAT IT DOES NOT DO
-------------------
It does not re-encode, re-publish or delete anything, and it is CREATE-ONLY: it will never
overwrite a subtitle it did not make. It writes exactly one new file per item, on the NAS, beside
a file that is already there.

HOW THE LANGUAGE IS PROVEN
--------------------------
The subtitle streams are remuxed out of the disc title WITH THEIR LANGUAGE TAGS INTACT, then
handed to `ocr-subtitles.ps1 -Lang eng`. That script picks the tagged track AND runs its English
dictionary gate, which throws "this is not an English track (the disc's language tag is wrong)"
when the content disagrees with the tag. So the tag is a hint and the CONTENT is the proof - which
is the check that would have caught the Danish mislabelling at the time.

Everything here FAILS CLOSED. A guard that cannot run is a refusal, never a pass.

.PARAMETER Manifest
JSON describing what to do. Authored per disc (the one manual step).

** IT LIVES IN `D:/video/_subs-queue/`, NOT `_queue/`. ** `_queue` belongs to the encode lane,
which scans it and claims anything it finds. A subtitle manifest dropped there was picked up and
thrown into `_queue/failed` within seconds - correctly, since it has no `out` rows, but it meant
the file vanished from under a run that was about to use it. Separate directory, separate lane.

Shape:

  {
    "disc": "Boston Legal Season 1 Disk 1",
    "src":  "D:/video/_stage/Boston Legal Season 1 Disk 1",
    "items": [
      { "title": 1, "target": "\\\\NASTEAMV\\Multimedia\\Television Shows\\Boston Legal\\Season 01\\Boston Legal - S01E01 - Head Cases.mkv" }
    ]
  }

`title` is the dvdvideo title number - the PROVEN one from prove-dvd-mapping.py, never the
catalogue's duration-derived guess, which on this very disc was wrong on four of five rows.

.EXAMPLE
  pwsh -File publish-disc-subtitles.ps1 -Manifest D:/video/_queue/subs-boston-legal-s1d1.json -WhatIf
  pwsh -File publish-disc-subtitles.ps1 -Manifest D:/video/_queue/subs-boston-legal-s1d1.json
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [string]$Lang = 'eng',
  # Disc and published runtimes must agree this closely, in seconds. A sidecar is only valid for
  # the CUT it was timed against; a different cut is the one way this silently ships nonsense.
  [double]$MaxDurationDriftS = 5.0,
  # Below this many cues for a full-length episode the OCR did not really work.
  [int]$MinCues = 100,
  # Standing rule: ALL working set lives under D:\video. A MakeMKV rip is gigabytes, and it has no
  # business landing on C: either - `rip-titles.ps1`'s space gate reasons about D:.
  [string]$ScratchDir = 'D:/video/_subs-work',
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- tools ------------------------------------------------------------------------------------
# Resolve up front and REFUSE if anything is missing. A missing ffprobe would otherwise turn the
# duration guard into a silent no-op, which is the failure mode this project has hit repeatedly:
# the guard does not run, and its silence reads exactly like a pass.
$toolPaths = 'D:/video/.transcode-tools/tool-paths.json'
if (-not (Test-Path -LiteralPath $toolPaths)) { throw "REFUSING: no tool-paths.json at $toolPaths" }
$tools = Get-Content -LiteralPath $toolPaths -Raw | ConvertFrom-Json
$ffprobe   = Join-Path (Split-Path $tools.ffmpeg -Parent) 'ffprobe.exe'
$ocr       = Join-Path $scriptDir 'ocr-subtitles.ps1'
$ripTitles = Join-Path $scriptDir 'rip-titles.ps1'
foreach ($t in @($ffprobe, $ocr, $ripTitles)) {
  if (-not (Test-Path -LiteralPath $t)) { throw "REFUSING: required tool not found: $t" }
}

if (-not (Test-Path -LiteralPath $Manifest)) { throw "REFUSING: no manifest at $Manifest" }
$m = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
if (-not $m.src)   { throw 'REFUSING: manifest has no `src`' }
if (-not $m.items) { throw 'REFUSING: manifest has no `items`' }
if (-not (Test-Path -LiteralPath $m.src)) { throw "REFUSING: staged disc not found: $($m.src)" }

# SCRATCH IS LOCAL, ALWAYS. Standing rule: all working set under D:\video or a temp dir, NEVER on
# the NAS. The intermediate container and the OCR's own working files must not be derived from the
# TARGET path, because the target is a NAS path - that is precisely how 142 MB of temp WAV ended up
# inside the Plex library on 2026-09-02.
New-Item -ItemType Directory -Force $ScratchDir | Out-Null

function Get-DurationS([string]$path, [int]$title = -1) {
  if ($title -ge 0) {
    $o = & $ffprobe -v error -f dvdvideo -title $title -i $path -show_entries format=duration -of csv=p=0 2>$null
  } else {
    $o = & $ffprobe -v error -show_entries format=duration -of csv=p=0 -- $path 2>$null
  }
  $v = 0.0
  if ([double]::TryParse(("$o").Trim(), [ref]$v)) { return $v }
  return -1.0
}

$ok = 0; $skipped = 0; $failed = 0; $problems = @()

foreach ($item in $m.items) {
  $label = "title $($item.title)"
  Write-Output ''
  Write-Output "=== $label -> $(Split-Path $item.target -Leaf)"

  try {
    # -- guard 1: the published file must exist. We are adding a sidecar to something real. -----
    if (-not (Test-Path -LiteralPath $item.target)) {
      throw "published .mkv not found on the NAS: $($item.target)"
    }

    # -- guard 2: CREATE-ONLY. Never clobber a subtitle we did not make - it might be a real -----
    #    disc-derived or hand-corrected one.
    $srtTarget = [IO.Path]::ChangeExtension($item.target, $null) + "$Lang.srt"
    if (Test-Path -LiteralPath $srtTarget) {
      Write-Output "    SKIP - a $Lang sidecar already exists there"
      $skipped++
      continue
    }

    # -- guard 3: same cut? A sidecar is only valid for the runtime it was timed against. --------
    $dDisc = Get-DurationS $m.src $item.title
    $dNas  = Get-DurationS $item.target
    if ($dDisc -le 0 -or $dNas -le 0) {
      throw "could not read a duration (disc=$dDisc published=$dNas) - refusing rather than guessing"
    }
    $drift = [math]::Abs($dDisc - $dNas)
    Write-Output ("    disc {0:N1}s vs published {1:N1}s  (drift {2:N1}s)" -f $dDisc, $dNas, $drift)
    if ($drift -gt $MaxDurationDriftS) {
      throw ("runtime drift {0:N1}s exceeds {1:N1}s - these may be DIFFERENT CUTS. " -f $drift, $MaxDurationDriftS) +
            'A sidecar timed against the wrong cut is worse than no sidecar: it looks right and drifts. Investigate.'
    }

    if ($WhatIf) { Write-Output '    WHATIF - would extract, OCR and publish'; $ok++; continue }

    # -- extract with MAKEMKV, not ffmpeg -------------------------------------------------------
    # THE FIRST VERSION USED `ffmpeg -f dvdvideo ... -map 0:s -c copy` AND IT CANNOT WORK.
    # That demuxer does not carry the DVD's PGC palette into the Matroska CodecPrivate, so the
    # .idx extracted downstream gets ffmpeg's flat fallback - measured on Boston Legal S01E01 as
    # `000000, 818181, 818181, ... ` with THIRTEEN OF SIXTEEN entries the same grey. The subtitle
    # bitmaps are then grey-on-grey and no OCR engine can read them; seconv fails with a garbled
    # tesseract error that looks like a tooling problem and is not one. Mapping the video stream
    # too makes no difference - the palette comes from the IFO, not the video - and both remuxes
    # produced a byte-identical bad palette. A control file from the normal encode path has a
    # properly varied palette, which is how the difference was isolated.
    #
    # This is the same demuxer whose multi-cell truncation is already on record, and the same
    # standing answer applies: MAKEMKV IS THE AUTHORITY FOR GETTING DATA OFF A DVD. It carries
    # VOBSUB palettes correctly, and it is what every other disc-reading step here already uses.
    #
    # NOTE THE TITLE NUMBERING. `title` is the dvdvideo number (what ffmpeg/transcode use);
    # `makemkvTitle` is MakeMKV's own index. THEY ARE DIFFERENT NUMBERS and the mapping between
    # them is what prove-dvd-mapping.py exists to establish from byte totals. Both go in the
    # manifest so neither is re-derived by guesswork - on this very disc the catalogue's
    # duration-derived guess was wrong on four of five rows.
    if ($null -eq $item.makemkvTitle) {
      throw 'manifest item has no `makemkvTitle` - refusing to guess MakeMKV''s index from the dvdvideo number, they are not the same numbering'
    }
    # USE rip-titles.ps1. Do not invoke makemkvcon here. That script already owns the space gate
    # (including the stale-free-space re-read after a large delete), the `file:` source quoting
    # that bash mangles, and - crucially - verification BY COUNTING OUTPUT FILES and checking
    # durations, because MakeMKV exits 0 having written nothing when it cannot read the source.
    # Re-implementing any of that here would be a second, worse copy of a solved problem.
    $ripDir = Join-Path $ScratchDir "rip-$($item.makemkvTitle)"
    if (Test-Path -LiteralPath $ripDir) { Remove-Item -LiteralPath $ripDir -Recurse -Force }
    & pwsh -NoProfile -File $ripTitles -Disc $m.src -Titles $item.makemkvTitle -Dest $ripDir
    $ripExit = $LASTEXITCODE          # read DIRECTLY, never through a pipe
    if ($ripExit -ne 0) { throw "rip-titles.ps1 exited $ripExit" }

    $ripped = @(Get-ChildItem -LiteralPath $ripDir -Filter '*.mkv' -File -ErrorAction SilentlyContinue)
    if ($ripped.Count -ne 1) { throw "expected exactly 1 ripped file, got $($ripped.Count)" }
    $work = $ripped[0].FullName
    Write-Output ("    ripped {0:N0} MB" -f ($ripped[0].Length / 1MB))

    # COUNT WHAT WE GOT. "A declared stream is not a stream" - and an empty container would send
    # the OCR script off to fail for a reason that has nothing to do with OCR.
    $streams = @(& $ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 -- $work 2>$null)
    if ($streams.Count -eq 0) { throw 'extracted container carries no subtitle stream' }
    Write-Output "    extracted $($streams.Count) subtitle stream(s) -> scratch"

    # -- OCR, reusing the campaign's own script so there is ONE implementation of the repairs ----
    & pwsh -NoProfile -File $ocr -Path $work -Lang $Lang -Mode Sidecar
    $ocrExit = $LASTEXITCODE          # read DIRECTLY - never through a pipe
    $srtWork = [IO.Path]::ChangeExtension($work, $null) + "$Lang.srt"
    if ($ocrExit -ne 0) { throw "ocr-subtitles.ps1 exited $ocrExit" }
    if (-not (Test-Path -LiteralPath $srtWork)) { throw 'OCR reported success but wrote no .srt' }

    # -- guard 4: did it actually produce subtitles, or an empty shell? -------------------------
    $cues = @(Select-String -LiteralPath $srtWork -Pattern '^\s*\d+\s*$').Count
    Write-Output "    OCR produced $cues cue(s)"
    if ($cues -lt $MinCues) {
      throw "only $cues cue(s) - below the floor of $MinCues for a full-length item. Not publishing a stub."
    }

    # -- publish, then VERIFY THE COPY BY BYTES -------------------------------------------------
    Copy-Item -LiteralPath $srtWork -Destination $srtTarget -Force
    $srcLen = (Get-Item -LiteralPath $srtWork).Length
    $dstLen = (Get-Item -LiteralPath $srtTarget).Length
    if ($srcLen -ne $dstLen) { throw "copy verify FAILED: $srcLen B local vs $dstLen B on the NAS" }
    Write-Output ("    PUBLISHED {0:N0} B -> {1}" -f $dstLen, (Split-Path $srtTarget -Leaf))
    $ok++
  }
  catch {
    Write-Output "    FAILED: $($_.Exception.Message)"
    $problems += "$label : $($_.Exception.Message)"
    $failed++
  }
  finally {
    # DROP THE RIP AS SOON AS ITS .srt IS SAFE. Each item rips to its own folder, so without this
    # they ACCUMULATE - four Boston Legal episodes would hold 6.4 GB instead of peaking at 1.6, and
    # a full season would be tens of GB of video whose only purpose was to carry a subtitle track
    # for a few minutes. Peak usage should be ONE title, and the disk here is routinely near its
    # floor. In `finally` so a failed item cleans up too.
    if ($ripDir -and (Test-Path -LiteralPath $ripDir)) {
      Remove-Item -LiteralPath $ripDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    $ripDir = $null
  }
}

Write-Output ''
Write-Output ("summary: {0} published, {1} skipped (already had one), {2} failed" -f $ok, $skipped, $failed)
foreach ($p in $problems) { Write-Output "  ! $p" }
# Exit non-zero on ANY failure so a caller cannot read a partial run as a clean one.
if ($failed -gt 0) { exit 2 }
exit 0
