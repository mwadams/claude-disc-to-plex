<#
  list-discs.ps1 — find MakeMKV's CLI and enumerate optical drives + loaded discs.
  Prints one line per drive that currently has a disc, with its index (for backup-disc.ps1).
  Usage:  pwsh -File list-discs.ps1
#>
$ErrorActionPreference = 'Stop'

function Find-MakeMkv {
  $c = @(
    "C:\Program Files (x86)\MakeMKV\makemkvcon64.exe",
    "C:\Program Files (x86)\MakeMKV\makemkvcon.exe",
    "C:\Program Files\MakeMKV\makemkvcon64.exe",
    "C:\Program Files\MakeMKV\makemkvcon.exe"
  ) | Where-Object { Test-Path $_ } | Select-Object -First 1
  if(-not $c){ $c = (Get-ChildItem "C:\Program Files*\MakeMKV" -Filter "makemkvcon*.exe" -EA SilentlyContinue | Select-Object -First 1).FullName }
  if(-not $c){ throw "makemkvcon not found. Install MakeMKV (https://www.makemkv.com) — it must be registered/licensed." }
  $c
}

$mk = Find-MakeMkv
Write-Host ("makemkvcon: " + $mk) -ForegroundColor Cyan

# robot-mode enumeration. DRV line format:
#   DRV:index,state,flags,drivetype,"drive name","disc name","device path"
# A drive with media loaded has a non-empty disc name (field 6) and/or device path (field 7).
$lines = & $mk -r --cache=1 info disc:9999 2>&1
$found = $false
foreach($l in $lines){
  if($l -match '^DRV:(\d+),(\d+),\d+,\d+,"([^"]*)","([^"]*)","([^"]*)"'){
    $idx=$Matches[1]; $drive=$Matches[3]; $disc=$Matches[4]; $dev=$Matches[5]
    if($disc -or $dev){
      $found = $true
      Write-Host ("  drive {0}: '{1}'  disc: '{2}'  [{3}]" -f $idx,$drive,$disc,$dev) -ForegroundColor Green
    }
  }
}
if(-not $found){
  Write-Host "  No disc detected in any optical drive." -ForegroundColor Yellow
  Write-Host "  Connect the drive and insert a disc, then re-run. (Laptops often use an external USB BD drive.)"
}
