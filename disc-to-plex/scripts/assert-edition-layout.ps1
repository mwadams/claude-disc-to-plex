<#
.SYNOPSIS
  Refuse a manifest that puts an {edition-...} file in a movie folder which also ships local extras.

.WHY
  Measured on this server, 2026-08-27:

    Who Dares Wins (1982) - edition in its OWN top-level folder -> 2 library items, 4/4 local extras indexed
    M (1931)              - edition INSIDE the film's folder    -> 1 library item,  0/1 local extras indexed

  M's `Interviews/Zum Beispiel Fritz Lang (1968).mkv` is on the NAS and Plex indexes no local extras
  for that item at all. Multiple editions in one movie folder stop Plex detecting that movie's local
  extras - they vanish from the UI while the files sit on disk looking perfectly healthy.

  This is worth a guard rather than a paragraph because the prose already existed and was overruled.
  On 2026-08-26 an agent laid M out correctly and I "fixed" it into the film's folder, because the
  single-folder layout looks tidier and the reference said both things in different sections. The
  cost is invisible: nothing errors, the publish verifies, and the extras are simply not there.

  So: when a film has local extras, the edition goes in its own top-level folder. The duplicate
  library entry that costs is VISIBLE and gets reported; missing extras are not.

  Checked at gate time because that is the last point where the fix is a one-line edit to `out`
  rather than a re-encode plus a NAS deletion only the user can perform.

.EXAMPLE
  pwsh -File assert-edition-layout.ps1 -Manifest D:/video/_manifests/sunrise.json
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [string]$MoviesRoot = 'D:/video/Movies'
)

$ErrorActionPreference = 'Stop'

# Plex's local-extra folder names. An output under any of these is an extra of the movie folder
# above it - which is exactly what an in-folder edition suppresses.
$extraDirs = @('behind the scenes', 'featurettes', 'trailers', 'interviews', 'scenes',
               'shorts', 'deleted scenes', 'other', 'extras')

$items = Get-Content -LiteralPath $Manifest -Raw -Encoding UTF8 | ConvertFrom-Json
if ($items -isnot [array]) { $items = @($items) }

$rootNorm = ($MoviesRoot -replace '\\', '/').TrimEnd('/').ToLowerInvariant()

# work folder -> what it contains
$hasEdition = @{}
$hasExtras  = @{}
$label      = @{}

foreach ($it in $items) {
  if (-not $it.out) { continue }
  $p = "$($it.out)" -replace '\\', '/'
  if (-not $p.ToLowerInvariant().StartsWith($rootNorm + '/')) { continue }   # movies only

  $rel   = $p.Substring($rootNorm.Length + 1)
  $parts = $rel -split '/'
  if ($parts.Count -lt 2) { continue }          # a loose file directly under Movies/
  $work  = $parts[0]
  $key   = $work.ToLowerInvariant()
  $label[$key] = $work

  if ($parts.Count -eq 2) {
    # directly in the work folder
    if ($parts[1] -match '\{edition-') { $hasEdition[$key] = $true }
  } else {
    # nested - an extra if the subfolder is one Plex recognises
    if ($extraDirs -contains $parts[1].ToLowerInvariant()) { $hasExtras[$key] = $true }
  }
}

$bad = @($hasEdition.Keys | Where-Object { $hasExtras[$_] })

if ($bad.Count -eq 0) {
  Write-Output "edition layout OK - $(Split-Path $Manifest -Leaf)"
  exit 0
}

foreach ($k in $bad) {
  $w = $label[$k]
  Write-Output "REFUSE  '$w' ships local extras AND an {edition-...} file in the same folder."
  Write-Output "        Plex will index ZERO local extras for it (proved on M (1931), 2026-08-27)."
  Write-Output "        Fix: move the edition to its own top-level folder, e.g."
  Write-Output "          $MoviesRoot/$w {edition-<Name>}/$w {edition-<Name>}.mkv"
  Write-Output "        Leave the feature and every extras subfolder in '$w'."
}
Write-Output "See references/naming.md - 'Editions: BOTH layouts cost you something'."
exit 1
