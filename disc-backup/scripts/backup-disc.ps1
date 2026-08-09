<#
  backup-disc.ps1 — decrypt-and-back-up an optical disc to a folder that disc-to-plex consumes.
  Blu-ray -> BDMV/ tree (STREAM/*.m2ts). DVD -> VIDEO_TS/ tree (*.VOB). Uses MakeMKV's backup
  mode with --decrypt (AACS for Blu-ray; CSS handled by MakeMKV / libdvdcss for DVD).

  Usage:
    pwsh -File backup-disc.ps1 -Dest "E:\Movies\<Title> Disk 1" [-Drive 0] [-Cache 16]

  -Dest   destination folder (created; should be empty). Name it the way disc-to-plex expects,
          e.g. "<Show> Disk N" or "<Movie>".
  -Drive  MakeMKV drive index (from list-discs.ps1). Omit to auto-pick the only loaded disc.
#>
param(
  [Parameter(Mandatory)][string]$Dest,
  [int]$Drive = -1,
  [int]$Cache = 16
)
$ErrorActionPreference = 'Stop'

function Find-MakeMkv {
  $c = @("C:\Program Files (x86)\MakeMKV\makemkvcon64.exe","C:\Program Files (x86)\MakeMKV\makemkvcon.exe",
         "C:\Program Files\MakeMKV\makemkvcon64.exe","C:\Program Files\MakeMKV\makemkvcon.exe") |
       Where-Object { Test-Path $_ } | Select-Object -First 1
  if(-not $c){ $c = (Get-ChildItem "C:\Program Files*\MakeMKV" -Filter "makemkvcon*.exe" -EA SilentlyContinue | Select-Object -First 1).FullName }
  if(-not $c){ throw "makemkvcon not found — install MakeMKV and register it (see references/makemkv.md)." }
  $c
}
$mk = Find-MakeMkv

# Auto-detect the loaded disc if no drive index given.
if($Drive -lt 0){
  $discs = @()
  foreach($l in (& $mk -r --cache=1 info disc:9999 2>&1)){
    if($l -match '^DRV:(\d+),(\d+),\d+,\d+,"([^"]*)","([^"]*)","([^"]*)"' -and ($Matches[4] -or $Matches[5])){
      $discs += [pscustomobject]@{ idx=[int]$Matches[1]; disc=$Matches[4] }
    }
    if($l -match 'registration|expired|shareware' ){ Write-Warning "MakeMKV registration issue — run register-makemkv.ps1. ($l)" }
  }
  if($discs.Count -eq 0){ throw "No disc detected. Insert a disc (see list-discs.ps1)." }
  if($discs.Count -gt 1){ throw "Multiple discs loaded: $($discs | ForEach-Object { "$($_.idx)='$($_.disc)'" }). Pass -Drive." }
  $Drive = $discs[0].idx
  Write-Host ("Backing up drive {0}: '{1}'" -f $Drive, $discs[0].disc) -ForegroundColor Cyan
}

New-Item -ItemType Directory -Force $Dest | Out-Null
if((Get-ChildItem $Dest -Force | Measure-Object).Count -gt 0){ Write-Warning "Dest '$Dest' is not empty; MakeMKV may refuse or mix content." }

Write-Host "=== MakeMKV backup --decrypt (this reads the whole disc; can take 20-60+ min) ===" -ForegroundColor Cyan
& $mk backup --decrypt -r --progress=-same --cache=$Cache "disc:$Drive" "$Dest"
$code = $LASTEXITCODE

# Verify: a usable rip has a BDMV/STREAM/*.m2ts tree (Blu-ray) or VIDEO_TS/*.VOB (DVD).
$bd  = Get-ChildItem (Join-Path $Dest "BDMV\STREAM") -Filter *.m2ts -EA SilentlyContinue
$dvd = Get-ChildItem (Join-Path $Dest "VIDEO_TS")    -Filter *.VOB  -EA SilentlyContinue
if($bd)      { Write-Host ("OK — Blu-ray backup: {0} m2ts, {1:N1}GB in {2}" -f $bd.Count, (($bd|Measure-Object Length -Sum).Sum/1GB), $Dest) -ForegroundColor Green }
elseif($dvd) { Write-Host ("OK — DVD backup: {0} VOB, {1:N1}GB in {2}"    -f $dvd.Count,(($dvd|Measure-Object Length -Sum).Sum/1GB), $Dest) -ForegroundColor Green }
else {
  Write-Warning "makemkvcon exit=$code but no BDMV/STREAM or VIDEO_TS found in '$Dest'."
  Write-Warning "If MakeMKV produced .mkv files instead (DVD title mode), disc-to-plex needs a folder backup — see references/makemkv.md."
  exit 1
}
Write-Host "Next: hand this folder to the disc-to-plex skill to transcode." -ForegroundColor Cyan
