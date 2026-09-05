<#
.SYNOPSIS
  Set (and LOCK) the Plex episode title for every published item whose manifest declared a
  `plexTitle`. Runs after a publish; takes its names from the MANIFEST, never from a guess.

.WHY THIS EXISTS
  fix-plex-extras.ps1 sets Plex titles from THE FILENAME, and says so: "our filenames are the
  source of truth". That works for a normally-named extra
  (`Show (Year) - S00E56 - Local People.mkv`) and cannot work at all for a BARE one
  (`The Sweeney S00E18.mkv`) - there is nothing in the name to parse.

  Bare names are not sloppiness, they are forced: an in-place `supersedes` MUST keep the old NAS
  filename or it ships a duplicate instead of a replacement. So every quality re-rip of a legacy
  bare-named special lands with no title, Plex's agent labels it "Episode 18", and the only fix
  was a human noticing and calling the API by hand. On 2026-09-05 five Sweeney specials shipped
  exactly that way and the user had to ask for the titles to be set.

  audit-season00-titles.ps1 already DETECTS this and _idlewatch.ps1 reports it - but reporting is
  not fixing, and the report says "run fix-plex-extras.ps1", which for these files cannot help.
  This closes the loop: the disposition step already knows what each item IS, the manifest records
  it as `plexTitle`, and this applies it the moment the file is on the NAS.

.WHAT IT DOES
  For each manifest item carrying `plexTitle`:
    * finds the Plex episode whose media Part file BASENAME matches the item's `out` basename
      (basename, because the server's path is its own - /share/CACHEDEV1_DATA/... - not ours);
    * sets title.value and title.locked=1, so a later agent refresh cannot revert it;
    * verifies by reading the title back, and reports a per-item line either way.
  It NEVER invents a title, never renames a file, and never touches an item without `plexTitle`.

.NOTES
  - Idempotent: an episode already carrying the wanted title is left alone and reported as "ok".
  - Never fatal to the caller. A Plex outage must not fail a publish that genuinely succeeded.
#>
param(
  [Parameter(Mandatory)][string]$Manifest,          # a manifest .json (typically from _queue/done)
  [int]$Section = 5,                                # Plex library section (5 = TV programmes here)
  [switch]$Quiet,
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Say "apply-plex-titles: no manifest at $Manifest"; exit 0 }
try { $items = @(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json) } catch { Say "apply-plex-titles: unreadable manifest ($($_.Exception.Message))"; exit 0 }

$want = @($items | Where-Object { $_.PSObject.Properties.Name -contains 'plexTitle' -and "$($_.plexTitle)".Trim() })
if ($want.Count -eq 0) { exit 0 }        # the common case - say nothing at all

$token = [Environment]::GetEnvironmentVariable('PLEX_TOKEN', 'User')
$base  = [Environment]::GetEnvironmentVariable('PLEX_BASEURL', 'User')
if (-not $token -or -not $base) { Say 'apply-plex-titles: PLEX_TOKEN/PLEX_BASEURL not set - skipping (not a publish failure)'; exit 0 }
$h = @{ 'X-Plex-Token' = $token }

# ONE fetch of the section's episodes, not one per item: this runs after every publish.
try {
  $all = [xml](Invoke-WebRequest -Uri "$base/library/sections/$Section/all?type=4" -Headers $h -TimeoutSec 90).Content
} catch { Say "apply-plex-titles: Plex unreachable ($($_.Exception.Message)) - skipping"; exit 0 }

# basename -> episode node. Plex reports ITS OWN path for Part.file, so only the leaf is comparable.
$byFile = @{}
foreach ($v in @($all.MediaContainer.Video)) {
  foreach ($p in @($v.Media.Part)) {
    if (-not $p.file) { continue }
    $leaf = [IO.Path]::GetFileName("$($p.file)")
    if ($leaf -and -not $byFile.ContainsKey($leaf)) { $byFile[$leaf] = $v }
  }
}

$set = 0; $already = 0; $missing = 0; $failed = 0
foreach ($it in $want) {
  $leaf  = [IO.Path]::GetFileName("$($it.out)")
  $title = "$($it.plexTitle)".Trim()
  $ep = $byFile[$leaf]
  if (-not $ep) {
    # Not an error worth failing on: Plex may simply not have scanned the new file yet.
    Say ("    [plex-title] NOT INDEXED YET: {0} - wanted '{1}' (re-run after a scan)" -f $leaf, $title)
    $missing++; continue
  }
  if ("$($ep.title)" -eq $title) { $already++; continue }
  if ($WhatIf) { Say ("    [plex-title] WhatIf: {0} '{1}' -> '{2}'" -f $leaf, $ep.title, $title); continue }
  try {
    $u = "$base/library/metadata/$($ep.ratingKey)?type=4&id=$($ep.ratingKey)&title.value=" +
         [uri]::EscapeDataString($title) + '&title.locked=1'
    Invoke-RestMethod -Uri $u -Headers $h -Method Put -TimeoutSec 30 | Out-Null
    $back = [xml](Invoke-WebRequest -Uri "$base/library/metadata/$($ep.ratingKey)" -Headers $h -TimeoutSec 30).Content
    $now  = "$($back.MediaContainer.Video.title)"
    if ($now -eq $title) { Say ("    [plex-title] set + locked: {0} -> '{1}'" -f $leaf, $title); $set++ }
    else { Say ("    [plex-title] SET DID NOT STICK: {0} reads '{1}', wanted '{2}'" -f $leaf, $now, $title); $failed++ }
  } catch {
    Say ("    [plex-title] FAILED: {0} - {1}" -f $leaf, $_.Exception.Message); $failed++
  }
}
if ($set -or $failed -or $missing) {
  Say ("    [plex-title] {0} set, {1} already correct, {2} not indexed yet, {3} failed" -f $set, $already, $missing, $failed)
}
exit 0
