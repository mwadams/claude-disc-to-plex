<#
.SYNOPSIS
  Given files you have changed, name EVERY test suite that exercises them - and run them.

.WHY THIS EXISTS
  On 2026-09-06 `Resolve-BackupFolderName` in lib-optical.ps1 was changed so an archive folder name
  carries the disc fingerprint. `backup-dvd-folder.tests.ps1` was updated with it and reported
  183 passed, and the change was declared finished on that basis. `_optical-loop.tests.ps1` covers
  the SAME function and sat at 37 failures for hours, found only because those tests were run later
  for an unrelated reason.

  Nothing was wrong with the reasoning. What was missing was a definition of DONE: "the suite I was
  looking at is green" instead of "every suite that exercises what I touched is green". That is not
  a thing to remember harder - this project's own rule is that a rule which can be a check should be
  a check, and this is that check.

.WHAT IT DOES
  Takes changed file paths. For each, works out the identifiers it defines (function and Python def
  names) plus its own base name, then greps every *.tests.ps1 in the project for any of them. Prints
  the suites that reference your change, and with -Run executes each and reports pass/fail.

  It is deliberately OVER-INCLUSIVE: a suite that merely mentions the name is listed. A suite you did
  not need to run costs seconds; one you did not know about costs a day.

  pwsh -NoProfile -File assert-suites-for-changed.ps1 -Changed lib-optical.ps1
  pwsh -NoProfile -File assert-suites-for-changed.ps1 -Changed a.ps1,b.py -Run

.EXIT CODES
  0 = nothing to run, or every suite passed   1 = at least one suite failed   2 = bad input
#>
param(
  [Parameter(Mandatory)][string[]]$Changed,
  [string[]]$SearchRoots = @('D:/video', 'D:/video/.claude/skills/disc-to-plex/scripts', 'D:/video/.claude/skills/disc-backup/scripts'),
  [switch]$Run
)
$ErrorActionPreference = 'Stop'

# ---- resolve the changed files, and pull the identifiers they define -----------------------------
$targets = @()
foreach ($c in $Changed) {
  $hit = $null
  if (Test-Path -LiteralPath $c -PathType Leaf) { $hit = (Resolve-Path -LiteralPath $c).Path }
  else {
    foreach ($r in $SearchRoots) {
      $p = Join-Path $r (Split-Path -Leaf $c)
      if (Test-Path -LiteralPath $p -PathType Leaf) { $hit = (Resolve-Path -LiteralPath $p).Path; break }
    }
  }
  if (-not $hit) { Write-Output "cannot find changed file: $c"; exit 2 }
  $targets += $hit
}

$names = @{}
foreach ($t in $targets) {
  $base = [IO.Path]::GetFileNameWithoutExtension($t)
  $names[$base] = $true
  $names[(Split-Path -Leaf $t)] = $true
  $text = Get-Content -LiteralPath $t -Raw -ErrorAction SilentlyContinue
  foreach ($m in [regex]::Matches("$text", '(?im)^\s*function\s+([A-Za-z][\w\-]*)')) { $names[$m.Groups[1].Value] = $true }
  foreach ($m in [regex]::Matches("$text", '(?im)^\s*def\s+([A-Za-z_]\w*)'))          { $names[$m.Groups[1].Value] = $true }
}
# Names too generic to be evidence of coverage - matching on them would list every suite there is.
foreach ($drop in @('Say', 'Log', 'main', 'Run', 'Check', 'Add', 'Fmt', 'Test', 'Get', 'Set')) { $names.Remove($drop) | Out-Null }
$wanted = @($names.Keys | Where-Object { $_.Length -ge 4 })

Write-Output ("changed: {0}" -f (($targets | ForEach-Object { Split-Path -Leaf $_ }) -join ', '))
Write-Output ("identifiers to look for: {0}" -f $wanted.Count)

# ---- which suites mention any of them? -----------------------------------------------------------
$suites = @()
foreach ($r in ($SearchRoots | Sort-Object -Unique)) {
  if (-not (Test-Path -LiteralPath $r -PathType Container)) { continue }
  $suites += @(Get-ChildItem -LiteralPath $r -File -Filter '*.tests.ps1' -ErrorAction SilentlyContinue)
}
$suites = @($suites | Sort-Object FullName -Unique)

$matched = @()
foreach ($s in $suites) {
  $body = Get-Content -LiteralPath $s.FullName -Raw -ErrorAction SilentlyContinue
  $why = @($wanted | Where-Object { "$body" -match ('(?i)' + [regex]::Escape($_)) })
  if ($why.Count) { $matched += [pscustomobject]@{ Suite = $s; Why = @($why | Select-Object -First 3) } }
}

if ($matched.Count -eq 0) {
  Write-Output 'NO test suite references what you changed.'
  Write-Output 'That is a finding, not a clean bill of health: either the change is untested, or the'
  Write-Output 'suite that covers it names things differently. Decide which before calling it done.'
  exit 0
}

Write-Output ("{0} suite(s) exercise this change:" -f $matched.Count)
foreach ($m in $matched) { Write-Output ("   {0,-44} (matched: {1})" -f $m.Suite.Name, ($m.Why -join ', ')) }

if (-not $Run) {
  Write-Output ''
  Write-Output 'Re-run with -Run to execute them. Listing is not verifying.'
  exit 0
}

Write-Output ''
$bad = 0
foreach ($m in $matched) {
  $out = & pwsh -NoProfile -File $m.Suite.FullName 2>&1 | ForEach-Object { "$_" }
  $code = $LASTEXITCODE
  $tail = @($out | Where-Object { $_ -match 'passed|FAILED|failed' } | Select-Object -Last 1)
  if ($code -eq 0) { Write-Output ("   PASS  {0,-44} {1}" -f $m.Suite.Name, ($tail -join '')) }
  else {
    $bad++
    Write-Output ("   FAIL  {0,-44} exit {1}" -f $m.Suite.Name, $code)
    @($out | Where-Object { $_ -match '^\s*FAIL' } | Select-Object -First 5) | ForEach-Object { Write-Output ("           {0}" -f $_.Trim()) }
  }
}
Write-Output ''
if ($bad) { Write-Output ("{0} of {1} suite(s) FAILED - the change is not finished." -f $bad, $matched.Count); exit 1 }
Write-Output ("all {0} suite(s) passed" -f $matched.Count)
exit 0
