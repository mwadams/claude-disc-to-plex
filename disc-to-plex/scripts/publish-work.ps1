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
  [switch]$SkipSubtitleCheck,   # publish a work whose bitmap subs are deliberately not being OCR'd
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

# Refuse to publish AHEAD of the OCR pass. The documented order is encode -> OCR -> publish, and
# publishing early is not harmless: the .mkv lands without its sidecar, so every one of them needs
# a second, individual copy afterwards to carry the .srt up. It is easy to do by accident because
# the encode finishing feels like the work being finished, and nothing downstream complains - the
# film plays, with blocky bitmap subtitles, exactly as if no OCR had been intended.
#
# A file with a BITMAP subtitle track (dvd_subtitle / hdmv_pgs_subtitle) and no matching sidecar is
# the signature. Text subtitle tracks and files with no subtitles at all are fine.
#
# But wait only for a sidecar that CAN exist. A declared bitmap track carrying no packets (a silent
# film's empty subtitle shell) can never produce one, and blocking on it strands the work here
# permanently - see lib-subtitles.ps1.
. (Join-Path $PSScriptRoot 'lib-subtitles.ps1')
if (-not $SkipSubtitleCheck) {
  $awaiting = @()
  foreach ($f in $local | Where-Object { $_.Extension -eq '.mkv' }) {
    $sidecar = [IO.Path]::ChangeExtension($f.FullName, $null) + 'eng.srt'
    if (Test-Path -LiteralPath $sidecar) { continue }
    if (Test-BitmapSubsPopulated -Path $f.FullName -Ffprobe $ffprobe) { $awaiting += $f.Name }
  }
  if ($awaiting) {
    Write-Warning ("REFUSING: {0} file(s) have bitmap subtitles but no OCR sidecar yet - run ocr-subtitles.ps1 first, or pass -SkipSubtitleCheck:" -f $awaiting.Count)
    $awaiting | ForEach-Object { Write-Warning "    $_" }
    exit 2
  }
}

Write-Host ("publishing {0} file(s), {1} GB" -f $local.Count, [math]::Round(($local | Measure-Object Length -Sum).Sum / 1GB, 2))
$local | Group-Object Extension | ForEach-Object { "   {0,-6} {1}" -f $_.Name, $_.Count }

# /E = whole tree, ALL file types. Without -Overwrite keep the no-clobber flags so a re-run is safe.
#
# ALWAYS LOG, because an exit >=8 CANNOT BE DIAGNOSED AFTER THE FACT. Rome season 2 threw
# `exit 11` on two separate publishes (2026-08-21). Both times every file verified byte-identical
# on the NAS, and a re-run reported FAILED=0 with everything already present - because by then
# there was nothing left to copy, so the failing pass could never be reproduced. Exit 11 is
# 1 (copied) + 2 (extras in destination, normal - the target holds earlier discs) + 8 (something
# failed). Without the log from the FAILING pass, the 8 is unattributable.
$rcLog  = Join-Path $env:TEMP ("robocopy_{0}_{1}.log" -f ($Work -replace '[^\w]','_'), $PID)
$flags = @('/E','/R:3','/W:5','/NP','/NFL','/NDL',"/LOG:$rcLog")
if (-not $Overwrite) { $flags += @('/XC','/XN','/XO') }
robocopy $src $dst @flags | Out-Null
$rcExit = $LASTEXITCODE
if ($rcExit -ge 8) {
  Write-Warning "robocopy exit $rcExit - the >=8 bit means at least one item failed. Log: $rcLog"
  # Surface the actual errors AND the summary, then let the per-file byte check below decide.
  # A failure here does NOT necessarily mean data loss: verify before concluding either way.
  Get-Content -LiteralPath $rcLog -EA SilentlyContinue |
    Select-String -Pattern 'ERROR|Access is denied|The process cannot access' |
    Select-Object -First 10 | ForEach-Object { Write-Warning "    $_" }
  Get-Content -LiteralPath $rcLog -EA SilentlyContinue | Select-Object -Last 8 |
    ForEach-Object { Write-Warning "    $_" }
  Write-Warning "continuing to the byte-for-byte verification - it, not the exit code, decides."
}

$ok = 0; $bad = 0
foreach ($f in $local) {
  $t = $f.FullName.Replace($src, $dst)
  if ((Test-Path -LiteralPath $t) -and ((Get-Item -LiteralPath $t).Length -eq $f.Length)) { $ok++ }
  else { $bad++; Write-Warning "MISMATCH $($f.Name)" }
}
Write-Host ("verified {0}/{1}{2}" -f $ok, $local.Count, $(if ($bad) { ", $bad MISMATCHED" } else { '' }))
if ($bad) { exit 1 }
