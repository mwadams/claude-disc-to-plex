# Identify EVERY audio track on every shipped film, from the audio itself.
#
# WHY. Zulu shipped with three audio tracks where the disc has two: a:0 and a:1 were the SAME
# dialogue mix duplicated, and a:2 - the commentary - was left untitled. Nothing in the container
# metadata revealed that; only transcribing the audio did. A sweep of the batch found untitled
# tracks on nine of eleven films, so the Zulu case is unlikely to be unique.
#
# Read-only. Reports; changes nothing.

param(
  [string]$NasRoot = '\\NASTEAMV\Multimedia\Movies',
  [string[]]$Discs = @('Zulu','King Lear','Run Lola Run','The Men Who Stare At Goats',
                       'The Ipcress File','In the Line of Fire','Spy Game',
                       'Fantastic 4','The Dam Busters','Ratatouille','The Italian Job'),
  [int]$Start = 3000,
  [int]$Dur = 40
)

$paths   = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'
$ident   = 'D:\video\.claude\skills\disc-to-plex\scripts\identify-audio.py'

foreach ($d in $Discs) {
  $nas = Get-ChildItem -LiteralPath $NasRoot -Directory -EA SilentlyContinue |
         Where-Object { $_.Name -like "*$d*" } | Select-Object -First 1
  if (-not $nas) { Write-Host "$d : not on NAS"; continue }

  $mkv = Get-ChildItem -LiteralPath $nas.FullName -File -Filter *.mkv |
         Sort-Object Length -Descending | Select-Object -First 1
  if (-not $mkv) { Write-Host "$d : no mkv"; continue }

  $rows = @(& $ffprobe -v error -select_streams a -show_entries 'stream=index:stream_tags=title' -of csv=p=0 $mkv.FullName)

  Write-Host ""
  Write-Host "=== $($nas.Name)  ($($rows.Count) audio) ==="
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $title = ($rows[$i] -split ',', 2)[1]
    Write-Host ("  a:{0}  title={1}" -f $i, $(if ($title) { $title } else { '<none>' }))
  }

  $tracks = 0..($rows.Count - 1)
  & python $ident $mkv.FullName --tracks $tracks --start $Start --dur $Dur 2>&1 |
    Where-Object { $_ -notmatch '^loading whisper' }
}
