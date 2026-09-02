# Has anything been sitting ENCODED BUT UNPUBLISHED for too long?
#
# WHY THIS EXISTS
# ---------------
# On 2026-09-01 the user asked "so it has been a couple of hours since anything published." They
# were right, and nothing had noticed. Manifests were gating, encodes were completing, all nine
# loops held their mutexes, `_stallwatch.ps1` said "nothing waiting on the operator" - and the far
# end of the chain had shipped nothing since 19:30. Every signal being watched was upstream of the
# only outcome that matters, which is a file arriving on the NAS.
#
# The cause that time was benign and will RECUR: publishing is ALL-OR-NOTHING PER WORK, because
# `_publish.ps1` refuses a work while any of its local files still lacks an OCR sidecar. DVD sources
# carry bitmap subtitles, so every episode needs OCR first. While a disc encodes four episodes back
# to back, each new .mkv resets the "all ready" condition and the work never sits still long enough
# to publish. Not a stall - a starvation, invisible unless you go and look at Plex.
#
# WHAT IT MEASURES, and why not "time since last publish": a publish timestamp says nothing about
# whether there was anything TO publish. This asks the useful question instead - is there a finished
# local file with no counterpart on the NAS, and how long has it been waiting? A quiet pipeline with
# nothing to ship is healthy; one file waiting an hour is not.
#
#   pwsh -File audit-publish-freshness.ps1 [-MaxWaitMin 45] [-Quiet]
# exit 0 = nothing overdue, 2 = something has waited too long
param(
  [string]$VideoRoot  = 'D:/video',
  [string]$NasRoot    = '\\NASTEAMV\Multimedia',
  [int]$MaxWaitMin    = 45,
  # A file written in the last few minutes may still be growing under ffmpeg. Ignore those: a
  # half-written encode is not an unpublished one, and flagging it would train the reader to
  # ignore this check - the failure every monitor here has already had once.
  [int]$SettleMin     = 6,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$now = Get-Date
$waiting = @()

# Needed to ask a file whether it actually carries a bitmap subtitle stream - see the note where
# $why is worked out. Fail closed: without ffprobe we cannot measure, so say so rather than guess.
$toolPaths = Join-Path $VideoRoot '.transcode-tools/tool-paths.json'
$ffprobe = $null
if (Test-Path -LiteralPath $toolPaths) {
  try {
    $ffprobe = Join-Path (Split-Path ((Get-Content -LiteralPath $toolPaths -Raw | ConvertFrom-Json).ffmpeg)) 'ffprobe.exe'
    if (-not (Test-Path -LiteralPath $ffprobe)) { $ffprobe = $null }
  } catch { $ffprobe = $null }
}
if (-not $ffprobe -and -not $Quiet) {
  Write-Output 'WARNING: ffprobe not found - cannot tell a missing sidecar from a file that needs none.'
}

foreach ($area in 'Television Shows', 'Movies') {
  $local = Join-Path $VideoRoot $area
  if (-not (Test-Path -LiteralPath $local)) { continue }
  $base = (Resolve-Path -LiteralPath $local).Path
  foreach ($f in Get-ChildItem -LiteralPath $local -Recurse -File -Filter *.mkv -EA SilentlyContinue) {
    $ageMin = ($now - $f.LastWriteTime).TotalMinutes
    if ($ageMin -lt $SettleMin) { continue }                    # still being written
    $rel = $f.FullName.Substring($base.Length).TrimStart('\', '/')
    $nas = Join-Path (Join-Path $NasRoot $area) $rel
    # SUBTITLES-ONLY WORK: the .mkv is never published - the SIDECAR is the deliverable, and the
    # local mkv is deliberately a different encode from the NAS file of the same name (same root
    # cause as the publish-loop churn fixed 2026-09-02). Measure the sidecar, or this monitor
    # flags the work as overdue forever and teaches the reader to ignore it.
    if (Test-Path -LiteralPath (Join-Path (Join-Path $base (($rel -split '[\\/]')[0])) '.subtitles-only')) {
      $srtLocal = [IO.Path]::ChangeExtension($f.FullName, $null) + 'eng.srt'
      if (Test-Path -LiteralPath $srtLocal) {
        $srtItem = Get-Item -LiteralPath $srtLocal
        $srtNas  = [IO.Path]::ChangeExtension($nas, $null) + 'eng.srt'
        if ((Test-Path -LiteralPath $srtNas) -and (Get-Item -LiteralPath $srtNas).Length -eq $srtItem.Length) { continue }
        $srtAge = ($now - $srtItem.LastWriteTime).TotalMinutes
        if ($srtAge -ge $SettleMin) {
          $waiting += [pscustomobject]@{ File = $rel; WaitedMin = [int]$srtAge
                                         Why = 'subtitles-only: sidecar made but not on the NAS yet - waiting on the publish loop' }
        }
      } else {
        $waiting += [pscustomobject]@{ File = $rel; WaitedMin = [int]$ageMin
                                       Why = 'subtitles-only: NO OCR SIDECAR yet - the mkv exists solely to produce one' }
      }
      continue
    }
    if ((Test-Path -LiteralPath $nas) -and (Get-Item -LiteralPath $nas).Length -eq $f.Length) { continue }

    # WHY is it waiting? MEASURE IT - do not infer it from the absence of a sidecar.
    #
    # The first version said "NO OCR SIDECAR yet" for every unpublished file without an .eng.srt,
    # and was wrong on the first one it met: `S00E33 - Season 4 Episode Previews` is a concat of
    # four preview clips whose declared subtitle streams were empty, so it was manifested
    # `subTrack: "none"` and HAS NO SUBTITLE STREAM AT ALL. It needs no sidecar and was never
    # blocked - the check invented a cause and stated it as fact, which is the exact fault this
    # pipeline keeps having to catch elsewhere.
    #
    # `_publish.ps1` refuses on a BITMAP subtitle stream with no sidecar beside it. So ask the file.
    $srt = [IO.Path]::ChangeExtension($f.FullName, $null) + 'eng.srt'
    if (Test-Path -LiteralPath $srt) {
      $why = 'ready - waiting on the publish loop'
    } else {
      $bitmap = @(& $ffprobe -v error -select_streams s -show_entries stream=codec_name `
                    -of csv=p=0 $f.FullName 2>$null) -match 'dvd_subtitle|hdmv_pgs_subtitle|dvb_subtitle'
      $why = if ($bitmap) { 'NO OCR SIDECAR yet (publish refuses the whole work until every file has one)' }
             else { 'ready - no subtitle stream, so no sidecar is needed' }
    }
    $waiting += [pscustomobject]@{ File = $rel; WaitedMin = [int]$ageMin; Why = $why }
  }
}

if ($waiting.Count -eq 0) {
  if (-not $Quiet) { Write-Output 'PUBLISH FRESHNESS OK - no finished local file is waiting to be published.' }
  exit 0
}
$worst = ($waiting | Measure-Object WaitedMin -Maximum).Maximum
if ($worst -le $MaxWaitMin) {
  if (-not $Quiet) {
    Write-Output ("publishing in progress - {0} file(s) waiting, longest {1} min (cap {2})" -f $waiting.Count, $worst, $MaxWaitMin)
  }
  exit 0
}

if (-not $Quiet) {
  Write-Output ''
  Write-Output ("*** NOTHING HAS PUBLISHED FOR {0} MINUTES and {1} finished file(s) are waiting:" -f $worst, $waiting.Count)
  foreach ($w in ($waiting | Sort-Object WaitedMin -Descending | Select-Object -First 12)) {
    Write-Output ("    {0,4} min  {1}" -f $w.WaitedMin, $w.File)
    Write-Output ("             {0}" -f $w.Why)
  }
  $noSrt = @($waiting | Where-Object { $_.Why -like 'NO OCR*' }).Count
  if ($noSrt -gt 0) {
    Write-Output ''
    Write-Output ("    {0} of them have no sidecar. Check the OCR track is running and draining -" -f $noSrt)
    Write-Output '    publish refuses a WORK while ANY of its files lacks one, so one stuck file'
    Write-Output '    holds back every finished episode beside it.'
  }
}
exit 2
