<#
.SYNOPSIS
  OCR a VOBSUB track to an .eng.srt sidecar using PaddleOCR in BATCH - the fallback for discs the
  Tesseract path cannot read cleanly.

.WHY THIS EXISTS
  `ocr-subtitles.ps1` (seconv + Tesseract) is the default and stays the default: it is faster and
  it is right on most discs. This is for the marginal ones - Pulling (2006) converts at ~94%
  against the 95% dictionary floor, with "letters are being split".

  Two things had to be solved to make PaddleOCR usable, and both are the reason this script exists
  rather than a flag on the old one:

  1. seconv drives PaddleOCR ONE IMAGE PER PROCESS, reloading the neural model every cue. Caught in
     the process list: `paddleocr.exe ocr -i ...\in_b92...`. A 504-cue episode was still running
     after 50 minutes. Here the images are rendered first and paddleocr is invoked ONCE over the
     folder, so the model loads once.

  2. The bitmap handed to the engine was the real defect all along. PaddleOCR reproduced
     Tesseract's "I'd Uke to, but no one will Usten" character for character - two independent
     engines making an identical mistake, which puts the fault upstream of both. See
     vobsub-render.py: a binary render either erodes strokes (letters split) or fattens them
     (letters merge); preserving the anti-alias as a real mid-tone fixes it, and the same cue then
     reads "I'd like to, but no one will listen."

  Cropping each cue to its ink took a cue from 168 s to 6-7 s - the display area on these discs is
  near full-frame and ~90% white, and detection scans all of it.

.EXAMPLE
  pwsh -File ocr-paddle.ps1 -Path "D:\video\Television Shows\Pulling (2006)\Season 01\ep.mkv"
  pwsh -File ocr-paddle.ps1 -Path "\\NAS\...\ep.mkv" -KeepWork      # keep the intermediates
#>
param(
  [Parameter(Mandatory)][string]$Path,
  [string]$Lang = 'eng',                 # tag to select the subtitle track
  # 🔴 TESSERACT IS THE DEFAULT. PADDLE IS MARGINALLY MORE ACCURATE AND 33x SLOWER.
  # This script was written because Tesseract scored ~94% on Pulling and PaddleOCR looked like the
  # answer. It was not: PaddleOCR reproduced Tesseract's "I'd Uke to, but no one will Usten"
  # character for character, which showed the fault was the BITMAP, not the engine. Once
  # vobsub-render.py preserved the anti-alias as a real mid-tone, BOTH engines read the cue
  # correctly ("I'd like to, but no one will listen.").
  #
  # BOTH ENGINES RUN OVER THE IDENTICAL RENDERS, so this is a clean comparison. Measured on the
  # full Pulling S01E03 (504 cues, 497 with a shared timing span):
  #     differ in WORDS            3 cues (0.6%) - and Paddle is the better one in all three
  #                                ("If I came in" vs Tesseract's "lf I came in ... Later")
  #     differ only in PUNCTUATION 153 cues - Tesseract keeps the source's curly apostrophes and
  #                                em-dashes; Paddle normalises to ASCII. Neither is wrong.
  #     speed                      Tesseract ~0.6-1 s/cue (~8 min an episode)
  #                                Paddle    ~20 s/cue    (93 min an episode, measured)
  #
  # So Tesseract by default: three cues an episode is not worth 33x the time, and it needs no
  # paddlepaddle, no mkldnn workaround and no GPU. Reach for -Engine paddle when accuracy on a
  # particular disc matters more than throughput, or as a second opinion on a disputed cue.
  [ValidateSet('tesseract','paddle')][string]$Engine = 'tesseract',
  [string]$PaddleLang = 'en',
  [int]$Scale = 3,
  [switch]$KeepWork,
  [switch]$Force                          # overwrite an existing sidecar
)
$ErrorActionPreference = 'Stop'

$tools   = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $tools.ffmpeg) 'ffprobe.exe'
$seconv  = $tools.seconv
$mkvx    = $tools.mkvextract
if (-not $mkvx) { $mkvx = (Get-Command mkvextract -EA SilentlyContinue).Source }
$paddle  = (Get-Command paddleocr -EA SilentlyContinue).Source
if (-not $paddle) { $paddle = Join-Path $env:USERPROFILE '.local\bin\paddleocr.exe' }
foreach ($t in @($ffprobe, $seconv, $mkvx, $paddle)) {
  if (-not (Test-Path -LiteralPath $t)) { throw "tool not found: $t" }
}

$media = Get-Item -LiteralPath $Path
$sidecar = [IO.Path]::ChangeExtension($media.FullName, $null) + 'eng.srt'
if ((Test-Path -LiteralPath $sidecar) -and -not $Force) { "sidecar already exists (use -Force): $sidecar"; return }

# --- pick the subtitle stream ------------------------------------------------------------------
# By TAG, never "the first subtitle stream". Taking s:0 on a disc whose English is not first is how
# a Spanish track got shipped labelled English on Band of Brothers.
$rows = @(& $ffprobe -v error -select_streams s -show_entries 'stream=index,codec_name:stream_tags=language' -of csv=p=0 $media.FullName)
if (-not $rows) { "no subtitle streams in $($media.Name) - nothing to do"; return }
$pick = $null; $ord = -1; $i = 0
foreach ($r in $rows) {
  $f = $r -split ','
  if ($f[-1].Trim() -eq $Lang) { $pick = $f; $ord = $i; break }
  $i++
}
if (-not $pick) { throw "no '$Lang' subtitle stream in $($media.Name) - streams: $($rows -join ' ; ')" }
$absIndex = [int]($pick[0])

$work = Join-Path $env:TEMP ("paddleocr_{0}" -f ([IO.Path]::GetFileNameWithoutExtension($media.Name) -replace '[^\w]','_'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
  Write-Host "  extracting subtitle stream $absIndex ($Lang) ..."
  & $mkvx tracks $media.FullName "${absIndex}:$work\sub.idx" 2>&1 | Out-Null
  if (-not (Test-Path -LiteralPath "$work\sub.idx")) { throw "mkvextract produced no .idx" }

  # Timings come from seconv, NOT from a second parse of the .idx. One implementation.
  Write-Host "  reading time codes ..."
  & $seconv "$work\sub.idx" subrip --time-codes-only --output-folder:$work --overwrite 2>&1 | Out-Null
  if (-not (Test-Path -LiteralPath "$work\sub.srt")) { throw "seconv produced no timing SRT" }
  $cueCount = @(Get-Content "$work\sub.srt" | Where-Object { $_ -match '^\d+$' }).Count

  Write-Host "  rendering $cueCount cue(s) ..."
  python 'D:\video\.claude\skills\disc-to-plex\scripts\vobsub-render.py' "$work\sub.idx" "$work\cues" --scale $Scale | ForEach-Object { "    $_" }

  $t0 = Get-Date
  New-Item -ItemType Directory -Path "$work\out" -Force | Out-Null
  if ($Engine -eq 'tesseract') {
    Write-Host "  OCR with Tesseract ..."
    $tess = $tools.tesseract
    if (-not (Test-Path -LiteralPath $tess)) { $tess = (Get-Command tesseract -EA SilentlyContinue).Source }
    if (-not $tess) { throw 'tesseract not found' }
    foreach ($png in Get-ChildItem "$work\cues" -Filter *.png) {
      # --psm 6: treat the image as a single uniform block. Each render is ONE cue cropped to its
      # ink, so page segmentation has nothing to find and psm 6 avoids it inventing columns.
      $txt = (& $tess $png.FullName stdout --psm 6 -l $Lang 2>$null) -join "`n"
      Set-Content -LiteralPath (Join-Path "$work\out" ($png.BaseName + '.txt')) -Value $txt -Encoding UTF8
    }
  } else {
    Write-Host "  OCR with PaddleOCR (one batch, model loads once) ..."
    & $paddle ocr -i "$work\cues" --lang $PaddleLang --enable_mkldnn False `
        --use_doc_orientation_classify False --use_doc_unwarping False --use_textline_orientation False `
        --save_path "$work\out" *> "$work\paddle.log"
  }
  "    {0:N1} min" -f ((Get-Date) - $t0).TotalMinutes

  python 'D:\video\.claude\skills\disc-to-plex\scripts\srt-from-paddle.py' "$work\sub.srt" "$work\out" $sidecar |
    ForEach-Object { "    $_" }
}
finally {
  if (-not $KeepWork) { Remove-Item -LiteralPath $work -Recurse -Force -EA SilentlyContinue }
  else { "  intermediates kept in $work" }
}
