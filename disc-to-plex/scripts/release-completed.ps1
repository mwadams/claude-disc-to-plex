# Release the RAW STAGING of units that are finished: published, confirmed by the user, reclaimed.
#
# WHY THIS IS A SCRIPT AND NOT A HAND-DELETE
# ------------------------------------------
# Releasing staging is the one irreversible step in the pipeline - the disc has to be re-fetched
# from a slow USB spindle to undo it. Two distinct mistakes have already been paid for:
#
#   - Colonel Blimp D1 was released having ripped 4 of its 7 titles. The rips that were taken all
#     verified; t02/t04/t05 had simply never been looked at. Duration-verifying the rips you took
#     says NOTHING about the titles you never enumerated, so this refuses without a clean
#     assert-accounted.
#   - BTTF2 was re-fetched (40 GB) and began re-ripping a FINISHED film, because nothing recorded
#     that it was done. So release NEVER restores the _fetch-done.txt line - that is the difference
#     between this and _release-front.ps1, which releases UNWORKED discs and must re-queue them.
#
# The gate is deliberately built from evidence that already exists rather than a fresh judgement:
#
#   1. the unit is named in _completed.txt  (only written after the user confirms it in Plex)
#   2. assert-accounted.ps1 -RequireEvidence exits 0  (every title has a cited disposition)
#
# Both must pass. Neither can be satisfied by an encode "looking finished".
#
#   pwsh -File _release-completed.ps1 -Units 'Disc A','Disc B' [-DryRun]
#
# Also removes the unit's <name>.tracks.json and its <normalised>-rip intermediate, which are
# derived artefacts of the same disc and are worthless once it is gone.

param(
  [Parameter(Mandatory)][string[]]$Units,
  [string]$Stage      = 'D:/video/_stage',
  [string]$Catalogue  = 'D:/video/_catalogue',
  [string]$Completed  = 'D:/video/_completed.txt',
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

$done = @(Get-Content -LiteralPath $Completed -ErrorAction SilentlyContinue |
          Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })

$assert = 'D:/video/.claude/skills/disc-to-plex/scripts/assert-accounted.ps1'
$freed  = 0
$okCount = 0

foreach ($u in $Units) {
  $unit = $u.Trim()
  $dir  = Join-Path $Stage $unit

  # A staged path must resolve INSIDE the staging root. A unit name carrying '..' or an absolute
  # path would otherwise aim the removal somewhere else entirely. StartsWith, not -like: a literal
  # wildcard next to a removal trips the project's own delete guard.
  $full = [System.IO.Path]::GetFullPath($dir)
  $root = [System.IO.Path]::GetFullPath($Stage)
  if (-not $full.StartsWith($root + [System.IO.Path]::DirectorySeparatorChar)) {
    Write-Output "REFUSE  $unit - resolves outside the staging root"
    continue
  }

  if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
    Write-Output "skip    $unit - not staged"
    continue
  }

  if ($done -notcontains $unit) {
    Write-Output "REFUSE  $unit - not in _completed.txt (publish, confirm and reclaim it first)"
    continue
  }

  & pwsh -NoProfile -File $assert -Disc $dir -RequireEvidence > $null 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Output "REFUSE  $unit - assert-accounted exit $LASTEXITCODE (titles unaccounted for)"
    continue
  }

  # A DISC CAN HAVE MORE THAN ONE CONSUMER. Refuse while any manifest still needs it.
  #
  # Both gates above ask "is this disc's own work finished?" - accounted for, and confirmed in Plex.
  # Neither asks whether something ELSE is still going to read it. On 2026-08-26 the user asked for
  # two programmes carried as Strangers extras to ALSO be filed as episodes of their own series, so
  # `Strangers D2` gained a second manifest (`new-scotland-yard-s04e05.json`, title 5) long after
  # `strangers-d2.json` had encoded. Releasing on the strength of the first would have deleted the
  # staging out from under an encode that had not run.
  #
  # Match the STAGED PATH, not the bare name: a unit can be called `M`, and a substring match on one
  # letter hits every manifest containing an "m".
  $pathRx = '_stage[\\/]' + [regex]::Escape($unit) + '(?=["\\/])'
  $pending = @(Get-ChildItem "D:/video/_queue/*.json", "D:/video/_queue/running/*.json" -ErrorAction SilentlyContinue |
               Where-Object { (Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue) -match $pathRx })
  if ($pending.Count -gt 0) {
    Write-Output ("REFUSE  {0} - {1} manifest(s) still queued or running against it: {2}" -f `
                  $unit, $pending.Count, (($pending.Name) -join ', '))
    continue
  }

  # Derived artefacts: the analysis sidecar and the rip intermediate. The rip folder is named from
  # the unit with every non-alphanumeric character dropped, which is how _rip-loop.ps1 names it.
  $slug     = ($unit -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
  $targets  = @($dir)
  $sidecar  = Join-Path $Stage "$unit.tracks.json"
  if (Test-Path -LiteralPath $sidecar) { $targets += $sidecar }
  foreach ($suffix in @('-rip', '-x', '-main', '-mkv')) {
    $ripDir = Join-Path $Stage "$slug$suffix"
    if (Test-Path -LiteralPath $ripDir -PathType Container) { $targets += $ripDir }
  }

  $bytes = 0
  foreach ($t in $targets) {
    $bytes += (Get-ChildItem -LiteralPath $t -Recurse -File -ErrorAction SilentlyContinue |
               Measure-Object Length -Sum).Sum
  }

  if ($DryRun) {
    Write-Output ("WOULD   {0} - {1} path(s), {2:N2} GB" -f $unit, $targets.Count, ($bytes/1GB))
    $freed += $bytes; $okCount++
    continue
  }

  foreach ($t in $targets) { Remove-Item -LiteralPath $t -Recurse -Force -ErrorAction SilentlyContinue }

  $left = @($targets | Where-Object { Test-Path -LiteralPath $_ })
  if ($left.Count -gt 0) {
    Write-Output "PARTIAL $unit - $($left.Count) path(s) still present"
  } else {
    Write-Output ("release {0} - {1:N2} GB" -f $unit, ($bytes/1GB))
    $freed += $bytes; $okCount++
  }
}

Write-Output ("{0}: {1} unit(s), {2:N2} GB" -f $(if ($DryRun) { 'would free' } else { 'freed' }), $okCount, ($freed/1GB))
Write-Output ("free on D: {0:N0} GB" -f ((Get-PSDrive D).Free/1GB))
