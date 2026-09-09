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

# Get-BitmapSubsVerdict lives here: it is THE one place the pipeline's subtitle-state distinctions
# are made, and publish consults it - so this report must consult the same thing rather than
# re-deriving a weaker answer from the container.
. "$PSScriptRoot/lib-subtitles.ps1"

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
    # ...AND THE SAME FAULT WAS STILL HERE, ONE LAYER UP. Asking ffprobe "does a bitmap stream
    # exist" is not the same question as "is this file waiting on OCR", because a stream that OCR
    # HAS ALREADY READ AND FOUND EMPTY is settled: Set-BitmapSubsExhausted records that, and it
    # explicitly stops blocking publish. 2026-09-07: six of The Song Remains The Same's featurettes
    # are wordless performance items whose subtitle streams carry no usable text - all six settled
    # `exhausted` - and the board named every one of them as "NO OCR SIDECAR yet (publish refuses
    # the whole work until every file has one)". That sends the next reader to check the OCR track,
    # which is draining perfectly, while the actual reason the work has not published is that its
    # manifest is still in _queue.
    #
    # So ask the VERDICT, which is the thing publish actually consults, not the container.
    $srt = [IO.Path]::ChangeExtension($f.FullName, $null) + 'eng.srt'
    if (Test-Path -LiteralPath $srt) {
      $why = 'ready - waiting on the publish loop'
    } else {
      $verdict = try { Get-BitmapSubsVerdict -Path $f.FullName -Ffprobe $ffprobe } catch { $null }
      $why = switch -Wildcard ("$verdict") {
        'none'      { 'ready - no subtitle stream, so no sidecar is needed' }
        'empty'     { 'ready - subtitle stream declared but carries no packets, so no sidecar is possible' }
        'exhausted' { 'ready - OCR ran and found no usable text; settled, and NOT blocking publish' }
        'blocked:*' { "BLOCKED - $($verdict -replace '^blocked:','') (publish refuses the work until this is resolved)" }
        'populated' { 'NO OCR SIDECAR yet (publish refuses the whole work until every file has one)' }
        default     {
          # No verdict cached at all - fall back to the container, and say that is what this is.
          $bitmap = @(& $ffprobe -v error -select_streams s -show_entries stream=codec_name `
                        -of csv=p=0 $f.FullName 2>$null) -match 'dvd_subtitle|hdmv_pgs_subtitle|dvb_subtitle'
          if ($bitmap) { 'NO OCR SIDECAR yet (publish refuses the whole work until every file has one)' }
          else { 'ready - no subtitle stream, so no sidecar is needed' }
        }
      }
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
  # The healthy verdict is stated too. Absence of the marker then means the audit did not RUN -
  # which is a different thing from "nothing is stalled" and must not read as reassurance.
  Write-Output ("PUBLISH-STALL-STATE stalled=0 minutes={0} waiting={1}" -f $worst, $waiting.Count)
  if (-not $Quiet) {
    Write-Output ("publishing in progress - {0} file(s) waiting, longest {1} min (cap {2})" -f $waiting.Count, $worst, $MaxWaitMin)
  }
  exit 0
}

# MACHINE-READABLE FIRST, PROSE AFTER - so _stallwatch.ps1 can publish this and _stall-alarm.ps1
# can raise it, instead of it existing only as a sentence nobody is watching.
#
# This line was printed and nothing else for months. On 2026-09-08 Star Trek The Motion Picture's
# OCR failed a dictionary gate at 84.8% ("letters are being split"), publish correctly held the
# whole work, and it sat for SIXTEEN HOURS holding 12 finished files - while every alarm stayed
# correctly silent, because none of them covers this: `fullyStopped` needs `-not busy` and the
# optical lane was ripping all night; `encodersStarved` needs work awaiting authoring and there was
# none; `manifestFailed` was clean because the manifest succeeded and the OCR did not. The operator
# found it by asking. That is the SAME defect already recorded against failed manifests in
# _stallwatch.ps1 - "the line went into $stalls as prose, and the alarm raises only on the NAMED
# lists" - fixed there and not asked of anything else in the same position.
#
# Anchored at line start and emitted even under -Quiet: a verdict is an assertion, not a mention,
# and a caller that filters output must still be able to find it.
Write-Output ("PUBLISH-STALL-STATE stalled=1 minutes={0} waiting={1}" -f $worst, $waiting.Count)

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
