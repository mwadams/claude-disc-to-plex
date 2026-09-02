<#
.SYNOPSIS
  Force Plex to display OUR filename-derived episode titles (locked), for a show/season.

.DESCRIPTION
  The Plex agent (tv.plex.agents.series) injects its OWN metadata by episode number. For a
  show's **Season 00 (Specials)** this is almost always wrong: the agent has a short list of
  canonical "specials" (reunion panels, docs) that have nothing to do with the DVD bonus features
  we ripped and carefully named. It labels the first few S00 slots with those, and the rest as
  "Episode N". Our real titles live in the filenames (`... - S00E04 - Secrets of Quark's Bar.mkv`).

  This sets each episode's Plex title to the title embedded in its filename and LOCKS the field,
  so a later library refresh can't overwrite it. Read-then-write via the PMS API; reads
  $env:PLEX_TOKEN / $env:PLEX_BASEURL (owner token, not stored in the repo).

  Default season is 0 (Specials) — that's the usual need. Pass -Season for others. Run AFTER the
  files are staged to the library and scanned, and AFTER episode order is title-card-validated
  (see extract-title-cards.ps1) so the names you lock are the right ones.

.EXAMPLE
  pwsh -File lock-plex-titles.ps1 -Show "Deep Space" -Season 0
  pwsh -File lock-plex-titles.ps1 -Show "The Avengers" -Season 0 -WhatIf   # preview only

.NOTES
  To UNLOCK later (let the agent take over again): re-run with -Unlock.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][string]$Show,
  [int]$Season = 0,
  [switch]$Unlock,
  [string]$BaseUrl = $env:PLEX_BASEURL,
  [string]$Token   = $env:PLEX_TOKEN
)
if (-not $Token)   { Write-Error "No Plex token. Set `$env:PLEX_TOKEN or pass -Token."; exit 2 }
if (-not $BaseUrl) { $BaseUrl = 'http://localhost:32400' }
$BaseUrl = $BaseUrl.TrimEnd('/')
$h = @{ 'X-Plex-Token' = $Token; 'Accept' = 'application/json' }
function Get-MC($p){ (Invoke-RestMethod ($BaseUrl + $p) -Headers $h).MediaContainer }

# Find show across ALL show-type sections. Don't stop at the first section that returns
# anything truthy: collect every candidate with a usable ratingKey, then prefer an exact
# (case-insensitive) title match over a regex substring match, so e.g. -Show 'Danger Man'
# can't be satisfied by a show called "Danger Man Returns".
#
# NOTE: local result variables are named $showObj/$seasonObj, NOT $show/$season. PowerShell
# variable names are case-INSENSITIVE, so $show and $Show (the parameter) are literally the
# same variable slot — assigning $show clobbers the $Show parameter. That was the actual bug:
# `$show = $null` (and later `$show = $hit | Select-Object -First 1`) wiped out $Show, so every
# subsequent `-match $Show` became `-match $null`, which matches EVERY title (an empty pattern
# matches anywhere) — so the loop "found" whatever the first show-type section happened to
# return, and later `[int]$Season` / "Season $Season" read back a metadata object instead of
# the int, because `$season = ...` clobbered `$Season` the exact same way.
$candidates = @()
foreach ($s in ((Get-MC '/library/sections').Directory | Where-Object type -eq 'show')) {
  $items = (Get-MC "/library/sections/$($s.key)/all?type=2").Metadata |
    Where-Object { $_.ratingKey -and $_.title -match $Show }
  foreach ($item in $items) { $candidates += $item }
}
$showObj = $candidates | Where-Object { $_.title -eq $Show } | Select-Object -First 1
if (-not $showObj) { $showObj = $candidates | Select-Object -First 1 }
if (-not $showObj -or -not $showObj.ratingKey) { Write-Error "Show '$Show' not found."; exit 3 }
$seasonObj = (Get-MC "/library/metadata/$($showObj.ratingKey)/children").Metadata | Where-Object { $_.index -eq $Season }
if (-not $seasonObj) { Write-Error "Season $Season not found for $($showObj.title)."; exit 4 }

$lockVal = if ($Unlock) { 0 } else { 1 }
$eps = (Get-MC "/library/metadata/$($seasonObj.ratingKey)/children").Metadata | Sort-Object index
$n = 0
foreach ($e in $eps) {
  $file = $e.Media.Part.file | Select-Object -First 1
  if (-not $file) { continue }
  if ((Split-Path $file -Leaf) -notmatch 'S\d+E[\dE\-]+ - (.+)\.[^.]+$') { continue }
  $title = $Matches[1]
  if ($PSCmdlet.ShouldProcess("$($showObj.title) S$([int]$Season)E$($e.index)", "set title='$title' locked=$lockVal")) {
    $enc = [uri]::EscapeDataString($title)
    $url = "$BaseUrl/library/metadata/$($e.ratingKey)?type=4&title.value=$enc&title.locked=$lockVal"
    try { Invoke-RestMethod $url -Headers $h -Method Put -ErrorAction Stop | Out-Null; $n++; "E{0:D2}: {1}" -f $e.index,$title }
    catch { "FAIL E$($e.index): $($_.Exception.Message)" }
  }
}
"$(if($Unlock){'Unlocked'}else{'Locked'}) $n titles on $($showObj.title) Season $Season."
