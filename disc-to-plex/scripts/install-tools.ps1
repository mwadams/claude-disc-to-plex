<#
  install-tools.ps1 — fetch the transcode toolchain into a durable folder and verify NVENC.
  Usage:  pwsh -File install-tools.ps1 [-ToolsDir "D:\video\.transcode-tools"]
  Writes the resolved ffmpeg/supmover paths to <ToolsDir>\tool-paths.json for the other scripts to read.

  WHY a portable ffmpeg: the ffmpeg that ships on PATH may be too new for the installed
  NVIDIA driver (e.g. ffmpeg 9.0 needs driver >=610; a 59x driver only supports the
  NVENC API that ffmpeg 7.x targets). BtbN's n7.1 win64 build is the known-good pairing.
#>
param([string]$ToolsDir = "D:\video\.transcode-tools")

$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force $ToolsDir | Out-Null

# 1. NVIDIA driver / GPU sanity
Write-Host "=== GPU / driver ===" -ForegroundColor Cyan
& nvidia-smi --query-gpu=name,driver_version --format=csv,noheader

# 2. ffmpeg (BtbN n7.1 — older NVENC SDK, works with ~55x-60x drivers)
$ffDir = Join-Path $ToolsDir "ffmpeg-n7.1"
$ffExe = Get-ChildItem $ffDir -Recurse -Filter ffmpeg.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ffExe) {
  $zip = Join-Path $ToolsDir "ffmpeg-n71.zip"
  $url = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n7.1-latest-win64-gpl-7.1.zip"
  Write-Host "Downloading ffmpeg n7.1..." -ForegroundColor Cyan
  curl.exe -L --fail -o $zip $url
  New-Item -ItemType Directory -Force $ffDir | Out-Null
  & tar.exe -xf $zip -C $ffDir
  Remove-Item $zip -ErrorAction SilentlyContinue
  $ffExe = Get-ChildItem $ffDir -Recurse -Filter ffmpeg.exe | Select-Object -First 1
}
$ff = $ffExe.FullName
Write-Host ("ffmpeg: " + $ff)

# 2b. libdvdcss — lets ffmpeg's dvdvideo demuxer read/decrypt CSS DVDs directly from a live disc.
#     Not needed for already-decrypted VIDEO_TS folders. NOTE: VideoLAN ships libdvdcss as SOURCE
#     ONLY (download.videolan.org/pub/libdvdcss = *.tar.xz, no prebuilt Windows DLL). The official
#     binary reaches Windows bundled inside VideoLAN's own apps — VLC and HandBrake — so copying
#     libdvdcss-2.dll from one of those IS the original binary (no trustworthy standalone download
#     exists; the alternative is compiling the source yourself). Decrypted folders work regardless.
$ffBin = Split-Path $ff
if(-not (Test-Path (Join-Path $ffBin "libdvdcss-2.dll"))){
  $dll = @("C:\Program Files\HandBrake\libdvdcss-2.dll","C:\Program Files\VideoLAN\VLC\libdvdcss-2.dll",
           "C:\Program Files (x86)\VideoLAN\VLC\libdvdcss-2.dll") | Where-Object { Test-Path $_ } | Select-Object -First 1
  if(-not $dll){ $dll = (Get-ChildItem "C:\Program Files*\" -Recurse -Filter "libdvdcss-2.dll" -EA SilentlyContinue | Select-Object -First 1).FullName }
  if($dll){ Copy-Item $dll (Join-Path $ffBin "libdvdcss-2.dll") -Force; Write-Host ("libdvdcss: copied from " + $dll) }
  else { Write-Warning "libdvdcss-2.dll not found (install HandBrake or VLC, or drop it next to ffmpeg.exe). Decrypted DVD folders still work; live CSS discs won't." }
} else { Write-Host "libdvdcss: already present next to ffmpeg" }

# 3. SupMover (PGS subtitle repositioning after crop — Blu-ray only)
$smDir = Join-Path $ToolsDir "supmover"
$sm = Get-ChildItem $smDir -Recurse -Filter supmover.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $sm) {
  $zip = Join-Path $ToolsDir "supmover.zip"
  # pin a known release; bump if needed
  curl.exe -L --fail -o $zip "https://github.com/MonoS/SupMover/releases/download/v2.5.1/supmover-win.zip"
  New-Item -ItemType Directory -Force $smDir | Out-Null
  & tar.exe -xf $zip -C $smDir
  Remove-Item $zip -ErrorAction SilentlyContinue
  $sm = Get-ChildItem $smDir -Recurse -Filter supmover.exe | Select-Object -First 1
}
Write-Host ("supmover: " + $sm.FullName)

# 3b. Subtitle OCR toolchain — turns the disc's BITMAP subtitles (PGS on Blu-ray, VOBSUB on DVD)
#     into text SRT. This matters for readability, not tidiness: bitmap subs are pictures of text
#     baked at a fixed size, so Plex's subtitle size/font/colour settings do NOTHING for them. DVD
#     VOBSUB is 720x576 with a 4-colour palette and looks blocky upscaled to 1080p/4K. A text SRT
#     renders crisply at any size the viewer chooses.
#
#     Two pieces, because neither does the whole job:
#       mkvextract — ffmpeg has NO vobsub muxer, so it cannot write .idx/.sub; mkvextract can.
#       seconv     — Subtitle Edit's CLI; does the bitmap->SRT conversion.
#                    It cannot read VOBSUB out of an .mkv itself ("No subtitle tracks in Matroska
#                    file"), hence the mkvextract step first.

$mkvDir = Join-Path $ToolsDir "mkvtoolnix"
$mkvx = Get-ChildItem $mkvDir -Recurse -Filter mkvextract.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $mkvx) {
  $7z = Join-Path $ToolsDir "mkvtoolnix.7z"
  New-Item -ItemType Directory -Force $mkvDir | Out-Null
  curl.exe -L --fail -o $7z "https://mkvtoolnix.download/windows/releases/95.0/mkvtoolnix-64-bit-95.0.7z"
  $sevenZip = @("C:\Program Files\7-Zip\7z.exe","C:\Program Files (x86)\7-Zip\7z.exe") |
              Where-Object { Test-Path $_ } | Select-Object -First 1
  if ($sevenZip) { & $sevenZip x $7z "-o$mkvDir" -y | Out-Null; Remove-Item $7z -ErrorAction SilentlyContinue }
  else { Write-Warning "7-Zip not found - cannot unpack mkvtoolnix.7z. Install 7-Zip, or unpack it manually into $mkvDir" }
  $mkvx = Get-ChildItem $mkvDir -Recurse -Filter mkvextract.exe -ErrorAction SilentlyContinue | Select-Object -First 1
}
if ($mkvx) { Write-Host ("mkvextract: " + $mkvx.FullName) } else { Write-Warning "mkvextract missing - subtitle OCR unavailable" }

$seDir = Join-Path $ToolsDir "seconv"
$se = Get-ChildItem $seDir -Recurse -Filter seconv.exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $se) {
  $zip = Join-Path $ToolsDir "seconv.zip"
  New-Item -ItemType Directory -Force $seDir | Out-Null
  curl.exe -L --fail -o $zip "https://github.com/SubtitleEdit/subtitleedit/releases/download/v5.1.0/SeConv-Windows-x64.zip"
  & tar.exe -xf $zip -C $seDir
  Remove-Item $zip -ErrorAction SilentlyContinue
  $se = Get-ChildItem $seDir -Recurse -Filter seconv.exe -ErrorAction SilentlyContinue | Select-Object -First 1
}
if ($se) { Write-Host ("seconv: " + $se.FullName) }

# Tesseract is the recognition engine and CANNOT be installed unattended: its installer needs UAC
# elevation, so a non-interactive shell gets 0x800704c7 ("cancelled by user"). It has to be a
# manual step.
#
# Do NOT reach for Subtitle Edit's built-in nOCR engine to dodge this. It was tried on a real DVD
# and returned "*" for every single cue - the disc fonts are not in its pattern database. It fails
# SILENTLY in the sense that seconv reports success, so only an output check catches it.
$tess = (Get-Command tesseract -ErrorAction SilentlyContinue).Source
if (-not $tess) {
  $tess = @("$env:ProgramFiles\Tesseract-OCR\tesseract.exe","${env:ProgramFiles(x86)}\Tesseract-OCR\tesseract.exe",
            "$env:LOCALAPPDATA\Programs\Tesseract-OCR\tesseract.exe") |
          Where-Object { Test-Path $_ } | Select-Object -First 1
}
if ($tess) { Write-Host ("tesseract: " + $tess) }
else {
  Write-Warning @"
Tesseract NOT installed - subtitle OCR will not work. Run this yourself in an ELEVATED terminal
and accept the UAC prompt:

  winget install --id UB-Mannheim.TesseractOCR --accept-package-agreements --accept-source-agreements

Everything else still works; only the bitmap->SRT step is unavailable.
"@
}

# 4. Verify NVENC actually works on this driver (synthetic 2s encode)
Write-Host "=== NVENC self-test ===" -ForegroundColor Cyan
$test = Join-Path $ToolsDir "nvenc-selftest.mkv"
& $ff -y -hide_banner -v error -f lavfi -i "testsrc2=size=1280x720:rate=24" -t 2 `
  -c:v h264_nvenc -preset medium -rc vbr -cq 20 -b:v 0 -pix_fmt yuv420p $test
if (Test-Path $test) { Write-Host "NVENC OK" -ForegroundColor Green; Remove-Item $test } else { throw "NVENC self-test FAILED — check driver vs ffmpeg build" }

# 5. Persist paths for the other scripts
@{ ffmpeg = $ff; supmover = $sm.FullName; toolsDir = $ToolsDir
   mkvextract = $(if($mkvx){ $mkvx.FullName } else { $null })
   seconv     = $(if($se){ $se.FullName } else { $null })
   tesseract  = $tess } | ConvertTo-Json |
  Set-Content (Join-Path $ToolsDir "tool-paths.json")
Write-Host ("`nWrote " + (Join-Path $ToolsDir "tool-paths.json")) -ForegroundColor Green
