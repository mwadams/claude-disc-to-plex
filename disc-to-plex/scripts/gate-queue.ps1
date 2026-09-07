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

# SAME REASONING, DIFFERENT FAULT: a Season 00 item that ships BARE-NAMED with no `plexTitle` can
# never be titled correctly afterwards. fix-plex-extras.ps1 parses the title out of the filename,
# and a bare name (forced by an in-place `supersedes`, which must keep the legacy NAS filename) has
# none - so Plex titles it by index and re-guesses on every refresh. Cheap to fix here, and after
# publish it needs a human noticing and calling the API by hand: five Sweeney specials on
# 2026-09-05, and S00E63 of The League of Gentlemen on 2026-09-06, which Plex titled "Christmas
# Special - Extended Scene - Papa Lazarou" over a 63-minute Paul Jackson interview.
$titleGuard = 'D:/video/.claude/skills/disc-to-plex/scripts/assert-season00-titles-declared.ps1'
if (Test-Path -LiteralPath $titleGuard) {
  & pwsh -NoProfile -File $titleGuard -Manifest $Manifest
  if ($LASTEXITCODE -ne 0) {
    Write-Output ("gate REFUSED: {0} - a Season 00 item would publish with no title Plex could get right. Not queued." -f (Split-Path $Manifest -Leaf))
    exit 2
  }
}

# THIRD FAULT, SAME LOGIC: a DVD row that asks ffmpeg for the WRONG TITLE NUMBER. transcode.ps1
# passes `title` straight to the dvdvideo demuxer as a 1-based dvdvideoTitle, so numbering the
# chosen episodes 1..N - instead of using each one's true dvdvideoTitle - shifts every output by
# however many leader/menu titles the selection skipped. 2026-09-07: two Tales of the Unexpected
# Season 4 discs, manifested an hour apart by different agents; 7c5172b2 used titles 2..8 and
# published, 38d2ed75 used 1..7 and quarantined all seven as .wrong-length after the encodes had
# already run. The catalogue can settle it outright - it records each title's duration against its
# dvdvideoTitle - so the disagreement is mechanical, not a matter of judgement.
$numberingGuard = 'D:/video/.claude/skills/disc-to-plex/scripts/assert-dvd-title-numbering.ps1'
if (Test-Path -LiteralPath $numberingGuard) {
  & pwsh -NoProfile -File $numberingGuard -Manifest $Manifest
  if ($LASTEXITCODE -ne 0) {
    Write-Output ("gate REFUSED: {0} - DVD title numbers disagree with the disc catalogue by duration; every output would be shifted. Not queued." -f (Split-Path $Manifest -Leaf))
    exit 2
  }
}

# FOURTH FAULT, cheapest of the lot: an output NAME Windows cannot create. S04E01 "Would You
# Believe It?" died as `Error opening output ...: Invalid argument` / ffmpeg exit -22, having
# decoded nothing - and the line sat under fourteen lines of benign libdvdcss warnings that every
# item on that disc printed, including the six that encoded fine. The episode was just absent from
# Plex afterwards. Punctuated episode titles are ordinary, so this recurs.
$pathGuard = 'D:/video/.claude/skills/disc-to-plex/scripts/assert-output-paths-legal.ps1'
if (Test-Path -LiteralPath $pathGuard) {
  & pwsh -NoProfile -File $pathGuard -Manifest $Manifest
  if ($LASTEXITCODE -ne 0) {
    Write-Output ("gate REFUSED: {0} - an output filename cannot be created on Windows. Not queued." -f (Split-Path $Manifest -Leaf))
    exit 2
  }
}

# FIFTH FAULT, and the cheapest of all - it needs no disc, no catalogue and no probe, only the two
# numbers already in the row. expectSeconds and expectFrames are TWO MEASUREMENTS OF ONE QUANTITY,
# so their ratio has to be a real frame rate; when it is not, one of them was copied from another
# title. The Song Remains The Same's playlist row paired 969.068 s with 27,007 frames - 27.87 fps -
# because the seconds were updated when the row was re-pointed at the playlist and the frames were
# left behind from the truncated Extras 08 it supersedes. ffmpeg then encoded the playlist
# perfectly (969.109 s, 29,043 frames, exactly matching the source) and transcode.ps1 quarantined
# that correct output as .wrong-length, failing all ten items. Caught here it costs nothing.
$expectGuard = 'D:/video/.claude/skills/disc-to-plex/scripts/assert-expectations-consistent.ps1'
if (Test-Path -LiteralPath $expectGuard) {
  & pwsh -NoProfile -File $expectGuard -Manifest $Manifest
  if ($LASTEXITCODE -ne 0) {
    Write-Output ("gate REFUSED: {0} - expectSeconds and expectFrames cannot describe the same title; one is stale. Not queued." -f (Split-Path $Manifest -Leaf))
    exit 2
  }
}

# SIXTH FAULT, and the operator found this one rather than any check: an extra filed into a movie
# subfolder Plex does not recognise is not an extra at all - the scanner indexes it as a FILM.
# Moulin Rouge's four stills galleries went to "Still Galleries\" on 2026-09-07 and turned up in
# the Films library as titles ("Costume Gallery", "The Little Red Book", and one mis-matched to an
# unrelated film). Everything else about them was right: encoded, verified, published, byte-matched.
# references/naming.md has always listed the eight valid folders; writing it down was not enough.
$extrasGuard = 'D:/video/.claude/skills/disc-to-plex/scripts/assert-extras-folders-recognised.ps1'
if (Test-Path -LiteralPath $extrasGuard) {
  & pwsh -NoProfile -File $extrasGuard -Manifest $Manifest
  if ($LASTEXITCODE -ne 0) {
    Write-Output ("gate REFUSED: {0} - a movie extra would be filed where Plex does not look; it would be indexed as a separate film. Not queued." -f (Split-Path $Manifest -Leaf))
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
