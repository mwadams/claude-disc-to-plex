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

# AND THE SAME FAILURE IN THE OTHER SHAPE: A SIDECAR WHOSE DISC HAS GONE.
#
# '<unit>.tracks.json', '<unit>.title<N>.tracks.json' and '<unit>.title<N>.single-audio' are
# per-disc evidence: what audio streams a title carries, measured off the staged VOBs. They exist to
# describe a staged disc and, as lib-disk.ps1 puts it, are "just as meaningless once the disc has
# gone". Get-UnitStageTargets takes them WITH their unit - but only when that unit is released
# through it. A unit released before that enumerator existed (2026-09-02, after 13 Danger Man rip
# folders were stranded), or one whose staging left by some other route, leaves its sidecars behind
# with nothing that will ever look at them again.
#
# Found 2026-09-21 by the operator, not by this line: 15 of them in _stage, the oldest from
# 2026-08-29, for 11 units of which none was still staged. Tiny - a few KB each - which is exactly
# why nothing noticed and nothing would have. The cost is not space, it is that _stage stops being
# readable as "what is in flight".
$rxSidecar = '^(?<unit>.+?)(\.title\d+)?\.(tracks\.json|single-audio)$'
$orphanSidecars = @()
foreach ($f in @(Get-ChildItem -LiteralPath $Stage -File -ErrorAction SilentlyContinue)) {
  if ($f.Name -notmatch $rxSidecar) { continue }
  $owner = $Matches['unit']
  if (Test-Path -LiteralPath (Join-Path $Stage $owner) -PathType Container) { continue }
  $orphanSidecars += [pscustomobject]@{ Name = $f.Name; Unit = $owner; When = $f.LastWriteTime }
}

if (-not $hits.Count -and -not $orphanSidecars.Count) { exit 0 }

if ($hits.Count) {
  Write-Output ("*** {0} STAGED INTERMEDIATE(S) NO UNIT CAN REACH - {1:N2} GB that no release will ever take:" -f `
                $hits.Count, (($hits | Measure-Object GB -Sum).Sum))
  foreach ($h in ($hits | Sort-Object GB -Descending)) {
    Write-Output ("      {0,-34} {1,7:N2} GB  {2} file(s)" -f $h.Name, $h.GB, $h.Files)
  }
  Write-Output '      Neither the slug convention nor a .unit marker resolves these to a disc, so every'
  Write-Output '      release path skips them silently. Add a .unit file naming the disc they came from'
  Write-Output ('      (first non-# line = the unit name), then release that disc: ' + $Stage + '/<dir>/.unit')
}

if ($orphanSidecars.Count) {
  $units = @($orphanSidecars | Select-Object -ExpandProperty Unit -Unique)
  Write-Output ("*** {0} ORPHAN SIDECAR(S) in _stage for {1} unit(s) that are no longer staged (oldest {2:yyyy-MM-dd}):" -f `
                $orphanSidecars.Count, $units.Count, (($orphanSidecars | Sort-Object When | Select-Object -First 1).When))
  foreach ($u in ($units | Sort-Object)) {
    $mine = @($orphanSidecars | Where-Object { $_.Unit -eq $u })
    Write-Output ("      {0,-46} {1} file(s)" -f $u, $mine.Count)
  }
  Write-Output '      Per-disc audio evidence with no disc left to describe. Harmless but permanent:'
  Write-Output '      nothing reads them and no release will ever take them. Safe to remove (D: only).'
}
exit 0
