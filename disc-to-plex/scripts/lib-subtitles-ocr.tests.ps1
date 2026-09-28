<#
  Tests for the OCR-outcome half of lib-subtitles.ps1: Invoke-OcrDirectRenderFallback,
  Register-OcrUnexplainedFailure and Resolve-OcrOutcome.
  Run: pwsh -File lib-subtitles-ocr.tests.ps1   (exit 0 = all passed)

  WHY THESE EXIST. 2026-09-27/28: the OCR track re-OCR'd Doctor Who S00E349 49 times, each pass
  printing the identical "only 94.7% of lowercase words are in the English dictionary (865 words)"
  refusal, while publish held all 55 finished Season 00 files behind it for ~10 hours. The
  classifier was right (quality-near-miss -> blocked) and the verdict was never written, because
  Invoke-OcrDirectRenderFallback emitted its progress with Write-Output: called inside `if (...)`
  without -Say, its `$false` arrived as a non-empty array, the `if` read TRUE, and the loop took
  "recovered - the sidecar exists" for a file with no sidecar. Section 1 is that bug.

  Fixtures are scratch files in a temp directory; the verdict cache is redirected there with
  -CacheDir, so nothing touches the real cache under %LOCALAPPDATA%.
#>
. "$PSScriptRoot/lib-subtitles.ps1"
if (-not (Get-Command Invoke-OcrDirectRenderFallback -ErrorAction SilentlyContinue) -or
    -not (Get-Command Register-OcrUnexplainedFailure -ErrorAction SilentlyContinue)) {
  Write-Output 'FAIL: lib-subtitles.ps1 did not load'   # a dot-source failure is NON-terminating
  exit 1
}

$fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}

$root  = Join-Path ([IO.Path]::GetTempPath()) ("lib-subtitles-ocr-tests-" + [guid]::NewGuid().ToString('N'))
$cache = Join-Path $root 'subcache'
New-Item -ItemType Directory -Path $root, $cache -Force | Out-Null
$reachedEnd = $false
try {
  $media   = Join-Path $root 'Show - S00E349 - Part Four.mkv'
  Set-Content -LiteralPath $media -Value 'not really a matroska file' -Encoding ASCII
  $sidecar = [IO.Path]::ChangeExtension($media, $null) + 'eng.srt'

  # Fake direct renderers: one prints progress and gives up, one writes the sidecar.
  $paddleFails = Join-Path $root 'paddle-fails.ps1'
  Set-Content -LiteralPath $paddleFails -Encoding UTF8 -Value @'
param([string]$Path)
'rendering 256 cues ...'
'[pgssub] Bitmap dimensions (1920x1080) invalid.'
'no sidecar written'
'@
  $paddleWorks = Join-Path $root 'paddle-works.ps1'
  Set-Content -LiteralPath $paddleWorks -Encoding UTF8 -Value @'
param([string]$Path)
'rendering 256 cues ...'
Set-Content -LiteralPath ([IO.Path]::ChangeExtension($Path, $null) + 'eng.srt') -Value "1`r`n00:00:01,000 --> 00:00:02,000`r`nHello.`r`n"
'@
  $nearMiss = { [pscustomobject]@{ Status = 'quality-near-miss'; Verdict = 'blocked'; BlockReason = 'dictionary gate rejected'; Lines = @() } }

  Write-Output '1. THE S00E349 BUG: the fallback returns exactly one [bool] on the output stream'
  $o = & $nearMiss
  $out = @(Invoke-OcrDirectRenderFallback -Path $media -Sidecar $sidecar -Outcome $o -PaddleScript $paddleFails 6>$null)
  Check 'failing fallback, no -Say: one object on the output stream' $out.Count 1
  Check 'and it is a [bool]'                                         ($out[0] -is [bool]) 'True'
  Check 'and it is $false'                                           $out[0] 'False'
  $took = if (Invoke-OcrDirectRenderFallback -Path $media -Sidecar $sidecar -Outcome (& $nearMiss) -PaddleScript $paddleFails 6>$null) { 'recovered' } else { 'not recovered' }
  Check 'inside `if (...)` (how _ocr-loop.ps1 called it) it reads FALSE' $took 'not recovered'
  Check 'the block reason records that both attempts failed'          ($o.BlockReason -match 'direct-render fallback .* also failed') 'True'
  Check 'no sidecar was invented'                                     (Test-Path -LiteralPath $sidecar) 'False'

  $out = @(Invoke-OcrDirectRenderFallback -Path $media -Sidecar $sidecar -Outcome (& $nearMiss) -PaddleScript (Join-Path $root 'absent.ps1') 6>$null)
  Check 'renderer absent, no -Say: still exactly one $false' ("$($out.Count)/$($out[0])") '1/False'

  Write-Output '2. -Say receives the progress; the return value stays a bare [bool]'
  $said = [System.Collections.Generic.List[string]]::new()
  $out = @(Invoke-OcrDirectRenderFallback -Path $media -Sidecar $sidecar -Outcome (& $nearMiss) -PaddleScript $paddleFails -Say { param($m) $said.Add($m); "a -Say that returns a value $m" })
  Check 'one object even when -Say itself emits' $out.Count 1
  Check 'and it is $false'                       $out[0] 'False'
  Check 'the progress lines reached -Say'        (@($said | Where-Object { $_ -match 'retrying ONCE|no sidecar written' }).Count -ge 2) 'True'

  Write-Output '3. a renderer that writes the sidecar returns exactly $true'
  $out = @(Invoke-OcrDirectRenderFallback -Path $media -Sidecar $sidecar -Outcome (& $nearMiss) -PaddleScript $paddleWorks 6>$null)
  Check 'one object'        $out.Count 1
  Check 'and it is $true'   ("$($out[0] -is [bool])/$($out[0])") 'True/True'
  Remove-Item -LiteralPath $sidecar -Force

  Write-Output '4. any other outcome is not the fallback''s business'
  $o = [pscustomobject]@{ Status = 'wrong-language'; Verdict = 'blocked'; BlockReason = 'x'; Lines = @() }
  $out = @(Invoke-OcrDirectRenderFallback -Path $media -Sidecar $sidecar -Outcome $o -PaddleScript $paddleWorks 6>$null)
  Check 'wrong-language -> $false, renderer not run' ("$($out.Count)/$($out[0])/$(Test-Path -LiteralPath $sidecar)") '1/False/False'
  Check 'and its block reason is untouched'           $o.BlockReason 'x'

  Write-Output '5. the S00E349 refusal classifies as a quality near-miss (blocked, not retry)'
  $s349 = "WARNING:   FAILED Show - S00E349 - Part Four.mkv: only 94.7% of lowercase words are in the English dictionary (865 words) - letters are being split (good conversions score 97-99%)`nocr: 0 converted, 0 skipped, 1 failed"
  $r = Resolve-OcrOutcome -OutputText $s349 -SourceExists $true
  Check 'status'  $r.Status  'quality-near-miss'
  Check 'verdict' $r.Verdict 'blocked'

  Write-Output '6. Register-OcrUnexplainedFailure: IDENTICAL failures, bounded at 3'
  $verdictFile = Get-BitmapSubsCachePath -Path $media -CacheDir $cache
  Check 'a failure with NO stated reason is not counted' (Register-OcrUnexplainedFailure -Path $media -OutputText 'ocr: 0 converted' -CacheDir $cache) 'False'
  Check 'and leaves no counter behind'                   (Test-Path -LiteralPath "$verdictFile.tries") 'False'
  $got = @(1..3 | ForEach-Object { Register-OcrUnexplainedFailure -Path $media -OutputText $s349 -CacheDir $cache })
  Check 'same refusal x3 -> false, false, true'          ($got -join ',') 'False,False,True'
  $v = "$(Get-Content -LiteralPath $verdictFile -Raw)".Trim()
  Check 'a blocked verdict is recorded'                  ($v -like 'blocked:*') 'True'
  Check "carrying the gate's own words"                  ($v -match '94\.7% of lowercase words') 'True'
  Check 'and saying it was deterministic'                ($v -match 'same OCR failure 3 times in a row') 'True'
  Check 'under the content key too (what the NAS gate reads)' (Test-Path -LiteralPath (Get-BitmapSubsCachePath -Path $media -CacheDir $cache -ContentKey)) 'True'

  Write-Output '7. a DIFFERENT refusal restarts the count - two problems, neither yet proven deterministic'
  $media2 = Join-Path $root 'Show - S00E350.mkv'
  Set-Content -LiteralPath $media2 -Value 'x' -Encoding ASCII
  $a = "  FAILED Show - S00E350.mkv: only 90.1% of lowercase words are in the English dictionary"
  $b = "  FAILED Show - S00E350.mkv: only 0% of dialogue lines contain a common English word - output is not English text"
  $got = @(
    (Register-OcrUnexplainedFailure -Path $media2 -OutputText $a -CacheDir $cache),
    (Register-OcrUnexplainedFailure -Path $media2 -OutputText $a -CacheDir $cache),
    (Register-OcrUnexplainedFailure -Path $media2 -OutputText $b -CacheDir $cache),
    (Register-OcrUnexplainedFailure -Path $media2 -OutputText $b -CacheDir $cache))
  Check 'A, A, B, B -> never blocks'                  ($got -join ',') 'False,False,False,False'
  Check 'the third B blocks'                          (Register-OcrUnexplainedFailure -Path $media2 -OutputText $b -CacheDir $cache) 'True'

  Write-Output '8. a pre-2026-09-28 bare-integer counter is continued, not reset'
  $media3 = Join-Path $root 'Show - S00E351.mkv'
  Set-Content -LiteralPath $media3 -Value 'x' -Encoding ASCII
  Set-Content -LiteralPath ((Get-BitmapSubsCachePath -Path $media3 -CacheDir $cache) + '.tries') -Value '2'
  Check 'legacy "2" + one more failure -> blocks at 3' (Register-OcrUnexplainedFailure -Path $media3 -OutputText $a -CacheDir $cache) 'True'

  Write-Output '9. rewritten bytes earn fresh attempts (the key is leaf|length|mtime)'
  $media4 = Join-Path $root 'Show - S00E352.mkv'
  Set-Content -LiteralPath $media4 -Value 'x' -Encoding ASCII
  [void](Register-OcrUnexplainedFailure -Path $media4 -OutputText $a -CacheDir $cache)
  [void](Register-OcrUnexplainedFailure -Path $media4 -OutputText $a -CacheDir $cache)
  Set-Content -LiteralPath $media4 -Value 'a re-encode, longer' -Encoding ASCII
  (Get-Item -LiteralPath $media4).LastWriteTimeUtc = (Get-Date).ToUniversalTime().AddMinutes(5)
  Check 'third failure AFTER the rewrite does not block' (Register-OcrUnexplainedFailure -Path $media4 -OutputText $a -CacheDir $cache) 'False'

  Write-Output '10. a vanished file is not counted'
  Check 'missing path -> false' (Register-OcrUnexplainedFailure -Path (Join-Path $root 'gone.mkv') -OutputText $a -CacheDir $cache) 'False'

  Write-Output '11. _ocr-loop.ps1 decides "recovered" from the SIDECAR, never from the call in an if'
  $loop = Get-Content -LiteralPath 'D:/video/_ocr-loop.ps1' -Raw
  Check 'no `if (Invoke-OcrDirectRenderFallback` in the loop'    ($loop -match 'if\s*\(\s*Invoke-OcrDirectRenderFallback') 'False'
  Check 'the loop bounds by post-condition (Test-BitmapSubsAttemptable then Register)' `
        ($loop -match '(?s)Test-BitmapSubsAttemptable -Path \$f\.FullName -Ffprobe \$ffprobe\)\s*\{\s*\r?\n\s*if \(Register-OcrUnexplainedFailure') 'True'

  $reachedEnd = $true
}
catch {
  Write-Output "  FAIL the suite threw: $($_.Exception.Message)"; $fails++
}
finally {
  if ($root.StartsWith([IO.Path]::GetTempPath()) -and $root -match 'lib-subtitles-ocr-tests-') {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
  }
}

Write-Output ''
# "Every Check passed" is NOT the same as "every Check ran".
if (-not $reachedEnd) { Write-Output 'the suite did not reach its end - treating as FAILED'; $fails++ }
if ($fails) { Write-Output "$fails test(s) FAILED"; exit 1 }
Write-Output 'all tests passed'
exit 0
