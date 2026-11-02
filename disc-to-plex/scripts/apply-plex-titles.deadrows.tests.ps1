<#
  Tests for apply-plex-titles.ps1 dropping DEAD carried pending titles (2026-11-02).
  Run: pwsh -File apply-plex-titles.deadrows.tests.ps1     (exit 0 = all passed)

  Doctor Who's Androids of Tara extras were renumbered S00E320-324 -> S00E325-329; the five old ledger
  rows were carried for five weeks because Plex can never index a file that is not on the NAS. A TV row
  older than -DeadAfterHours whose file is in no matching season folder is now dropped. Known-negatives:
  a file under a DIFFERENTLY named show folder is found and kept; a young row is kept; a movie-shaped
  row is kept. Uses a throwaway ledger and a local folder standing in for the NAS.
#>
$ErrorActionPreference = 'Stop'
$apt = Join-Path $PSScriptRoot 'apply-plex-titles.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('aptdead-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Write-Host "  PASS  $name" } else { $script:fail++; Write-Host "  FAIL  $name`n        $detail" }
}
try {
  $nas = Join-Path $root 'nas'; $tv = Join-Path $nas 'Television Shows'
  # The real file for row 2 lives under a folder whose name is NOT the show prefix in the basename.
  New-Item -ItemType Directory -Force -Path (Join-Path $tv 'Upstairs, Downstairs (1971)/Season 00') | Out-Null
  Set-Content -LiteralPath (Join-Path $tv 'Upstairs, Downstairs (1971)/Season 00/Upstairs Downstairs - S00E13 - Sandy.mkv') -Value 'x'
  New-Item -ItemType Directory -Force -Path (Join-Path $tv 'Doctor Who (1963)/Season 00') | Out-Null
  $old = (Get-Date).AddDays(-30).ToString('s'); $young = (Get-Date).AddMinutes(-10).ToString('s')
  $ledger = Join-Path $root 'pending.tsv'
  @(
    [pscustomobject]@{ File = 'Doctor Who (1963) - S00E320 - Now and Then - The Androids of Tara.mkv'; Title = 'Now and Then'; FirstSeen = $old },
    [pscustomobject]@{ File = 'Upstairs Downstairs - S00E13 - Sandy.mkv'; Title = 'Sandy'; FirstSeen = $old },
    [pscustomobject]@{ File = 'Doctor Who (1963) - S00E400 - Just Published.mkv'; Title = 'Just Published'; FirstSeen = $young },
    [pscustomobject]@{ File = 'Some Film (1999).mkv'; Title = 'Some Film'; FirstSeen = $old }
  ) | Export-Csv -LiteralPath $ledger -Delimiter "`t" -NoTypeInformation -Encoding UTF8
  $o = @(& pwsh -NoProfile -File $apt -Pending $ledger -NasRoot $nas 2>&1 | ForEach-Object { "$_" }) -join "`n"
  $left = @(if (Test-Path -LiteralPath $ledger) { Import-Csv -LiteralPath $ledger -Delimiter "`t" | ForEach-Object { $_.File } })
  Check 'REAL: the renumbered S00E320 row is dropped' ($left -notcontains 'Doctor Who (1963) - S00E320 - Now and Then - The Androids of Tara.mkv') ($left -join ' | ')
  Check '  ...and the log says so' ($o -match 'DROPPED dead pending title .*S00E320') $o
  Check 'known-negative: a file under a differently named show folder is found and kept' ($left -contains 'Upstairs Downstairs - S00E13 - Sandy.mkv') ($left -join ' | ')
  Check 'known-negative: a young row is kept (Plex may simply be behind)' ($left -contains 'Doctor Who (1963) - S00E400 - Just Published.mkv') ($left -join ' | ')
  Check 'known-negative: a movie-shaped row is kept' ($left -contains 'Some Film (1999).mkv') ($left -join ' | ')
}
catch { Write-Host "  FAIL exception: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"; $fail++ }
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ("{0} passed, {1} failed" -f $pass, $fail)
if ($fail) { exit 1 }
Write-Host 'all tests passed'
exit 0
