<#
  Tests for release-ships-nothing.ps1's manifest check and its archive age-out (2026-10-16).
  Run: pwsh -File release-ships-nothing.tests.ps1     (exit 0 = all passed)

  Star Trek 11 Disk 1 was closed ships-nothing, then skipped here because the August
  _manifests/st2009.json - written two months before this copy was staged - names its staging path.
  Same rule as close-ships-nothing.ps1 check 5: an ARCHIVED manifest older than the staging is history.
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'release-ships-nothing.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('rsn-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Write-Host "  PASS  $name" } else { $script:fail++; Write-Host "  FAIL  $name`n        $detail" }
}
try {
  $cat = Join-Path $root '_catalogue'; $stage = Join-Path $root '_stage'; $mans = Join-Path $root '_manifests'
  $queue = Join-Path $root '_queue'; $rq = Join-Path $root '_reclaim-queue'
  New-Item -ItemType Directory -Force -Path $cat, $stage, $mans, $queue, $rq | Out-Null
  $auth = Join-Path $root 'auth.json'
  @{ releaseShipsNothingStaging = @{ granted = '2026-09-17'; userWords = 'test fixture authorisation' } } | ConvertTo-Json | Set-Content -LiteralPath $auth
  $disc = 'Kappa Disk 1'
  $disp = Join-Path $cat "$disc.dispositions.txt"; Set-Content -LiteralPath $disp -Value '# NOTHING IS WORTH SHIPPING: fixture'
  @{ dispositionsSha256 = (Get-FileHash -LiteralPath $disp -Algorithm SHA256).Hash } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $cat "$disc.ships-nothing.json")
  $staged = New-Item -ItemType Directory -Force -Path (Join-Path $stage $disc)
  $body = '[{"src":"' + ((Join-Path $stage $disc) -replace '\\', '/') + '/BDMV/STREAM/00000.m2ts"}]'
  function Run {
    $globs = @("$mans/*.json", "$queue/*.json", "$queue/done/*.json")
    # In-process, not `pwsh -File`: -File hands a [string[]] only its first element and the rest bind
    # positionally (here to -Disc, which then matched nothing - a silent zero).
    $o = @(& $script -WhatIf -CatalogueDir $cat -Stage $stage -ReclaimQueue $rq -Authorisations $auth -ManifestGlobs $globs -Manifests $mans 2>&1 | ForEach-Object { "$_" })
    return ($o -join "`n")
  }
  Write-Host '1. REAL: an archived manifest older than the staging does not block the release'
  $old = Join-Path $mans 'kappa.json'; Set-Content -LiteralPath $old -Value $body
  (Get-Item -LiteralPath $old).LastWriteTime = $staged.CreationTime.AddDays(-60)
  $t = Run
  Check 'would queue' ($t -match 'WOULD QUEUE\s+Kappa Disk 1') $t
  Write-Host '2. the same archive file newer than the staging blocks it'
  (Get-Item -LiteralPath $old).LastWriteTime = $staged.CreationTime.AddMinutes(5)
  $t = Run
  Check 'skipped' ($t -match 'SKIP\s+Kappa Disk 1 - a manifest references') $t
  Write-Host '3. known-negative: an old manifest in a LIVE glob still blocks it'
  (Get-Item -LiteralPath $old).LastWriteTime = $staged.CreationTime.AddDays(-60)
  $live = Join-Path $queue 'kappa-live.json'; Set-Content -LiteralPath $live -Value $body
  (Get-Item -LiteralPath $live).LastWriteTime = $staged.CreationTime.AddDays(-60)
  $t = Run
  Check 'skipped' ($t -match 'SKIP\s+Kappa Disk 1 - a manifest references') $t
}
catch { Write-Host "  FAIL exception: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"; $fail++ }
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ("{0} passed, {1} failed" -f $pass, $fail)
if ($fail) { exit 1 }
Write-Host 'all tests passed'
exit 0
