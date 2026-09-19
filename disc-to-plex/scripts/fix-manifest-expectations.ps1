<#
.SUPERSEDED 2026-09-19 by derive-manifest-fields.ps1, which absorbs this logic and derives every
  measurable field; the dispositions loop no longer calls this script. Kept for its tests and history.

.SYNOPSIS
  Correct a manifest's `expectSeconds` to the SOURCE's own container duration, for the small,
  mechanical mismatches only. Exit 0 = manifest now agrees with its sources (or already did).

.WHY THIS EXISTS
  `expectSeconds` must be the source's CONTAINER duration (`format=duration`), because that is what
  transcode.ps1's post-encode guard measures. Authors keep writing the VIDEO STREAM's duration or a
  rounded catalogue figure instead, and the gate then refuses a manifest whose encodes would have been
  perfect - by hand, three times: Friends S1 D1 (audio ~0.96 s past the last frame, 12 rows), The
  Rubber-Keyed Wonder Disc 2 (+1.000 s on 18 rows, 35 GB of correct encodes quarantined), Friends S6
  D1 (2026-09-17, 11 rows at -0.9 s). It is arithmetic, not judgement, so it belongs in a script.

.WHAT IT WILL NOT DO
  This must never turn "this row names the WRONG SOURCE" into a silent pass. So it only rewrites a row
  when the gap is small enough to be the known clerical class: |delta| <= -MaxDeltaSeconds (3 s by
  default, ~2 frames over a 22-minute episode is 0.9 s; a wrong title is out by minutes). Anything
  larger is left exactly as it is and REPORTED, so the gate still refuses it and a human looks.
  Rows whose src is a folder (a DVD's VIDEO_TS), rows with a `title`, and STILLS rows are untouched -
  the same rows assert-expectations-match-source.ps1 skips, for the same reasons.

  It does NOT touch `expectFrames`: that is a packet count, and a field-coded source needs half of it
  (see assert-expectations-match-source.ps1's PAFF note), which is not this script's arithmetic.

.EXIT CODES
  0 = every measurable row now matches its source   2 = at least one row is out by more than the
  allowance and was NOT changed (the gate must still refuse)   3 = nothing measurable / no ffprobe
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [double]$MaxDeltaSeconds = 3.0,
  [double]$ToleranceSeconds = 0.50,        # matches assert-expectations-match-source.ps1
  [string]$ToolsDir = 'D:/video/.transcode-tools',
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Write-Output "fix-manifest-expectations: no manifest at $Manifest"; exit 3 }
$raw = Get-Content -LiteralPath $Manifest -Raw
try { $doc = $raw | ConvertFrom-Json } catch { Write-Output "fix-manifest-expectations: $Manifest is not readable JSON"; exit 3 }
$rows = if ($doc -is [array]) { @($doc) } elseif ($doc.outputs) { @($doc.outputs) } else { @($doc) }

$ffprobe = $null
try {
  $paths = Get-Content (Join-Path $ToolsDir 'tool-paths.json') -Raw | ConvertFrom-Json
  $ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'
} catch { }
if (-not $ffprobe -or -not (Test-Path -LiteralPath $ffprobe)) { Write-Output 'fix-manifest-expectations: ffprobe not found - nothing measured, nothing changed'; exit 3 }

$changed = 0; $tooBig = @(); $checked = 0
foreach ($r in $rows) {
  if ($r.PSObject.Properties.Name -notcontains 'expectSeconds') { continue }
  if ("$($r.kind)".Trim() -eq 'STILLS') { continue }
  if ("$($r.title)".Trim() -ne '') { continue }
  $src = "$($r.src)".Trim() -replace '/', '\'
  if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Leaf)) { continue }
  $expSec = 0.0
  if (-not [double]::TryParse("$($r.expectSeconds)", [ref]$expSec) -or $expSec -le 0) { continue }
  $act = 0.0
  $probe = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $src 2>$null | Select-Object -First 1)".Trim()
  if (-not [double]::TryParse($probe, [ref]$act) -or $act -le 0) { continue }
  $checked++
  $delta = $expSec - $act
  if ([math]::Abs($delta) -le $ToleranceSeconds) { continue }
  $leaf = Split-Path "$($r.out)" -Leaf
  if ([math]::Abs($delta) -gt $MaxDeltaSeconds) {
    $tooBig += ("   {0}`n      source {1,12:N3}s   manifest {2,12:N3}s   {3:+0.000;-0.000}s   - LEFT ALONE, past the {4:N1}s allowance" -f $leaf, $act, $expSec, $delta, $MaxDeltaSeconds)
    continue
  }
  Write-Output ("   {0}: expectSeconds {1:N3} -> {2:N3} ({3:+0.000;-0.000}s)" -f $leaf, $expSec, $act, (-$delta))
  $r.expectSeconds = [double]([math]::Round($act, 3))
  $changed++
}

if ($changed -and -not $WhatIf) {
  Copy-Item -LiteralPath $Manifest -Destination ($Manifest + '.before-expectations-fix') -Force
  $out = if ($doc -is [array]) { $rows } elseif ($doc.outputs) { $doc.outputs = $rows; $doc } else { $rows }
  Set-Content -LiteralPath $Manifest -Value (ConvertTo-Json -InputObject $out -Depth 12) -Encoding UTF8
}
if ($tooBig.Count) {
  Write-Output ''
  Write-Output ("{0} row(s) are out by MORE than {1:N1}s - not a rounding slip, so nothing was changed for them:" -f $tooBig.Count, $MaxDeltaSeconds)
  $tooBig | ForEach-Object { Write-Output $_ }
  Write-Output 'Re-identify those rows: a gap that size usually means the row names the wrong source title.'
  exit 2
}
Write-Output ("fix-manifest-expectations: {0} row(s) corrected from their source, {1} measurable row(s) checked{2}" -f $changed, $checked, $(if ($WhatIf) { ' (WhatIf - nothing written)' } else { '' }))
exit 0
