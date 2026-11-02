<#
  Tests for publish-work.ps1's slot-collision check honouring `supersedes` (2026-11-02).
  Run: pwsh -File publish-work.supersede.tests.ps1     (exit 0 = all passed)

  Noggin the Nog was re-split from three combined files (S01E01-E06 ...) into fifteen episodes. Every
  new row named the combined file in `supersedes`, but the combined copy still in the local folder
  "claimed" S01E01 beside the new E01 and the season was held as a SLOT COLLISION. A superseded file
  is history: it neither clashes nor publishes. Two known-negatives keep the guard honest: a real
  double claim (no supersedes) still refuses, and a same-name in-place replacement still publishes.
  Runs against a throwaway LocalRoot and a local folder standing in for the NAS (-NoIndex -Manual).
#>
$ErrorActionPreference = 'Stop'
$pw = Join-Path $PSScriptRoot 'publish-work.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('pwsup-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Write-Host "  PASS  $name" } else { $script:fail++; Write-Host "  FAIL  $name`n        $detail" }
}
$ff = (Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json).ffmpeg
function Mkv([string]$path) {
  New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
  & $ff -v error -y -f lavfi -i 'color=c=black:s=64x48:r=25' -t 1 -c:v libx264 -preset ultrafast $path
}
function Fixture([string]$name, [bool]$declareSupersede, [bool]$sameName) {
  $lr = Join-Path $root "$name/local"; $nas = Join-Path $root "$name/nas"
  New-Item -ItemType Directory -Force -Path (Join-Path $lr '_queue/done'), (Join-Path $nas 'Television Shows/Kappa') | Out-Null
  $season = Join-Path $lr 'Television Shows/Kappa/Season 01'
  $new = Join-Path $season 'Kappa - S01E01 - One.mkv'; Mkv $new
  $oldLeaf = if ($sameName) { 'Kappa - S01E01 - One.mkv' } else { 'Kappa - S01E01-E06 - Combined.mkv' }
  if (-not $sameName) { Mkv (Join-Path $season $oldLeaf) }
  $row = [ordered]@{ out = ($new -replace '\\', '/'); src = 'x'; kind = 'MKV' }
  if ($declareSupersede) { $row.supersedes = @("\\NASTEAMV\Multimedia\Television Shows\Kappa\Season 01\$oldLeaf") }
  ConvertTo-Json -InputObject @([pscustomobject]$row) -Depth 4 | Set-Content -LiteralPath (Join-Path $lr '_queue/done/kappa.json')
  $o = @(& pwsh -NoProfile -File $pw -Work 'Kappa' -Kind 'Television Shows' -LocalRoot $lr -NasRoot $nas -NoIndex -Manual -SkipSubtitleCheck 2>&1 | ForEach-Object { "$_" })
  [pscustomobject]@{ Text = ($o -join "`n"); Nas = (Join-Path $nas 'Television Shows/Kappa/Season 01') }
}
try {
  Write-Host '1. REAL (Noggin): the combined file is superseded by the new episode row'
  $r = Fixture 'real' $true $false
  Check 'no slot collision' ($r.Text -notmatch 'SLOT COLLISION') $r.Text
  Check 'the new episode is published' (Test-Path -LiteralPath (Join-Path $r.Nas 'Kappa - S01E01 - One.mkv')) $r.Text
  Check 'the superseded combined file is NOT published' (-not (Test-Path -LiteralPath (Join-Path $r.Nas 'Kappa - S01E01-E06 - Combined.mkv'))) $r.Text
  Check 'and the log says why' ($r.Text -match 'NOT PUBLISHING \(superseded by a manifest row\): Kappa - S01E01-E06 - Combined\.mkv') $r.Text

  Write-Host '2. known-negative: the same two files with NO supersedes are a real double claim'
  $r = Fixture 'clash' $false $false
  Check 'SLOT COLLISION still refused' ($r.Text -match 'SLOT COLLISION') $r.Text
  Check 'nothing in that season published' (-not (Test-Path -LiteralPath (Join-Path $r.Nas 'Kappa - S01E01 - One.mkv'))) $r.Text

  Write-Host '3. known-negative: a same-name in-place replacement is the NEW file and still publishes'
  $r = Fixture 'inplace' $true $true
  Check 'published' (Test-Path -LiteralPath (Join-Path $r.Nas 'Kappa - S01E01 - One.mkv')) $r.Text
  Check 'not reported as superseded' ($r.Text -notmatch 'superseded by a manifest row') $r.Text
}
catch { Write-Host "  FAIL exception: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"; $fail++ }
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ("{0} passed, {1} failed" -f $pass, $fail)
if ($fail) { exit 1 }
Write-Host 'all tests passed'
exit 0
