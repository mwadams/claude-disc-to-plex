<#
.SYNOPSIS
  REFUSE a manifest row whose `subTrack: "eng"` transcode.ps1 would be unable to resolve on a raw
  Blu-ray clip - because the disc declares SEVERAL English subtitle streams and none dominates.

.WHY THIS EXISTS
  On a raw BDMV\STREAM\<clip>.m2ts the subtitle streams are untagged, so transcode.ps1 resolves
  "eng" from the disc's CLPI declaration (Sub-IdxByClpi). That works when exactly one stream is
  declared English, or when one English stream dominates (Friends S3 D1: a populated track beside
  an 8-packet forced-only one). When two or more are comparable - full dialogue + SDH, or a
  dialogue track beside COMMENTARY subtitle tracks - it correctly refuses to choose and ABORTS.

  It aborted at ENCODE time, after every other row of the manifest had run. Moon (2009),
  2026-09-29: the CLPI declares FIVE English PGS streams (dialogue x2, SDH, two commentary
  subtitle tracks); the feature aborted mid-manifest, the seven extras beside it had already
  encoded, and the unit had to be re-authored and re-queued as a retry. The Akerman Blu-rays
  (Golden Eighties, D'Est, La Captive, 2026-09-28) hit the same wall one disc at a time.

  The fact is measurable before anything is queued, so the gate says it here, with the ordinals.

.WHAT IT CHECKS
  Rows whose `src` is a raw BDMV\STREAM\*.m2ts FILE and whose `subTrack` is "eng" or ABSENT (an
  absent subTrack means "eng" to transcode.ps1). A numeric ordinal is the author's choice and
  "none" is an explicit decision - both pass.

  The dominance rule is transcode.ps1's own, so the two can never disagree: a stream is chosen only
  when it has at least 100 packets and ten times any other English candidate. Packets are counted
  in ONE pass over the clip, and only when two or more English streams are declared.

.WHAT IT DELIBERATELY SKIPS (exit 0)
  Anything it cannot measure - no CLPI, an undeclared PID, a missing source, no ffprobe. A guard
  that cannot measure has not found a fault.

  Exit 0 = nothing to refuse.  Exit 2 = REFUSED.
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [string]$ToolsDir = 'D:/video/.transcode-tools',
  # Tests point this at a stub; in the gate it is left empty and read from tool-paths.json.
  [string]$Ffprobe = '',
  [switch]$Quiet
)

function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

. (Join-Path $PSScriptRoot 'lib-clpi.ps1')

if (-not (Test-Path -LiteralPath $Manifest)) { Say "assert-subtrack-resolvable: no manifest at $Manifest - nothing to check."; exit 0 }
try { $mj = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json }
catch { Say "assert-subtrack-resolvable: $Manifest is not readable JSON - leaving it to the gate's own parser."; exit 0 }

# ConvertFrom-Json UNWRAPS a single-element array - read rows the way every other guard does.
$rows = @()
if ($null -ne $mj) {
  if ($mj -isnot [System.Array] -and $mj.PSObject.Properties.Name -contains 'outputs') { $rows = @($mj.outputs) }
  else { $rows = @($mj) }
}
if (-not $rows.Count) { Say 'assert-subtrack-resolvable: no rows in this manifest.'; exit 0 }

$ffprobe = if ($Ffprobe) { $Ffprobe } else { $null }
if (-not $ffprobe) {
  try {
    $paths = Get-Content (Join-Path $ToolsDir 'tool-paths.json') -Raw | ConvertFrom-Json
    $ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'
  } catch { }
}
if (-not $ffprobe -or -not (Test-Path -LiteralPath $ffprobe)) {
  Say 'assert-subtrack-resolvable: ffprobe not found - CANNOT MEASURE, so nothing is refused.'
  exit 0
}

function Get-Text($row, [string]$name) {
  if ($null -eq $row -or $row.PSObject.Properties.Name -notcontains $name) { return '' }
  return "$($row.$name)".Trim()
}

$faults = @(); $checked = 0
foreach ($r in $rows) {
  $st = Get-Text $r 'subTrack'
  if ($st -ne '' -and $st -ne 'eng') { continue }            # an ordinal, or "none": decided
  $src = Get-Text $r 'src'
  if ($src -notmatch '(?i)[\\/]BDMV[\\/]STREAM[\\/]\d+\.m2ts$') { continue }
  if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }

  # Assign, THEN wrap: `@(Get-ClpiSubtitleLangs ...)` would wrap the comma-returned array as ONE
  # element and every disc would read as having a single subtitle stream.
  $langs = Get-ClpiSubtitleLangs -Src $src -Ffprobe $ffprobe
  if ($null -eq $langs) { continue }
  $langs = @($langs)
  $checked++
  $eng = @(for ($i = 0; $i -lt $langs.Count; $i++) { if ($langs[$i] -eq 'eng') { $i } })
  if ($eng.Count -lt 2) { continue }

  # ONE pass: count every subtitle stream's packets, keyed by stream index (a .m2ts lists each
  # stream twice - under its program and again under streams - so de-duplicate on the index).
  $byIndex = @{}
  foreach ($line in @(& $ffprobe -v error -select_streams s -count_packets -show_entries stream=index,nb_read_packets -of csv=p=0 $src 2>$null)) {
    if ("$line".Trim() -match '^(\d+),(\d+)$') { $byIndex[[int]$Matches[1]] = [int]$Matches[2] }
  }
  $ordered = @($byIndex.Keys | Sort-Object)
  if ($ordered.Count -ne $langs.Count) { continue }          # cannot join counts to ordinals: unmeasured
  $counts = @{}
  foreach ($e in $eng) { $counts[$e] = $byIndex[$ordered[$e]] }

  # transcode.ps1's Sub-IdxByClpi rule: the biggest wins only with >= 100 packets and 10x every other.
  $best = $eng | Sort-Object { $counts[$_] } -Descending | Select-Object -First 1
  $dominates = $counts[$best] -ge 100
  foreach ($e in $eng) { if ($e -ne $best -and $counts[$e] * 10 -gt $counts[$best]) { $dominates = $false } }
  if ($dominates) { continue }

  $detail = ($eng | ForEach-Object { "s:$_ ($($counts[$_]) pkts)" }) -join ', '
  $faults += ("  {0}: subTrack {1} - the disc declares {2} English subtitle streams ({3}) and none dominates, so transcode.ps1 cannot choose and will ABORT this item mid-manifest. Render each over the same frame, read them, and set subTrack to the ordinal of the main (dialogue) track." -f (Split-Path (Get-Text $r 'out') -Leaf), $(if ($st) { '"eng"' } else { '(absent = "eng")' }), $eng.Count, $detail)
}

if ($faults.Count) {
  Say "assert-subtrack-resolvable: REFUSED - $($faults.Count) row(s) ask for 'eng' where the disc has several comparable English subtitle streams:"
  $faults | ForEach-Object { Say $_ }
  exit 2
}
Say "assert-subtrack-resolvable: OK - $checked raw Blu-ray row(s) with a CLPI-resolvable subtitle checked; no ambiguous 'eng'."
exit 0
