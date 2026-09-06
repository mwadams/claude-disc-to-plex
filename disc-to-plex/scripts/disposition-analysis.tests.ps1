<#
  Tests for disposition-analysis.ps1's TRUNCATION verdict.

  WHY THIS FILE EXISTS
  The script had no tests, and its truncation check was wrong in two independent ways from the day
  it was written until 2026-09-06. Neither was caught by anything, because a wrong verdict looks
  exactly like a right one in the report:

    1. WRONG FIELD. It matched MakeMKV's log line "Title #N was added" against the catalogue's
       0-based MakeMKV index, but that number is the DVD TITLE NUMBER. Measured across ten discs
       carrying MakeMKV logs: matching on `dvdvideoTitle` agreed 3-11 times per disc, matching on
       the index agreed ZERO times on every disc. Every finding it ever produced compared a fragment
       against some OTHER title's duration. On Doctor Who "The Ark" it paired a 24-minute episode
       with the disc's 1:38:05 play-all and reported "TRUNCATED, 24.8%".

    2. NO THRESHOLD. `full > trunc` flagged any difference at all - and MakeMKV floors its printed
       duration to whole seconds, so up to 1 s is pure formatting, before any real still cell.

    Re-running the corrected check across every catalogue with a cell-removal warning: 19 TRUNCATED
    findings before, 0 after. All nineteen were spurious. It also MISSED one it should have seen.

  The rule is now `Get-TruncationVerdict`, extracted so it can be tested at all.
#>
$ErrorActionPreference = 'Stop'

# Load the function without running the script: it needs -Unit and would go and read a disc.
$src = Get-Content -LiteralPath "$PSScriptRoot/disposition-analysis.ps1" -Raw
$m = [regex]::Match($src, '(?ms)^function Get-TruncationVerdict \{.*?^\}')
if (-not $m.Success) { Write-Output 'FAIL: Get-TruncationVerdict not found in disposition-analysis.ps1'; exit 1 }
. ([scriptblock]::Create($m.Value))

$fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}

Write-Output '1. THE MEASURED BENIGN POPULATION - every cell-removal warning in the catalogue, 2026-09-06'
# These are the only three that produce any shortfall at all. All are a single tail cell.
Check 'Day of the Triffids  Title #4  5s of 1558s (0.32%)' (Get-TruncationVerdict -FullSec 1558 -TruncSec 1553) 'benign'
Check "Blake's 7 S3 Disk 2  Title #6  3s of 3089s (0.10%)" (Get-TruncationVerdict -FullSec 3089 -TruncSec 3086) 'benign'
Check 'The Mutants D1       Title #4  1s of 1464s (0.07%)' (Get-TruncationVerdict -FullSec 1464 -TruncSec 1463) 'benign'

Write-Output '2. THE CONFIRMED REAL TRUNCATION must still fire'
# Spaced S00E04: 70.12 s emitted against an expected 1076.92 s. This is the failure the check exists
# for - MakeMKV cell-deduplication dropping most of a title - and it reached the library.
Check 'Spaced S00E04  70.12s of 1076.92s (93% loss)' (Get-TruncationVerdict -FullSec 1076.92 -TruncSec 70.12) 'truncated'

Write-Output '3. THE BAND IS ASYMMETRIC ON PURPOSE - a false benign hides content, a false truncated costs a measurement'
Check '25-min episode losing 12 s (0.8%) flags'   (Get-TruncationVerdict -FullSec 1500 -TruncSec 1488) 'truncated'
Check '25-min episode losing 5 s  (0.33%) benign' (Get-TruncationVerdict -FullSec 1500 -TruncSec 1495) 'benign'
# The absolute cap stops a long title swallowing a real loss by percentage alone.
Check '3-hour feature losing 54 s (0.5%) flags'   (Get-TruncationVerdict -FullSec 10800 -TruncSec 10746) 'truncated'
Check '3-hour feature losing 20 s (0.19%) flags'  (Get-TruncationVerdict -FullSec 10800 -TruncSec 10780) 'truncated'
Check '3-hour feature losing 2 s benign'          (Get-TruncationVerdict -FullSec 10800 -TruncSec 10798) 'benign'

Write-Output '4. HH:MM:SS FLOORING alone must never read as truncation'
# MakeMKV prints its duration floored to whole seconds, so a sub-second difference is formatting.
Check 'shortfall 0.48 s (The Ark still cell)' (Get-TruncationVerdict -FullSec 1462.48 -TruncSec 1462) 'benign'
Check 'shortfall 0.99 s'                      (Get-TruncationVerdict -FullSec 1462.99 -TruncSec 1462) 'benign'

Write-Output '5. DEGENERATE INPUT is "none", never a verdict'
Check 'null full'          (Get-TruncationVerdict -FullSec $null -TruncSec 100) 'none'
Check 'null trunc'         (Get-TruncationVerdict -FullSec 100 -TruncSec $null) 'none'
Check 'equal durations'    (Get-TruncationVerdict -FullSec 1500 -TruncSec 1500) 'none'
Check 'fragment LONGER'    (Get-TruncationVerdict -FullSec 1500 -TruncSec 1510) 'none'
Check 'zero full duration' (Get-TruncationVerdict -FullSec 0 -TruncSec 0) 'none'

if ($fails) { Write-Output "TESTS FAILED - $fails case(s)"; exit 1 }
Write-Output 'all tests passed'
exit 0
