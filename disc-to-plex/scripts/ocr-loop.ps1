# CPU track: keep OCR running over every encoded file that still needs a sidecar.
#
# Runs as a loop rather than a one-shot list, because new encodes land continuously and a fixed
# list goes stale the moment the next manifest finishes. Publishing is BLOCKED on this (publish
# refuses bitmap subs with no sidecar), so an idle OCR track stalls the NAS track behind it.
#
# One file at a time: OCR is CPU-bound and Tesseract already uses the cores.

$paths   = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'

while ($true) {
  $did = $false
  foreach ($f in Get-ChildItem 'D:\video\Movies','D:\video\Television Shows' -Recurse -File -Filter *.mkv -ErrorAction SilentlyContinue) {
    # skip anything still being written - no duration in the header yet
    $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null)".Trim()
    if (-not $d -or $d -eq 'N/A') { continue }

    $codecs = @(& $ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 $f.FullName 2>$null)
    if (-not ($codecs | Where-Object { $_ -match 'dvd_subtitle|hdmv_pgs_subtitle' })) { continue }

    $sidecar = [IO.Path]::ChangeExtension($f.FullName, $null) + 'eng.srt'
    if (Test-Path -LiteralPath $sidecar) { continue }

    Write-Output "OCR: $($f.Name)"
    & pwsh -File 'D:\video\.claude\skills\disc-to-plex\scripts\ocr-subtitles.ps1' -Path $f.FullName 2>&1 |
      Select-String 'cues|refus|reject|SKIP|FAIL' | Select-Object -First 2 | ForEach-Object { "    $_" }
    $did = $true
  }
  if (-not $did) { Start-Sleep -Seconds 120 }
}
