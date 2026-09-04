<#
  Tests for Wait-FreeSpaceSettled and Get-UnitStageTargets.
  Run: pwsh -File lib-disk.tests.ps1   (exit 0 = all passed)

  The point of these is the case that actually bit: a volume that has not yet begun accounting for
  a delete reports its PRE-delete figure, repeatedly and consistently. That looks exactly like a
  settled reading, so "the number stopped changing" alone is not enough to trust it - which is why
  test 3 exists and why the function requires the figure to have MOVED before stability counts.
#>
. "$PSScriptRoot/lib-disk.ps1"
if (-not (Get-Command Wait-FreeSpaceSettled -ErrorAction SilentlyContinue)) {
  Write-Output 'FAIL: lib-disk.ps1 did not load'   # a dot-source failure is NON-terminating
  exit 1
}

$fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}

# A reader that returns a scripted sequence, repeating its last value forever.
function Seq([long[]]$values) {
  $i = [ref]0
  { $v = $values[[Math]::Min($i.Value, $values.Count - 1)]; $i.Value++; $v }.GetNewClosure()
}
$noSleep = { param($ms) }
$B = 100GB

Write-Output '1. reaches the expected gain'
$r = Wait-FreeSpaceSettled -Before $B -ExpectedGain 50GB -Reader (Seq @($B, ($B + 20GB), ($B + 48GB))) `
       -Sleeper $noSleep -MaxPolls 10
Check 'reason'  $r.Reason  'expected'
Check 'settled' $r.Settled 'True'
Check 'free'    $r.Free    ($B + 48GB)

Write-Output '2. THE PLATEAU BUG: moves a little, then holds far short of the expected gain'
#   Reclaiming 83 GB, the volume ticked up a few MB and held flat for three reads. The old rule
#   ("it moved, and it is steady") accepted that and reported a figure 83 GB short as fact. A large
#   delete frees space in BURSTS with plateaus between them, so a plateau proves nothing on its own.
$r = Wait-FreeSpaceSettled -Before $B -ExpectedGain 50GB -StableReads 3 `
       -Reader (Seq @($B, ($B + 20MB))) -Sleeper $noSleep -MaxPolls 10
Check 'reason'  $r.Reason  'timeout'
Check 'settled' $r.Settled 'False'   # -> caller must say PROVISIONAL, not present it as fact
Check 'gain'    $r.Gain    20MB

Write-Output '3. THE REAL BUG: never moves -> timeout, never "stable"'
$r = Wait-FreeSpaceSettled -Before $B -ExpectedGain 50GB -StableReads 3 `
       -Reader (Seq @($B)) -Sleeper $noSleep -MaxPolls 8
Check 'reason'  $r.Reason  'timeout'
Check 'settled' $r.Settled 'False'
Check 'gain'    $r.Gain    0

Write-Output '4. unknown expected gain still settles on stability'
$r = Wait-FreeSpaceSettled -Before $B -ExpectedGain 0 -StableReads 2 `
       -Reader (Seq @($B, ($B + 5GB))) -Sleeper $noSleep -MaxPolls 10
Check 'reason'  $r.Reason  'stable'
Check 'gain'    $r.Gain    5GB


# =================================================================================================
# Get-UnitStageTargets
#
# The NEGATIVES matter more than the positives here. This function's output is fed straight to
# `Remove-Item -Recurse` by _release-completed.ps1, so a target claimed in error destroys staging
# that nobody agreed to release - and re-fetching it is the one irreversible step in this pipeline.
# The `.unit` marker was added because no MATCHER can bridge `mumins1-mkv` to `DIE_MUMINS_1`; these
# tests exist to prove the marker did not smuggle a matcher in by the back door.
# =================================================================================================
if (-not (Get-Command Get-UnitStageTargets -ErrorAction SilentlyContinue)) {
  Write-Output 'FAIL: Get-UnitStageTargets did not load'
  exit 1
}

$stage = Join-Path ([IO.Path]::GetTempPath()) ('lib-disk-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
function NewDir([string]$name) { New-Item -ItemType Directory -Path (Join-Path $stage $name) -Force | Out-Null }
function NewMarker([string]$dir, [string[]]$lines) {
  Set-Content -LiteralPath (Join-Path (Join-Path $stage $dir) '.unit') -Value $lines -Encoding UTF8
}
function Targets([string]$unit) {
  # ASSIGN, THEN ENUMERATE. Get-UnitStageTargets returns `,$targets`, so the empty case arrives as a
  # single element that IS an empty array; piping it straight into Split-Path is a parameter-binding
  # failure, not zero results. That mattered on the first run of these tests: the binding error was
  # TERMINATING, so it aborted the try block, tests 7-14 never ran, and the script still printed
  # "all tests passed" and exited 0 - a test file lying in exactly the direction that makes a guard
  # worthless. Hence this, and the catch below.
  $t = Get-UnitStageTargets -Unit $unit -Stage $stage
  @(@($t) | Where-Object { $_ } | ForEach-Object { Split-Path $_ -Leaf } | Sort-Object)
}

try {
  # --- the pre-existing slug behaviour, which must not change ---------------------------------
  NewDir 'Some Disc'                                          # raw staged disc folder
  NewDir 'somedisc-rip'                                       # slug intermediate
  Set-Content -LiteralPath (Join-Path $stage 'Some Disc.tracks.json') -Value '{}'
  Set-Content -LiteralPath (Join-Path $stage 'Some Disc.title4.tracks.json') -Value '{}'

  Write-Output '5. slug convention still finds the raw folder, sidecars and -rip intermediate'
  Check 'targets' ((Targets 'Some Disc') -join ',') 'Some Disc,Some Disc.title4.tracks.json,Some Disc.tracks.json,somedisc-rip'

  Write-Output '6. a unit with nothing on disk returns EMPTY (the only honest "already released")'
  Check 'count' (Targets 'Never Staged').Count 0

  # --- the marker: the mumins1-mkv case -------------------------------------------------------
  NewDir 'mumins1-mkv'
  NewMarker 'mumins1-mkv' @('DIE_MUMINS_1', '# provenance prose the reader can check')

  Write-Output '7. POSITIVE: a marker-declared intermediate is reached from the unit name'
  Check 'targets' ((Targets 'DIE_MUMINS_1') -join ',') 'mumins1-mkv'

  Write-Output '8. NEGATIVE: a DIFFERENT unit does not reach it'
  Check 'count' (Targets 'DIE_MUMINS_3').Count 0

  Write-Output '9. NEGATIVE: no prefix/substring matching - DIE_MUMINS_1 must not claim _11'
  NewDir 'mumins11-mkv'
  NewMarker 'mumins11-mkv' @('DIE_MUMINS_11')
  Check 'unit 1 sees only its own'  ((Targets 'DIE_MUMINS_1')  -join ',') 'mumins1-mkv'
  Check 'unit 11 sees only its own' ((Targets 'DIE_MUMINS_11') -join ',') 'mumins11-mkv'

  Write-Output '10. NEGATIVE: an intermediate with NO marker is never claimed'
  NewDir 'someoneelse-mkv'
  Check 'count' (Targets 'DIE_MUMINS_1').Count 1

  Write-Output '11. NEGATIVE: a marker on a RAW disc folder is ignored (suffix constraint)'
  #    A -Dest written into another unit''s staged disc must not be able to aim a release at it.
  NewDir 'INNOCENT_DISC'
  NewMarker 'INNOCENT_DISC' @('DIE_MUMINS_1')
  Check 'still only the intermediate' ((Targets 'DIE_MUMINS_1') -join ',') 'mumins1-mkv'

  Write-Output '12. NEGATIVE: an empty / comment-only marker claims nothing'
  NewDir 'blankmarker-x'
  NewMarker 'blankmarker-x' @('# no unit named here', '')
  Check 'count' (Targets 'DIE_MUMINS_1').Count 1

  Write-Output '13. case-insensitive (Windows paths are), and no double-listing'
  Check 'lowercase unit name' ((Targets 'die_mumins_1') -join ',') 'mumins1-mkv'
  NewDir 'selfnamed-rip'
  NewMarker 'selfnamed-rip' @('selfnamed')          # slug of 'selfnamed' -> also matches by slug
  Check 'listed once' ((Targets 'selfnamed') -join ',') 'selfnamed-rip'

  Write-Output '14. all six intermediate suffixes are honoured by the marker path'
  foreach ($sfx in @('rip','x','main','mkv','reel','audio')) {
    NewDir "sfx-$sfx"
    NewMarker "sfx-$sfx" @('SUFFIX_UNIT')
  }
  Check 'six found' (Targets 'SUFFIX_UNIT').Count 6

  $script:reachedEnd = $true
}
catch {
  # A THROW MUST FAIL THE RUN, NOT SILENTLY TRUNCATE IT. Without this, any terminating error jumps
  # straight past the remaining Checks to the summary, which then reports "all tests passed" on a
  # suite that stopped a third of the way through.
  Write-Output "  FAIL exception in the Get-UnitStageTargets tests: $($_.Exception.Message)"
  $script:fails++
}
finally {
  Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}


# =================================================================================================
# Get-RipRecreationRisk
#
# This one REPORTS rather than deletes, so the asymmetry runs the other way from Get-UnitStageTargets:
# the dangerous answer is a FALSE NEGATIVE - "no, releasing this alone is fine" for a directory the
# rip loop will re-create within 90 s, off staging that is still present. That is the reading that
# put 30.2 GB of "recoverable" space on the board on 2026-09-04 when the true figure was 0.
#
# So every stop condition _rip-loop.ps1 actually has gets its own negative test, and the one case
# where the answer is genuinely unknown (no unit resolvable) is asserted on its REASON TEXT, so a
# later refactor cannot quietly turn "unknown" into a clearance while still returning $false.
# =================================================================================================
if (-not (Get-Command Get-RipRecreationRisk -ErrorAction SilentlyContinue)) {
  Write-Output 'FAIL: Get-RipRecreationRisk did not load'
  exit 1
}

$stage2 = Join-Path ([IO.Path]::GetTempPath()) ('lib-disk-rip-' + [guid]::NewGuid().ToString('N'))
$cat2   = Join-Path $stage2 '_catalogue'
$done2  = Join-Path $stage2 '_completed.txt'
New-Item -ItemType Directory -Path $stage2 | Out-Null
New-Item -ItemType Directory -Path $cat2 | Out-Null
Set-Content -LiteralPath $done2 -Value @('# confirmed in Plex')

function Stage2Dir([string]$name) { New-Item -ItemType Directory -Path (Join-Path $stage2 $name) -Force | Out-Null }
function Disp2([string]$unit, [string[]]$lines) {
  Set-Content -LiteralPath (Join-Path $cat2 "$unit.dispositions.txt") -Value $lines
}
function Risk([string]$dir) { Get-RipRecreationRisk -Dir $dir -Stage $stage2 -Catalogue $cat2 -Completed $done2 }

try {
  Write-Output '15. POSITIVE: disc still staged, dispositions name keep-titles -> the rip loop WOULD re-create it'
  Stage2Dir 'Some Film Disk 1'
  Stage2Dir 'somefilmdisk1-rip'
  Disp2 'Some Film Disk 1' @('t00|feature|The Film|frame:x', 't03|extra|An Intro|speech:y', 't09|exclude|copyright reel|boilerplate:z')
  $r = Risk 'somefilmdisk1-rip'
  Check 'unit'      $r.Unit          'Some Film Disk 1'
  Check 'recreate'  $r.WouldRecreate 'True'
  Check 'titles'    $r.Titles        2      # the exclude row is not a keep-title

  Write-Output '16. NEGATIVE (the mirror case): raw staging already released -> nothing re-creates it'
  #    The 13 stranded "Danger Man Series 1964-1968" -rip folders. This is the ONE shape where an
  #    intermediate really can be released on its own, and it must not be lumped in with the rest.
  Stage2Dir 'stranded-rip'
  Set-Content -LiteralPath (Join-Path (Join-Path $stage2 'stranded-rip') '.unit') -Value @('Gone Disc 4') -Encoding UTF8
  Disp2 'Gone Disc 4' @('t00|feature|Whatever|frame:x')
  $r = Risk 'stranded-rip'
  Check 'unit'     $r.Unit          'Gone Disc 4'
  Check 'recreate' $r.WouldRecreate 'False'
  Check 'reason'   ($r.Reason -match 'already released') 'True'

  Write-Output '17. NEGATIVE: unit named in _completed.txt -> the rip loop skips the disc'
  Stage2Dir 'Done Disk 2'
  Stage2Dir 'donedisk2-rip'
  Disp2 'Done Disk 2' @('t00|feature|Finished|frame:x')
  Add-Content -LiteralPath $done2 -Value 'Done Disk 2'
  $r = Risk 'donedisk2-rip'
  Check 'recreate' $r.WouldRecreate 'False'
  Check 'reason'   ($r.Reason -match '_completed\.txt') 'True'

  Write-Output '18. NEGATIVE: .HOLD on the disc -> the rip loop skips it'
  Stage2Dir 'Held Disk 1'
  Stage2Dir 'helddisk1-rip'
  Disp2 'Held Disk 1' @('t00|feature|Parked|frame:x')
  Set-Content -LiteralPath (Join-Path (Join-Path $stage2 'Held Disk 1') '.HOLD') -Value 'awaiting a missing disc'
  Check 'recreate' (Risk 'helddisk1-rip').WouldRecreate 'False'

  Write-Output '19. NEGATIVE: no dispositions file -> the rip loop has nothing to act on'
  Stage2Dir 'Raw Disk 1'
  Stage2Dir 'rawdisk1-rip'
  Check 'recreate' (Risk 'rawdisk1-rip').WouldRecreate 'False'

  Write-Output '20. NEGATIVE: dispositions still carry an unresolved ? -> the rip loop skips'
  Stage2Dir 'Unsure Disk 1'
  Stage2Dir 'unsuredisk1-rip'
  Disp2 'Unsure Disk 1' @('t00|feature|Known|frame:x', 't01|?|unidentified|')
  Check 'recreate' (Risk 'unsuredisk1-rip').WouldRecreate 'False'

  Write-Output '21. the DVD/BD keep vocabulary differs - `episode` is not ripped on a DVD'
  #    _rip-loop.ps1: a DVD manifest reads the disc folder with a title number, so ripping an
  #    episode first is pure waste. Read the disc's shape; never assume one.
  Stage2Dir 'Show DVD Disk 1'
  Stage2Dir 'Show DVD Disk 1/VIDEO_TS'
  Stage2Dir 'showdvddisk1-rip'
  Disp2 'Show DVD Disk 1' @('t01|episode|S01E01|frame:x', 't02|episode|S01E02|frame:y')
  Check 'DVD episodes are not ripped' (Risk 'showdvddisk1-rip').WouldRecreate 'False'
  Stage2Dir 'Show BD Disk 1'
  Stage2Dir 'showbddisk1-rip'
  Disp2 'Show BD Disk 1' @('t01|episode|S01E01|frame:x', 't02|episode|S01E02|frame:y')
  $r = Risk 'showbddisk1-rip'
  Check 'BD episodes ARE ripped' $r.WouldRecreate 'True'
  Check 'BD title count'         $r.Titles        2

  Write-Output '22. a title written off in rip-problems.txt is never retried, so it is not coming back'
  Stage2Dir 'Problem Disk 1'
  Stage2Dir 'problemdisk1-rip'
  Disp2 'Problem Disk 1' @('t00|feature|Fine|frame:x', 't05|extra|Looping gallery|frame:y')
  Set-Content -LiteralPath (Join-Path $cat2 'Problem Disk 1.rip-problems.txt') -Value @('t05|rip did not verify after 2 attempts')
  $r = Risk 'problemdisk1-rip'
  Check 'recreate' $r.WouldRecreate 'True'
  Check 'titles'   $r.Titles        1
  Set-Content -LiteralPath (Join-Path $cat2 'Problem Disk 1.rip-problems.txt') -Value @('t00|no', 't05|no')
  $r = Risk 'problemdisk1-rip'
  Check 'all titles written off -> nothing to re-rip' $r.WouldRecreate 'False'

  Write-Output '23. POSITIVE: a marker-declared directory that follows NO slug convention resolves'
  Stage2Dir 'DIE_MUMINS_9'
  Stage2Dir 'mumins9-mkv'
  Set-Content -LiteralPath (Join-Path (Join-Path $stage2 'mumins9-mkv') '.unit') -Value @('DIE_MUMINS_9', '# provenance') -Encoding UTF8
  Disp2 'DIE_MUMINS_9' @('t00|feature|Moomins|frame:x')
  $r = Risk 'mumins9-mkv'
  Check 'unit'     $r.Unit          'DIE_MUMINS_9'
  Check 'recreate' $r.WouldRecreate 'True'

  Write-Output '24. NEGATIVE: a name outside the intermediate namespace is not evaluated at all'
  $r = Risk 'Some Film Disk 1'
  Check 'recreate' $r.WouldRecreate 'False'
  Check 'reason'   $r.Reason        'not an intermediate directory name'

  Write-Output '25. UNKNOWN must not read as a clearance when no unit can be resolved'
  Stage2Dir 'orphaned-rip'
  $r = Risk 'orphaned-rip'
  Check 'recreate'      $r.WouldRecreate 'False'
  Check 'reason says so' ($r.Reason -match 'UNKNOWN, not as safe') 'True'

  $script:reachedEnd2 = $true
}
catch {
  Write-Output "  FAIL exception in the Get-RipRecreationRisk tests: $($_.Exception.Message)"
  $script:fails++
}
finally {
  Remove-Item -LiteralPath $stage2 -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
# "Every Check passed" is NOT the same as "every Check ran" - see the catch above.
if (-not $reachedEnd)  { Write-Output 'the suite did not reach its end - treating as FAILED'; $fails++ }
if (-not $reachedEnd2) { Write-Output 'the Get-RipRecreationRisk section did not reach its end - treating as FAILED'; $fails++ }
if ($fails) { Write-Output "$fails test(s) FAILED"; exit 1 }
Write-Output 'all tests passed'
exit 0
