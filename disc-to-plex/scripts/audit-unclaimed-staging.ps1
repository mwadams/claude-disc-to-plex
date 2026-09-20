<#
.SYNOPSIS
  Report staged INTERMEDIATE directories that no unit can reach - so nothing will ever release them.
  Read-only; it names paths and never removes anything.

.WHY THIS EXISTS
  `Get-UnitStageTargets` (lib-disk.ps1) is the one authority for "what under _stage belongs to this
  unit". It reaches an intermediate two ways: the SLUG CONVENTION (exactly '<slug><suffix>', e.g.
  'porcorosso-mkv') or a '.unit' MARKER file naming its disc. A folder matching neither is
  unreachable from every unit there is - so every release path skips it, silently, for ever. There
  is no error: each script correctly reports that it released everything it could see.

  2026-09-12 the Porco Rosso storyboard recovery extracted angle 2 of VTS_05 by hand into
  '_stage/porcorosso-angles-mkv' - a QUALIFIED name, because the recovery needed to distinguish it
  from an ordinary '-mkv' intermediate. It was the sole source of the published storyboard edition.
  That edition was confirmed in Plex on 09-18 and its disc's staging released the same day, and the
  folder stayed: 1.98 GB, unreferenced, unreachable, for eight days, until the operator asked why
  17 GB of Porco Rosso was still staged. The board had it on screen the whole time, filed under
  "awaiting OCR/publish/confirmation" - true of its manifest, and by then true of nothing.

  Widening the slug convention to match '<slug>-.+-<suffix>' was tried and REVERTED: ConvertTo-RipSlug
  only lowercases and strips spaces, so hyphens survive, and this pipeline names optical discs
  '<LABEL>-<fingerprint>'. The unit 'GHOST_STORIES_FOR_CHRISTMAS' would then have matched
  'ghost_stories_for_christmas-49ed7525-rip' and aimed a delete at a DIFFERENT disc's rip. A slug is
  a convention, not a record of ownership, and it must not be stretched into one. The marker is the
  record. What was missing was never matching power - it was somebody noticing. This is that.

.WHAT TO DO ABOUT A HIT
  Drop a '.unit' file in the folder whose first non-comment line is the disc it belongs to; the rest
  of the file is free-text provenance. The next release of that disc takes it.

.EXAMPLE
  pwsh -File audit-unclaimed-staging.ps1
#>
param(
  [string]$Stage       = 'D:/video/_stage',
  [string]$CompletedFile = 'D:/video/_completed.txt',
  [string]$LibDisk     = 'D:/video/.claude/skills/disc-to-plex/scripts/lib-disk.ps1'
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Stage -PathType Container)) { exit 0 }
. $LibDisk

# The same six suffixes Get-UnitStageTargets knows. A directory outside that namespace is a staged
# DISC, not an intermediate, and is none of this script's business.
$rxSuffix = '-(rip|x|main|mkv|reel|audio)$'

# Every unit name that could own one: what is staged now, plus what has already been released.
# A released disc is the interesting case - that is exactly when its orphan stops being noticed.
$units = @(Get-ChildItem -LiteralPath $Stage -Directory -ErrorAction SilentlyContinue |
           Where-Object { $_.Name -notmatch $rxSuffix } | ForEach-Object { $_.Name })
if (Test-Path -LiteralPath $CompletedFile) {
  $units += @(Get-Content -LiteralPath $CompletedFile -ErrorAction SilentlyContinue |
              ForEach-Object { "$_".Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') })
}
# Pre-compute the reachable names ONCE: '<slug><suffix>' for every unit. Comparing this way round
# is O(units + dirs) rather than re-deriving a slug per directory per unit.
$reachable = @{}
foreach ($u in ($units | Sort-Object -Unique)) {
  $slug = ConvertTo-RipSlug $u
  foreach ($sfx in @('-rip', '-x', '-main', '-mkv', '-reel', '-audio')) { $reachable[($slug + $sfx)] = $u }
}

$hits = @()
foreach ($d in @(Get-ChildItem -LiteralPath $Stage -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -match $rxSuffix })) {
  if ($reachable.ContainsKey($d.Name.ToLowerInvariant())) { continue }
  if (Test-Path -LiteralPath (Join-Path $d.FullName '.unit') -PathType Leaf) { continue }
  $sz = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue |
         Measure-Object Length -Sum)
  $hits += [pscustomobject]@{ Name = $d.Name; GB = [math]::Round(($sz.Sum/1GB), 2); Files = $sz.Count }
}

if (-not $hits.Count) { exit 0 }

Write-Output ("*** {0} STAGED INTERMEDIATE(S) NO UNIT CAN REACH - {1:N2} GB that no release will ever take:" -f `
              $hits.Count, (($hits | Measure-Object GB -Sum).Sum))
foreach ($h in ($hits | Sort-Object GB -Descending)) {
  Write-Output ("      {0,-34} {1,7:N2} GB  {2} file(s)" -f $h.Name, $h.GB, $h.Files)
}
Write-Output '      Neither the slug convention nor a .unit marker resolves these to a disc, so every'
Write-Output '      release path skips them silently. Add a .unit file naming the disc they came from'
Write-Output ('      (first non-# line = the unit name), then release that disc: ' + $Stage + '/<dir>/.unit')
exit 0
