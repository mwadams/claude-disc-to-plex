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
$rootFilms  = @{}   # work -> the movie files this manifest puts in the folder ROOT

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
    # COUNT THEM ALL, not just {edition-} ones. Plex does not care WHY a movie folder holds more
    # than one movie file - it stops indexing that folder's local extras either way.
    #
    # `Movies/Led Zeppelin/` on 2026-09-06: EIGHT concert films flat in the folder root
    # (Royal Albert Hall, Earls Court, Knebworth, two Madison Square Garden parts, Supershow,
    # Danish TV, French TV) beside a `Featurettes/` subfolder holding fifteen extras. None carried
    # an `{edition-}` tag, so this guard - which looked only for that tag - passed the manifest, and
    # every one of those featurettes is invisible in Plex while sitting healthy on disk. The user:
    # "a recurrence of the Plex issue that none of the featurettes appear because of the multiple
    # files in the root for the Movie."
    #
    # The tag was never the cause; it was just the shape the first instance happened to take. The
    # rule is about COUNT.
    if ([IO.Path]::GetExtension($parts[1]).ToLowerInvariant() -in '.mkv', '.mp4', '.avi') {
      if (-not $rootFilms.ContainsKey($key)) { $rootFilms[$key] = @() }
      $rootFilms[$key] += $parts[1]
    }
  } else {
    # nested - an extra if the subfolder is one Plex recognises
    if ($extraDirs -contains $parts[1].ToLowerInvariant()) { $hasExtras[$key] = $true }
  }
}

$bad = @($hasEdition.Keys | Where-Object { $hasExtras[$_] })
# The general case: extras plus MORE THAN ONE film in the root, tagged or not.
$crowded = @($rootFilms.Keys | Where-Object { $hasExtras[$_] -and @($rootFilms[$_]).Count -gt 1 })

if ($crowded.Count -gt 0) {
  foreach ($k in $crowded) {
    $w = $label[$k]
    $files = @($rootFilms[$k])
    Write-Output ("REFUSE  '{0}' ships local extras AND {1} movie files in the folder ROOT." -f $w, $files.Count)
    foreach ($f in ($files | Select-Object -First 8)) { Write-Output "          $f" }
    Write-Output "        Plex treats each root file as a separate movie and then indexes ZERO local"
    Write-Output "        extras for that folder - the extras sit on disk looking healthy and are simply"
    Write-Output "        not in the UI. Measured on Movies/Led Zeppelin, 2026-09-06: 8 concert films in"
    Write-Output "        the root, 15 Featurettes, none visible."
    Write-Output "        Fix: ONE film per folder. Each concert/feature gets its own top-level folder,"
    Write-Output "        and the extras subfolders live under the one they belong to, e.g."
    Write-Output "          $MoviesRoot/$w - Knebworth (1979)/$w - Knebworth (1979).mkv"
    Write-Output "          $MoviesRoot/$w - Knebworth (1979)/Featurettes/..."
  }
  Write-Output "See references/naming.md - a movie folder holds ONE movie."
  exit 1
}

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
