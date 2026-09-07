<#
.SYNOPSIS
  REFUSE a movie manifest that files an extra into a subfolder Plex does not recognise as a
  local-extras folder - because Plex then scans those files as SEPARATE FILMS.

.WHY THIS EXISTS
  2026-09-07, reported by the operator: "many of these extras have appeared as top level films e.g.
  'snapshot', costume gallery, Mary Ellen, little red book". All four were Moulin Rouge's stills
  galleries, published that afternoon into

      Movies/Moulin Rouge/Still Galleries/

  `Still Galleries` is a perfectly sensible name and it is NOT one of Plex's local-extras folders.
  Plex has a FIXED list; a subfolder outside it is just a directory holding movie files, so the
  scanner indexed each one as a film in its own right. The library gained four bogus entries, one
  of them matched to an unrelated title ("Snapshot: Stills and Poster Gallery with Audio Interview
  with stuntman Grant Page") - which is what a wrong film entry looks like once the agent matcher
  has had a go at it.

  Nothing caught it because every OTHER check passed: the files encoded correctly, verified their
  length, published, byte-matched on the NAS, and the folder name is descriptive and well spelled.
  The defect is only visible against Plex's list, which is exactly the kind of fact that belongs in
  a guard rather than in a reference file people read once.

  references/naming.md has always named the eight valid folders. It was written down and it was
  still got wrong, which is the standing lesson of this project: a rule that can be a check should
  be a check.

.THE LIST
  Plex recognises exactly these, and this library uses the subfolder form throughout:
      Behind The Scenes, Deleted Scenes, Featurettes, Interviews, Other, Scenes, Shorts, Trailers
  Galleries go in `Other/` - the precedent is the Back to the Future films, whose galleries are
  filed as `Other/Gallery - <name>.mkv` and index correctly as local extras.

.NOTES
  MOVIES ONLY. Television uses `Season NN` folders and Season 00 for extras, which is a different
  convention policed by assert-season00-titles-declared.ps1.

  Silent (exit 0) when it cannot judge: a manifest with no movie rows, or rows whose outputs sit
  directly in the film folder (the feature itself), have nothing to check.

.EXAMPLE
  pwsh -NoProfile -File assert-extras-folders-recognised.ps1 -Manifest D:/video/_queue/x.json
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [string]$MoviesRoot = 'D:/video/Movies',
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

# Plex's local-extras folder names. Compared case-insensitively but NOT loosely: "Featurette",
# "Behind the Scenes " and "Trailer" are all misses as far as the scanner is concerned, and a guard
# that normalises them away would pass exactly the manifests it exists to stop.
$valid = @('Behind The Scenes','Deleted Scenes','Featurettes','Interviews','Other','Scenes','Shorts','Trailers')

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Say "assert-extras-folders-recognised: no manifest at $Manifest"; exit 0 }
try { $rows = @(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json) }
catch { Say ("assert-extras-folders-recognised: unreadable manifest ({0}) - not this guard's call to refuse on" -f $_.Exception.Message); exit 0 }

$root = ($MoviesRoot -replace '/','\').TrimEnd('\')
$bad = @(); $judged = 0
foreach ($r in $rows) {
  $o = "$($r.out)" -replace '/','\'
  if (-not $o) { continue }
  if (-not $o.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { continue }

  $rel = $o.Substring($root.Length + 1)
  $parts = @($rel -split '\\')
  # parts[0] = the film folder. A file directly inside it is the feature - nothing to judge.
  if ($parts.Count -le 2) { continue }
  $judged++
  $folder = $parts[1]
  if ($valid -contains $folder) { continue }

  $bad += [pscustomobject]@{ Film = $parts[0]; Folder = $folder; File = $parts[-1] }
}

if (-not $judged) { Say 'assert-extras-folders-recognised: no movie extras in this manifest - nothing to check'; exit 0 }

if (-not $bad.Count) {
  Say ("assert-extras-folders-recognised: OK - all {0} movie extra(s) are in a Plex local-extras folder" -f $judged)
  exit 0
}

Say ("assert-extras-folders-recognised: REFUSED - {0} of {1} movie extra(s) would be filed where Plex does not look:" -f $bad.Count, $judged)
foreach ($g in ($bad | Group-Object Film)) {
  Say ("   {0}" -f $g.Name)
  foreach ($b in $g.Group) { Say ("      {0}\{1}" -f $b.Folder, $b.File) }
}
Say ''
Say ("   Plex recognises ONLY: {0}" -f ($valid -join ', '))
Say  '   Anything else is scanned as a SEPARATE FILM - Moulin Rouge''s "Still Galleries" put four'
Say  '   stills galleries into the Films library as titles in their own right (2026-09-07).'
Say  '   Galleries belong in Other\ - see the Back to the Future films, "Other\Gallery - <name>.mkv".'
exit 2
