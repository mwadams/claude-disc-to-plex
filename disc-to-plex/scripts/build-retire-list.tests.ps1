<#
  Tests for build-retire-list.ps1 (2026-11-02): a single-backslash UNC supersedes, and same-episode twins.
  Run: pwsh -File build-retire-list.tests.ps1     (exit 0 = all passed)

  41 supersedes in 9 manifests were written "\NASTEAMV\..." (JSON "\\" decodes to one backslash) and were
  held back as "not on the NAS", so 12 legacy Upstairs Downstairs .mp4s stayed in Plex beside their
  re-rips. And a re-rip whose author never wrote supersedes leaves its twin forever. The NAS is stood in
  for by an admin share (\\localhost\X$\...) so the UNC repair runs on a real UNC path. Known-negatives:
  a twin whose programme differs is held with the figure, a range file is never a twin, a file written
  after its replacement is refused, and a title that begins with a number is not read as a range.
#>
$ErrorActionPreference = 'Stop'
$brl = Join-Path $PSScriptRoot 'build-retire-list.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('brl-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$pass = 0; $fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Write-Host "  PASS  $name" } else { $script:fail++; Write-Host "  FAIL  $name`n        $detail" }
}
$ff = (Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json).ffmpeg
function Media([string]$path, [int]$sec) {
  New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
  & $ff -v error -y -f lavfi -i "color=c=black:s=64x48:r=25" -t $sec -c:v libx264 -preset ultrafast $path
}
try {
  $local = Join-Path $root 'local'
  $nasDisk = Join-Path $root 'nas'
  $nasUnc = '\\localhost\' + $nasDisk.Substring(0, 1) + '$' + $nasDisk.Substring(2)
  $lseason = Join-Path $local 'Television Shows/Kappa/Season 01'
  $nseason = Join-Path $nasDisk 'Television Shows/Kappa/Season 01'
  $useason = "$nasUnc\Television Shows\Kappa\Season 01"
  $eps = [ordered]@{ '05' = 'Five'; '06' = 'Six'; '07' = 'Seven'; '08' = '1914 and After'; '09' = 'Nine' }
  $past = (Get-Date).AddDays(-60)
  # the legacy library, written long before the re-rip
  Media (Join-Path $nseason 'Kappa S01E05.mp4') 10    # named in supersedes, single backslash
  Media (Join-Path $nseason 'Kappa S01E06.mp4') 10    # no supersedes: a twin, same length
  Media (Join-Path $nseason 'Kappa S01E07.mp4') 14    # no supersedes: same number, different programme
  Media (Join-Path $nseason 'Kappa - S01E05-E09 - Omnibus.mkv') 10   # a range is never a twin
  Get-ChildItem -LiteralPath $nseason -File | ForEach-Object { $_.LastWriteTime = $past }
  $rows = foreach ($k in $eps.Keys) {
    $leaf = "Kappa - S01E$k - $($eps[$k]).mkv"
    Media (Join-Path $lseason $leaf) 10
    Copy-Item -LiteralPath (Join-Path $lseason $leaf) -Destination (Join-Path $nseason $leaf)
    $row = [ordered]@{ out = ((Join-Path $lseason $leaf) -replace '\\', '/'); src = 'x'; kind = 'MKV' }
    if ($k -eq '05') { $row.supersedes = @($useason.Substring(1) + '\Kappa S01E05.mp4') }   # ONE leading backslash
    [pscustomobject]$row
  }
  # A hand RENAME of S01E09's output: an .mkv copy, same bytes, same mtime. It is the wanted file.
  $e9 = Join-Path $nseason 'Kappa - S01E09 - Nine.mkv'
  Copy-Item -LiteralPath $e9 -Destination (Join-Path $nseason 'Kappa - S01E09 - Nine, Renamed.mkv')
  (Get-Item -LiteralPath (Join-Path $nseason 'Kappa - S01E09 - Nine, Renamed.mkv')).LastWriteTime = (Get-Item -LiteralPath $e9).LastWriteTime
  # S01E08's "twin" lands AFTER the replacement - reoccupied, never the superseded copy.
  Media (Join-Path $nseason 'Kappa S01E08.mp4') 10
  (Get-Item -LiteralPath (Join-Path $nseason 'Kappa S01E08.mp4')).LastWriteTime = (Get-Date).AddHours(1)
  New-Item -ItemType Directory -Force -Path (Join-Path $local '_queue/done') | Out-Null
  ConvertTo-Json -InputObject @($rows) -Depth 4 | Set-Content -LiteralPath (Join-Path $local '_queue/done/kappa.json')

  $out = Join-Path $root 'retire.txt'; $rep = Join-Path $root 'detail.tsv'
  $o = @(& pwsh -NoProfile -File $brl -ManifestRoot (Join-Path $local '_queue') -Out $out -Report $rep -Manual (Join-Path $root 'none.tsv') `
           -NasRoot $nasUnc -LocalRoot $local 2>&1 | ForEach-Object { "$_" }) -join "`n"
  $list = @(Get-Content -LiteralPath $out | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { Split-Path $_ -Leaf })
  $det = @(Import-Csv -LiteralPath $rep -Delimiter "`t")
  $why = { param($leaf) ($det | Where-Object { (Split-Path $_.Superseded -Leaf) -eq $leaf } | ForEach-Object { $_.Reason }) -join ' / ' }

  Check 'REAL: a single-backslash UNC supersedes is repaired and listed' ($list -contains 'Kappa S01E05.mp4') "$o`n$($list -join ' | ')"
  Check '  ...listed once, by its supersedes (not again as a twin)' (@($list | Where-Object { $_ -eq 'Kappa S01E05.mp4' }).Count -eq 1 -and (& $why 'Kappa S01E05.mp4') -match 'replacement verified') (& $why 'Kappa S01E05.mp4')
  Check 'REAL: a same-length twin with no supersedes is listed' ($list -contains 'Kappa S01E06.mp4' -and (& $why 'Kappa S01E06.mp4') -match 'same-episode twin') (& $why 'Kappa S01E06.mp4')
  Check 'known-negative: a twin 4 s different is HELD with the figure' ($list -notcontains 'Kappa S01E07.mp4' -and (& $why 'Kappa S01E07.mp4') -match 'differ by 4\.0s') (& $why 'Kappa S01E07.mp4')
  Check 'known-negative: a twin written after its replacement is refused' ($list -notcontains 'Kappa S01E08.mp4' -and (& $why 'Kappa S01E08.mp4') -match '^REFUSED') (& $why 'Kappa S01E08.mp4')
  Check 'known-negative: a range file is never a twin' ($list -notcontains 'Kappa - S01E05-E09 - Omnibus.mkv') ($list -join ' | ')
  Check 'known-negative: "S01E08 - 1914 and After" is a single episode, not a range' ((& $why 'Kappa S01E08.mp4') -ne '') $o
  Check 'known-negative: an .mkv copy of an output (a hand rename, same mtime) is never a twin' ($list -notcontains 'Kappa - S01E09 - Nine, Renamed.mkv' -and (& $why 'Kappa - S01E09 - Nine, Renamed.mkv') -eq '') ($list -join ' | ')
  Check 'known-negative: no published replacement is ever listed' (@($list | Where-Object { $_ -like 'Kappa - S01E0? - *' }).Count -eq 0) ($list -join ' | ')
  Check 'every listed path is on the stand-in NAS (UNC)' (@(Get-Content -LiteralPath $out | Where-Object { $_ -and -not $_.StartsWith('#') -and -not $_.StartsWith($nasUnc) }).Count -eq 0) (Get-Content -LiteralPath $out -Raw)
}
catch { Write-Host "  FAIL exception: $($_.Exception.Message) at line $($_.InvocationInfo.ScriptLineNumber)"; $fail++ }
finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Host ("{0} passed, {1} failed" -f $pass, $fail)
if ($fail) { exit 1 }
Write-Host 'all tests passed'
exit 0
