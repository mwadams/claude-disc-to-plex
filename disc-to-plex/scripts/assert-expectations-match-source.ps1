<#
.SYNOPSIS
  REFUSE a manifest whose `expectSeconds` does not match the SOURCE FILE it claims to describe.

.WHY THIS EXISTS - AND WHY assert-expectations-consistent.ps1 CANNOT DO IT
  That guard compares `expectSeconds` against `expectFrames` and asks whether the ratio is a real
  frame rate. Its header is explicit that this is deliberate: "checkable against each other with no
  disc access at all - the cheapest possible guard". It catches one figure being copied from another
  title. It CANNOT catch both figures being wrong by the same factor, because then they agree
  perfectly with each other and imply a perfectly ordinary 29.97 fps.

  That is exactly what happened. The Rubber-Keyed Wonder Disc 2, 2026-09-11: all EIGHTEEN rows
  carried an `expectSeconds` precisely 1.000 s too high, and `expectFrames` precisely 30 too high.
  Internally consistent, so this chain passed them; every encode then came out 30 frames "short",
  was quarantined as `.wrong-length`, and the whole manifest failed - 35 GB of correct encodes
  rejected, the unit escalated, and ~146 GB of staging held for hours on a disk that was already
  below its fetch floor.

  THE SOURCE OF THE ERROR, since a guard should say what it is guarding against. The catalogue
  records MakeMKV's own duration string, which is ROUNDED UP to the whole second:

      catalogue duration   0:17:46      (= 1066 s)
      true source          1065.130 s
      manifest wrote       1066.13 s    = ceil(1065.130) + 0.130

  The integer part was taken from the rounded-up string and the fraction re-attached from the true
  measurement. `_briefs/manifest.md` already says to take these figures from the EMITTED PACKET
  COUNTS; that instruction was there and was not followed, which is the usual reason a rule needs to
  become a check.

.WHAT IT CHECKS
  Only rows whose `src` is a FILE this machine can probe - a rip's .mkv, a BD .m2ts. For those the
  source's own container duration is the authority, and `expectSeconds` must match it.

.WHAT IT DELIBERATELY SKIPS, silently (exit 0)
  * `src` that is a DIRECTORY - a DVD's VIDEO_TS. ffprobe cannot open a folder, and the row's
    `title` selects one title from many, so the folder has no single duration to compare.
  * rows carrying a non-empty `title` - the source holds several titles and `expectSeconds`
    describes ONE of them, not the file.
  * `kind` STILLS - assembled from carved PGC pages, not transcoded from a runtime.
  * rows with no `expectSeconds`, a missing source, or an unprobeable one.
  A guard that cannot measure has not found a fault: it must not refuse.

.NOTES
  ONE header probe per row - no decode, no packet count. `format=duration` is a few KB even on a
  31 GB mkv, so this is cheap enough to sit in the gate chain.

  Exit 0 = nothing to refuse.  Exit 2 = REFUSED.
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  # The real error was 1.000 s. Container/encoder rounding is far smaller - a correct encode of a
  # 1065.130 s source measured 1065.151 s, 0.021 s out - so 0.50 s sits an order of magnitude above
  # the noise and an order of magnitude below the fault it exists to catch.
  [double]$ToleranceSeconds = 0.50,
  [string]$ToolsDir = 'D:/video/.transcode-tools',
  [switch]$Quiet
)

function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path -LiteralPath $Manifest)) { Say "assert-expectations-match-source: no manifest at $Manifest - nothing to check."; exit 0 }
try { $mj = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json }
catch { Say "assert-expectations-match-source: $Manifest is not readable JSON - leaving it to the gate's own parser."; exit 0 }

# ConvertFrom-Json UNWRAPS a single-element array, so a one-row manifest is not an array and an
# `-is [System.Array]` test would read zero rows and exit 0 having checked nothing.
$rows = @()
if ($null -ne $mj) {
  if ($mj -isnot [System.Array] -and $mj.PSObject.Properties.Name -contains 'outputs') { $rows = @($mj.outputs) }
  else { $rows = @($mj) }
}
if (-not $rows.Count) { Say 'assert-expectations-match-source: no rows in this manifest.'; exit 0 }

$ffprobe = $null
try {
  $paths = Get-Content (Join-Path $ToolsDir 'tool-paths.json') -Raw | ConvertFrom-Json
  $ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'
} catch { }
if (-not $ffprobe -or -not (Test-Path -LiteralPath $ffprobe)) {
  Say 'assert-expectations-match-source: ffprobe not found - CANNOT MEASURE, so nothing is refused.'
  exit 0
}

function Get-Text($row, [string]$name) {
  if ($null -eq $row -or $row.PSObject.Properties.Name -notcontains $name) { return '' }
  return "$($row.$name)".Trim()
}

$faults = @(); $checked = 0; $skipped = 0
foreach ($r in $rows) {
  $exp = Get-Text $r 'expectSeconds'
  if (-not $exp) { $skipped++; continue }
  $expSec = 0.0
  if (-not [double]::TryParse($exp, [ref]$expSec) -or $expSec -le 0) { $skipped++; continue }
  if ((Get-Text $r 'kind') -eq 'STILLS') { $skipped++; continue }
  # A non-empty `title` means the source holds several titles and this row is ONE of them.
  if ((Get-Text $r 'title') -ne '') { $skipped++; continue }

  $src = (Get-Text $r 'src') -replace '/', '\'
  if (-not $src) { $skipped++; continue }
  if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { $skipped++; continue }   # folder, or gone

  $raw = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $src 2>$null)".Trim()
  $act = 0.0
  # ffprobe returns the STRING 'N/A' when the header carries no duration, and [double]'N/A' throws.
  if (-not [double]::TryParse($raw, [ref]$act) -or $act -le 0) { $skipped++; continue }

  $checked++
  $delta = $expSec - $act
  if ([math]::Abs($delta) -gt $ToleranceSeconds) {
    $faults += [pscustomobject]@{
      Out = (Split-Path (Get-Text $r 'out') -Leaf)
      Src = (Split-Path $src -Leaf)
      Expect = $expSec; Actual = $act; Delta = $delta
    }
  }
}

if ($faults.Count) {
  Say ''
  Say ("EXPECTATION DOES NOT MATCH THE SOURCE - {0} of {1} measurable row(s):" -f $faults.Count, $checked)
  Say ''
  foreach ($f in ($faults | Select-Object -First 25)) {
    Say ("   {0}" -f $f.Out)
    Say ("      source {0,12:N3}s   manifest {1,12:N3}s   {2:+0.000;-0.000}s   ({3})" -f $f.Actual, $f.Expect, $f.Delta, $f.Src)
  }
  if ($faults.Count -gt 25) { Say ("   ... and {0} more" -f ($faults.Count - 25)) }
  Say ''
  $deltas = @($faults | ForEach-Object { [math]::Round($_.Delta, 2) })
  $uniform = (@($deltas | Sort-Object -Unique).Count -le 2)
  if ($uniform -and $faults.Count -gt 2) {
    Say  'EVERY ROW IS OUT BY THE SAME AMOUNT. That is not a per-title mistake, it is one rule applied'
    Say  'wrongly to all of them - the commonest being MakeMKV''s duration string, which ROUNDS UP to'
    Say  'the whole second (0:17:46 for a 1065.130 s title). Take these figures from the EMITTED'
    Say  'PACKET COUNTS as _briefs/manifest.md rule 2 says, not from the catalogue''s duration text.'
  } else {
    Say  'Re-measure from the source and correct the row. The source is the authority: transcode.ps1'
    Say  'quarantines an output as .wrong-length by comparing against these figures, so a wrong'
    Say  'expectation rejects a CORRECT encode and fails the whole manifest.'
  }
  exit 2
}

Say ("assert-expectations-match-source: OK - {0} row(s) measured against their source, {1} not measurable (DVD folder, multi-title, STILLS or no figure)." -f $checked, $skipped)
exit 0
