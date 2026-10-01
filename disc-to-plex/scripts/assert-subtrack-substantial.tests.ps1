<#
  Tests for assert-subtrack-substantial.ps1. The fixture evidence pack is The Enemy Below's real title-1
  subtitle layout (2026-10-01): six real streams, then four 7-packet forced phantoms. Each negative case
  differs from a passing one by one fact.
#>
$ErrorActionPreference = 'Stop'
$guard = Join-Path $PSScriptRoot 'assert-subtrack-substantial.ps1'
$fails = 0
function Check([string]$name, $got, $want) {
  if ("$got" -eq "$want") { Write-Host "  PASS  $name" -ForegroundColor Green }
  else { $script:fails++; Write-Host ("  FAIL  {0}  (got {1}, want {2})" -f $name, $got, $want) -ForegroundColor Red }
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('subsubst' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$cat = Join-Path $root 'cat'
New-Item -ItemType Directory -Force -Path $cat | Out-Null
function Sub([int]$idx, [int]$pk, [string]$lang) { [ordered]@{ index = $idx; type = 'subtitle'; codec = 'dvd_subtitle'; packets = $pk; packetsKeyPresent = $true; lang = $lang } }
$streams = @(
  [ordered]@{ index = 0; type = 'video'; packets = 140412; packetsKeyPresent = $true },
  [ordered]@{ index = 1; type = 'audio'; packets = 175514; packetsKeyPresent = $true; lang = 'eng' },
  (Sub 6 746 'dut'), (Sub 7 939 'eng'), (Sub 8 832 'fre'), (Sub 9 946 'ger'), (Sub 10 832 'ita'), (Sub 11 832 'spa'),
  (Sub 12 7 'fre'), (Sub 13 7 'ger'), (Sub 14 7 'ita'), (Sub 15 7 'spa'))
$sparseOnly = @([ordered]@{ index = 0; type = 'video'; packets = 100; packetsKeyPresent = $true }, (Sub 1 7 'eng'), (Sub 2 5 'fre'))
[ordered]@{ titles = @([ordered]@{ dvdvideoTitle = 1; streams = $streams }, [ordered]@{ dvdvideoTitle = 2; streams = $sparseOnly }) } |
  ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $cat 'Demo Disc.evidence.json') -Encoding UTF8

function Run($doc) {
  $mf = Join-Path $root ('m' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
  ConvertTo-Json -InputObject $doc -Depth 6 | Set-Content -LiteralPath $mf -Encoding UTF8
  $o = & pwsh -NoProfile -File $guard -Manifest $mf -Catalogue $cat 2>&1
  [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($o -join "`n") }
}
function Row($sub, [int]$title = 1, [hashtable]$extra = @{}) {
  $h = [ordered]@{ out = 'D:/video/Movies/Demo (1957)/Demo (1957).mkv'; kind = 'DVD'; src = 'D:/video/_stage/Demo Disc'; title = $title; subTrack = $sub }
  foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] }
  [pscustomobject]$h
}
try {
  $r = Run @((Row '7'))
  Check 'REAL: subTrack 7 (absolute index) picks the 7-packet phantom -> REFUSED' $r.Code 2
  Check '  ...and names ordinal 1 as the eng stream it meant' ($r.Text -match 'ABSOLUTE stream index of the eng stream \(939 packets\); its subtitle ORDINAL is 1') $true
  Check 'the right ordinal (1) passes' (Run @((Row '1'))).Code 0
  Check 'subTrack "eng" is not this guard''s question' (Run @((Row 'eng'))).Code 0
  Check 'subTrack "none" is not this guard''s question' (Run @((Row 'none'))).Code 0
  Check 'subTrackSparseOk with a reason passes' (Run @((Row '7' 1 @{ subTrackSparseOk = 'German forced-narrative track, wanted' }))).Code 0
  Check 'subTrackSparseOk EMPTY is not a reason -> REFUSED' (Run @((Row '7' 1 @{ subTrackSparseOk = '  ' }))).Code 2
  Check 'an ordinal past the last subtitle stream -> REFUSED' (Run @((Row '12'))).Code 2
  Check 'a title with ONLY sparse streams -> passes (nothing better to pick)' (Run @((Row '0' 2))).Code 0
  $r = Run @((Row '1' 9))
  Check 'title absent from the evidence -> passes, reported UNCHECKED' "$($r.Code)/$($r.Text -match 'UNCHECKED')" '0/True'
  Check 'a non-DVD row is not checked' (Run @((Row '7' 1 @{ kind = 'MKV' }))).Code 0
  Check 'one bad row among good ones -> REFUSED' (Run @((Row '1'), (Row '7'), (Row 'eng'))).Code 2
  # A SINGLE-ROW manifest is not an array after ConvertFrom-Json - mishandled, it would check nothing.
  $mf = Join-Path $root 'single.json'; (Row '7') | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $mf -Encoding UTF8
  & pwsh -NoProfile -File $guard -Manifest $mf -Catalogue $cat | Out-Null
  Check 'a single-row (unwrapped) manifest is still checked' $LASTEXITCODE 2
  Check 'an outputs-wrapped manifest is checked' (Run ([pscustomobject]@{ unit = 'Demo Disc'; outputs = @((Row '7')) })).Code 2
  & pwsh -NoProfile -File $guard -Manifest (Join-Path $root 'nope.json') -Catalogue $cat | Out-Null
  Check 'missing manifest -> 0' $LASTEXITCODE 0
}
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ''
if ($fails) { Write-Host "$fails test(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all subtrack-substantial tests passed' -ForegroundColor Green
