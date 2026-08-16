# Publish a finished work to the NAS: copy EVERY file (media + sidecar subtitles + artwork),
# then verify count and bytes.
#
# WHY THIS EXISTS. Publishing used to be an ad-hoc robocopy naming "<title>.mkv" explicitly - a
# habit picked up from the "never folder-copy while an encode is still writing" rule. That is
# right about the danger and wrong about the remedy: naming one file silently leaves behind
# anything else the work needs, and since OCR now writes subtitles as SIDECARS, a *.mkv filter
# drops the subtitles without a word of complaint.
#
# The real guard against copying a half-written file is to publish only AFTER the encode reports
# done and the outputs have been duration-checked - not to narrow the filter.
#
#   pwsh -File _publish.ps1 -Work "Zulu (1964)" -Kind Movies
#   pwsh -File _publish.ps1 -Work "Being Human (2009)" -Kind 'Television Shows'
#   pwsh -File _publish.ps1 -Work "Zulu (1964)" -Kind Movies -Overwrite   # replace a bad copy

param(
  [Parameter(Mandatory)][string]$Work,
  [ValidateSet('Movies','Television Shows')][string]$Kind = 'Movies',
  [switch]$Overwrite,
  [string]$LocalRoot = 'D:\video',
  [string]$NasRoot   = '\\NASTEAMV\Multimedia'
)

$src = Join-Path (Join-Path $LocalRoot $Kind) $Work
$dst = Join-Path (Join-Path $NasRoot   $Kind) $Work
if (-not (Test-Path -LiteralPath $src)) { throw "no such local work: $src" }

$local = @(Get-ChildItem -LiteralPath $src -Recurse -File)
if (-not $local) { throw "nothing to publish in $src" }

# refuse to publish anything that looks unfinished - a truncated mkv has no duration in its header
$paths   = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'
foreach ($f in $local | Where-Object { $_.Extension -eq '.mkv' }) {
  $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null)".Trim()
  if (-not $d -or $d -eq 'N/A') { throw "REFUSING: $($f.Name) has no duration - it is a partial file" }
}

Write-Host ("publishing {0} file(s), {1} GB" -f $local.Count, [math]::Round(($local | Measure-Object Length -Sum).Sum / 1GB, 2))
$local | Group-Object Extension | ForEach-Object { "   {0,-6} {1}" -f $_.Name, $_.Count }

# /E = whole tree, ALL file types. Without -Overwrite keep the no-clobber flags so a re-run is safe.
$flags = @('/E','/R:3','/W:5','/NP','/NFL','/NDL')
if (-not $Overwrite) { $flags += @('/XC','/XN','/XO') }
robocopy $src $dst @flags | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed (exit $LASTEXITCODE)" }

$ok = 0; $bad = 0
foreach ($f in $local) {
  $t = $f.FullName.Replace($src, $dst)
  if ((Test-Path -LiteralPath $t) -and ((Get-Item -LiteralPath $t).Length -eq $f.Length)) { $ok++ }
  else { $bad++; Write-Warning "MISMATCH $($f.Name)" }
}
Write-Host ("verified {0}/{1}{2}" -f $ok, $local.Count, $(if ($bad) { ", $bad MISMATCHED" } else { '' }))
if ($bad) { exit 1 }
