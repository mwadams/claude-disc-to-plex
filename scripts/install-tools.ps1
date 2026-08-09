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

# 4. Verify NVENC actually works on this driver (synthetic 2s encode)
Write-Host "=== NVENC self-test ===" -ForegroundColor Cyan
$test = Join-Path $ToolsDir "nvenc-selftest.mkv"
& $ff -y -hide_banner -v error -f lavfi -i "testsrc2=size=1280x720:rate=24" -t 2 `
  -c:v h264_nvenc -preset medium -rc vbr -cq 20 -b:v 0 -pix_fmt yuv420p $test
if (Test-Path $test) { Write-Host "NVENC OK" -ForegroundColor Green; Remove-Item $test } else { throw "NVENC self-test FAILED — check driver vs ffmpeg build" }

# 5. Persist paths for the other scripts
@{ ffmpeg = $ff; supmover = $sm.FullName; toolsDir = $ToolsDir } | ConvertTo-Json |
  Set-Content (Join-Path $ToolsDir "tool-paths.json")
Write-Host ("`nWrote " + (Join-Path $ToolsDir "tool-paths.json")) -ForegroundColor Green
