<#
  Tests for assert-superseded-sidecars.ps1.

  The NAS is not stubbed - it is REDIRECTED. The guard takes -NasRoot, so the fixture builds a fake
  library under a temp folder and points the guard at it. That exercises the real path mapping and
  the real Test-Path calls without reading or writing anything on \\NASTEAMV.

  Every negative case here must fail for the RIGHT reason, so each one differs from a passing case
  by exactly one fact.
#>
$ErrorActionPreference = 'Stop'
$guard = Join-Path $PSScriptRoot 'assert-superseded-sidecars.ps1'
$fails = 0
function Check([string]$name, $got, $want) {
  if ("$got" -eq "$want") { Write-Host "  PASS  $name" -ForegroundColor Green }
  else { $script:fails++; Write-Host ("  FAIL  {0}  (got {1}, want {2})" -f $name, $got, $want) -ForegroundColor Red }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ("sidecartest" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
$nas  = Join-Path $root 'nas'
$show = Join-Path $nas 'Television Shows\Demo Show\Season 01'
$done = Join-Path $root 'done'
New-Item -ItemType Directory -Force -Path $show | Out-Null
New-Item -ItemType Directory -Force -Path $done | Out-Null

# The published state we are superseding: a .mkv with a sidecar, and one without.
Set-Content -LiteralPath (Join-Path $show 'Demo Show - s01e01.mkv')     -Value 'old video'
Set-Content -LiteralPath (Join-Path $show 'Demo Show - s01e01.eng.srt') -Value 'old subs'
Set-Content -LiteralPath (Join-Path $show 'Demo Show - s01e02.mkv')     -Value 'old video, never subtitled'

function Run([object[]]$rows) {
  $mf = Join-Path $root ('m' + [Guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
  ,$rows | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $mf -Encoding UTF8
  $o = & pwsh -NoProfile -File $guard -Manifest $mf -NasRoot $nas -DoneDir $done 2>&1
  [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($o -join "`n") }
}
function Row([string]$out, [hashtable]$extra = @{}) {
  $h = [ordered]@{ out = $out; kind = 'DVD'; src = 'D:/video/_stage/Demo'; title = 1 }
  foreach ($k in $extra.Keys) { $h[$k] = $extra[$k] }
  [pscustomobject]$h
}
$e01 = 'D:/video/Television Shows/Demo Show/Season 01/Demo Show - s01e01.mkv'
$e02 = 'D:/video/Television Shows/Demo Show/Season 01/Demo Show - s01e02.mkv'
$e09 = 'D:/video/Television Shows/Demo Show/Season 01/Demo Show - s01e09.mkv'

try {
  # THE DEFECT ITSELF: replaces a file that has a sidecar, names no subtitle source.
  $r = Run @(Row $e01)
  Check 'in-place + existing sidecar + no subTrack -> REFUSED' $r.Code 2
  Check '  ...and it names the sidecar it found' ($r.Text -match 'Demo Show - s01e01\.eng\.srt') $true

  # subTrack: "none" is the SAME fault stated explicitly - it is a fact about the disc, not a decision.
  Check 'subTrack "none" is not an answer -> REFUSED' (Run @(Row $e01 @{ subTrack = 'none' })).Code 2

  # The two ways out.
  Check 'a named subtitle stream -> passes'  (Run @(Row $e01 @{ subTrack = '0' })).Code 0
  Check 'staleSidecar stated -> passes'      (Run @(Row $e01 @{ staleSidecar = 'no subpicture stream on this disc; timings spot-checked and still match' })).Code 0
  Check 'staleSidecar EMPTY is not an answer -> REFUSED' (Run @(Row $e01 @{ staleSidecar = '   ' })).Code 2

  # Not a replacement at all: nothing on the NAS at that path.
  Check 'a NEW output (no NAS file) -> passes' (Run @(Row $e09)).Code 0
  # A replacement with no sidecar to go stale.
  Check 'in-place but no sidecar present -> passes' (Run @(Row $e02)).Code 0

  # One bad row among good ones must still refuse - a per-row fault, not a per-manifest average.
  Check 'one faulty row among three -> REFUSED' (Run @((Row $e02), (Row $e01), (Row $e09))).Code 2

  # A SINGLE-ROW manifest is not an array after ConvertFrom-Json. If that unwrap were mishandled the
  # guard would check nothing and exit 0 - which is what every case above would look like.
  $mf = Join-Path $root 'single.json'
  (Row $e01) | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $mf -Encoding UTF8
  & pwsh -NoProfile -File $guard -Manifest $mf -NasRoot $nas -DoneDir $done | Out-Null
  Check 'a single-row (unwrapped) manifest is still checked' $LASTEXITCODE 2

  # An `outputs`-wrapped manifest is the other shape in use.
  $mf2 = Join-Path $root 'wrapped.json'
  [pscustomobject]@{ unit = 'Demo'; outputs = @((Row $e01)) } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $mf2 -Encoding UTF8
  & pwsh -NoProfile -File $guard -Manifest $mf2 -NasRoot $nas -DoneDir $done | Out-Null
  Check 'an outputs-wrapped manifest is checked' $LASTEXITCODE 2

  # CANNOT JUDGE -> exit 0, never a refusal.
  & pwsh -NoProfile -File $guard -Manifest (Join-Path $root 'nope.json') -NasRoot $nas -DoneDir $done | Out-Null
  Check 'missing manifest -> silent 0' $LASTEXITCODE 0
  $bad = Join-Path $root 'bad.json'; Set-Content -LiteralPath $bad -Value '{ not json'
  & pwsh -NoProfile -File $guard -Manifest $bad -NasRoot $nas -DoneDir $done | Out-Null
  Check 'unreadable JSON -> silent 0' $LASTEXITCODE 0
  Check 'a row with no out -> passes' (Run @([pscustomobject]@{ kind = 'DVD'; title = 1 })).Code 0

  # A sidecar of another accepted kind is just as stale.
  Set-Content -LiteralPath (Join-Path $show 'Demo Show - s01e02.ass') -Value 'old subs'
  Check 'a .ass sidecar counts too -> REFUSED' (Run @(Row $e02)).Code 2

  # ---- WHO PUT THE FILE THERE. The first cut of this guard refused 16 of 40 completed manifests
  # because it read "the NAS file exists" as "this is a replacement". These two cases are the
  # difference, and they differ from each other by the src unit alone.
  @([pscustomobject]@{ out = $e01; src = 'D:/video/_stage/Demo' }) | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $done 'demo.json') -Encoding UTF8
  Check 'RE-GATE: the same src already claims this out -> passes' (Run @(Row $e01)).Code 0
  Check 'a DIFFERENT src claims this out -> REFUSED' `
        (Run @(Row $e01 @{ src = 'D:/video/_stage/Demo Blu-ray' })).Code 2
  # And a src expressed as a FILE inside the unit resolves to the same unit, so a rip-based manifest
  # re-gates cleanly instead of reading as a different source.
  Check 'RE-GATE: src as a file inside the same unit -> passes' `
        (Run @(Row $e01 @{ src = 'D:/video/_stage/Demo/VIDEO_TS/VTS_01_1.VOB' })).Code 0
}
finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($fails) { Write-Host "$fails test(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'all superseded-sidecar tests passed' -ForegroundColor Green
