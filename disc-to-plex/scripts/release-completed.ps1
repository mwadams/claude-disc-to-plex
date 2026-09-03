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
#   pwsh -NoProfile -Command "& D:/video/_release-completed.ps1 -Units @('Disc A','Disc B')"
#
# (-NoProfile because the profile Import-Clixml's Terminal-Icons theme files on every pwsh start;
# with concurrent pwsh processes a reader catches a half-written file and prints "Import-Clixml:
# 'Element' is an invalid XmlNodeType" before this script even runs. Harmless but alarming; this
# script has no profile dependence.)
#
# NOT `pwsh -File ... -Units 'Disc A','Disc B'`. That is a NATIVE call, so the comma-separated list
# expands into FOUR SEPARATE command-line arguments before the child process sees them. -File binds
# only the first to -Units; the rest land positionally in -Stage, -Catalogue and -Completed. On
# 2026-09-01 that reported 'skip Babylon 5 Season 1 Disk 2 - not staged' for a disc that was plainly
# staged (its -Stage had become 'Babylon 5 Season 1 Disk 3') and said nothing at all about the other
# three. It fails CLOSED - a corrupted -Completed reads as an empty confirmation list - but it fails
# SILENTLY, and 'not staged' reads exactly like 'already released'. The guard below catches it now.
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

# DID THE ARGUMENTS ARRIVE INTACT? See the -File warning in the header. If the array collapsed into
# separate native arguments, these three hold DISC NAMES rather than paths, every unit is measured
# against a staging root that does not exist, and each one reports 'not staged' - indistinguishable
# from 'already released'. Check them, and name the real cause rather than the symptom.
foreach ($pair in @(@{ n='Stage'; v=$Stage; t='Container' },
                    @{ n='Catalogue'; v=$Catalogue; t='Container' },
                    @{ n='Completed'; v=$Completed; t='Leaf' })) {
  if (-not (Test-Path -LiteralPath $pair.v -PathType $pair.t)) {
    throw ('-{0} is [{1}], which is not an existing {2}. If you passed several units as ' +
           'pwsh -File ... -Units A,B then the array collapsed into separate native arguments and ' +
           'spilled into -Stage/-Catalogue/-Completed. Invoke with -Command and an explicit @() ' +
           'array instead - see the header.') -f $pair.n, $pair.v, $pair.t
  }
}

# A UNIT NAME NEVER CONTAINS A COMMA. It does when `-File ... -Units A,B` reaches the child as one
# string: [string[]] keeps it as a SINGLE element, so the loop runs once against a unit that cannot
# exist and prints 'not staged' - the same misleading line the -Stage spill produces, by a different
# route. Whichever shell mangled it, the answer is the same, so say it once.
foreach ($u0 in $Units) {
  if ($u0 -match ',') {
    throw ('-Units contains a comma: [{0}]. The array was flattened into one string on the way in. ' +
           'Invoke with -Command and an explicit @() array - see the header.') -f $u0
  }
}

$done = @(Get-Content -LiteralPath $Completed -ErrorAction SilentlyContinue |
          Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })

$assert = 'D:/video/.claude/skills/disc-to-plex/scripts/assert-accounted.ps1'
$freed  = 0
$okCount = 0
# Baseline for the settle-check at the end: free space BEFORE anything is removed.
$startFree = [System.IO.DriveInfo]::new('D').AvailableFreeSpace

# LOAD VERIFIED. A dot-source of a bad path raises a NON-TERMINATING error, so the function would
# simply be undefined, the call at the bottom would write one more error to the stream, and the
# script would finish having printed no free-space line at all. Same failure mode as the track
# guard in _publish.ps1 (2026-08-23).
. 'D:/video/.claude/skills/disc-to-plex/scripts/lib-disk.ps1'
if (-not (Get-Command Wait-FreeSpaceSettled -ErrorAction SilentlyContinue)) {
  throw 'lib-disk.ps1 failed to load - refusing to run without the free-space settle check'
}
if (-not (Get-Command Get-UnitStageTargets -ErrorAction SilentlyContinue)) {
  throw 'lib-disk.ps1 failed to load - refusing to run without the shared target enumerator'
}

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

  # Derived artefacts: the analysis sidecar and the rip intermediate, via the ONE shared enumerator
  # (Get-UnitStageTargets, lib-disk.ps1) so this list can never drift from what _reclaim-loop.ps1's
  # own "is there anything left" pre-check believes exists - that drift (loop checked only $dir,
  # this script also checked slug-based -rip/-x/-main/-mkv/-reel/-audio folders) is exactly what let
  # 13 "Danger Man Series 1964-1968" -rip folders (~15 GB) survive a DONE-verdict reclaim: the loop
  # never called this script at all once the raw folder was gone. Computed regardless of whether
  # $dir currently exists - a unit whose raw disc folder already went must still be found here, from
  # its derived artefacts alone.
  $targets = Get-UnitStageTargets -Unit $unit -Stage $Stage

  # NOT STAGED means none of the above exist - not merely that $dir doesn't. A unit whose raw
  # folder is gone but still has a derived artefact sitting in _stage is NOT already released; it
  # is exactly the gap this script exists to close, and "skip" here would make that gap permanent
  # (there is nowhere else this cleanup runs from).
  if ($targets.Count -eq 0) {
    Write-Output "skip    $unit - not staged"
    continue
  }

  # A UNIT CLOSED shipped-outside-manifest IS A HARD REFUSE, NOT SOMETHING _completed.txt CAN
  # OVERRIDE. close-shipped-outside-manifest.ps1 (scripts/) exists for a disc whose one shippable
  # item reached the library by a route no manifest could take (Survivors Series 2 Disk 4's photo
  # gallery: authored as still MENUS, invisible to MakeMKV/transcode.ps1) - for such a disc the raw
  # staging may be the ONLY place that item could ever be re-derived from, and
  # assert-accounted.ps1 has no concept of a non-title item, so it exits 0 and prints "may be
  # released" regardless. This unit's Plex confirmation says the SHIPPED ITEM was seen and is fine,
  # not that the RAW DISC is safe to destroy - those are different questions for this class of disc,
  # unlike every other unit this script handles. So this check runs before -Completed is even
  # consulted, and there is no override flag: removing the record is a deliberate, separate, human
  # act (see the record's own releaseNotice field), never a side effect of running this script.
  $somGuard = Join-Path $Catalogue "$unit.shipped-outside-manifest.json"
  if (Test-Path -LiteralPath $somGuard) {
    Write-Output "REFUSE  $unit - shipped-outside-manifest record present ($somGuard); this staging is NOT releasable by this script. Read the record's releaseNotice; removing it is a deliberate human step, not an automatic one."
    continue
  }

  if ($done -notcontains $unit) {
    Write-Output "REFUSE  $unit - not in _completed.txt (publish, confirm and reclaim it first)"
    continue
  }

  # assert-accounted keys off the catalogue/dispositions FILENAME (Split-Path -Leaf of -Disc), not
  # off $dir existing on disk - it already tolerates a reclaimed staged disc (see its own "staged
  # disc is no longer on disk" branch). Passing $dir here is safe whether or not it currently exists.
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
# FREE SPACE LAGS A LARGE DELETE - WAIT FOR IT TO SETTLE BEFORE REPORTING.
# Rationale, the two measurements behind it, and the tests: scripts/lib-disk.ps1.
#
# On a DryRun nothing was removed, so there is nothing to wait for - and waiting would make a
# preview that touches no files sit there for a minute.
if ($DryRun -or $freed -le 0 -or $null -eq $startFree) {
  Write-Output ("free on D: {0:N1} GB" -f ([System.IO.DriveInfo]::new('D').AvailableFreeSpace/1GB))
} else {
  $s = Wait-FreeSpaceSettled -Before $startFree -ExpectedGain $freed
  if ($s.Settled) {
    Write-Output ("free on D: {0:N1} GB" -f ($s.Free/1GB))
  } else {
    # Say it plainly rather than printing a stale number as though it were the answer. $freed is
    # measured from the files themselves before removal, so it is the figure to trust here.
    Write-Output ("free on D: {0:N1} GB - PROVISIONAL: the volume has not yet accounted for this release ({1:N2} GB removed). Re-check in a moment before deciding anything." -f ($s.Free/1GB), ($freed/1GB))
  }
}
