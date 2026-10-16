<#
  Tests for close-ships-nothing.ps1 check 5 - "no manifest references the disc" - and its archive age-out.
  Run: pwsh -File close-ships-nothing.tests.ps1     (exit 0 = all passed)

  2026-10-16: Star Trek 11 Disk 1, re-fetched to check for a re-rip and found to ship nothing, was refused
  on _manifests/st2009.json - the August manifest that published the film two months before this copy was
  staged. An ARCHIVED manifest older than the staging is history; anything live, or newer, still refuses.
  Only check 5's verdict is asserted: later checks (assert-accounted) fail on these bare fixtures by design.
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'close-ships-nothing.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('csn-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Write-Host "  PASS  $name" } else { $script:fail++; Write-Host "  FAIL  $name`n        $detail" }
}
try {
  $cat = Join-Path $root '_catalogue'; $stage = Join-Path $root '_stage'; $mans = Join-Path $root '_manifests'
  $pend = Join-Path $root '_pending'; $queue = Join-Path $root '_queue'
  New-Item -ItemType Directory -Force -Path $cat, $stage, $mans, $pend, $queue, (Join-Path $queue 'done') | Out-Null
  $disc = 'Kappa Disk 1'
  Set-Content -LiteralPath (Join-Path $cat "$disc.dispositions.txt") -Value "# NOTHING IS WORTH SHIPPING: test fixture`nt00|exclude|x"
  $staged = New-Item -ItemType Directory -Force -Path (Join-Path $stage $disc)
  $body = '[{"out":"D:/video/Movies/Kappa/Kappa.mkv","src":"' + ((Join-Path $stage $disc) -replace '\\', '/') + '/BDMV/STREAM/00000.m2ts"}]'
  function Run {
    $o = @(& pwsh -NoProfile -File $script -Disc $disc -Because 'test fixture: subtitles, second audio, structure, quality and extras all checked' -CatalogueDir $cat -Stage $stage -Manifests $mans -Pending $pend -Queue $queue 2>&1 | ForEach-Object { "$_" })
    return ($o -join "`n")
  }
  $refused = 'manifest\(s\) reference this disc'

  Write-Host '1. REAL: an archived manifest older than the staging is history'
  $old = Join-Path $mans 'kappa.json'; Set-Content -LiteralPath $old -Value $body
  (Get-Item -LiteralPath $old).LastWriteTime = $staged.CreationTime.AddDays(-60)
  $t = Run
  Check 'not refused on it' ($t -notmatch $refused) $t
  Check 'and says why it was set aside' ($t -match 'archived manifest\(s\) predate this staging') $t

  Write-Host '2. the same archive file written AFTER the staging is a real claim'
  (Get-Item -LiteralPath $old).LastWriteTime = $staged.CreationTime.AddMinutes(5)
  $t = Run
  Check 'refused' ($t -match $refused) $t

  Write-Host '3. known-negative: an equally old manifest in a LIVE directory still refuses'
  (Get-Item -LiteralPath $old).LastWriteTime = $staged.CreationTime.AddDays(-60)
  $live = Join-Path $queue 'done/kappa-done.json'; Set-Content -LiteralPath $live -Value $body
  (Get-Item -LiteralPath $live).LastWriteTime = $staged.CreationTime.AddDays(-60)
  $t = Run
  Check 'refused on the _queue/done copy' ($t -match $refused -and $t -match 'kappa-done\.json') $t
  Remove-Item -LiteralPath $live -Force

  Write-Host '4. known-negative: no staging folder -> nothing is aged out'
  Remove-Item -LiteralPath (Join-Path $stage $disc) -Recurse -Force
  $t = Run
  Check 'the old archive manifest refuses again' ($t -match $refused) $t
}
catch { Write-Host "  FAIL exception: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"; $fail++ }
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ("{0} passed, {1} failed" -f $pass, $fail)
if ($fail) { exit 1 }
Write-Host 'all tests passed'
exit 0
