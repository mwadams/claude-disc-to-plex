<#
  Tests for Wait-FreeSpaceSettled. Run: pwsh -File lib-disk.tests.ps1   (exit 0 = all passed)

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

Write-Output '2. falls short of expectation but stops moving -> stable'
$r = Wait-FreeSpaceSettled -Before $B -ExpectedGain 50GB -StableReads 3 `
       -Reader (Seq @($B, ($B + 30GB))) -Sleeper $noSleep -MaxPolls 10
Check 'reason'  $r.Reason  'stable'
Check 'settled' $r.Settled 'True'
Check 'gain'    $r.Gain    30GB

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

Write-Output ''
if ($fails) { Write-Output "$fails test(s) FAILED"; exit 1 }
Write-Output 'all tests passed'
exit 0
