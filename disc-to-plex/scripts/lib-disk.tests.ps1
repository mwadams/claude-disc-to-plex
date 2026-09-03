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

Write-Output ''
# "Every Check passed" is NOT the same as "every Check ran" - see the catch above.
if (-not $reachedEnd) { Write-Output 'the suite did not reach its end - treating as FAILED'; $fails++ }
if ($fails) { Write-Output "$fails test(s) FAILED"; exit 1 }
Write-Output 'all tests passed'
exit 0
