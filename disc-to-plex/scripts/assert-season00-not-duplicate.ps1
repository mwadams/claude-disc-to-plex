<#
.SYNOPSIS
  REFUSE a manifest that adds a NEW Season 00 item whose duration matches a special the library
  already holds, unless the row says why it is not that special.

.WHY THIS EXISTS
  2026-09-17, Firefly. The Blu-ray Disk 2 reunion ("Lunch with Joss, Nathan, Alan and Ron", 24.0 min)
  was published as a NEW S00E15. The library already held it as the legacy, bare-named
  `Firefly S00E02.mkv` (24.0 min), published before this pipeline kept any record. The dispositions
  agent could not see the duplicate: a bare legacy special has no title to compare, and
  assert-replacement-identity.ps1 only checks numbered episodes. The user found it in Plex.

  A matching duration is NOT identity - but it is exactly the prompt to look, and it is free: Plex
  already holds every published special's duration, so this reads no file on the NAS.

.WHAT IT REFUSES
  An item whose `out` is a Season 00 file (S00Exx), with no `supersedes`, whose expectSeconds is within
  max(-ToleranceSeconds, -TolerancePct of the duration), directly or at the PAL 25/23.976 speed ratio, of an EXISTING Season 00 item of the same show
  in Plex (other than the item's own output file). The row passes if it carries
  `notDuplicateOf: { "S00Exx": "<why it is different content>" }` naming every matched special - a
  written reason, never a bare flag. Use `supersedes` instead when it IS the same content.

.EXIT CODES
  0 = no unexplained match (or nothing checkable - reported)   2 = refuse; the caller must not queue it
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  # TIGHT, because the real duplicates match to the millisecond (Firefly: 1442.464 vs 1442.5; 1719.01 vs 1719.0)
  # and a loose window floods on short clips - Friends' deleted scenes cluster within 3 s of each other.
  # 0.5 s: Doctor Who's Riverside Story (1220.0 s) and Stripped for Action (1220.9 s) are different programmes.
  [double]$ToleranceSeconds = 0.5,
  [double]$TolerancePct = 0.05,
  # Below this, equal durations are common and the content is cheap; not worth a refusal.
  [double]$MinSeconds = 120,
  [int]$TvSection = 5,
  # Test seam: JSON file of { "<show folder>": [ { "index": n, "seconds": s, "file": "<basename>", "title": "..." } ] }
  [string]$SpecialsStub,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Say "assert-season00-not-duplicate: no manifest at $Manifest"; exit 0 }
try { $doc = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json }
catch { Say ("assert-season00-not-duplicate: unreadable manifest ({0}) - not this guard's call" -f $_.Exception.Message); exit 0 }
$items = if ($doc -is [array]) { @($doc) } elseif ($doc.items) { @($doc.items) } else { @($doc) }

$rx = '[\\/]Television Shows[\\/]([^\\/]+)[\\/]Season 00[\\/]([^\\/]+)$'
# Every output of THIS manifest: two new items are not duplicates of each other just because a re-gate after
# publish finds them in Plex (The West Wing S1 D3's Sheen and Whitford interviews are both 238.7 s).
$ownLeaves = @($items | ForEach-Object { Split-Path "$($_.out)" -Leaf })
$candidates = @($items | Where-Object {
  "$($_.out)" -match $rx -and -not "$($_.supersedes)".Trim() -and [double]"$($_.expectSeconds)" -ge $MinSeconds
})
if (-not $candidates.Count) { Say 'assert-season00-not-duplicate: no new Season 00 item with an expectSeconds - nothing to check'; exit 0 }

# ---- the show's existing specials, from Plex (durations are measured from the files) ----------
$cache = @{}
function Get-Specials([string]$showFolder) {
  if ($cache.ContainsKey($showFolder)) { return , $cache[$showFolder] }
  $list = [System.Collections.Generic.List[object]]::new()
  if ($SpecialsStub) {
    $stub = Get-Content -LiteralPath $SpecialsStub -Raw | ConvertFrom-Json
    foreach ($e in @($stub.$showFolder)) { if ($e) { $list.Add($e) } }
    $cache[$showFolder] = $list; return , $list
  }
  $tok = [Environment]::GetEnvironmentVariable('PLEX_TOKEN', 'User')
  $base = [Environment]::GetEnvironmentVariable('PLEX_BASEURL', 'User')
  if (-not $tok -or -not $base) { $cache[$showFolder] = $null; return , $null }
  $h = @{ 'X-Plex-Token' = $tok; Accept = 'application/json' }
  $name = $showFolder -replace '\s*\(\d{4}\)\s*$', ''
  $year = if ($showFolder -match '\((\d{4})\)\s*$') { [int]$Matches[1] } else { 0 }
  try {
    $shows = @((Invoke-RestMethod -Headers $h -TimeoutSec 30 -Uri ("{0}/library/sections/{1}/all?type=2&title={2}" -f $base, $TvSection, [uri]::EscapeDataString($name))).MediaContainer.Metadata)
    $show = @($shows | Where-Object { $_ -and $_.title -eq $name -and (-not $year -or [int]$_.year -eq $year) }) | Select-Object -First 1
    if (-not $show) { $cache[$showFolder] = $list; return , $list }    # a new show: nothing published to duplicate
    $seasons = @((Invoke-RestMethod -Headers $h -TimeoutSec 30 -Uri "$base/library/metadata/$($show.ratingKey)/children").MediaContainer.Metadata)
    $s0 = $seasons | Where-Object { [int]$_.index -eq 0 } | Select-Object -First 1
    if ($s0) {
      foreach ($e in @((Invoke-RestMethod -Headers $h -TimeoutSec 30 -Uri "$base/library/metadata/$($s0.ratingKey)/children").MediaContainer.Metadata)) {
        if (-not $e) { continue }
        foreach ($m in @($e.Media)) { foreach ($p in @($m.Part)) {
          $list.Add([pscustomobject]@{ index = [int]$e.index; seconds = [double]$e.duration / 1000; file = (Split-Path "$($p.file)" -Leaf); title = "$($e.title)" })
        } }
      }
    }
  } catch { $cache[$showFolder] = $null; return , $null }
  $cache[$showFolder] = $list
  return , $list
}

$refuse = 0
foreach ($it in $candidates) {
  [void]("$($it.out)" -match $rx)
  $showFolder = $Matches[1]; $outLeaf = $Matches[2]
  $specials = Get-Specials $showFolder
  if ($null -eq $specials) { Say ("  UNCHECKED  {0} - Plex could not be read; this guard skipped (a skip is not a pass)" -f $outLeaf); continue }
  $want = [double]"$($it.expectSeconds)"
  $tol = [Math]::Max($ToleranceSeconds, $want * $TolerancePct / 100)
  # The same material from a PAL disc runs 25/23.976 = 4.27% short (or long, the other way round).
  $hits = @($specials | Where-Object { $s = $_.seconds; $ownLeaves -notcontains $_.file -and @(1.0, (25/23.976), (23.976/25)) | Where-Object { [Math]::Abs($s * $_ - $want) -le $tol } | Select-Object -First 1 })
  $unexplained = @()
  foreach ($hh in $hits) {
    $slot = 'S00E{0:00}' -f $hh.index
    $why = $null
    if ($it.notDuplicateOf) { $why = "$($it.notDuplicateOf.$slot)".Trim() }
    if ($why) { Say ("  explained  {0} ~ {1} ({2:N1}s vs {3:N1}s): {4}" -f $outLeaf, $hh.file, $want, $hh.seconds, $why) }
    else { $unexplained += $hh }
  }
  if ($unexplained.Count) {
    $refuse++
    Say ("  POSSIBLE DUPLICATE  {0} ({1:N1}s) is NEW, but the library already holds:" -f $outLeaf, $want)
    foreach ($hh in $unexplained) { Say ("      S00E{0:00}  {1}  ({2:N1}s, Plex title '{3}')" -f $hh.index, $hh.file, $hh.seconds, $hh.title) }
  }
}
if ($refuse) {
  Say ''
  Say ("assert-season00-not-duplicate: REFUSED - {0} new Season 00 item(s) match an existing special by duration." -f $refuse)
  Say 'Look at both (title card, a speech sample). SAME content -> give the row `supersedes` with the existing path, so the better'
  Say 'source replaces it in place. DIFFERENT content -> add `notDuplicateOf: { "S00Exx": "<what differs, from the content>" }`.'
  exit 2
}
Say ("assert-season00-not-duplicate: OK - {0} new Season 00 item(s), none matching an existing special by duration" -f $candidates.Count)
exit 0
