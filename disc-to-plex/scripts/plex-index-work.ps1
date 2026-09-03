<#
.SYNOPSIS
  Force the Plex item refresh for a published work, then CHECK that every shipped extra indexed.

.WHY THIS EXISTS
  Local movie extras do NOT appear from a library section scan. They index only after a forced
  ITEM refresh:  PUT /library/metadata/<ratingKey>/refresh?force=1

  That was known, written down, and still skipped on a disc - because it was a step to remember per
  work rather than part of the publish. On Stravinsky and the Ballets Russes (2026-08-22) one of two
  extras sat on the NAS, byte-verified, with the accounting gate passing and nothing anywhere
  reporting a fault. It surfaced only because the USER counted and said "its ONE extra is on Plex"
  when two had shipped. Without that, a shipped extra would have stayed invisible indefinitely.

  So this does the refresh AND reads back the count. The refresh alone is not evidence: it returns
  200 whether or not anything indexed. The comparison against what is on the NAS is what can fail.

.WHY XML AND NOT JSON
  Plex's per-item response carries BOTH `guid` and `Guid`. PowerShell's ConvertFrom-Json refuses
  keys differing only by case - and `Invoke-RestMethod`, which converts implicitly, does NOT throw:
  it hands back an object with EMPTY fields. The first version of this script matched nothing and
  reported "NOT FOUND in Plex" for a film that was plainly there. Use XML for anything that reads a
  single item; section listings happen to be safe, but XML costs nothing there either.

.EXAMPLE
  pwsh -File plex-index-work.ps1 -Work "Serenity (2005)" -Kind Movies
#>
param(
  [Parameter(Mandatory)][string]$Work,
  [ValidateSet('Movies','TV')][string]$Kind = 'Movies',
  [string]$NasRoot = '\\NASTEAMV\Multimedia',
  [int]$WaitSeconds = 45
)
$ErrorActionPreference = 'Stop'
$token = [Environment]::GetEnvironmentVariable('PLEX_TOKEN','User')
$base  = [Environment]::GetEnvironmentVariable('PLEX_BASEURL','User')
if(-not $token -or -not $base){ throw "PLEX_TOKEN / PLEX_BASEURL not set for this user" }
$section = if($Kind -eq 'Movies'){ 6 } else { 5 }
$hdr = @{ 'X-Plex-Token' = $token }
function Get-PlexXml($path){ [xml](Invoke-WebRequest -Uri "$base$path" -Headers $hdr).Content }

# ---- resolve the NAS folder name from PLEX'S OWN CONFIG, not a second guess -----------------
#
# This used to build the folder as `Join-Path $NasRoot $Kind` - i.e. assume the on-disk folder is
# literally named "Movies" or "TV". That happened to be right for films (the folder IS "Movies")
# and wrong for television, whose real folder is "Television Shows" - so this threw on every TV
# work, and because publish-work.ps1 only text-matched a couple of expected phrases in the output
# instead of checking the child's exit code, the failure never reached anyone (see there for the
# `NOT FOUND`/"not found" note). Broken since this script was written (2026-08-22); TV reindexing
# has never worked before this fix.
#
# Fix: ask Plex's `/library/sections` for THIS section's configured Location path - that is the
# actual root the server itself scans, not a name this script has to keep in sync by hand. The NAS
# reports it QNAP-style (`/share/CACHEDEV1_DATA/Multimedia/Television Shows`); the last path
# segment is the folder name under $NasRoot on the Windows side.
$sections = Get-PlexXml '/library/sections'
$sectionDir = @($sections.MediaContainer.Directory) | Where-Object { $_.key -eq [string]$section }
if(-not $sectionDir){ throw "Plex section $section not found in /library/sections at $base - check the section number / PLEX_BASEURL" }
$locPath = @($sectionDir.Location)[0].path
if(-not $locPath){ throw "Plex section $section ($($sectionDir.title)) has no configured Location in /library/sections" }
$folderName = @(($locPath -replace '\\','/') -split '/' | Where-Object { $_ }) | Select-Object -Last 1
Write-Output ("section {0} = '{1}', NAS location '{2}' -> folder '{3}'" -f $section, $sectionDir.title, $locPath, $folderName)

# ---- what did we actually ship? ------------------------------------------------------------
$workDir = Join-Path (Join-Path $NasRoot $folderName) $Work
if(-not (Test-Path -LiteralPath $workDir)){ throw "work not found on the NAS: $workDir" }
$all = @(Get-ChildItem -LiteralPath $workDir -Recurse -File -Filter *.mkv)
if($Kind -eq 'Movies'){
  # Movie folder shape: the top-level file IS the feature; anything in a subfolder is an extra.
  $feature = @($all | Where-Object { $_.DirectoryName -eq $workDir })
  $extras  = @($all | Where-Object { $_.DirectoryName -ne $workDir })
} else {
  # TV folder shape is NOT the movie shape - every episode lives one level down in a "Season NN"
  # subfolder, so "anything not at the top level" would count every ordinary episode as an "extra"
  # and this check would fail on almost every TV work that has episodes at all (Plex's /extras
  # endpoint, read below, never lists regular episodes - only genuine local extras). Episodes,
  # including Season 00 specials, are indexed by a normal library scan same as any TV show; this
  # script's forced-refresh is only needed for a genuine LOCAL EXTRA folder under the show.
  #
  # Same vocabulary as the edition/extras guards elsewhere in this skill (assert-edition-layout.ps1,
  # catalogue-disc.ps1, publish-work.ps1) - not re-derived, so a folder that counts as "extras" for
  # the publish gate counts as "extras" here too.
  $extraDirNames = @('behind the scenes','featurettes','trailers','interviews','scenes',
                      'shorts','deleted scenes','other','extras')
  $extras = @($all | Where-Object {
    $rel = $_.DirectoryName.Substring($workDir.Length).TrimStart([char]92)
    $seg = @($rel -split [regex]::Escape([string][char]92))
    $seg.Count -ge 1 -and $extraDirNames -contains $seg[0].ToLowerInvariant()
  })
  $feature = @($all | Where-Object { $extras.FullName -notcontains $_.FullName })
}
Write-Output ("$Work : {0} episode/feature file(s), {1} local-extra file(s) on the NAS" -f $feature.Count, $extras.Count)

# ---- find it in Plex ---------------------------------------------------------------------------
# MOVIES: match on FILE PATH, not title - the agent's title legitimately differs from the folder (a
# Bel Air ballet disc matched under a much longer name). A movie section's `/all` returns <Video>
# elements directly, and each item's own metadata carries its file path under Media/Part/file.
#
# TV: a TV section's `/all` returns <Directory type="show"> elements, not <Video> - a show is a
# container, not a file, so there is no Media/Part to match on. Its own metadata DOES carry
# <Location path="..."> though (the show's root folder), which is exactly as reliable an identity
# check as the movie file-path match and comes from the same per-item metadata fetch.
#
# Getting this wrong is not cosmetic: `@($x.Video)` on a TV listing (no <Video> children at all)
# evaluates to `@($null)` - an ARRAY OF ONE NULL, not an empty array - so an unguarded loop over it
# calls Test-Match on a null item, which requests `/library/metadata/` with an EMPTY ratingKey and
# 404s. That is a second, independent defect behind the folder-path one: fixing only the path still
# leaves TV throwing, just later and less legibly.
#
# Search by title first because a full section walk is one request per item; fall back to the walk
# only if that misses.
$nodeName = if($Kind -eq 'Movies'){ 'Video' } else { 'Directory' }
function Test-Match($ratingKey){
  $d = Get-PlexXml "/library/metadata/$ratingKey"
  $parts = @($d.MediaContainer.Video.Media.Part)     | ForEach-Object { $_.file }
  $locs  = @($d.MediaContainer.Directory.Location)   | ForEach-Object { $_.path }
  $candidates = @($parts + $locs) | Where-Object { $_ }
  foreach($c in $candidates){
    $cn = $c -replace '/','\'
    if($cn -like "*\$Work\*" -or $cn -like "*\$Work"){ return $true }
  }
  return $false
}
$hit = $null; $hitKey = $null
$titleGuess = ($Work -replace '\s*\(\d{4}\)\s*$','')
try {
  $s = Get-PlexXml ("/library/sections/$section/all?title=" + [uri]::EscapeDataString($titleGuess))
  foreach($v in @($s.MediaContainer.$nodeName)){
    if($v -and $v.ratingKey -and (Test-Match $v.ratingKey)){ $hit = $v; $hitKey = $v.ratingKey; break }
  }
} catch { }
if(-not $hitKey){
  Write-Output "title search missed - walking the section (slow)"
  $r = Get-PlexXml "/library/sections/$section/all"
  foreach($v in @($r.MediaContainer.$nodeName)){
    if($v -and $v.ratingKey -and (Test-Match $v.ratingKey)){ $hit = $v; $hitKey = $v.ratingKey; break }
  }
}
if(-not $hitKey){
  Write-Output "*** NOT FOUND in Plex section $section - trigger a section scan first ***"
  exit 2
}
Write-Output ("plex item: {0} ({1})  ratingKey {2}" -f $hit.title, $hit.year, $hitKey)

# ---- force the ITEM refresh ------------------------------------------------------------------
Invoke-WebRequest -Method Put -Uri "$base/library/metadata/$hitKey/refresh?force=1" -Headers $hdr | Out-Null
Write-Output "forced item refresh - waiting $WaitSeconds s"
Start-Sleep -Seconds $WaitSeconds

# ---- read back, and COUNT ---------------------------------------------------------------------
$e = Get-PlexXml "/library/metadata/$hitKey/extras"
$listed = @($e.MediaContainer.Video)
# Plex supplies its own online trailers and clips. Those carry no local file part; ours do, so
# counting only local ones stops a Plex-supplied trailer masking one of ours that failed to index.
$local = @($listed | Where-Object { @($_.Media.Part) | Where-Object { $_.file } })
Write-Output ("plex extras: {0} total, {1} local" -f $listed.Count, $local.Count)
$local | ForEach-Object { Write-Output ("    {0,-14} {1}" -f $_.subtype, $_.title) }

if($local.Count -lt $extras.Count){
  Write-Output ""
  Write-Output ("*** {0} SHIPPED EXTRA(S) DID NOT INDEX ***" -f ($extras.Count - $local.Count))
  $seen = @($local | ForEach-Object { $_.title })
  foreach($f in $extras){ if($seen -notcontains $f.BaseName){ Write-Output ("    missing: {0}" -f $f.BaseName) } }
  Write-Output "Re-run this script; if it persists, Plex may not be able to read the file, or it is misnamed."
  exit 2
}
Write-Output ""
Write-Output "OK - every shipped extra is indexed."
exit 0
