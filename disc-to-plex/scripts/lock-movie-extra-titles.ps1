<#
.SYNOPSIS
  Set each of a FILM's local extras' Plex titles from its filename and LOCK the field, so the agent
  cannot rename them. Report by default; `-Apply` to write.

.WHY THIS EXISTS
  `fix-plex-extras.ps1` and `lock-plex-titles.ps1` both do this for TELEVISION - they take -Show and
  -Season and walk a Season 00 folder. There has never been a movie equivalent, so EVERY local extra
  on EVERY film in this library has an unlocked title, and an unlocked title is re-guessed on every
  refresh.

  Three Kings, 2026-09-09. The operator asked where "Making of Three Kings - Part 6 of 7 (Editorial -
  The Opening Scene)" had gone. Nothing was lost: the file was on the NAS, correctly named, correctly
  in `Behind The Scenes\` - and Plex was displaying it as **"Opening"**, because the agent carries its
  own "Opening" extra for that film and adopted the title over the filename. Its six siblings kept
  their names by luck, not by design; Part 4 has the same inner " - " and was untouched. All nine
  were unlocked, so any of them could go the same way on any refresh.

.WHAT IT WILL NOT TOUCH
  An AGENT-SUPPLIED extra - a trailer Plex fetched itself - has no local file, and its title is the
  agent's to own. Those are skipped, and skipping them is load-bearing: the first cut of this logic
  read `$e.Media.Part.file` on such an item, threw, and left the loop's `$want` variable holding the
  PREVIOUS iteration's value - so it renamed the agent's trailer to "Gallery - Behind the Scenes".
  Hence: per-item state is re-initialised every iteration, and the file test is a real test, not an
  assumption that Media implies a Part with a path.

.DO NOT REFRESH AFTERWARDS
  Triggering a metadata refresh straight after locking put "Opening" back, once. Lock, then verify by
  READING the item, and leave the refresh alone.

.EXAMPLE
  pwsh -File lock-movie-extra-titles.ps1 -Film 'Three Kings'
  pwsh -File lock-movie-extra-titles.ps1 -Film 'Three Kings' -Apply
  pwsh -File lock-movie-extra-titles.ps1 -All -Apply        # every film with local extras
#>
param(
  [string]$Film,
  [int]$RatingKey = 0,
  [switch]$All,
  [int]$Section = 6,
  [switch]$Apply,
  [string]$BaseUrl = $env:PLEX_BASEURL,
  [string]$Token   = $env:PLEX_TOKEN
)
$ErrorActionPreference = 'Stop'

if (-not $Token)   { $Token   = [Environment]::GetEnvironmentVariable('PLEX_TOKEN','User') }
if (-not $BaseUrl) { $BaseUrl = [Environment]::GetEnvironmentVariable('PLEX_BASEURL','User') }
if (-not $Token -or -not $BaseUrl) { throw 'PLEX_TOKEN / PLEX_BASEURL not available (never printed)' }
if (-not $Film -and -not $RatingKey -and -not $All) { throw 'give -Film, -RatingKey or -All' }

$base = $BaseUrl.TrimEnd('/')
$hJson = @{ 'X-Plex-Token' = $Token; 'Accept' = 'application/json' }
$hRaw  = @{ 'X-Plex-Token' = $Token }

function Get-Films {
  if ($RatingKey) { return @([pscustomobject]@{ ratingKey = $RatingKey; title = "(ratingKey $RatingKey)" }) }
  # NOT `$all`. POWERSHELL VARIABLE NAMES ARE CASE-INSENSITIVE, so a local `$all` IS the `-All`
  # switch parameter. Assigning the film list to it made `if ($All)` test a non-empty array -
  # truthy - so `-Film 'Three Kings'` silently scanned all 393 films in the section and reported
  # 574 retitles. Caught only because the run was report-only. Same family as this project's
  # `$rm`/`$mv` guard collisions: the name, not the value, is what bit.
  $catalogue = (Invoke-RestMethod "$base/library/sections/$Section/all?type=1" -Headers $hJson).MediaContainer.Metadata
  if ($All) { return @($catalogue) }
  return @($catalogue | Where-Object { $_.title -match [regex]::Escape($Film) })
}

$films = @(Get-Films)
if (-not $films.Count) { Write-Output "no film matches"; exit 0 }
Write-Output ("scanning {0} film(s) in section {1}{2}" -f $films.Count, $Section, $(if ($Apply) { '' } else { '  (report only)' }))

$changed = 0; $lockedOnly = 0; $skipped = 0; $failed = 0
foreach ($f in $films) {
  $extras = @()
  try { $extras = @((Invoke-RestMethod "$base/library/metadata/$($f.ratingKey)/extras" -Headers $hJson).MediaContainer.Metadata) } catch { continue }
  if (-not $extras.Count) { continue }

  $header = $false
  foreach ($e in $extras) {
    # RE-INITIALISED EVERY ITERATION. The bug this replaces carried a stale $want across a thrown
    # Split-Path and renamed an agent trailer with the previous extra's name.
    $file = $null; $want = $null

    # WHAT AN AGENT-SUPPLIED EXTRA ACTUALLY LOOKS LIKE - it is NOT "no Part.file".
    #
    #   local  : key='/library/parts/36387/0/file.mkv'
    #            file='/share/CACHEDEV1_DATA/Multimedia/Movies/Three Kings/Behind The Scenes/....mkv'
    #   agent  : key='/services/iva/assets/679329/video.mp4?fmt=4&bitrate=1500 ...'
    #            file=' '                                   <- ONE SPACE, which is TRUTHY
    #
    # So `if ($e.Media.Part.file)` passes for an agent trailer, and the derived title becomes ' '.
    # In report mode that printed `RETITLE 'Three Kings' -> ' '` for every film in the sweep; with
    # -Apply it would have blanked the agent trailer's title on all of them. Plex's own marker for a
    # local part is the `/library/parts/` key prefix - test THAT, and then still require the derived
    # name to be non-blank.
    $key = $null
    try { $key  = @("$($e.Media.Part.key)")  | Select-Object -First 1 } catch { $key = $null }
    try { $file = @("$($e.Media.Part.file)") | Select-Object -First 1 } catch { $file = $null }
    if (-not $key -or -not "$key".StartsWith('/library/parts/')) { $skipped++; continue }
    if (-not "$file".Trim()) { $skipped++; continue }

    $want = [IO.Path]::GetFileNameWithoutExtension((Split-Path -Leaf "$file".Trim()))
    if (-not "$want".Trim()) { $skipped++; continue }

    # PLEX HAS TWO LOCAL-EXTRA NAMING FORMS, AND ONLY ONE PUTS THE WHOLE FILENAME IN THE TITLE.
    #
    #   folder form : Behind The Scenes\Making of Three Kings - Part 6 of 7 (....).mkv
    #                 -> the whole basename IS the title.
    #   suffix form : Making of-featurette.mkv , Teaser trailer-trailer.mkv
    #                 -> the trailing `-<type>` is the TYPE MARKER; Plex strips it and shows
    #                    "Making of". That is correct, and writing the basename back would set the
    #                    title to "Making of-featurette".
    #
    # Bridge on the River Kwai uses the suffix form throughout. In the first full sweep this script
    # proposed six such "fixes" - every one of them damage - alongside four real ones. Strip the
    # marker so the suffix form is recognised as ALREADY CORRECT and merely gets locked.
    $suffixes = 'trailer','featurette','behindthescenes','deleted','deletedscene','interview','scene','short','other'
    foreach ($sfx in $suffixes) {
      if ("$want".ToLowerInvariant().EndsWith('-' + $sfx)) {
        $want = "$want".Substring(0, "$want".Length - $sfx.Length - 1)
        break
      }
    }
    if (-not "$want".Trim()) { $skipped++; continue }

    $xml = $null
    try { $xml = [xml](Invoke-RestMethod "$base/library/metadata/$($e.ratingKey)" -Headers $hRaw) } catch { }
    $isLocked = $false
    if ($xml) { $isLocked = @($xml.MediaContainer.Video.Field | Where-Object { $_.name -eq 'title' }).Count -gt 0 }

    $titleWrong = ("$($e.title)" -cne $want)
    if (-not $titleWrong -and $isLocked) { continue }  # already correct and protected

    if (-not $header) { Write-Output ("  {0}" -f $f.title); $header = $true }
    if ($titleWrong) { Write-Output ("     RETITLE  '{0}'  ->  '{1}'" -f $e.title, $want); $changed++ }
    else             { Write-Output ("     lock     '{0}'" -f $want); $lockedOnly++ }
    if (-not $Apply) { continue }

    $uri = "{0}/library/metadata/{1}?type={2}&id={1}&title.value={3}&title.locked=1" -f `
             $base, $e.ratingKey, $e.type, [uri]::EscapeDataString($want)
    try { Invoke-RestMethod -Method Put -Uri $uri -Headers $hRaw | Out-Null }
    catch { Write-Output ("     !! failed on rk={0}: {1}" -f $e.ratingKey, $_.Exception.Message); $failed++; continue }

    # VERIFY BY READING IT BACK - a PUT that returns 200 is not evidence the field took.
    $chk = $null
    try { $chk = (Invoke-RestMethod "$base/library/metadata/$($e.ratingKey)" -Headers $hJson).MediaContainer.Metadata[0] } catch { }
    if ($chk -and "$($chk.title)" -cne $want) {
      Write-Output ("     !! did NOT take - still '{0}'" -f $chk.title); $failed++
    }
  }
}

Write-Output ''
Write-Output ("{0} retitled, {1} already-correct locked, {2} agent-supplied skipped, {3} failed" -f $changed, $lockedOnly, $skipped, $failed)
if (-not $Apply) { Write-Output 'report only - re-run with -Apply'; exit 0 }
Write-Output 'Do NOT trigger a metadata refresh now: one did put a stale agent title straight back.'
if ($failed) { exit 1 }
exit 0
