# Hold a manifest until its source disc is BYTE-COMPLETE, then drop it in the encode queue.
#
# Enumerating or encoding a half-copied disc is the documented silent failure: titles simply are
# not there yet, durations look plausible, and nothing errors. MakeMKV happily reported a credible
# 2:12:07 feature for Die Hard while 42 of its 266 files were still copying.
#
# So the judgement (which title, what language, how named) is made up front and written into the
# manifest, but the manifest only becomes runnable once source and staged copies match on BOTH
# file count and total bytes.
#
# THIS IS THE ONLY SANCTIONED ROUTE INTO `_queue`. lane-runner.ps1 refuses a manifest that is not
# recorded in the ledger this script writes. See "THE LEDGER" below.
#
#   pwsh -File _gate-queue.ps1 -Disc 'Babylon 5 Season 1 Disk 6' -Manifest D:/video/b5d6.json
#   pwsh -File _gate-queue.ps1 -SourceDir E:/Movies/X -StageDir D:/video/_stage/X -Manifest ...
#
# WHY `-Disc` EXISTS (added 2026-09-01).
# The two-directory form was the only form, and it made the gate UNUSABLE for the common case:
# a disc that was staged and verified days ago, whose source drive has since been swapped out.
# `Get-ChildItem` on a detached E: returns nothing, the counts never match, and the gate polls
# for ever. Faced with that, the main session wrote manifests straight into `_queue` instead -
# three times on 2026-09-01 alone, and "went unused all of 2026-08-23" before that. A guard that
# is cheaper to bypass than to satisfy will be bypassed; that is not a discipline problem, it is
# a design defect.
#
# `-Disc` closes it. `_fetch-done.txt` records ONLY copies already verified on count AND bytes -
# it is the same check, already performed and written down. When the disc is listed there, the
# gate's condition is DISCHARGED, not waived, and the manifest queues immediately.
param(
  # Either -Disc (preferred), or the explicit pair. -Disc resolves both and short-circuits on
  # _fetch-done.txt; the pair is kept for a disc mid-copy that is not yet recorded anywhere.
  [string]$Disc,
  [string]$SourceDir,
  [string]$StageDir,
  [Parameter(Mandatory)][string]$Manifest,       # a .json written but NOT yet in the queue
  [string]$Queue     = 'D:/video/_queue',
  [string]$Stage     = 'D:/video/_stage',
  [string]$SrcRoot   = 'E:/Movies',
  [string]$FetchDone = 'D:/video/_fetch-done.txt',
  [int]$PollSec      = 30
)

$ErrorActionPreference = 'Stop'

if (-not $Disc -and -not ($SourceDir -and $StageDir)) {
  throw 'give either -Disc <name>, or both -SourceDir and -StageDir.'
}
if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) {
  throw "-Manifest '$Manifest' does not exist. Author it first, then gate it."
}

# LAYOUT CHECKS FIRST - fail fast, before waiting on a copy.
#
# The byte-completeness wait below asks "is the SOURCE ready?". It says nothing about whether the
# manifest's OUTPUT paths are sane, and a layout fault is only cheap to fix here: once the encode
# has run and published, correcting it needs a re-encode plus a NAS deletion only the user can do.
$editionGuard = 'D:/video/.claude/skills/disc-to-plex/scripts/assert-edition-layout.ps1'
if (Test-Path -LiteralPath $editionGuard) {
  & pwsh -NoProfile -File $editionGuard -Manifest $Manifest
  if ($LASTEXITCODE -ne 0) {
    Write-Output ("gate REFUSED: {0} - edition layout would lose this film's local extras. Not queued." -f (Split-Path $Manifest -Leaf))
    exit 2
  }
}

# THE LEDGER. Record WHICH manifest passed and WHAT IT CONTAINED when it did.
#
# The hash matters, not just the name: without it, gating an empty placeholder and then writing the
# real manifest over it would satisfy the check. With it, any edit after gating reads as ungated -
# which is the correct answer, because the thing that was checked is not the thing being run.
function Add-LedgerEntry($manifestPath, $how) {
  $ledger = Join-Path $Queue '.gated.jsonl'
  $entry = [ordered]@{
    name   = Split-Path $manifestPath -Leaf
    sha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash
    gated  = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    how    = $how
  }
  Add-Content -LiteralPath $ledger -Value ($entry | ConvertTo-Json -Compress)
}

function Complete-Gate($manifestPath, $how, $note) {
  Add-LedgerEntry $manifestPath $how
  $dest = Join-Path $Queue (Split-Path $manifestPath -Leaf)
  Move-Item -LiteralPath $manifestPath -Destination $dest -Force
  Write-Output ("gate passed ({0}): {1} - queued {2}" -f $how, $note, (Split-Path $manifestPath -Leaf))
}

# -Disc: is the copy ALREADY verified? _fetch-done.txt is written only after a count-and-bytes
# match, so a line there is the gate's own condition, already met and recorded.
if ($Disc) {
  $done = @(Get-Content -LiteralPath $FetchDone -ErrorAction SilentlyContinue |
            Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
  $StageDir = Join-Path $Stage $Disc
  # $SourceDir IS DELIBERATELY *NOT* COMPUTED HERE. It used to be, and that broke Staggered on
  # 2026-09-05 with "Cannot find drive. A drive with the name 'E' does not exist."
  #
  # Two reasons it must be lazy:
  #   1. PowerShell's Join-Path resolves the PROVIDER, so it THROWS on an absent drive rather than
  #      returning a string. $SrcRoot defaults to 'E:/Movies'.
  #   2. A disc already listed in _fetch-done.txt exits below WITHOUT EVER USING $SourceDir - its
  #      copy was verified on count and bytes when it was fetched, which is the gate's condition,
  #      already met and recorded. Computing the path to a source it does not need, and dying on
  #      it, is pure self-harm.
  # This is now the NORMAL case, not an edge case: source drives are swapped out as soon as their
  # discs are staged (media2 out, media3 in, the same morning), and discs backed up by the OPTICAL
  # lane - Staggered, the Jeeves set - never had a source on $SrcRoot at all.

  if (-not (Test-Path -LiteralPath $StageDir -PathType Container)) {
    throw "-Disc '$Disc' is not staged at $StageDir. Fetch it before gating a manifest against it."
  }
  if ($done -contains $Disc) {
    Complete-Gate $Manifest 'fetch-verified' "$Disc (already verified in _fetch-done.txt)"
    exit 0
  }
  Write-Output ("$Disc is not in _fetch-done.txt yet - waiting on the copy to match on count and bytes")
}

# Only now, when the source is genuinely going to be compared against, is its path needed.
# [IO.Path]::Combine, not Join-Path: it is pure string work and does not resolve the drive, so an
# absent source produces the explicit message below instead of a provider exception 12 lines earlier.
if (-not $SourceDir) {
  if (-not $Disc) { throw 'neither -SourceDir nor -Disc was given - nothing to compare the staged copy against.' }
  $SourceDir = [IO.Path]::Combine($SrcRoot, $Disc)
}
if (-not (Test-Path -LiteralPath $SourceDir -PathType Container)) {
  throw ("source '$SourceDir' is not reachable, and '$Disc' is not in $FetchDone either. " +
         "If its drive has been swapped out, put it back; if the disc was backed up by the OPTICAL " +
         "lane it has no source there at all, and the right fix is to record it in $FetchDone once " +
         "its _disc-backup.json verifies (byte total equal to the volume, IFO/BUP identical, 0 read errors).")
}

while ($true) {
  $s = Get-ChildItem -LiteralPath $SourceDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
  $t = Get-ChildItem -LiteralPath $StageDir  -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
  if ($s.Count -gt 0 -and $s.Count -eq $t.Count -and $s.Sum -eq $t.Sum) {
    Complete-Gate $Manifest 'bytes-match' ("{0} ({1} files / {2} GB)" -f (Split-Path $StageDir -Leaf), $s.Count, [math]::Round($s.Sum/1GB,2))
    break
  }
  Start-Sleep -Seconds $PollSec
}
