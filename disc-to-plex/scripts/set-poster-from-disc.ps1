<#
.SYNOPSIS
  Upload a disc's own cover art to Plex as the poster for a movie or show.

.WHY
  Obscure archive titles (Imperial War Museum documentaries, regional-TV releases,
  privately-issued sets) frequently get NO agent match — Plex creates them as
  `local://` items with a generic grey placeholder or a frame grab. The rip folder
  usually carries the real retail cover art, put there by MyMovies:

      folder.jpg           <- the cover as MyMovies stored it (usually front)
      mymovies-front.jpg   <- explicit front cover  (hidden attribute)
      mymovies-back.jpg    <- rear cover, NOT wanted as a poster

  Uploaded posters auto-select and are sticky across refreshes, so no lock is needed.

  `mymovies-front.jpg` is used FIRST because it is the full-resolution scan, while
  `folder.jpg` is a downscaled thumbnail — on Advanced Base they are 762x1079 vs
  360x510. Pass -PreferFolderJpg only if a particular disc's front scan is bad.

.NOTES
  - The disc folder may live on the SOURCE drive (read-only use — never write there).
  - Verify the result: a poster narrower than ~200px means only a thumbnail was
    available; point -Image at better art if you have it.
  - PLEX_TOKEN / PLEX_BASEURL are read from the User environment if the process env
    is empty (child shells started before the vars were set inherit a stale env).

.EXAMPLE
  pwsh -File set-poster-from-disc.ps1 -RatingKey 24940 -DiscDir "E:\Movies\Advanced Base"

.EXAMPLE
  # find the item by title instead of knowing its ratingKey
  pwsh -File set-poster-from-disc.ps1 -Title "Advanced Base" -Section 6 -DiscDir "E:\Movies\Advanced Base"

.EXAMPLE
  # check what would be used, without changing anything
  pwsh -File set-poster-from-disc.ps1 -Title "Beasts" -Section 5 -DiscDir "E:\Movies\Beasts Disk 1" -WhatIf
#>
param(
  [int]$RatingKey = 0,                       # Plex ratingKey of the movie/show (skip lookup)
  [string]$Title,                            # ...or match by title
  [int]$Section = 6,                         # 6 = Films, 5 = TV programmes
  [string]$DiscDir,                          # rip folder holding folder.jpg / mymovies-front.jpg
  [string]$Image,                            # explicit image path, overrides DiscDir discovery
  [switch]$PreferFolderJpg,                  # use folder.jpg first (default is the higher-res front cover)
  [switch]$WhatIf                            # report what would be uploaded, change nothing
)

$ErrorActionPreference = 'Stop'
function Env-Fallback($n){ $v=[Environment]::GetEnvironmentVariable($n,'Process'); if(-not $v){ $v=[Environment]::GetEnvironmentVariable($n,'User') }; $v }
$tok  = Env-Fallback 'PLEX_TOKEN'
$base = Env-Fallback 'PLEX_BASEURL'
if(-not $tok -or -not $base){ throw "PLEX_TOKEN / PLEX_BASEURL not set (User or Process env)." }
$h = @{ "X-Plex-Token"=$tok; "Accept"="application/json" }

# --- resolve the target item ---
if(-not $RatingKey){
  if(-not $Title){ throw "Pass -RatingKey or -Title." }
  $type = if($Section -eq 5){ 2 } else { 1 }          # 2 = show, 1 = movie
  $all  = @((Invoke-RestMethod "$base/library/sections/$Section/all?type=$type" -Headers $h).MediaContainer.Metadata)
  $hit  = $all | Where-Object { $_.title -like "*$Title*" -and $_.ratingKey } | Select-Object -First 1
  if(-not $hit){ throw "No item matching '$Title' in section $Section." }
  $RatingKey = $hit.ratingKey
  Write-Host "Matched '$($hit.title)' ($($hit.year))  rk=$RatingKey"
}

# --- pick the image ---
if(-not $Image){
  if(-not $DiscDir){ throw "Pass -Image or -DiscDir." }
  if(-not (Test-Path -LiteralPath $DiscDir)){ throw "DiscDir not found: $DiscDir" }
  # -Force: mymovies-*.jpg are HIDDEN in these rips and are invisible without it.
  # Deliberately never consider mymovies-back.jpg — a rear cover is not a poster.
  $order = if($PreferFolderJpg){ 'folder.jpg','mymovies-front.jpg' } else { 'mymovies-front.jpg','folder.jpg' }
  foreach($cand in $order){
    $f = Get-ChildItem -LiteralPath $DiscDir -Filter $cand -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    if($f){ $Image = $f.FullName; break }
  }
  if(-not $Image){ throw "No folder.jpg or mymovies-front.jpg in $DiscDir" }
}
if(-not (Test-Path -LiteralPath $Image)){ throw "Image not found: $Image" }

# -Force again: mymovies-front.jpg is HIDDEN, and Get-Item won't resolve a hidden
# file without it (it fails with "Could not find item" even though it exists).
$info = Get-Item -LiteralPath $Image -Force
Add-Type -AssemblyName System.Drawing
$dim = try { $img=[System.Drawing.Image]::FromFile($info.FullName); $d="$($img.Width)x$($img.Height)"; $img.Dispose(); $d } catch { 'unknown' }
Write-Host ("Image: {0}  ({1:N0} bytes, {2})" -f $info.Name, $info.Length, $dim)
if($dim -match '^(\d+)x' -and [int]$Matches[1] -lt 200){
  Write-Warning "That is thumbnail-sized. Consider -Front, or point -Image at better art."
}

if($WhatIf){ Write-Host "WhatIf: would upload to rk=$RatingKey"; return }

Invoke-RestMethod "$base/library/metadata/$RatingKey/posters?X-Plex-Token=$tok" `
  -Method Post -InFile $info.FullName -ContentType 'image/jpeg' | Out-Null

$p = (Invoke-RestMethod "$base/library/metadata/$RatingKey/posters" -Headers $h).MediaContainer.Metadata
$sel = $p | Where-Object { $_.selected -eq 1 } | Select-Object -First 1
Write-Host ("Uploaded. selected poster provider='{0}' key={1}" -f $sel.provider, $sel.key)
