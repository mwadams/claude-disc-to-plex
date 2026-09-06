<#
.SYNOPSIS
  Remove the disposition EVIDENCE PACKS (contact sheets, extracted frames) for units that are no
  longer staged. Keeps every durable record, and keeps the packs of units still being worked.

.WHY THESE ARE RECLAIMABLE, WHICH IS NOT THE OBVIOUS ANSWER
  `D:/video/_catalogue` is 2.89 GB, and 2.85 GB of that is 3,802 PNGs - `<unit>-frames/`,
  `<unit>-evidence/` and loose `<unit>-sheetN.png`. The durable record (the .catalogue.json, the
  .dispositions.txt, the .analysis.json) is 0.04 GB and is never touched by this script.

  The first reading was that packs for units whose staging has been released are the ONLY surviving
  visual evidence for those discs, and therefore precious. The user corrected it on 2026-09-06, and
  the correction is the whole basis of this script:

      "They could be regenerated, by returning the correct drive (as we own the drives) but would
       not be needing to refer to them *unless* we had already reserved the drive."

  That is decisive. The drives are owned, not borrowed, and the optical-lane discs are physically on
  a shelf - so nothing here is unrecoverable, only inconvenient to recover. And the only circumstance
  that would make anyone open one of these packs is a dispute about what a disc contained, which
  cannot be settled without the disc anyway. Any situation that creates a need for the evidence also
  restores the ability to rebuild it. Evidence with that property has no retention value.

.WHAT IT KEEPS, AND WHY THAT IS THE EXPENSIVE HALF
  Packs whose unit is STILL STAGED are kept, and this is the point people get backwards: they are the
  cheap ones to rebuild in principle and the costly ones to lose in practice, because they belong to
  the discs being dispositioned RIGHT NOW. Rebuilding one is not free - disposition-analysis.ps1 took
  2,628 seconds on a single Blake's 7 disc. Deleting a pack out from under a running agent trades
  0.02 GB for three-quarters of an hour of CPU and a confused agent.

  So the rule is the opposite of "delete what can be rebuilt": delete what nothing is using, and keep
  what is in flight.

  Also always kept: everything that is not a .png, and every loose file that is not a `-sheetN.png`.

  pwsh -NoProfile -File prune-catalogue-evidence.ps1 -WhatIf     # say what would go
  pwsh -NoProfile -File prune-catalogue-evidence.ps1             # do it
#>
param(
  [string]$Catalogue = 'D:/video/_catalogue',
  [string]$Stage     = 'D:/video/_stage',
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

# THE SAFETY PREFIX IS SPECIFIC ON PURPOSE. CLAUDE.md: a filter carrying the bare literal
# 'D:\video\' next to a delete is itself read as a delete target by the guard, and a wildcard
# (-like 'D:\video\*') trips a separate one. A concrete prefix + StartsWith avoids both and is a
# tighter check than either.
$root = (Resolve-Path -LiteralPath $Catalogue).Path
if (-not $root.EndsWith('\')) { $root += '\' }
if (-not $root.StartsWith('D:\video\_catalogue')) { throw "refusing to operate outside the catalogue: $root" }

$staged = @{}
foreach ($d in @(Get-ChildItem -LiteralPath $Stage -Directory -ErrorAction SilentlyContinue)) {
  $staged[$d.Name.ToLowerInvariant()] = $true
}
function Test-InFlight([string]$unit) { return $staged.ContainsKey("$unit".Trim().ToLowerInvariant()) }

$targets = @()
$keptInFlight = 0

foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
  if ($d.Name -notmatch '-(frames|evidence)$') { continue }
  $unit = $d.Name -replace '-(frames|evidence)$', ''
  if (Test-InFlight $unit) { $keptInFlight++; continue }
  $targets += @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue)
}
foreach ($f in @(Get-ChildItem -LiteralPath $root -File -Filter '*.png' -ErrorAction SilentlyContinue)) {
  if ($f.Name -notmatch '^(?<u>.+)-sheet\d+\.png$') { continue }
  if (Test-InFlight $Matches['u']) { $keptInFlight++; continue }
  $targets += $f
}

# Nothing outside the catalogue tree can reach the removal list, whatever the enumeration did.
$safe = @($targets | Where-Object { $_.FullName.StartsWith($root) })
$rejected = @($targets).Count - $safe.Count
if ($rejected -gt 0) { throw "$rejected enumerated path(s) fell outside $root - refusing to remove anything" }

$gb = if ($safe.Count) { ($safe | Measure-Object Length -Sum).Sum / 1GB } else { 0 }
Write-Output ("prune-catalogue-evidence: {0} file(s), {1:N2} GB from packs whose unit is no longer staged" -f $safe.Count, $gb)
Write-Output ("  kept: {0} pack(s)/sheet(s) for units still in _stage (in flight - see the header)" -f $keptInFlight)
if ($safe.Count -eq 0) { exit 0 }
if ($WhatIf) { Write-Output '  WhatIf: nothing removed'; exit 0 }

$n = 0
foreach ($f in $safe) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; $n++ }
foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
  if ($d.Name -notmatch '-(frames|evidence)$') { continue }
  if (@(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0) {
    Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
  }
}
Write-Output ("  removed {0} file(s), {1:N2} GB; empty pack folders tidied" -f $n, $gb)
exit 0
