<#
.SYNOPSIS
  Set AND LOCK a movie's title, summary and release date in Plex, for films whose correct identity
  no online agent can supply.

.WHY
  `apply-plex-titles.ps1` does this for EPISODES and hard-codes `type=4` throughout, so it cannot
  touch a movie. Concert films, industrial films, home-video compilations and disc-specific cuts
  have no canonical TMDB entry, so Plex's agent guesses - and it guesses badly. Measured on this
  server, 2026-09-06, after seven Led Zeppelin concerts were rehoused into their own folders:

    Led Zeppelin - Earls Court 1975   -> matched as "Led Zeppelin: In The Court Of King James"
    Led Zeppelin - Danish TV.mkv      -> matched as "Led Zeppelin: French TV Broadcast"
    Led Zeppelin DVD (2003)           -> matched as "Led Zeppelin"

  A bootleg title, a swap between two different concerts, and a bare band name.

.WHY IT LOCKS FOUR FIELDS AND NOT ONE
  Plex assigns title, summary, poster and release date TOGETHER, as one guess. Correcting only the
  title leaves three fields describing a DIFFERENT film and makes them conspicuous rather than
  hiding them - the user's report on an earlier pass was that "the descriptions are anomalous", from
  exactly that. So this writes and locks the text fields together, and refuses to write a title
  without a summary.

  Locks are what stop the next agent refresh reverting the lot. NOTE: a lock is readable ONLY in the
  item's own XML as <Field name="title" locked="1" />. The /children JSON omits the Field elements
  entirely, so anything reading locks from there sees every item as unlocked - this project once
  asserted "not one of 53 is locked" from a field that could never have said otherwise. This script
  verifies by re-reading the item XML.

.WHAT IT REFUSES
  * An item whose media parts live in MORE THAN ONE folder. Plex merges same-named files into one
    item as multiple versions, so mid-migration an item can hold both the old and the new file. That
    is a real state, and writing metadata onto it is guessing which film you meant - so it refuses
    unless -AllowMultiFolder says the merge is understood and intended.
  * A folder that matches no item, or more than one.
  * A row with no summary (see above).

.EXAMPLE
  pwsh -File pin-plex-movie-metadata.ps1 -Data D:/video/_pending/led-zeppelin-plex.json -WhatIf
  pwsh -File pin-plex-movie-metadata.ps1 -Data D:/video/_pending/led-zeppelin-plex.json
#>
param(
  [Parameter(Mandatory)][string]$Data,
  [int]$Section = 6,
  [switch]$AllowMultiFolder,
  [switch]$WhatIf,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

function Get-FolderOf {
  <# The folder segment a Plex Part.file sits in. Plex reports ITS OWN path
     (/share/CACHEDEV1_DATA/...), never ours, so only the trailing segments are comparable - and the
     folder, not the leaf, is what identifies the work here. #>
  param([Parameter(Mandatory)][string]$PartFile)
  $norm = "$PartFile" -replace '\\', '/'
  $segs = @($norm -split '/' | Where-Object { $_ })
  if ($segs.Count -lt 2) { return '' }
  return $segs[$segs.Count - 2]
}

function Test-MetadataRow {
  param([Parameter(Mandatory)]$Row, [int]$Index)
  if (-not "$($Row.folder)".Trim())  { return "row[$Index] has no folder" }
  if (-not "$($Row.title)".Trim())   { return "row[$Index] ($($Row.folder)) has no title" }
  # Deliberate: a locked title beside an inherited summary is WORSE than leaving both wrong,
  # because the mismatch then looks authoritative.
  if (-not "$($Row.summary)".Trim()) { return "row[$Index] ($($Row.folder)) has no summary - Plex assigns title and summary as one guess, so correcting only the title leaves a summary describing a different film" }
  if ("$($Row.date)".Trim() -and "$($Row.date)" -notmatch '^\d{4}-\d{2}-\d{2}$') { return "row[$Index] ($($Row.folder)) date '$($Row.date)' is not yyyy-MM-dd" }
  return $null
}

if ($SelfTest) {
  $fail = 0
  function T($n, $c) { if ($c) { "  ok   $n" } else { $script:fail++; "  FAIL $n" } }
  T 'folder from unix path'   ((Get-FolderOf '/share/CACHEDEV1_DATA/Multimedia/Movies/X (1975)/X (1975).mkv') -eq 'X (1975)')
  T 'folder from unc path'    ((Get-FolderOf '\\NAS\Multimedia\Movies\Y\Y.mkv') -eq 'Y')
  T 'folder too shallow'      ((Get-FolderOf 'x.mkv') -eq '')
  T 'row ok'                  ($null -eq (Test-MetadataRow ([pscustomobject]@{folder='f';title='t';summary='s'}) 0))
  T 'row no folder'           ((Test-MetadataRow ([pscustomobject]@{title='t';summary='s'}) 0) -match 'no folder')
  T 'row no title'            ((Test-MetadataRow ([pscustomobject]@{folder='f';summary='s'}) 0) -match 'no title')
  T 'row no summary'          ((Test-MetadataRow ([pscustomobject]@{folder='f';title='t'}) 0) -match 'no summary')
  T 'row bad date'            ((Test-MetadataRow ([pscustomobject]@{folder='f';title='t';summary='s';date='1975'}) 0) -match 'not yyyy-MM-dd')
  T 'row good date'           ($null -eq (Test-MetadataRow ([pscustomobject]@{folder='f';title='t';summary='s';date='1975-05-24'}) 0))
  if ($fail) { "SELFTEST FAILED - $fail case(s)"; exit 1 }
  'SELFTEST OK'; exit 0
}

$token = [Environment]::GetEnvironmentVariable('PLEX_TOKEN','User')
$base  = [Environment]::GetEnvironmentVariable('PLEX_BASEURL','User')
if (-not $token -or -not $base) { Write-Output 'REFUSE - PLEX_TOKEN / PLEX_BASEURL not set for this user'; exit 2 }
$hdr = @{ 'X-Plex-Token' = $token }

$rows = @(Get-Content -LiteralPath $Data -Raw -Encoding UTF8 | ConvertFrom-Json)
$problems = @()
for ($i = 0; $i -lt $rows.Count; $i++) { $p = Test-MetadataRow $rows[$i] $i; if ($p) { $problems += $p } }
if ($problems.Count) { Write-Output "REFUSE - $($problems.Count) problem(s):"; $problems | ForEach-Object { Write-Output "    $_" }; exit 2 }

# ONE section fetch, then map folder -> item.
$all = [xml](Invoke-WebRequest -Uri "$base/library/sections/$Section/all?type=1" -Headers $hdr -TimeoutSec 120).Content
$byFolder = @{}
foreach ($v in $all.MediaContainer.Video) {
  $folders = @($v.Media.Part | ForEach-Object { Get-FolderOf $_.file } | Where-Object { $_ } | Sort-Object -Unique)
  foreach ($f in $folders) {
    if (-not $byFolder.ContainsKey($f)) { $byFolder[$f] = @() }
    $byFolder[$f] += [pscustomobject]@{ Key = $v.ratingKey; Title = $v.title; Folders = $folders }
  }
}

$set = 0; $skipped = 0; $failed = 0
foreach ($row in $rows) {
  $folder = "$($row.folder)".Trim()
  $hits = @($byFolder[$folder])
  if (-not $hits -or $hits.Count -eq 0) { Write-Output "  MISS    $folder - no Plex movie has a media part in this folder (not indexed yet?)"; $skipped++; continue }
  if ($hits.Count -gt 1) { Write-Output "  AMBIG   $folder - $($hits.Count) items claim it: $((($hits | ForEach-Object { $_.Key }) -join ', '))"; $skipped++; continue }
  $hit = $hits[0]

  if ($hit.Folders.Count -gt 1 -and -not $AllowMultiFolder) {
    Write-Output "  REFUSE  $folder -> [$($hit.Key)] '$($hit.Title)' also holds parts in: $((@($hit.Folders) | Where-Object { $_ -ne $folder }) -join ', ')"
    Write-Output "          Plex merged several files into one item, so this metadata would describe more than one film."
    Write-Output "          Retire the superseded folder first, or pass -AllowMultiFolder if the merge is intended."
    $skipped++; continue
  }

  $q = "type=1&id=$($hit.Key)"
  $q += "&title.value=$([uri]::EscapeDataString("$($row.title)"))&title.locked=1"
  $q += "&summary.value=$([uri]::EscapeDataString("$($row.summary)"))&summary.locked=1"
  if ("$($row.date)".Trim()) {
    $q += "&originallyAvailableAt.value=$([uri]::EscapeDataString("$($row.date)"))&originallyAvailableAt.locked=1"
    $q += "&year.value=$(("$($row.date)" -split '-')[0])&year.locked=1"
  } elseif ("$($row.year)".Trim()) {
    $q += "&year.value=$([uri]::EscapeDataString("$($row.year)"))&year.locked=1"
  }

  if ($WhatIf) { Write-Output ("  WOULD   [{0}] '{1}' -> '{2}'" -f $hit.Key, $hit.Title, $row.title); $set++; continue }

  try { Invoke-RestMethod -Uri "$base/library/metadata/$($hit.Key)?$q" -Headers $hdr -Method Put -TimeoutSec 60 | Out-Null }
  catch { Write-Output "  FAILED  $folder - PUT threw: $($_.Exception.Message)"; $failed++; continue }

  # VERIFY FROM THE ITEM XML. The /children JSON omits Field elements, so locks are invisible there.
  $back = [xml](Invoke-WebRequest -Uri "$base/library/metadata/$($hit.Key)" -Headers $hdr -TimeoutSec 60).Content
  $vv = $back.MediaContainer.Video
  $locked = @($vv.Field | Where-Object { $_.locked -eq '1' } | ForEach-Object { $_.name })
  $okTitle = ("$($vv.title)" -eq "$($row.title)")
  $okLock  = ($locked -contains 'title')
  if ($okTitle -and $okLock) {
    Write-Output ("  SET     [{0}] {1}   (locked: {2})" -f $hit.Key, $row.title, ($locked -join ', '))
    $set++
  } else {
    Write-Output ("  FAILED  [{0}] reads back as '{1}', locked: {2}" -f $hit.Key, $vv.title, ($locked -join ', '))
    $failed++
  }
}

Write-Output ""
Write-Output ("pin-plex-movie-metadata: {0} set, {1} skipped, {2} failed" -f $set, $skipped, $failed)
if ($failed) { exit 1 }
exit 0
