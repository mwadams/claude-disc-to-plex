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
  [string]$Manifest,                                # a manifest .json (typically from _queue/done)
  [string]$Tsv,                                     # OR a PROPOSALS.tsv from identify-season00-extras.ps1
  [string]$RatingKey,                               # show ratingKey - only used to report against -Tsv
  [int]$Section = 5,                                # Plex library section (5 = TV programmes here)
  [string]$Pending = 'D:/video/_plex-titles-pending.tsv',
  [switch]$Quiet,
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

# THE PENDING LEDGER - because "NOT INDEXED YET" was a silent, PERMANENT loss.
#
# This runs from _publish-loop.ps1 the moment the copy lands on the NAS. Plex indexes new files on
# its own schedule (the user, 2026-09-06: "Plex auto-indexes new files published to the NAS"), so at
# that moment the episode usually DOES NOT EXIST yet - there is no Part.file to match a basename
# against. The original code reported "NOT INDEXED YET ... (re-run after a scan)" and exited 0, and
# NOTHING RE-RAN IT. So the miss was not an edge case at all: it was the normal path, and the title
# was lost every time, silently, with the publish reporting success.
#
# That is precisely the defect assert-season00-titles-declared.ps1 was written this morning to
# prevent, defeated one step later - a manifest could carry a correct `plexTitle`, pass the gate,
# publish cleanly, and STILL leave Plex showing the agent's guess. The Season 00 items of The League
# of Gentlemen are what that looks like after the fact.
#
# So an unmatched item is written here and retried on every subsequent run, and a row leaves the
# ledger only when the title is verified set. The ledger is also the reason a run needs no arguments:
# `apply-plex-titles.ps1` with no -Manifest and no -Tsv is a legitimate DRAIN pass.
function Read-Pending([string]$Path) {
  $rows = @()
  if (Test-Path -LiteralPath $Path -PathType Leaf) {
    try { $rows = @(Import-Csv -LiteralPath $Path -Delimiter "`t" -ErrorAction Stop) } catch { $rows = @() }
  }
  return $rows
}
function Write-Pending([string]$Path, [object[]]$Rows) {
  if (-not $Rows -or $Rows.Count -eq 0) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
    return
  }
  $Rows | Select-Object File, Title, FirstSeen | Export-Csv -LiteralPath $Path -Delimiter "`t" -NoTypeInformation -Encoding UTF8
}

$pendingRows = @(Read-Pending $Pending)
if (-not $Manifest -and -not $Tsv -and $pendingRows.Count -eq 0) {
  throw 'give -Manifest (a pipeline manifest) or -Tsv (a filled-in PROPOSALS.tsv), or leave a non-empty pending ledger to drain.'
}

# TWO INPUTS, ONE APPLIER, DELIBERATELY.
#   -Manifest covers items THIS PIPELINE publishes: the disposition step already knows what each
#            one is, so the manifest carries `plexTitle` and this runs automatically after publish.
#   -Tsv     covers everything ALREADY in the library with no manifest behind it - the ~31 untitled
#            Sweeney specials, and per audit-season00-titles.ps1 some 70 shows in the same state.
#            identify-season00-extras.ps1 builds the evidence and emits the TSV; an agent fills in
#            the Title column; this applies it. Same set+lock, same verification, one code path.
$want = @()
if ($Manifest) {
  if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Say "apply-plex-titles: no manifest at $Manifest"; exit 0 }
  try { $items = @(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json) } catch { Say "apply-plex-titles: unreadable manifest ($($_.Exception.Message))"; exit 0 }
  $want = @($items | Where-Object { $_.PSObject.Properties.Name -contains 'plexTitle' -and "$($_.plexTitle)".Trim() })
}
if ($Tsv) {
  if (-not (Test-Path -LiteralPath $Tsv -PathType Leaf)) { Say "apply-plex-titles: no TSV at $Tsv"; exit 0 }
  $rows = @(Import-Csv -LiteralPath $Tsv -Delimiter "`t")
  $blank = @($rows | Where-Object { -not "$($_.Title)".Trim() }).Count
  if ($blank) { Say ("apply-plex-titles: {0} of {1} row(s) have an EMPTY Title and are skipped - fill them in first" -f $blank, $rows.Count) }
  foreach ($r in @($rows | Where-Object { "$($_.Title)".Trim() })) {
    $want += [pscustomobject]@{ out = "$($r.File)"; plexTitle = "$($r.Title)".Trim() }
  }
}
# Carried-over misses join this run's work. Keyed on the output BASENAME, which is what the Plex
# match uses, so a manifest re-run and a pending row for the same file collapse to one entry rather
# than being set twice.
$seenLeaf = @{}
foreach ($w in $want) { $seenLeaf[[IO.Path]::GetFileName("$($w.out)")] = $true }
$carried = 0
foreach ($r in $pendingRows) {
  $leaf = "$($r.File)".Trim(); $t = "$($r.Title)".Trim()
  if (-not $leaf -or -not $t -or $seenLeaf.ContainsKey($leaf)) { continue }
  $want += [pscustomobject]@{ out = $leaf; plexTitle = $t; firstSeen = "$($r.FirstSeen)" }
  $seenLeaf[$leaf] = $true
  $carried++
}
if ($carried) { Say ("    [plex-title] {0} title(s) carried over from a previous publish that Plex had not indexed yet" -f $carried) }
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

$set = 0; $already = 0; $missing = 0; $failed = 0; $lockedNow = 0
$stillPending = @()
foreach ($it in $want) {
  $leaf  = [IO.Path]::GetFileName("$($it.out)")
  $title = "$($it.plexTitle)".Trim()
  $ep = $byFile[$leaf]
  if (-not $ep) {
    # Not an error worth failing on, and NOT a reason to forget it either: Plex indexes new files on
    # its own schedule, so this is the expected state immediately after a publish. Carry it.
    $first = if ("$($it.firstSeen)".Trim()) { "$($it.firstSeen)".Trim() } else { (Get-Date).ToString('s') }
    Say ("    [plex-title] not indexed yet: {0} - wanted '{1}' (carried; will retry next publish)" -f $leaf, $title)
    $stillPending += [pscustomobject]@{ File = $leaf; Title = $title; FirstSeen = $first }
    $missing++; continue
  }
  # ALREADY CORRECT IS NOT ALREADY DONE. This branch used to `continue` without touching Plex, on
  # the reasoning that the text matches so there is nothing to set. But the POINT of this script is
  # the LOCK, not the text: an unlocked title is re-guessed by the agent on every refresh, so an
  # item reported "already correct" and left unlocked drifts straight back to a guess - the exact
  # bug the script exists to prevent, reported as a success. Found 2026-09-06 by the agent titling
  # The League of Gentlemen's Season 00, which had to lock E01 by a direct API call afterwards
  # because this said "already correct" and did nothing.
  #
  # Only the lock is written here - never the title, which already reads correctly - so this stays
  # idempotent and cannot disturb text a human set deliberately.
  if ("$($ep.title)" -eq $title) {
    $already++
    if ($WhatIf) { continue }
    # THE LOCK IS WRITTEN UNCONDITIONALLY, AND NOT REPORTED AS A DISCOVERY.
    #
    # The obvious version of this reads the current lock state and only writes when unlocked. It
    # cannot work: $ep comes from the SECTION-WIDE listing (/library/sections/N/all), and like
    # /children that endpoint omits <Field> elements entirely - so the check reads "unlocked" for
    # every item, including ones that are locked. Tested against S00E63, known locked: it announced
    # "already correct but UNLOCKED - locked it". The write was harmless (locking a locked field is
    # idempotent); the CLAIM was false, which is worse than doing nothing, because a log that
    # reports work it did not do cannot be used to tell whether the work is needed.
    #
    # Lock state lives only in the item's own XML (<Field name="title" locked="1"/>), which would
    # cost one request per item on a path that runs after every publish. Since the write is
    # idempotent and cheap, just do it and describe it as what it is: ensuring, not discovering.
    try {
      Invoke-RestMethod -Uri ("$base/library/metadata/$($ep.ratingKey)?type=4&id=$($ep.ratingKey)&title.locked=1") `
                        -Headers $h -Method Put -TimeoutSec 30 | Out-Null
      $lockedNow++
    } catch { Say ("    [plex-title] could not ensure the lock on '{0}': {1}" -f $leaf, $_.Exception.Message); $failed++ }
    continue
  }
  if ($WhatIf) { Say ("    [plex-title] WhatIf: {0} '{1}' -> '{2}'" -f $leaf, $ep.title, $title); continue }
  # THE SUMMARY BELONGS TO THE OLD TITLE, SO IT GOES WITH IT.
  #
  # We only reach here when the standing title was WRONG. Plex's agent wrote that title and its
  # summary together, as one guess about one item - so a summary sitting beside a title we are
  # replacing describes the item the agent THOUGHT this was, not the file. Setting the title and
  # leaving the summary produces a visibly self-contradictory episode, which is what the user saw
  # on 2026-09-06: S00E63 correctly retitled "In Conversation ... with Paul Jackson" over the
  # standing summary "Extended scene from the Christmas Special." - the description belonging to
  # the wrong title that had just been removed. Fixing titles alone does not reduce the error, it
  # makes it conspicuous.
  #
  # Cleared rather than rewritten, and LOCKED: this pipeline knows what an item IS (that is the
  # title) but does not author synopses, and an unlocked empty summary is refilled by the agent on
  # the next refresh. This is the same default fix-plex-extras.ps1 has always applied to extras.
  # An item whose title was ALREADY correct is not touched - its summary was written for the right
  # item and may well be good.
  $hadSummary = "$($ep.summary)".Trim()
  try {
    $u = "$base/library/metadata/$($ep.ratingKey)?type=4&id=$($ep.ratingKey)&title.value=" +
         [uri]::EscapeDataString($title) + '&title.locked=1&summary.value=&summary.locked=1'
    Invoke-RestMethod -Uri $u -Headers $h -Method Put -TimeoutSec 30 | Out-Null
    if ($hadSummary) {
      Say ("    [plex-title] cleared the summary that belonged to the old title '{0}': '{1}'" -f `
           $ep.title, $(if ($hadSummary.Length -gt 80) { $hadSummary.Substring(0,80) + '...' } else { $hadSummary }))
    }
    $back = [xml](Invoke-WebRequest -Uri "$base/library/metadata/$($ep.ratingKey)" -Headers $h -TimeoutSec 30).Content
    $now  = "$($back.MediaContainer.Video.title)"
    if ($now -eq $title) { Say ("    [plex-title] set + locked: {0} -> '{1}'" -f $leaf, $title); $set++ }
    else { Say ("    [plex-title] SET DID NOT STICK: {0} reads '{1}', wanted '{2}'" -f $leaf, $now, $title); $failed++ }
  } catch {
    Say ("    [plex-title] FAILED: {0} - {1}" -f $leaf, $_.Exception.Message); $failed++
  }
}
if (-not $WhatIf) { Write-Pending $Pending $stillPending }
if ($set -or $failed -or $missing -or $lockedNow) {
  Say ("    [plex-title] {0} set, {1} already correct ({2} re-locked to stop agent drift), {3} not indexed yet (carried), {4} failed" -f `
       $set, $already, $lockedNow, $missing, $failed)
}
# A row that has been carried a long time is no longer "Plex has not caught up" - it means the file
# is not where we think it is, or is not in this section. Say so rather than retrying in silence for
# ever, which is the failure mode this whole ledger exists to end.
$stale = @($stillPending | Where-Object {
  $d = [datetime]::MinValue
  [datetime]::TryParse("$($_.FirstSeen)", [ref]$d) -and $d -lt (Get-Date).AddHours(-6)
})
if ($stale.Count) {
  Say ("    [plex-title] *** {0} title(s) have been pending over 6 hours - Plex is not simply behind. Check the file is on the NAS under section {1} and that its basename matches: {2}" -f `
       $stale.Count, $Section, (($stale | Select-Object -First 3 -ExpandProperty File) -join '; '))
}
exit 0
