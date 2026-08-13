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

# find show across show-type sections
$show = $null
foreach ($s in ((Get-MC '/library/sections').Directory | Where-Object type -eq 'show')) {
  $hit = (Get-MC "/library/sections/$($s.key)/all?type=2").Metadata | Where-Object { $_.title -match $Show }
  if ($hit) { $show = $hit | Select-Object -First 1; break }
}
if (-not $show) { Write-Error "Show '$Show' not found."; exit 3 }
$season = (Get-MC "/library/metadata/$($show.ratingKey)/children").Metadata | Where-Object { $_.index -eq $Season }
if (-not $season) { Write-Error "Season $Season not found for $($show.title)."; exit 4 }

$lockVal = if ($Unlock) { 0 } else { 1 }
$eps = (Get-MC "/library/metadata/$($season.ratingKey)/children").Metadata | Sort-Object index
$n = 0
foreach ($e in $eps) {
  $file = $e.Media.Part.file | Select-Object -First 1
  if (-not $file) { continue }
  if ((Split-Path $file -Leaf) -notmatch 'S\d+E[\dE\-]+ - (.+)\.[^.]+$') { continue }
  $title = $Matches[1]
  if ($PSCmdlet.ShouldProcess("$($show.title) S$([int]$Season)E$($e.index)", "set title='$title' locked=$lockVal")) {
    $enc = [uri]::EscapeDataString($title)
    $url = "$BaseUrl/library/metadata/$($e.ratingKey)?type=4&title.value=$enc&title.locked=$lockVal"
    try { Invoke-RestMethod $url -Headers $h -Method Put -ErrorAction Stop | Out-Null; $n++; "E{0:D2}: {1}" -f $e.index,$title }
    catch { "FAIL E$($e.index): $($_.Exception.Message)" }
  }
}
"$(if($Unlock){'Unlocked'}else{'Locked'}) $n titles on $($show.title) Season $Season."
