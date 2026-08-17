<#
  lib-subtitles.ps1 — shared subtitle-stream predicates. Dot-source this; it defines functions
  and does nothing on its own.

  WHY THIS EXISTS. A DECLARED bitmap subtitle track is not necessarily a POPULATED one. Camille
  (1921) is a silent film whose DVD declares a `dvd_subtitle` stream carrying ZERO packets. Every
  consumer that reasons from the stream LIST rather than its CONTENTS gets this wrong:

    - ocr-subtitles.ps1 extracts a 70-minute track and produces nothing,
    - no sidecar is written, so
    - publish-work.ps1 refuses the work "awaiting OCR" - forever, and
    - the OCR loop re-picks the same file on every pass, spinning on it.

  Nothing errors. The work simply never reaches the NAS, and the only symptom is a title that
  quietly fails to appear in Plex.

  This was met before and recorded in follow-up.md as a LIST OF AFFECTED WORKS rather than as a
  behaviour change, which is why it recurred - a note describes a problem, a predicate prevents it.
#>

# True when the file has at least one bitmap subtitle stream that actually carries packets, i.e.
# something OCR could convert. False when there are no bitmap streams at all, OR when every one
# of them is an empty shell.
#
# Counting packets means a full pass over the file, so the answer is cached: it can only change
# if the media file itself is rewritten, which is why the cache key includes size and write time.
function Test-BitmapSubsPopulated {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Ffprobe,
    [string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'disc-to-plex\subcache')
  )

  $codecs = @(& $Ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 $Path 2>$null)
  if (-not ($codecs | Where-Object { $_ -match 'dvd_subtitle|hdmv_pgs_subtitle' })) { return $false }

  $item = Get-Item -LiteralPath $Path
  $key  = '{0}|{1}|{2}' -f $item.FullName, $item.Length, $item.LastWriteTimeUtc.Ticks
  $md5  = [Security.Cryptography.MD5]::Create()
  $hash = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))).Replace('-','')
  $cache = Join-Path $CacheDir "$hash.txt"

  if (Test-Path -LiteralPath $cache) { return ((Get-Content -LiteralPath $cache -Raw).Trim() -eq 'populated') }

  $n = @(& $Ffprobe -v error -select_streams s -show_entries packet=pts_time -of csv=p=0 $Path 2>$null).Count
  $verdict = if ($n -gt 0) { 'populated' } else { 'empty' }
  New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
  Set-Content -LiteralPath $cache -Value $verdict
  return ($n -gt 0)
}
