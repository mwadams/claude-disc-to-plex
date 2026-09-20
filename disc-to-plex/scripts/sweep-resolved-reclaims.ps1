<#
.SYNOPSIS
  Archive the artefacts in `_reclaim-queue/failed` that the BOARD has already judged resolved, so it
  stops re-explaining them on every read. Report by default; `-Apply` to move. Never deletes.

.WHY THIS EXISTS
  The reclaim queue keeps a failed artefact deliberately - it records a confirmation that did not
  execute, and that is worth keeping. But nothing ever clears one once it is settled, and settling is
  normal: an artefact is superseded by a later one covering the same works, or it failed at 11:04 and
  a retry completed at 13:18. On 2026-09-20 TEN such files sat in `_reclaim-queue/failed`, every one
  of them explained at length by `_stallwatch.ps1` on every single board read - ten lines of "do NOT
  requeue" and "stale history; nothing to do" permanently between the operator and anything real.
  A board that spends ten lines re-explaining settled history is a board that gets skimmed, and the
  whole value of that board is that it is read to the end.

  This is the reclaim-side twin of sweep-resolved-manifests.ps1 and works exactly the same way.

.WHAT IT DOES NOT DO
  IT DOES NOT DECIDE WHETHER AN ARTEFACT IS RESOLVED. `_stallwatch.ps1` answers that, and publishes
  the answer as `reclaimFailedStale` in its state file. The question is subtle - a retry is
  deliberately renamed, so comparing filenames finds nothing, and "superseded" is recorded in a
  sibling .superseded.txt - and the board's own comment warns that a second implementation would
  drift from it: the board would keep reporting what the sweep just moved, or worse, the sweep would
  move something the board still considers open. So this reads the board's verdict and acts on it.
  Run `_stallwatch.ps1` first; with no state file this refuses rather than guessing.

.EXAMPLE
  pwsh -File sweep-resolved-reclaims.ps1              # report what would be archived
  pwsh -File sweep-resolved-reclaims.ps1 -Apply       # archive them
#>
param(
  [string]$ReclaimQueue = 'D:/video/_reclaim-queue',
  [string]$StateFile    = 'D:/video/_stallwatch-state.json',
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
function Say([string]$m) { Write-Output $m }

if (-not (Test-Path -LiteralPath $StateFile)) {
  Say "no board state at $StateFile - run _stallwatch.ps1 first; this script does not judge resolution itself"
  exit 0
}
try { $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json }
catch { Say "board state at $StateFile is unreadable ($($_.Exception.Message)) - refusing to guess"; exit 0 }

# ConvertFrom-Json UNWRAPS a single-element array, so one stale artefact comes back as a bare
# string and a .Count on it reads as the STRING's length. @() first, always.
$stale = @($state.reclaimFailedStale | Where-Object { "$_".Trim() })
$open  = @($state.reclaimFailed      | Where-Object { "$_".Trim() })

if ($open.Count) {
  Say ("{0} reclaim artefact(s) are still OPEN and are not touched here:" -f $open.Count)
  foreach ($o in $open) { Say "  open: $o" }
  Say ''
}
if (-not $stale.Count) { Say 'nothing the board calls resolved - nothing to archive'; exit 0 }

Say ("{0} reclaim artefact(s) the board reports as resolved:" -f $stale.Count)
$dest = Join-Path $ReclaimQueue 'archive'
$moved = 0
foreach ($n in $stale) {
  $src = Join-Path $ReclaimQueue ('failed/' + $n)
  if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { Say "  (gone already) $n"; continue }
  if (-not $Apply) { Say "  would archive: $n"; continue }
  if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
  $base = [IO.Path]::GetFileNameWithoutExtension($n)
  $target = Join-Path $dest $n
  # Never overwrite a previous archive of the same name - two different failures can share one.
  if (Test-Path -LiteralPath $target) {
    $target = Join-Path $dest ($base + '.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
  }
  Move-Item -LiteralPath $src -Destination $target -Force
  # The sibling records are what EXPLAIN the artefact; moving the .json alone would strip the
  # evidence from the thing being archived and leave the board's reason behind in failed/.
  foreach ($suffix in '.result.txt', '.status.txt', '.superseded.txt') {
    $sib = Join-Path $ReclaimQueue ('failed/' + $base + $suffix)
    if (Test-Path -LiteralPath $sib -PathType Leaf) {
      # Build the name FIRST. `Join-Path $dest (expr) + $suffix` binds the third token to
      # -AdditionalChildPath, so the destination came out as a path that does not exist.
      $sibName = ([IO.Path]::GetFileName($target) -replace '\.json$', '') + $suffix
      Move-Item -LiteralPath $sib -Destination (Join-Path $dest $sibName) -Force
    }
  }
  @("archived $(Get-Date -Format 's') by sweep-resolved-reclaims.ps1",
    "_stallwatch.ps1 reported this artefact as resolved - either SUPERSEDED by other artefacts, or",
    "FAILED once with a LATER retry that completed. This script did not re-judge that; it acted on",
    "the board's own verdict (reclaimFailedStale in _stallwatch-state.json).",
    "The file is KEPT as evidence; it is out of _reclaim-queue/failed so the board stops re-reporting it.") |
    Set-Content -LiteralPath ($target + '.resolved.txt') -Encoding UTF8
  Say "  archived: $n"
  $moved++
}
if (-not $Apply) { Say ''; Say 'report only - re-run with -Apply to archive them'; exit 0 }
Say ''
Say ("archived {0} of {1}; they stay readable in {2}" -f $moved, $stale.Count, $dest)
