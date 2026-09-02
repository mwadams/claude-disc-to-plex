# Find discs IN THE CURRENT BATCH that were released without a recorded confirmation.
#
# WHY THIS EXISTS
# ---------------
# _release-completed.ps1 and _release-published.ps1 both gate on _completed.txt, which is written
# only after the user confirms a unit in Plex. That gate is worth nothing if the release is done by
# hand instead - and on 2026-09-01 it was: 61 encoded files and two staging folders removed with a
# raw Remove-Item, correctly byte-verified against the NAS, but with no line ever written to
# _completed.txt. Nothing was lost that time, because the unit was still named in _fetch-done.txt
# and its manifest was in _queue/done. But that register is what stops a FINISHED unit being
# fetched and ripped a second time - the 40 GB BTTF2 mistake - and a gate that can be walked
# around without leaving a trace is not a gate.
#
# SCOPE IS THE CURRENT listN.txt, DELIBERATELY.
# The first version of this script audited every manifest in _queue/done and reported 240 units.
# Two reasons it was useless, both worth remembering:
#   - _completed.txt names DISCS ("Babylon 5 Season 4 Disk 2") while a manifest's `src` names the
#     STAGE FOLDER ("babylon5season4disk2", "...-rip"). They only compare after normalising away
#     case and punctuation.
#   - most of those units are from batches finished weeks ago under older conventions. A check that
#     reports 240 things gets ignored, which is exactly how the real one goes unnoticed.
# So: only the batch under management, where a gap is actionable today.
#
#   pwsh -File audit-release-records.ps1            # report
#   pwsh -File audit-release-records.ps1 -Quiet     # exit code only: 0 clean, 2 gaps found
param(
  [string]$VideoRoot = 'D:/video',
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

# Case- and punctuation-insensitive, because the disc register and the stage folders disagree by
# convention: "Babylon 5 Season 4 Disk 2" is staged as "babylon5season4disk2".
function Key([string]$s) { ($s -replace '[^A-Za-z0-9]', '').ToLower() }

$listFile = Get-ChildItem (Join-Path $VideoRoot 'list*.txt') -ErrorAction SilentlyContinue |
            Sort-Object { $m = [regex]::Match($_.BaseName, '\d+'); if ($m.Success) { [int]$m.Value } else { 0 } } |
            Select-Object -Last 1
if (-not $listFile) { Write-Output 'no listN.txt - nothing to audit'; exit 0 }

$fetched = @{}
foreach ($l in (Get-Content (Join-Path $VideoRoot '_fetch-done.txt') -ErrorAction SilentlyContinue)) {
  if ($l.Trim()) { $fetched[$l.Trim()] = $true }
}
$confirmed = @{}
foreach ($l in (Get-Content (Join-Path $VideoRoot '_completed.txt') -ErrorAction SilentlyContinue)) {
  if ($l.Trim()) { $confirmed[(Key $l)] = $true }
}
$staged = @{}
foreach ($d in (Get-ChildItem (Join-Path $VideoRoot '_stage') -Directory -ErrorAction SilentlyContinue)) {
  $staged[(Key ($d.Name -replace '-rip$', ''))] = $true
}

$gaps = @()
foreach ($e in (Get-Content -LiteralPath $listFile.FullName)) {
  $u = $e.Trim()
  if (-not $u -or $u.StartsWith('#')) { continue }
  if (-not $fetched.ContainsKey($u)) { continue }      # never fetched: not a release at all
  $k = Key $u
  if ($staged.ContainsKey($k)) { continue }            # still staged: simply not finished yet
  if ($confirmed.ContainsKey($k)) { continue }         # released and recorded: correct
  $gaps += $u
}

if ($gaps.Count -eq 0) {
  if (-not $Quiet) {
    Write-Output ("RELEASE RECORDS OK - every fetched-and-released disc in {0} is named in _completed.txt." -f $listFile.Name)
  }
  exit 0
}
if (-not $Quiet) {
  Write-Output ''
  Write-Output ("*** {0} disc(s) in {1} were RELEASED WITHOUT A RECORDED CONFIRMATION:" -f $gaps.Count, $listFile.Name)
  foreach ($g in $gaps) { Write-Output ("    {0}" -f $g) }
  Write-Output ''
  Write-Output '    Fetched, staging now gone, but nothing records the user confirming them in Plex.'
  Write-Output '    Either the release happened outside _release-completed.ps1 /'
  Write-Output '    _release-published.ps1, or the confirmation was never written down. Add the line'
  Write-Output '    to _completed.txt if the disc really was confirmed.'
}
exit 2
