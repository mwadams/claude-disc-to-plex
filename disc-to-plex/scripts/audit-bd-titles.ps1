# Audit every Blu-ray on the source drive with MakeMKV and compare its longest titles against
# what we actually shipped.
#
# WHY. Features were selected by taking the largest .m2ts in BDMV/STREAM and reading it with
# ffmpeg. On The Italian Job that produced the 95-minute cut when the disc also carries the full
# 99.5-minute version on a different playlist - and hid two commentary tracks that ffmpeg does not
# expose at all. Neither error is visible from the m2ts alone; MakeMKV reports every title with its
# true runtime and complete stream list in one command.
#
# Read-only. Reports; changes nothing.

param(
  [string]$SrcRoot = 'E:\Movies',
  [string]$NasRoot = '\\NASTEAMV\Multimedia\Movies',
  [string[]]$Discs = @('Zulu','King Lear','Run Lola Run','The Men Who Stare at Goats',
                       'The Ipcress File','In the Line of Fire','Spy Game',
                       'Fantastic 4 - Rise of the Silver Surfer','The Dam Busters','Ratatouille'),
  [string]$MakeMkv = 'C:\Program Files (x86)\MakeMKV\makemkvcon64.exe'
)

$paths = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'

foreach ($d in $Discs) {
  $src = Join-Path $SrcRoot $d
  if (-not (Test-Path -LiteralPath $src)) { Write-Host "$d : not on drive"; continue }

  $info = & $MakeMkv -r --cache=1 info "file:$src" 2>&1
  $titles = @()
  foreach ($line in $info) {
    if ($line -match '^TINFO:(\d+),9,0,"(\d+):(\d\d):(\d\d)"') {
      $titles += [pscustomobject]@{
        Id  = [int]$Matches[1]
        Min = [math]::Round([int]$Matches[2]*60 + [int]$Matches[3] + [int]$Matches[4]/60, 2)
      }
    }
  }
  if (-not $titles) { Write-Host "$d : MakeMKV reported no titles"; continue }

  $longest = ($titles | Sort-Object Min -Descending | Select-Object -First 3)

  # what did we actually ship?
  $shipped = $null
  $nas = Get-ChildItem -LiteralPath $NasRoot -Directory -EA SilentlyContinue |
         Where-Object { $_.Name -like "*$($d -replace ' - .*','')*" } | Select-Object -First 1
  if ($nas) {
    $mkv = Get-ChildItem -LiteralPath $nas.FullName -File -Filter *.mkv -EA SilentlyContinue |
           Sort-Object Length -Descending | Select-Object -First 1
    if ($mkv) {
      $dur = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $mkv.FullName 2>$null)".Trim()
      if ($dur -and $dur -ne 'N/A') { $shipped = [math]::Round([double]$dur/60, 2) }
    }
  }

  $best = $longest[0].Min
  $flag = if ($null -eq $shipped) { 'not found on NAS' }
          elseif ([math]::Abs($best - $shipped) -le 0.5) { 'ok' }
          else { "*** SHIPPED $shipped, DISC HAS $best ***" }

  Write-Host ("{0,-40} titles: {1}   shipped {2}   {3}" -f $d,
    (($longest | ForEach-Object { "$($_.Id)=$($_.Min)m" }) -join ' '),
    $(if ($null -eq $shipped) { '?' } else { "$shipped m" }), $flag)
}
