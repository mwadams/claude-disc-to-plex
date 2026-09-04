<#
  End-to-end test of the publish loop's CIRCUIT BREAKER, run against THE REAL LOOP SCRIPT - not a
  re-implementation of its logic - on a scratch local root, a scratch "NAS" and a stub publish.

  Run:  pwsh -File publish-loop.tests.ps1            (exit 0 = all passed)
        pwsh -File publish-loop.tests.ps1 -Loop D:/video/_publish-loop.ps1

  WHY THIS SHAPE. The unit tests in lib-publish-state.tests.ps1 prove the breaker's policy; this
  proves the LOOP actually consults it - that a work whose publish never takes effect is invoked
  exactly MaxNoProgress times and then refused, that a change to its files re-arms it once, that
  the lifetime cap then holds for good, and that a work whose publish DOES take effect is published
  normally alongside. Counting the stub's invocations is the measurement: 2,166 attempts on one
  work (Boston Legal, 2026-09-02) is the number this exists to make impossible.

  The loop runs as a separate process with a TEST mutex name (the script refuses that override on
  the production root, and that refusal is asserted here too), a scratch transcript, a scratch
  awaiting-verification register, and a governor config whose hold file does not exist - so a NAS
  hold engaged on the real library never blocks this test.
#>
param(
  [string]$Loop = 'D:/video/_publish-loop.ps1',
  [int]$TimeoutSeconds = 120
)

$fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}
function Q([string]$s) { '"' + $s + '"' }   # Start-Process joins -ArgumentList with spaces and does not quote

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('publoop-tests-' + [guid]::NewGuid().ToString('N'))
$L = Join-Path $tmp 'local'; $N = Join-Path $tmp 'nas'
$calls = Join-Path $tmp 'stub-calls.txt'
$fixList = Join-Path $tmp 'stub-fix.txt'
$outFile = Join-Path $tmp 'loop-stdout.txt'
$errFile = Join-Path $tmp 'loop-stderr.txt'
$proc = $null

function Put([string]$root, [string]$rel, [int]$bytes, [datetime]$when) {
  $p = Join-Path $root $rel
  $d = Split-Path $p -Parent
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  [IO.File]::WriteAllBytes($p, (New-Object byte[] $bytes))
  (Get-Item -LiteralPath $p).LastWriteTimeUtc = $when
}
function CallCount { if (Test-Path -LiteralPath $calls) { @(Get-Content -LiteralPath $calls).Count } else { 0 } }
function CallsFor([string]$work) {
  if (-not (Test-Path -LiteralPath $calls)) { return 0 }
  @(Get-Content -LiteralPath $calls | Where-Object { ($_ -split '\|')[1] -eq $work }).Count
}
function OutText { if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile -Raw } else { '' } }
function WaitFor([string]$what, [scriptblock]$cond, [int]$seconds) {
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt $seconds) {
    if (& $cond) { return $true }
    if ($proc -and $proc.HasExited) { break }
    Start-Sleep -Milliseconds 500
  }
  Write-Output "  (timed out waiting for: $what)"
  return $false
}

$T = [datetime]::new(2026, 9, 4, 12, 0, 0, [System.DateTimeKind]::Utc)

try {
  New-Item -ItemType Directory -Path $L, $N -Force | Out-Null

  # THE STUB PUBLISH. Records every invocation; "fixes" the NAS copy only for works named in
  # stub-fix.txt (simulating a publish that takes effect); otherwise leaves the NAS untouched and
  # reports a mismatch - the shape of every attempt in the Boston Legal band.
  $stub = Join-Path $tmp 'stub-publish.ps1'
  $stubBody = @'
param([string]$Work, [string]$Kind, [switch]$Overwrite, [switch]$SubtitlesOnly, [switch]$SkipSubtitleCheck, [switch]$NoIndex, [switch]$Manual)
$tmp = $PSScriptRoot
Add-Content -LiteralPath (Join-Path $tmp 'stub-calls.txt') -Value ("{0}|{1}|{2}|{3}|{4}" -f (Get-Date -Format o), $Work, $Kind, [bool]$Overwrite, [bool]$SubtitlesOnly)
$fixFile = Join-Path $tmp 'stub-fix.txt'
$fix = @()
if (Test-Path -LiteralPath $fixFile) { $fix = @(Get-Content -LiteralPath $fixFile) }
if ($fix -contains $Work) {
  $src = Join-Path (Join-Path (Join-Path $tmp 'local') $Kind) $Work
  $dst = Join-Path (Join-Path (Join-Path $tmp 'nas') $Kind) $Work
  foreach ($f in Get-ChildItem -LiteralPath $src -Recurse -File) {
    $rel = $f.FullName.Substring($src.Length).TrimStart([char]92)
    $t = Join-Path $dst $rel
    $d = Split-Path $t -Parent
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    Copy-Item -LiteralPath $f.FullName -Destination $t -Force
    (Get-Item -LiteralPath $t).LastWriteTimeUtc = $f.LastWriteTimeUtc
  }
  Write-Output 'verified 1/1'
  exit 0
}
Write-Output 'verified 0/1, 1 MISMATCHED'
exit 1
'@
  Set-Content -LiteralPath $stub -Value $stubBody

  # A governor config whose hold file cannot exist, so a real NAS hold never blocks the test loop.
  $gov = Join-Path $tmp 'gov.json'
  Set-Content -LiteralPath $gov -Value ('{ "holdFile": "' + ((Join-Path $tmp 'no-such-hold') -replace '\\', '/') + '" }')

  Write-Output '0. the mutex override is REFUSED on the production root (exit 1, nothing started)'
  $guard = & pwsh -NoProfile -File $Loop -MutexName 'video-publish-loop-guard-test' 2>&1
  Check 'exit code' $LASTEXITCODE 1
  Check 'says why' (("$guard" -match 'refusing a non-default mutex name')) True

  # THE FIXTURE.
  #   Film (2000)  - local 4096 B, NAS 1024 B: a size mismatch the stub NEVER repairs.
  #   Show         - local only, and the stub DOES publish it: the control that proves a working
  #                  publish is unaffected by another work's trip.
  Put $L 'Movies/Film (2000)/Film (2000).mkv' 4096 $T
  Put $N 'Movies/Film (2000)/Film (2000).mkv' 1024 $T
  Put $L 'Television Shows/Show/Season 01/Show S01E01.mkv' 2048 $T
  Set-Content -LiteralPath $fixList -Value 'Show'

  $env:NAS_GOVERNOR_CONFIG = $gov
  $argList = @('-NoProfile', '-File', (Q $Loop),
    '-LocalRoot', (Q $L), '-NasRoot', (Q $N), '-PublishScript', (Q $stub),
    '-LogDir', (Q (Join-Path $tmp 'logs')), '-Register', (Q (Join-Path $tmp 'awaiting.txt')),
    '-BreakerRegister', (Q (Join-Path $tmp 'breaker.txt')),
    '-MaxNoProgress', '3', '-MaxNoProgressLifetime', '4',
    '-IdleSleepSeconds', '1', '-MinPassSeconds', '0', '-MaxPasses', '40',
    '-NoDownstream', '-MutexName', 'video-publish-loop-test')
  $proc = Start-Process pwsh -ArgumentList $argList -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile

  Write-Output '1. TRIPS after exactly MaxNoProgress (3) attempts on the work that never settles'
  $tripped = WaitFor 'trip' { (OutText) -match 'CIRCUIT BREAKER TRIPPED' } $TimeoutSeconds
  Check 'trip reported'   $tripped True
  Start-Sleep -Seconds 4          # several more passes go by - they must all be refused
  Check 'Film attempts'   (CallsFor 'Film (2000)') 3
  Check 'refusal logged'  (((OutText) -match 'BREAKER OPEN \(tripped\)')) True
  $reg = @(Get-Content -LiteralPath (Join-Path $tmp 'breaker.txt') | Where-Object { $_ -notmatch '^#' })
  Check 'register row'    (($reg -join ';') -match '\|Film \(2000\)\|tripped') True

  Write-Output '2. CONTROL: the other work published normally alongside, exactly once'
  Check 'Show attempts'   (CallsFor 'Show') 1
  $await = if (Test-Path -LiteralPath (Join-Path $tmp 'awaiting.txt')) { Get-Content -LiteralPath (Join-Path $tmp 'awaiting.txt') -Raw } else { '' }
  Check 'Show registered' (($await -match '\|Show\s*$')) True
  Check 'NAS has Show'    (Test-Path -LiteralPath (Join-Path $N 'Television Shows/Show/Season 01/Show S01E01.mkv')) True

  Write-Output '3. RE-ARMS once when the outstanding set changes (a new local file appears)'
  Put $L 'Movies/Film (2000)/Extra.mkv' 512 $T
  $rearmed = WaitFor 're-arm attempt' { (CallsFor 'Film (2000)') -ge 4 } $TimeoutSeconds
  Check 'one more attempt' $rearmed True
  Check 'said so'          (((OutText) -match 'breaker RE-ARMED')) True

  Write-Output '4. HARD-TRIPS at the lifetime cap (4) and ignores further changes'
  $hard = WaitFor 'hard trip' { (OutText) -match 'CIRCUIT BREAKER HARD-TRIPPED' } $TimeoutSeconds
  Check 'hard trip reported' $hard True
  Put $L 'Movies/Film (2000)/Extra2.mkv' 256 $T
  Start-Sleep -Seconds 5
  Check 'still 4 attempts'  (CallsFor 'Film (2000)') 4
  $reg = @(Get-Content -LiteralPath (Join-Path $tmp 'breaker.txt') | Where-Object { $_ -notmatch '^#' })
  Check 'register HARD'     (($reg -join ';') -match '\|Film \(2000\)\|HARD-TRIPPED') True
  Check 'no "republishing" line for a refused work after the trip' `
        (@(((OutText) -split "`n") | Where-Object { $_ -match 'Film \(2000\).*republishing' }).Count -le 4) True

  Write-Output '5. the loop ends at MaxPasses on its own (it was never killed)'
  $ended = WaitFor 'exit' { $proc.HasExited } $TimeoutSeconds
  Check 'exited'          $ended True
  if ($ended) { Check 'exit 0' $proc.ExitCode 0 }
  $errText = if (Test-Path -LiteralPath $errFile) { Get-Content -LiteralPath $errFile -Raw } else { '' }
  Check 'no stderr'       ([string]::IsNullOrWhiteSpace($errText)) True
  Check 'total attempts'  (CallCount) 5

  $script:reachedEnd = $true
}
catch {
  Write-Output "  FAIL exception: $($_.Exception.Message)"
  $script:fails++
}
finally {
  if ($proc -and -not $proc.HasExited) {
    Write-Output '  (test loop still running at the end - stopping the TEST process; it is not a pipeline track)'
    try { Stop-Process -Id $proc.Id -Force } catch { }
    $script:fails++
  }
  Remove-Item Env:NAS_GOVERNOR_CONFIG -ErrorAction SilentlyContinue
  if ($fails -and (Test-Path -LiteralPath $outFile)) {
    Write-Output '--- loop stdout (kept for diagnosis) ---'
    Get-Content -LiteralPath $outFile | ForEach-Object { "    $_" }
  }
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if (-not $reachedEnd) { Write-Output 'the suite did not reach its end - treating as FAILED'; $fails++ }
if ($fails) { Write-Output "$fails test(s) FAILED"; exit 1 }
Write-Output 'all tests passed'
exit 0
