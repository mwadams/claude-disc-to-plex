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

# ---- what did we actually ship? ------------------------------------------------------------
$workDir = Join-Path (Join-Path $NasRoot $Kind) $Work
if(-not (Test-Path -LiteralPath $workDir)){ throw "work not found on the NAS: $workDir" }
$all     = @(Get-ChildItem -LiteralPath $workDir -Recurse -File -Filter *.mkv)
$feature = @($all | Where-Object { $_.DirectoryName -eq $workDir })
$extras  = @($all | Where-Object { $_.DirectoryName -ne $workDir })
Write-Output ("$Work : {0} feature file(s), {1} extra file(s) on the NAS" -f $feature.Count, $extras.Count)

# ---- find it in Plex, by FILE PATH -----------------------------------------------------------
# Match on path, not title: the agent's title legitimately differs from the folder (a Bel Air ballet
# disc matched under a much longer name). Search by title first because a full section walk is one
# request per item; fall back to the walk only if that misses.
function Test-Match($ratingKey){
  $d = Get-PlexXml "/library/metadata/$ratingKey"
  $parts = @($d.MediaContainer.Video.Media.Part) | ForEach-Object { $_.file }
  [bool]($parts | Where-Object { $_ -and ($_ -replace '/','\') -like "*\$Work\*" })
}
$hit = $null; $hitKey = $null
$titleGuess = ($Work -replace '\s*\(\d{4}\)\s*$','')
try {
  $s = Get-PlexXml ("/library/sections/$section/all?title=" + [uri]::EscapeDataString($titleGuess))
  foreach($v in @($s.MediaContainer.Video)){
    if($v -and (Test-Match $v.ratingKey)){ $hit = $v; $hitKey = $v.ratingKey; break }
  }
} catch { }
if(-not $hitKey){
  Write-Output "title search missed - walking the section (slow)"
  $r = Get-PlexXml "/library/sections/$section/all"
  foreach($v in @($r.MediaContainer.Video)){
    if(Test-Match $v.ratingKey){ $hit = $v; $hitKey = $v.ratingKey; break }
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
