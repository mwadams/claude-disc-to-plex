<#
.SYNOPSIS
  Shift a contiguous run of episode numbers in a LOCAL season folder, moving every sidecar with its
  media file. Plans the whole move first and refuses on any collision. Report by default; `-Apply`
  to rename. Never deletes, and never touches the NAS.

.WHY THIS EXISTS
  The West Wing Season 3, 2026-09-09. Disc 1 held four titles: the non-canonical special "Isaac and
  Ishmael" plus Manchester I, Manchester II and Ways and Means. Its manifest filed the special
  correctly as `S00E15` AND numbered the other three E01-E03 - both right. The disc-2 manifest then
  resumed at E05, because it had counted disc 1 as FOUR episodes. The special was filed in Season 00
  and still consumed a slot in Season 03, so every one of the eighteen episodes from disc 2 onward
  published one number too high, and the season ended at a non-existent E22.

  Nothing structural could see it: the file count was right, every runtime was plausible, and Plex
  faithfully displayed whatever the filename said. The discs settled it in seconds once asked - each
  episode's on-screen title card names itself, and all twenty-one read exactly one lower than the
  file claimed.

  Fixing that by hand is eighteen renames of two files each, in an order that must not collide,
  and the obvious loop is WRONG: rename E05 to E04 while E04 still exists and you either fail or
  overwrite. This is that step, done once, correctly.

.THE ORDER IS LOAD-BEARING
  Shifting DOWN must run in ASCENDING episode order (E05 vacates before E06 arrives); shifting UP
  must run in DESCENDING order. Get it backwards and each rename lands on a file that has not moved
  yet. The direction is derived from -Delta, never assumed.

.WHAT IT REFUSES
  - a target number below 1
  - a target already occupied by an episode OUTSIDE the moving set (a real collision, not a
    self-overlap - the whole point of the shift is that the set overlaps itself)
  - a target path that already exists on disk for any reason
  Refusals are decided against the FULL plan before a single file moves, so a rejected run leaves
  the folder exactly as it found it.

.WHAT IT DOES NOT DO
  It does not decide WHICH episodes are misnumbered - that is an identification, and it belongs to
  whoever read the title cards or the subtitles. It does not touch manifests, queues or the NAS; it
  prints the local paths it changed so the caller can carry the same correction to them.

.EXAMPLE
  # The West Wing S3: files E05..E22 actually hold episodes 04..21
  pwsh -File renumber-season.ps1 -Dir 'D:/video/Television Shows/The West Wing/Season 03' -Season 3 -From 5 -Delta -1
  pwsh -File renumber-season.ps1 -Dir 'D:/video/Television Shows/The West Wing/Season 03' -Season 3 -From 5 -Delta -1 -Apply
#>
param(
  [Parameter(Mandatory)][string]$Dir,
  [Parameter(Mandatory)][int]$Season,
  [Parameter(Mandatory)][int]$From,          # first episode number to move
  [int]$To = 0,                              # last to move; 0 = every episode at or above -From
  [Parameter(Mandatory)][int]$Delta,         # -1 shifts E05 -> E04
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
function Say([string]$m) { Write-Output $m }

if ($Delta -eq 0) { Say 'renumber-season: -Delta 0 would do nothing'; exit 2 }
if (-not (Test-Path -LiteralPath $Dir -PathType Container)) { Say "renumber-season: no such folder: $Dir"; exit 2 }

# THE WORKING SET IS LOCAL ONLY. A season folder on the NAS is a published library; renaming there
# is forbidden outright (a NAS correction is copy-then-the-user-deletes). Refusing here means the
# rule cannot be broken by a mistyped -Dir.
$full = (Resolve-Path -LiteralPath $Dir).Path
if (-not $full.StartsWith('D:\video\')) {
  Say "renumber-season: REFUSED - '$full' is not under D:/video. This renames the WORKING SET only."
  exit 2
}

$rxEp = '(?i)S{0:D2}E(\d{{1,3}})' -f $Season

# Group every file by the episode number in its name, so a .mkv and its .eng.srt move together and
# a sidecar can never be left pointing at the number its media used to have.
$byEp = @{}
foreach ($f in @(Get-ChildItem -LiteralPath $full -File)) {
  if ($f.Name -notmatch $rxEp) { continue }
  $n = [int]$Matches[1]
  if (-not $byEp.ContainsKey($n)) { $byEp[$n] = @() }
  $byEp[$n] += $f
}
if (-not $byEp.Count) { Say "renumber-season: no S$('{0:D2}' -f $Season)Exx files in $full"; exit 2 }

$present = @($byEp.Keys | Sort-Object)
$last = if ($To -gt 0) { $To } else { ($present | Measure-Object -Maximum).Maximum }
$moving = @($present | Where-Object { $_ -ge $From -and $_ -le $last })
if (-not $moving.Count) { Say "renumber-season: no episodes in range E$From..E$last"; exit 2 }

Say ("renumber-season: {0}" -f $full)
Say ("  season {0}, present: {1}" -f $Season, (($present | ForEach-Object { 'E{0:D2}' -f $_ }) -join ' '))
Say ("  moving E{0:D2}..E{1:D2} by {2}" -f $moving[0], $moving[-1], $Delta)
Say ''

# ---- PLAN EVERYTHING, THEN VALIDATE, THEN MOVE --------------------------------------------------
$movingSet = @{}; foreach ($m in $moving) { $movingSet[$m] = $true }
$refusals = @()
$plan = @()
foreach ($n in $moving) {
  $t = $n + $Delta
  if ($t -lt 1) { $refusals += "E$('{0:D2}' -f $n) would become E$t - below episode 1"; continue }
  # A target occupied by an episode that is ALSO moving is not a collision: it will have vacated by
  # the time we get there. One that is standing still is a real one.
  if ($byEp.ContainsKey($t) -and -not $movingSet.ContainsKey($t)) {
    $refusals += "E$('{0:D2}' -f $n) -> E$('{0:D2}' -f $t) but E$('{0:D2}' -f $t) exists and is not moving"
    continue
  }
  foreach ($f in $byEp[$n]) {
    $newName = [regex]::Replace($f.Name, $rxEp, ('S{0:D2}E{1:D2}' -f $Season, $t))
    if ($newName -eq $f.Name) { $refusals += "could not rewrite '$($f.Name)'"; continue }
    $plan += [pscustomobject]@{ Order = $n; From = $f.FullName; ToName = $newName; ToPath = (Join-Path $full $newName) }
  }
}

# A target that already exists on disk and is not itself about to move is fatal regardless of how
# the numbers looked - belt and braces, because overwriting a published encode is unrecoverable here.
$vacating = @{}; foreach ($p in $plan) { $vacating[$p.From] = $true }
foreach ($p in $plan) {
  if ((Test-Path -LiteralPath $p.ToPath) -and -not $vacating.ContainsKey($p.ToPath)) {
    $refusals += "target already exists: $($p.ToName)"
  }
}

if ($refusals.Count) {
  Say 'REFUSED - nothing renamed:'
  foreach ($r in ($refusals | Sort-Object -Unique)) { Say "    $r" }
  exit 2
}

# Shifting down frees the lower number first; shifting up must start from the top.
$ordered = if ($Delta -lt 0) { @($plan | Sort-Object Order) } else { @($plan | Sort-Object Order -Descending) }

foreach ($p in $ordered) {
  if (-not $Apply) { Say ("  would rename  {0}  ->  {1}" -f (Split-Path -Leaf $p.From), $p.ToName); continue }
  Rename-Item -LiteralPath $p.From -NewName $p.ToName
  Say ("  renamed  {0}  ->  {1}" -f (Split-Path -Leaf $p.From), $p.ToName)
}

if (-not $Apply) {
  Say ''
  Say ("report only - {0} file(s) would move. Re-run with -Apply." -f $ordered.Count)
  exit 0
}

# VERIFY, DO NOT ASSUME.
$missing = @($ordered | Where-Object { -not (Test-Path -LiteralPath $_.ToPath) })
if ($missing.Count) {
  Say ''
  Say ("!! {0} rename(s) did not land - the folder is now PART-MOVED, fix by hand:" -f $missing.Count)
  foreach ($m in $missing) { Say "    $($m.ToName)" }
  exit 1
}
Say ''
Say ("renumber-season: {0} file(s) renamed." -f $ordered.Count)
Say 'These paths are recorded elsewhere too - manifests in _queue/done, path-keyed queues'
Say '(revalidate-queue.ps1), and the published copies on the NAS. Carry the correction to them.'
exit 0
