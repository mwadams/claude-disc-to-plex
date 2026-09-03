<#
.SYNOPSIS
  Force Plex to display OUR filename-derived episode titles (locked), for a show/season.
  Optionally also set and lock episode SUMMARIES from a mapping file.

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

  SUMMARIES (-SummaryMap): the agent's mis-assigned summary is the same class of bug as the
  mis-assigned title, but summaries cannot be derived from the filename — there is no text to
  extract. So they come from a mapping file you author from PROVEN content (e.g. a disc's
  dispositions.txt), not from invention. Pass -SummaryMap to also set+lock summary.value for
  whichever episode numbers appear in the map; episodes not in the map are left alone. Combine
  with -SummaryOnly to skip the title-setting pass entirely (e.g. when titles are already correct
  and locked from an earlier run, and you only need to add summaries this time).

  Mapping file format — plain text, one episode per line, greppable:
      # comment lines start with #, blank lines ignored
      <episode-number>|<summary text, one paragraph, no pipe characters>
  Example:
      1|A 2006 reunion documentary bringing together the three leads.
      4|A 1983 compilation TV-movie edited from two episodes.
  <episode-number> matches the season-relative episode index (Plex's `e.index`, i.e. the NN in
  S00ENN) — not a disc/title number.

.EXAMPLE
  pwsh -File lock-plex-titles.ps1 -Show "Deep Space" -Season 0
  pwsh -File lock-plex-titles.ps1 -Show "The Avengers" -Season 0 -WhatIf   # preview only
  pwsh -File lock-plex-titles.ps1 -Show "The Champions" -Season 0 -SummaryMap ./champions-s00-summaries.txt -SummaryOnly

.NOTES
  To UNLOCK later (let the agent take over again): re-run with -Unlock. -Unlock applies to
  whichever field(s) the invocation is touching (title, summary, or both).
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][string]$Show,
  [int]$Season = 0,
  [switch]$Unlock,
  [string]$SummaryMap,
  [switch]$SummaryOnly,
  [string]$BaseUrl = $env:PLEX_BASEURL,
  [string]$Token   = $env:PLEX_TOKEN
)
if (-not $Token)   { Write-Error "No Plex token. Set `$env:PLEX_TOKEN or pass -Token."; exit 2 }
if (-not $BaseUrl) { $BaseUrl = 'http://localhost:32400' }
$BaseUrl = $BaseUrl.TrimEnd('/')
$h = @{ 'X-Plex-Token' = $Token; 'Accept' = 'application/json' }
# Fetch via Invoke-WebRequest + ConvertFrom-Json -AsHashtable, NOT Invoke-RestMethod's own JSON
# parsing. Reason (found 2026-09-03 verifying this show): Plex's episode objects carry BOTH a
# scalar "guid" key and an array "Guid" key. PowerShell's default JSON parsing folds property
# names case-insensitively into one PSCustomObject, so "guid"/"Guid" collide - and observed
# behaviour was NOT a clean, visible error every time: some calls threw, but others silently
# returned a corrupted object where an unrelated field (here, episode "index") read back wrong
# and DIFFERENTLY on different calls to the identical URL. -AsHashtable preserves both keys
# untouched (hashtables are case-preserving even though lookups stay case-insensitive), so this
# corruption cannot happen. Dot-property access below still works: PowerShell's ETS adapts
# Hashtable member access, including through arrays (member-enumeration), the same as it does
# for PSCustomObject - so no other line in this script needed to change for this fix.
function Get-MC($p){
  $resp = Invoke-WebRequest -Uri ($BaseUrl + $p) -Headers $h -UseBasicParsing
  ($resp.Content | ConvertFrom-Json -AsHashtable).MediaContainer
}

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

# NOTE: this local table is named $mapTable, NOT $summaryMap / $SummaryMap. PowerShell variable
# names are case-INSENSITIVE (see the big note above on $showObj/$seasonObj) — a local variable
# spelled any case-variant of the -SummaryMap parameter would clobber it the same way $show once
# clobbered $Show. $mapTable cannot collide with the -SummaryMap parameter slot.
$mapTable = $null
if ($SummaryMap) {
  if (-not (Test-Path -LiteralPath $SummaryMap)) { Write-Error "Summary map not found: $SummaryMap"; exit 5 }
  $mapTable = @{}
  foreach ($line in Get-Content -LiteralPath $SummaryMap) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $sep = $t.IndexOf('|')
    if ($sep -lt 0) { continue }
    $epNumText = $t.Substring(0, $sep).Trim()
    $text = $t.Substring($sep + 1).Trim()
    if ($epNumText -notmatch '^\d+$') { continue }
    $mapTable[[int]$epNumText] = $text
  }
  if ($mapTable.Count -eq 0) { Write-Error "Summary map '$SummaryMap' parsed to zero entries."; exit 6 }
}

$eps = (Get-MC "/library/metadata/$($seasonObj.ratingKey)/children").Metadata | Sort-Object index
$n = 0
foreach ($e in $eps) {
  $qs = @()
  $descBits = @()
  $title = $null

  if (-not $SummaryOnly) {
    $file = $e.Media.Part.file | Select-Object -First 1
    if (-not $file) { continue }
    if ((Split-Path $file -Leaf) -notmatch 'S\d+E[\dE\-]+ - (.+)\.[^.]+$') { continue }
    $title = $Matches[1]
    $qs += "title.value=$([uri]::EscapeDataString($title))"
    $qs += "title.locked=$lockVal"
    $descBits += "title='$title'"
  }

  $summaryText = $null
  if ($mapTable -and $mapTable.ContainsKey([int]$e.index)) {
    $summaryText = $mapTable[[int]$e.index]
    $qs += "summary.value=$([uri]::EscapeDataString($summaryText))"
    $qs += "summary.locked=$lockVal"
    $descBits += "summary set ($($summaryText.Length) chars)"
  }

  if ($qs.Count -eq 0) { continue }

  if ($PSCmdlet.ShouldProcess("$($showObj.title) S$([int]$Season)E$($e.index)", "set $($descBits -join ', ') locked=$lockVal")) {
    $url = "$BaseUrl/library/metadata/$($e.ratingKey)?type=4&" + ($qs -join '&')
    try {
      Invoke-RestMethod $url -Headers $h -Method Put -ErrorAction Stop | Out-Null
      $n++
      if ($title -and $summaryText) { "E{0:D2}: title='{1}'; summary set" -f $e.index, $title }
      elseif ($summaryText)         { "E{0:D2}: summary set" -f $e.index }
      else                          { "E{0:D2}: {1}" -f $e.index, $title }
    }
    catch { "FAIL E$($e.index): $($_.Exception.Message)" }
  }
}
$what = if ($SummaryOnly) { 'summaries' } elseif ($mapTable) { 'titles and summaries' } else { 'titles' }
"$(if($Unlock){'Unlocked'}else{'Locked'}) $n $what on $($showObj.title) Season $Season."
