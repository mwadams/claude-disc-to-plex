<#
.SYNOPSIS
  Extract an episode-title-card contact sheet per episode MKV, so you can VALIDATE that each
  disc title actually contains the episode its filename claims — before staging to the library.

.DESCRIPTION
  Disc order is NOT always broadcast/TMDB order. Many box sets are authored in PRODUCTION order
  (e.g. DS9 S1 swaps "A Man Alone"/"Past Prologue"), and feature-length pilots occupy two episode
  slots. Numbering by TMDB and assuming disc order = broadcast order silently mislabels episodes:
  Plex then shows the wrong title/artwork for correct-looking files. See references/identification.md
  ("Validate content with the episode title card").

  Most shows print the episode title on screen for a beat right AFTER the main-title sequence
  (for Star Trek: ~just after the "Created By ..." credit). This script tiles frames across that
  window into one image per episode; you read the on-screen title (and guest-star credits) off the
  sheet and confirm it matches the filename. This is the automatable replacement for eyeballing a
  disc in a player — and it works where the DVD menu can't be flat-rendered (Paramount/Trek menus
  put episode names in subpicture button overlays that a menu-PGC render won't composite).

  Point it at a folder of already-encoded episode MKVs (fast, local) or any folder of videos.

.EXAMPLE
  pwsh -File extract-title-cards.ps1 -Dir "D:\video\Television Shows\Star Trek Deep Space Nine (1993)\Season 02"
  # then open the PNGs in -OutDir and read each title card; rename any mismatch (SxxEyy token only, no re-encode)

.NOTES
  Title-card time = teaser length + ~100s of main titles, so it varies per episode (~2:40–6:15).
  The default window 90–430s at 6s intervals catches it. If a card lands between samples, drop
  -Interval to 3. Content + guest-star names are a reliable backup when the exact card is missed.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Dir,          # folder of episode .mkv files
  [string]$OutDir,                              # default: <Dir>\_titlecards
  [int]$Start = 90,
  [int]$End   = 430,
  [int]$Interval = 6,
  [string]$Filter = "*.mkv",
  [string]$Ffmpeg = "D:\video\.transcode-tools\ffmpeg-n7.1\ffmpeg-n7.1-latest-win64-gpl-7.1\bin\ffmpeg.exe"
)

if (-not (Test-Path $Dir)) { Write-Error "Dir not found: $Dir"; exit 2 }
if (-not $OutDir) { $OutDir = Join-Path $Dir "_titlecards" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$span = $End - $Start
$cols = 7
$rows = [math]::Ceiling(($span / $Interval + 1) / $cols)

$files = Get-ChildItem $Dir -File -Filter $Filter | Sort-Object Name
if (-not $files) { Write-Error "No $Filter files in $Dir"; exit 3 }

foreach ($f in $files) {
  $safe = ($f.BaseName -replace '[^A-Za-z0-9]','_')
  $sheet = Join-Path $OutDir "$safe.png"
  $vf = "fps=1/$Interval,scale=300:-1,drawtext=text='%{pts\:hms}':x=6:y=6:fontsize=20:fontcolor=yellow:box=1:boxcolor=black,tile=${cols}x${rows}"
  & $Ffmpeg -hide_banner -loglevel error -ss $Start -to $End -i $f.FullName -vf $vf -frames:v 1 $sheet -y 2>$null
  if (Test-Path $sheet) { "  $($f.Name) -> $sheet" } else { "  FAILED: $($f.Name)" }
}
"Done. Open the PNGs in $OutDir and confirm each on-screen title card matches the filename."
