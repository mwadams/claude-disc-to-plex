<#
  Tests for assert-tracks-analysed.ps1's EMPTY audio claim (audioTracks []) against declared streams.
  Run: pwsh -File assert-tracks-analysed.tests.ps1     (exit 0 = all passed)

  2026-10-29, operator: "Allow the gate to approve zero packet audio streams as no audio evidence".
  Big Train Series 1's stills gallery (dvdvideo title 7) declares two AC3 streams that carry ZERO
  packets; analyze-tracks.py cannot measure them, so [] was refused and no other value could pass.
  The gate now accepts the evidence pack's per-title audioPackets when EVERY declared stream counts 0.
  These pin both directions on the real title: all-zero passes; one counted packet, or no evidence
  pack at all, still refuses - the empty claim must never drop real audio.
#>
$ErrorActionPreference = 'Stop'
$gate = Join-Path $PSScriptRoot 'assert-tracks-analysed.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('ata-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Write-Host "  PASS  $name" } else { $script:fail++; Write-Host "  FAIL  $name`n        $detail" }
}
$disc = 'Big Train Series 1'
$src = "D:/video/_stage/$disc"
$realEv = "D:/video/_catalogue/$disc.evidence.json"
if (-not (Test-Path -LiteralPath $src) -or -not (Test-Path -LiteralPath $realEv)) {
  Write-Host "  (skipped: '$disc' is no longer staged or has no evidence pack - the real fixture is gone)"
  Write-Host 'all tests passed (skipped)'; exit 0
}
try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $man = Join-Path $root 'gallery.json'
  @(@{ title = 7; src = $src; kind = 'DVD'; audioTracks = @(); subTrack = 'none'; expectSeconds = 200.0
       out = 'D:/video/Television Shows/Big Train/Season 00/Big Train - s00e10 - Series One Stills Gallery.mkv' }) |
    ConvertTo-Json -Depth 4 -AsArray | Set-Content -LiteralPath $man
  function Run([string]$cat) {
    $o = @(& pwsh -NoProfile -File $gate -Manifest $man -Catalogue $cat 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($o -join "`n") }
  }
  $evAll = Get-Content -LiteralPath $realEv -Raw | ConvertFrom-Json

  Write-Host '1. REAL: two declared streams, 0 packets each, per the real evidence pack'
  $c1 = Join-Path $root 'cat-real'; New-Item -ItemType Directory -Force -Path $c1 | Out-Null
  Copy-Item -LiteralPath $realEv -Destination $c1
  $r = Run $c1
  Check 'the empty claim passes' ($r.Code -eq 0) $r.Text

  Write-Host '2. known-negative: one stream with packets -> real audio, still refused'
  $c2 = Join-Path $root 'cat-onepacket'; New-Item -ItemType Directory -Force -Path $c2 | Out-Null
  foreach ($t in @($evAll.titles)) { if ([int]$t.dvdvideoTitle -eq 7) { $t.audioPackets = @(0, 12) } }
  $evAll | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $c2 "$disc.evidence.json")
  $r = Run $c2
  Check 'refused - [] would drop real audio' ($r.Code -ne 0 -and $r.Text -match 'claims this title has NO audio') $r.Text

  Write-Host '3. known-negative: no evidence pack -> nothing measured, still refused'
  $c3 = Join-Path $root 'cat-none'; New-Item -ItemType Directory -Force -Path $c3 | Out-Null
  $r = Run $c3
  Check 'refused' ($r.Code -ne 0 -and $r.Text -match 'claims this title has NO audio') $r.Text
}
catch { Write-Host "  FAIL exception: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"; $fail++ }
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ("{0} passed, {1} failed" -f $pass, $fail)
if ($fail) { exit 1 }
Write-Host 'all tests passed'
exit 0
