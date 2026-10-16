<#
  Tests for assert-dvd-title-numbering.ps1 - the off-by-one guard - and its evidence-pack durations.
  Run: pwsh -File assert-dvd-title-numbering.tests.ps1     (exit 0 = all passed)

  2026-10-16, Big Train Series 2: MakeMKV's catalogue figures ran ~10 s short of what each dvdvideo
  title's IFO declares and the demuxer emits, and with six episodes within 40 s of each other the
  offset landed rows on neighbours' figures - refused twice as a "shift" on a correct manifest. The
  guard now also accepts each title's own figures from the evidence pack. These pin both directions:
  the real Big Train data passes WITH its evidence pack (and was refused without it), and the shift
  the guard exists for (Tales of the Unexpected: rows asking for a 23 s leader title) still refuses.
#>
$ErrorActionPreference = 'Stop'
$guard = Join-Path $PSScriptRoot 'assert-dvd-title-numbering.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('adtn-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Write-Host "  PASS  $name" } else { $script:fail++; Write-Host "  FAIL  $name`n        $detail" }
}
function Run([string]$manifest, [string]$cat) {
  $o = @(& pwsh -NoProfile -File $guard -Manifest $manifest -Catalogue $cat 2>&1 | ForEach-Object { "$_" })
  return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($o -join "`n") }
}
function Hms([int]$s) { '{0}:{1:00}:{2:00}' -f [int][math]::Floor($s / 3600), [int][math]::Floor(($s % 3600) / 60), ($s % 60) }
try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null

  Write-Host '1. REAL: Big Train Series 2 (catalogue + evidence pack + manifest as the line had them)'
  $realCat = 'D:/video/_catalogue'
  $realMan = 'D:/video/_pending/big-train-series-2.json'
  if (-not (Test-Path -LiteralPath $realMan)) { $realMan = @(Get-ChildItem 'D:/video/_queue', 'D:/video/_queue/done' -Filter 'big-train-series-2*.json' -File -ErrorAction SilentlyContinue | Select-Object -First 1).FullName }
  if ($realMan -and (Test-Path -LiteralPath (Join-Path $realCat 'Big Train Series 2.evidence.json'))) {
    $withEv = Join-Path $root 'with'; $noEv = Join-Path $root 'without'
    New-Item -ItemType Directory -Force -Path $withEv, $noEv | Out-Null
    Copy-Item -LiteralPath (Join-Path $realCat 'Big Train Series 2.catalogue.json') -Destination $withEv
    Copy-Item -LiteralPath (Join-Path $realCat 'Big Train Series 2.evidence.json') -Destination $withEv
    Copy-Item -LiteralPath (Join-Path $realCat 'Big Train Series 2.catalogue.json') -Destination $noEv
    $r = Run $realMan $withEv
    Check 'with the evidence pack: OK' ($r.Code -eq 0 -and $r.Text -match 'OK - all') $r.Text
    $r = Run $realMan $noEv
    Check 'without it (the old behaviour): REFUSED - the false shift this fixes' ($r.Code -ne 0 -and $r.Text -match 'REFUSED') $r.Text
  } else { Write-Host '  (skipped: Big Train Series 2 fixtures no longer present)' }

  Write-Host '2. known-negative: the Tales of the Unexpected shift still refuses WITH an evidence pack'
  $cat = Join-Path $root 'tales'; New-Item -ItemType Directory -Force -Path $cat | Out-Null
  $src = 'D:/video/_stage/Tales Disk 1'
  $durs = @(23, 1402, 1388, 1415, 1396)          # dv1 is a 23-second leader
  $titles = @(); $evTitles = @()
  for ($i = 0; $i -lt $durs.Count; $i++) {
    $titles += @{ title = $i; dvdvideoTitle = $i + 1; duration = (Hms $durs[$i]) }
    $evTitles += @{ dvdvideoTitle = $i + 1; declaredSec = $durs[$i]; emittedSec = $durs[$i] }
  }
  @{ disc = 'Tales Disk 1'; titles = $titles } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $cat 'Tales Disk 1.catalogue.json')
  @{ titles = $evTitles } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $cat 'Tales Disk 1.evidence.json')
  # Numbered 1..N from the CHOSEN titles: each row asks for the title BEFORE the one it describes.
  $rows = @(); for ($e = 1; $e -le 4; $e++) { $rows += @{ kind = 'DVD'; src = $src; title = $e; expectSeconds = $durs[$e]; out = "x/S01E0$e.mkv" } }
  $man = Join-Path $root 'tales.json'; ConvertTo-Json -InputObject $rows -Depth 4 | Set-Content -LiteralPath $man
  $r = Run $man $cat
  Check 'REFUSED as a shift' ($r.Code -ne 0 -and $r.Text -match 'REFUSED' -and $r.Text -match 'shift') $r.Text
  $rows = @(); for ($e = 1; $e -le 4; $e++) { $rows += @{ kind = 'DVD'; src = $src; title = $e + 1; expectSeconds = $durs[$e]; out = "x/S01E0$e.mkv" } }
  ConvertTo-Json -InputObject $rows -Depth 4 | Set-Content -LiteralPath $man
  $r = Run $man $cat
  Check 'and the corrected numbering passes' ($r.Code -eq 0) $r.Text
}
catch { Write-Host "  FAIL exception: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"; $fail++ }
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ("{0} passed, {1} failed" -f $pass, $fail)
if ($fail) { exit 1 }
Write-Host 'all tests passed'
exit 0
