<#
  Tests for Get-WorkOutstanding - the definition of "published" for a multi-file work.
  Run: pwsh -File lib-publish-state.tests.ps1   (exit 0 = all passed)

  THE CASE THAT ACTUALLY BIT is test 3: one small file correctly on the NAS while the big one is
  still encoding. publish-work.ps1 reported `verified 1/1` for that and _publish-loop.ps1 called the
  WORK published (Fight Club, 2026-09-04). A ratio over an already-narrowed list cannot fall below
  1.0, so the only test that can catch it is one that measures the work against the NAS itself.

  The NEGATIVES matter as much as the positives: anything this function reports as outstanding
  makes the loop re-invoke a publish and (now) withhold the "IS PUBLISHED" claim, so a false
  positive on quarantine litter or on subtitles-only scaffolding would put the loop straight back
  into the hot loops those exclusions were added to stop.
#>
. "$PSScriptRoot/lib-publish-state.ps1"
if (-not (Get-Command Get-WorkOutstanding -ErrorAction SilentlyContinue)) {
  Write-Output 'FAIL: lib-publish-state.ps1 did not load'   # a dot-source failure is NON-terminating
  exit 1
}

$fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('pubstate-tests-' + [guid]::NewGuid().ToString('N'))
$L = Join-Path $tmp 'local'; $N = Join-Path $tmp 'nas'
function Put([string]$root, [string]$rel, [int]$bytes, [datetime]$when) {
  $p = Join-Path $root $rel
  $d = Split-Path $p -Parent
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
  [IO.File]::WriteAllBytes($p, (New-Object byte[] $bytes))
  (Get-Item -LiteralPath $p).LastWriteTimeUtc = $when
}
function Out2([string]$prop) {
  $o = Get-WorkOutstanding -WorkDir $L -NasDir $N
  (@($o) | ForEach-Object { $_.$prop } | Sort-Object) -join ','
}
$T = [datetime]::new(2026, 9, 4, 0, 31, 38, [System.DateTimeKind]::Utc)

try {
  New-Item -ItemType Directory -Path $L -Force | Out-Null
  New-Item -ItemType Directory -Path $N -Force | Out-Null

  Write-Output '1. a work whose every file matches on the NAS is PUBLISHED (empty result)'
  Put $L 'Film.mkv' 2048 $T ; Put $N 'Film.mkv' 2048 $T
  Put $L 'Film.eng.srt' 64 $T ; Put $N 'Film.eng.srt' 64 $T
  Check 'count' @(Get-WorkOutstanding -WorkDir $L -NasDir $N).Count 0

  Write-Output '2. THE CALL FORM THE LOOP USES: @(...) must count files, at 0, 1 and N'
  #    The first version of this function returned `,$outstanding`, copying Get-UnitStageTargets.
  #    That convention emits the array as ONE object, so `@(Get-WorkOutstanding ...).Count` was 1 for
  #    every non-empty result however many files were outstanding - and the loop computes
  #    $landed = $before.Count - $after.Count from exactly that form, so every multi-file publish
  #    would have mis-counted while the unit tests (which called it bare) passed. Both forms are
  #    asserted here, and they must agree.
  Check 'wrapped 0' @(Get-WorkOutstanding -WorkDir $L -NasDir $N).Count 0
  Check 'bare 0'     (Get-WorkOutstanding -WorkDir $L -NasDir $N).Count 0
  Put $L 'One.mkv' 10 $T ; Put $L 'Two.mkv' 20 $T ; Put $L 'Three.mkv' 30 $T
  Check 'wrapped 3' @(Get-WorkOutstanding -WorkDir $L -NasDir $N).Count 3
  Check 'bare 3'     (Get-WorkOutstanding -WorkDir $L -NasDir $N).Count 3
  Remove-Item -LiteralPath (Join-Path $L 'Two.mkv') -Force
  Remove-Item -LiteralPath (Join-Path $L 'Three.mkv') -Force
  Check 'wrapped 1' @(Get-WorkOutstanding -WorkDir $L -NasDir $N).Count 1
  Check 'bare 1'     (Get-WorkOutstanding -WorkDir $L -NasDir $N).Count 1
  Remove-Item -LiteralPath (Join-Path $L 'One.mkv') -Force

  Write-Output '3. THE FIGHT CLUB CASE: extra published, feature still the old NAS copy'
  #    Local feature 2.86 GB / NAS 1.38 GB from July. publish-work.ps1 skips the partial feature and
  #    reports `verified 1/1` for the extra alone - the work is NOT published.
  Put $L 'Other/Warning.mkv' 512 $T ; Put $N 'Other/Warning.mkv' 512 $T
  Put $L 'Feature.mkv' 4096 $T
  Put $N 'Feature.mkv' 1024 ([datetime]::new(2026, 7, 23, 11, 19, 33, [System.DateTimeKind]::Utc))
  Check 'names'  (Out2 'Name')   'Feature.mkv'
  Check 'reason' (Out2 'Reason') 'size'

  Write-Output '4. a file absent from the NAS reports "missing", and the subfolder path is kept'
  Put $L 'Other/Gallery.mkv' 128 $T
  Check 'names' (Out2 'Name') ('Feature.mkv,Other' + [char]92 + 'Gallery.mkv')
  Remove-Item -LiteralPath (Join-Path $L 'Other/Gallery.mkv') -Force
  Remove-Item -LiteralPath (Join-Path $L 'Feature.mkv') -Force
  Remove-Item -LiteralPath (Join-Path $N 'Feature.mkv') -Force
  Check 'back to published' @(Get-WorkOutstanding -WorkDir $L -NasDir $N).Count 0

  Write-Output '5. SAME SIZE, DIFFERENT MTIME is outstanding (the DAR 4:3 -> 16:9 re-encode)'
  #    Michael J. Fox Interview re-encoded to the same byte length; size alone would have left the
  #    stretched copy on the NAS forever.
  (Get-Item -LiteralPath (Join-Path $L 'Film.mkv')).LastWriteTimeUtc = $T.AddMinutes(30)
  Check 'reason' (Out2 'Reason') 'timestamp'
  (Get-Item -LiteralPath (Join-Path $L 'Film.mkv')).LastWriteTimeUtc = $T

  Write-Output '6. NEGATIVE: 2 s of SMB timestamp granularity is tolerated'
  (Get-Item -LiteralPath (Join-Path $L 'Film.mkv')).LastWriteTimeUtc = $T.AddSeconds(1.5)
  Check 'count' @(Get-WorkOutstanding -WorkDir $L -NasDir $N).Count 0
  (Get-Item -LiteralPath (Join-Path $L 'Film.mkv')).LastWriteTimeUtc = $T

  Write-Output '7. NEGATIVE: quarantine litter is never outstanding (it is never published)'
  #    `X.mkv.wrong-length` has final extension .wrong-length. Counting it would make the loop
  #    re-invoke a publish on EVERY pass forever - the hot loop lib-artefact-types.ps1 exists to stop.
  Put $L 'Film.mkv.wrong-length' 999 $T
  Put $L 'Film.mkv.pre-retime-short' 999 $T
  Check 'count' @(Get-WorkOutstanding -WorkDir $L -NasDir $N).Count 0

  Write-Output '8. NEGATIVE: in a .subtitles-only work the .mkv is scaffolding, only .srt counts'
  #    The NAS holds the legacy encode under the SAME NAME with DIFFERENT BYTES, permanently and by
  #    design. Comparing it can only ever answer "stale" - 78 re-publish lines in 200 (Boston Legal).
  Set-Content -LiteralPath (Join-Path $L '.subtitles-only') -Value ''
  Put $N 'Film.mkv' 111 ([datetime]::new(2020, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc))
  Check 'scaffolding ignored' @(Get-WorkOutstanding -WorkDir $L -NasDir $N).Count 0

  Write-Output '9. POSITIVE inside a subtitles-only work: a MISSING sidecar is still outstanding'
  Put $L 'Episode2.eng.srt' 32 $T
  Check 'names' (Out2 'Name') 'Episode2.eng.srt'
  Check 'reason' (Out2 'Reason') 'missing'
  Remove-Item -LiteralPath (Join-Path $L '.subtitles-only') -Force

  Write-Output '10. NEGATIVE: a work with no NAS folder at all is outstanding, never "published"'
  #    All four artefacts (Film.mkv, Film.eng.srt, Other\Warning.mkv, Episode2.eng.srt) - and only
  #    those: the two quarantine files from test 7 are still on disk and must stay excluded.
  $missingNas = Join-Path $tmp 'nas-that-does-not-exist'
  Check 'count' @(Get-WorkOutstanding -WorkDir $L -NasDir $missingNas).Count 4

  Write-Output '11. NEGATIVE: a local folder that does not exist yields EMPTY, and does not throw'
  Check 'count' @(Get-WorkOutstanding -WorkDir (Join-Path $tmp 'no-such-work') -NasDir $N).Count 0

  # ---- the circuit breaker (pure; see the header block in lib-publish-state.ps1) ----
  function O([string]$n, [string]$r, [long]$l, $nl) {
    [pscustomobject]@{ Name = $n; Reason = $r; LocalLength = $l; NasLength = $nl } }

  Write-Output '12. fingerprint: empty set is "", order does not matter, any field difference does'
  Check 'empty'        (Get-OutstandingFingerprint @()) ''
  Check 'null'         (Get-OutstandingFingerprint $null) ''
  $fpA = Get-OutstandingFingerprint @((O 'A.mkv' 'size' 10 5), (O 'B.srt' 'missing' 3 $null))
  $fpB = Get-OutstandingFingerprint @((O 'B.srt' 'missing' 3 $null), (O 'A.mkv' 'size' 10 5))
  Check 'order-free'   ($fpA -eq $fpB) True
  $fpC = Get-OutstandingFingerprint @((O 'A.mkv' 'size' 10 6), (O 'B.srt' 'missing' 3 $null))
  Check 'nas size'     ($fpA -eq $fpC) False
  $fpD = Get-OutstandingFingerprint @((O 'A.mkv' 'timestamp' 10 10))
  $fpE = Get-OutstandingFingerprint @((O 'A.mkv' 'size' 10 10))
  Check 'reason'       ($fpD -eq $fpE) False
  Check 'single'       @(Get-OutstandingFingerprint @((O 'A.mkv' 'size' 10 5))).Count 1

  Write-Output '13. TRIPS after MaxNoProgress fruitless attempts, and REFUSES from then on'
  #    The Boston Legal shape: every attempt leaves the outstanding set exactly as it found it.
  $b = New-PublishBreaker -MaxNoProgress 3 -MaxNoProgressLifetime 10
  $fp = Get-OutstandingFingerprint @((O 'Ep.mkv' 'size' 100 50))
  $allowed = 0; $results = @()
  for ($i = 1; $i -le 8; $i++) {
    $v = Get-PublishBreakerVerdict -Breaker $b -Work 'Boston Legal' -Fingerprint $fp
    if ($v.Allow) { $allowed++; $results += (Register-PublishBreakerAttempt -Breaker $b -Work 'Boston Legal' -Before $fp -After $fp) }
  }
  Check 'attempts allowed' $allowed 3
  Check 'results'          ($results -join ',') 'ok,ok,tripped'
  $v = Get-PublishBreakerVerdict -Breaker $b -Work 'Boston Legal' -Fingerprint $fp
  Check 'state'            $v.State 'tripped'
  Check 'skipped count'    $v.Skipped 6

  Write-Output '14. NEGATIVE: a work that makes progress every pass NEVER trips (a growing TV show)'
  $b2 = New-PublishBreaker -MaxNoProgress 3 -MaxNoProgressLifetime 10
  $allowed = 0
  for ($i = 1; $i -le 50; $i++) {
    $before = Get-OutstandingFingerprint @((O "Ep$i.mkv" 'missing' 100 $null))
    $after  = ''
    $v = Get-PublishBreakerVerdict -Breaker $b2 -Work 'The Saint (1962)' -Fingerprint $before
    if ($v.Allow) { $allowed++; [void](Register-PublishBreakerAttempt -Breaker $b2 -Work 'The Saint (1962)' -Before $before -After $after) }
  }
  Check 'all 50 allowed' $allowed 50
  Check 'not tripped'    (Get-PublishBreakerWork $b2 'The Saint (1962)').Tripped False
  #    ... and an occasional fruitless attempt in between does not accumulate into a trip
  $b3 = New-PublishBreaker -MaxNoProgress 3 -MaxNoProgressLifetime 100
  $fpX = Get-OutstandingFingerprint @((O 'X.mkv' 'size' 1 2))
  foreach ($i in 1..12) {
    [void](Get-PublishBreakerVerdict -Breaker $b3 -Work 'W' -Fingerprint $fpX)
    if ($i % 3 -eq 0) { [void](Register-PublishBreakerAttempt -Breaker $b3 -Work 'W' -Before $fpX -After '') }   # progress
    else              { [void](Register-PublishBreakerAttempt -Breaker $b3 -Work 'W' -Before $fpX -After $fpX) } # none
  }
  Check 'interleaved never trips' (Get-PublishBreakerWork $b3 'W').Tripped False

  Write-Output '15. RE-ARMS when the outstanding set changes (the Hustle case: OCR sidecars arriving)'
  $fp2 = Get-OutstandingFingerprint @((O 'Ep.mkv' 'size' 100 50), (O 'Ep.eng.srt' 'missing' 7 $null))
  $v = Get-PublishBreakerVerdict -Breaker $b -Work 'Boston Legal' -Fingerprint $fp2
  Check 'rearmed'        $v.State 'rearmed'
  Check 'allowed again'  $v.Allow True
  Check 'no-progress run reset' (Get-PublishBreakerWork $b 'Boston Legal').NoProgress 0
  #    a fruitless attempt after re-arming counts from zero again ...
  Check 'after rearm' (Register-PublishBreakerAttempt -Breaker $b -Work 'Boston Legal' -Before $fp2 -After $fp2) 'ok'
  #    ... but the LIFETIME count carried over (3 + 1 = 4 of 10)
  Check 'lifetime carried' (Get-PublishBreakerWork $b 'Boston Legal').NoProgressLifetime 4

  Write-Output '16. HARD TRIP at MaxNoProgressLifetime: no re-arm, however much the set changes'
  $b4 = New-PublishBreaker -MaxNoProgress 2 -MaxNoProgressLifetime 5
  $n = 0; $last = ''
  for ($i = 1; $i -le 40; $i++) {
    # the set changes every pass (a churning fingerprint) so the soft breaker keeps re-arming,
    # yet every attempt itself changes nothing
    $fpI = Get-OutstandingFingerprint @((O 'Ep.mkv' 'size' 100 (50 + $i)))
    $v = Get-PublishBreakerVerdict -Breaker $b4 -Work 'Churn' -Fingerprint $fpI
    if ($v.Allow) { $n++; $last = Register-PublishBreakerAttempt -Breaker $b4 -Work 'Churn' -Before $fpI -After $fpI }
  }
  Check 'attempts capped for life' $n 5
  Check 'last verdict'             $last 'hard-tripped'
  $v = Get-PublishBreakerVerdict -Breaker $b4 -Work 'Churn' -Fingerprint 'something entirely new'
  Check 'still refused'            $v.State 'hard-tripped'
  Check 'not allowed'              $v.Allow False

  Write-Output '17. works are independent: one tripped work does not touch another'
  $v = Get-PublishBreakerVerdict -Breaker $b4 -Work 'Other' -Fingerprint 'x'
  Check 'other armed' $v.State 'armed'

  Write-Output '18. the register lists tripped works only, and is rewritten whole'
  $regPath = Join-Path $tmp 'breaker.txt'
  Write-PublishBreakerRegister -Breaker $b4 -Path $regPath
  $reg = @(Get-Content -LiteralPath $regPath | Where-Object { $_ -notmatch '^#' })
  Check 'one row'      $reg.Count 1
  Check 'names Churn'  ($reg[0] -match '\|Churn\|HARD-TRIPPED') True
  Write-PublishBreakerRegister -Breaker $b3 -Path $regPath
  Check 'rewritten empty' @(Get-Content -LiteralPath $regPath | Where-Object { $_ -notmatch '^#' }).Count 0

  Write-Output '19. NEGATIVE: a lifetime cap below the run cap is refused at construction'
  $threw = $false
  try { [void](New-PublishBreaker -MaxNoProgress 5 -MaxNoProgressLifetime 3) } catch { $threw = $true }
  Check 'throws' $threw True

  $script:reachedEnd = $true
}
catch {
  # A THROW MUST FAIL THE RUN, NOT SILENTLY TRUNCATE IT (see lib-disk.tests.ps1).
  Write-Output "  FAIL exception in the Get-WorkOutstanding tests: $($_.Exception.Message)"
  $script:fails++
}
finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if (-not $reachedEnd) { Write-Output 'the suite did not reach its end - treating as FAILED'; $fails++ }
if ($fails) { Write-Output "$fails test(s) FAILED"; exit 1 }
Write-Output 'all tests passed'
exit 0
