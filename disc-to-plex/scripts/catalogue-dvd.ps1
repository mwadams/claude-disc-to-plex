# Sweep a DVD once and capture the CONTENT EVIDENCE needed to name its titles - the DVD equivalent
# of catalogue-disc.ps1, which only understands Blu-ray clips.
#
# WHY THIS EXISTS
# ---------------
# scan-disc.ps1 enumerates and classifies DVD titles, then prints "REVIEW titles are probable
# EXTRAS - extract a frame and decide". That is a PROSE instruction to a human standing in the
# middle of an automated pipeline, and prose instructions are what this pipeline keeps being
# bitten by. On Witness (2026-08-23) it meant hand-extracting frames for thirteen titles before
# anything could be named - the same manual pass the Blu-ray path stopped needing that morning.
#
# ffmpeg's `dvdvideo` demuxer reads these discs fine (proved on Witness), so the same evidence the
# Blu-ray sweep collects can be collected here:
#   - two sample frames per title (geometry-clamped, never past the end)
#   - a HEAD STRIP, the first 40 s at 1 fps, where title cards live
#   - a SPEECH SAMPLE, because cards are optional and speech is not
#
# TITLE NUMBERING - the trap this script also removes.
#   MakeMKV numbers DVD titles from 0; the dvdvideo demuxer numbers them from 1.
#   Verified on Witness: identical 16 titles, identical durations, offset by one.
#   This catalogue reports the MAKEMKV number, because that is what you rip with, and converts
#   internally when probing. Getting this backwards hands back the wrong title under a
#   right-looking name.
#
# ⚠ dvdvideo reads only a title's FIRST CELL on multi-cell titles, so a sample point deep into a
# long title can land short or black. Head-of-title evidence (cards, opening speech) is unaffected,
# which is what naming actually depends on. Do not use these frames to judge a title's LENGTH -
# MakeMKV's duration is the authority, and it is what this records.

param(
  [Parameter(Mandatory)][string]$Disc,
  [string]$OutDir = 'D:/video/_catalogue',
  [int]$MinLength = 10,
  [int[]]$FrameAt = @(30, 95),
  [int]$HeadSeconds = 40,
  [int]$SpeechSeconds = 45
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath (Join-Path $Disc 'VIDEO_TS'))) {
  throw "$Disc has no VIDEO_TS - this is the DVD sweep. Use catalogue-disc.ps1 for Blu-ray."
}

$discName = Split-Path $Disc -Leaf
$paths    = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
$ff       = $paths.ffmpeg
$makemkv  = 'C:/Program Files (x86)/MakeMKV/makemkvcon64.exe'
$whisper  = Join-Path $PSScriptRoot 'transcribe-wav.ps1'
$whisperPy = Join-Path $PSScriptRoot 'transcribe-wav.py'
if (-not (Test-Path -LiteralPath $whisperPy)) { $whisperPy = $null }

$frameDir = Join-Path $OutDir "$discName-frames"
New-Item -ItemType Directory -Force $OutDir, $frameDir | Out-Null

# ---- 1. ENUMERATE with MakeMKV, the authority on what a disc contains -------------------------
Write-Output "enumerating $discName (MakeMKV, minlength=$MinLength) ..."
$info = & $makemkv -r --cache=1 "--minlength=$MinLength" info "file:$Disc" 2>&1
$byId = @{}     # NOT $T/$t - PowerShell variables are CASE-INSENSITIVE and that pair collapses
foreach ($line in $info) {
  if ("$line" -match '^TINFO:(\d+),9,0,"([^"]+)"') {
    $id = [int]$Matches[1]
    $byId[$id] = [pscustomobject]@{
      title = $id; duration = $Matches[2]; dvdvideoTitle = $id + 1
      width = $null; height = $null; frames = @(); headStrip = $null
      speechSample = $null; disposition = $null
    }
  }
}
if ($byId.Count -eq 0) { throw "MakeMKV enumerated no titles for $Disc" }
Write-Output "$($byId.Count) title(s)"

function Get-Seconds([string]$hms) {
  if ($hms -match '^(\d+):(\d\d):(\d\d)$') { return [int]$Matches[1]*3600 + [int]$Matches[2]*60 + [int]$Matches[3] }
  return 0
}

# ---- 2. EVIDENCE per title --------------------------------------------------------------------
foreach ($id in ($byId.Keys | Sort-Object)) {
  $rec = $byId[$id]
  $dv  = $rec.dvdvideoTitle
  $dur = Get-Seconds $rec.duration
  $src = @('-f', 'dvdvideo', '-title', "$dv", '-i', $Disc)

  # sample frames, clamped so a short title never yields a black frame read as "nothing here"
  $points = @($FrameAt | Where-Object { $dur -eq 0 -or $_ -lt $dur * 0.95 })
  if (-not $points -and $dur -gt 0) { $points = @([math]::Max(1, [int]($dur * 0.25))) }
  foreach ($sec in $points) {
    $png = Join-Path $frameDir ("t{0:D3}-{1:D4}.png" -f $id, $sec)
    $vf = "yadif,scale=480:270:force_original_aspect_ratio=decrease,pad=480:270:(ow-iw)/2:(oh-ih)/2:black," +
          "drawtext=text='t$id @ ${sec}s':x=8:y=8:fontsize=22:fontcolor=yellow:box=1:boxcolor=black@0.7"
    & $ff -v error @src -ss $sec -frames:v 1 -vf $vf -y $png 2>$null
    if (Test-Path -LiteralPath $png) { $rec.frames += $png }
  }

  # head strip - title cards live in the first seconds and are gone by 30 s
  $headLen = if ($dur -gt 0 -and $dur -lt $HeadSeconds) { $dur } else { $HeadSeconds }
  $head = Join-Path $frameDir ("t{0:D3}-head.png" -f $id)
  $hvf = "fps=1,scale=300:169:force_original_aspect_ratio=decrease," +
         "pad=300:169:(ow-iw)/2:(oh-ih)/2:black,tile=8x5"
  & $ff -v error @src -t $headLen -vf $hvf -frames:v 1 -y $head 2>$null
  if (Test-Path -LiteralPath $head) { $rec.headStrip = $head }

  # speech - a card is optional, speech is not
  if ($whisperPy -and $dur -ge 30) {
    $wav = Join-Path $env:TEMP ("cat-dvd-t{0:D3}.wav" -f $id)
    $at  = [int]([math]::Min(60, [math]::Max(5, $dur * 0.15)))
    & $ff -v error @src -ss $at -t $SpeechSeconds -map '0:a:0?' -ac 1 -ar 16000 -y $wav 2>$null
    if (Test-Path -LiteralPath $wav) {
      $txt = & python $whisperPy $wav 2>$null
      if ($txt) { $rec.speechSample = (($txt -join ' ') -replace '\s+', ' ').Trim() }
      Remove-Item -LiteralPath $wav -Force -ErrorAction SilentlyContinue
    }
  }

  $geo = & $ff -v error @src -frames:v 1 -f null - 2>&1
  Write-Output ("  t{0:D2} {1,9}  frames={2} head={3} speech={4}" -f $id, $rec.duration,
                $rec.frames.Count, [bool]$rec.headStrip, [bool]$rec.speechSample)
}

# ---- 3. CONTACT SHEETS ------------------------------------------------------------------------
$all = @($byId.Keys | Sort-Object | ForEach-Object { $byId[$_].frames } | Where-Object { $_ })
if ($all.Count -gt 0) {
  $seqDir = Join-Path $env:TEMP "dvdcat-$discName"
  New-Item -ItemType Directory -Force $seqDir | Out-Null
  Get-ChildItem -LiteralPath $seqDir -File | Remove-Item -Force -ErrorAction SilentlyContinue
  $i = 0
  foreach ($f in $all) { Copy-Item -LiteralPath $f -Destination (Join-Path $seqDir ("f{0:D3}.png" -f $i)); $i++ }
  $per = 16; $sheet = 1
  for ($start = 0; $start -lt $all.Count; $start += $per) {
    $outPng = Join-Path $OutDir "$discName-sheet$sheet.png"
    & $ff -v error -framerate 1 -start_number $start -i (Join-Path $seqDir 'f%03d.png') `
          -frames:v 1 -vf "tile=4x4" -y $outPng 2>$null
    $sheet++
  }
  Remove-Item -LiteralPath $seqDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---- 4. CATALOGUE ------------------------------------------------------------------------------
$cat = [pscustomobject]@{
  disc = $discName; discPath = $Disc; discType = 'DVD'; minLength = $MinLength
  titleNumbering = 'MakeMKV (0-based). dvdvideo demuxer titles are these +1.'
  titleCount = $byId.Count
  titles = @($byId.Keys | Sort-Object | ForEach-Object { $byId[$_] })
}
$catPath = Join-Path $OutDir "$discName.catalogue.json"
$cat | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $catPath -Encoding UTF8
Write-Output ""
Write-Output "catalogue: $catPath"
Write-Output "$($byId.Count) title(s) - every one needs a disposition before the raw disc is released (assert-accounted.ps1)"
Write-Output "Rip with the MAKEMKV numbers shown above."
