# Publish a finished work to the NAS: copy EVERY file (media + sidecar subtitles + artwork),
# then verify count and bytes.
#
# WHY THIS EXISTS. Publishing used to be an ad-hoc robocopy naming "<title>.mkv" explicitly - a
# habit picked up from the "never folder-copy while an encode is still writing" rule. That is
# right about the danger and wrong about the remedy: naming one file silently leaves behind
# anything else the work needs, and since OCR now writes subtitles as SIDECARS, a *.mkv filter
# drops the subtitles without a word of complaint.
#
# The real guard against copying a half-written file is to publish only AFTER the encode reports
# done and the outputs have been duration-checked - not to narrow the filter.
#
#   pwsh -File _publish.ps1 -Work "Zulu (1964)" -Kind Movies
#   pwsh -File _publish.ps1 -Work "Being Human (2009)" -Kind 'Television Shows'
#   pwsh -File _publish.ps1 -Work "Zulu (1964)" -Kind Movies -Overwrite   # replace a bad copy

param(
  [Parameter(Mandatory)][string]$Work,
  [ValidateSet('Movies','Television Shows')][string]$Kind = 'Movies',
  [switch]$Overwrite,
  [switch]$SkipSubtitleCheck,   # publish a work whose bitmap subs are deliberately not being OCR'd
  # SHIP THE SIDECARS AND LEAVE THE VIDEO ALONE.
  #
  # For a work whose media is ALREADY on the NAS and correct, but which was published by a legacy
  # encode that muxed no subtitle stream. Boston Legal Seasons 1 and 3 are 41 such episodes: the
  # picture is fine and matches the disc (verified at two landmarks 38 minutes apart), and the only
  # thing missing is the subtitles - which the library OCR campaign can never supply, because it
  # reads tracks from INSIDE files that are already published and these have none.
  #
  # Re-encoding is how the subtitle gets made; this switch is about not SHIPPING the result twice.
  # It avoids pushing ~5.6 GB per episode back over SMB, avoids disturbing a published file that is
  # already correct, and avoids the supersedes/retire-list machinery entirely.
  #
  # The local output must therefore be named to match the file ALREADY on the NAS, because Plex
  # matches a sidecar on the media basename. That is the manifest's job, not this script's - set
  # `out` to the existing published name (e.g. `Boston Legal  S01E01.mkv`, two spaces and no
  # episode title) so OCR writes `Boston Legal  S01E01.eng.srt` and it lands beside its media.
  [switch]$SubtitlesOnly,
  [string]$LocalRoot = 'D:\video',
  [string]$NasRoot   = '\\NASTEAMV\Multimedia',
  [switch]$NoIndex,   # skip the Plex reindex (copy only)
  [switch]$Manual   # override the track guard (see lib-track-guard.ps1)
)

# The guard must be IMPOSSIBLE to skip by failing to load. A dot-source of a bad path raises a
# NON-TERMINATING error, so Assert-TrackOwner was simply undefined, calling it wrote one more
# error to the stream, and the script sailed on and published anyway (observed 2026-08-23 with
# a mangled path). Verify the load, and abort if the function is not there.
$guardLib = "$PSScriptRoot/lib-track-guard.ps1"   # DOUBLE quotes: single quotes do not expand $PSScriptRoot
if (-not (Test-Path -LiteralPath $guardLib)) { throw "track guard missing: $guardLib" }
. $guardLib
if (-not (Get-Command Assert-TrackOwner -ErrorAction SilentlyContinue)) {
  throw 'track guard failed to load - refusing to run unguarded'
}
Assert-TrackOwner -Track Publish -Manual:$Manual


$src = Join-Path (Join-Path $LocalRoot $Kind) $Work
$dst = Join-Path (Join-Path $NasRoot   $Kind) $Work
if (-not (Test-Path -LiteralPath $src)) { throw "no such local work: $src" }

$local = @(Get-ChildItem -LiteralPath $src -Recurse -File)
if (-not $local) { throw "nothing to publish in $src" }

if ($SubtitlesOnly) {
  # Narrow the REPORTING/VERIFICATION list here; the copy itself is narrowed at the robocopy call
  # below. Both are required - see the /XF comment there for why filtering this list alone is not
  # enough, and would put the video on the NAS while the report counted only the sidecars.
  $local = @($local | Where-Object { $_.Extension -eq '.srt' })
  if (-not $local) {
    throw "-SubtitlesOnly but no .srt in $src - OCR has not run yet, or its sidecars are named differently. Refusing rather than publishing nothing and calling it success."
  }
}

# refuse to publish anything that looks unfinished - a truncated mkv has no duration in its header
$paths   = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'
# SKIP THE PARTIAL FILE, DO NOT ABANDON THE WHOLE WORK.
#
# This threw on the first partial mkv, which refuses the ENTIRE work folder. That is correct for a
# work encoded in one go, and badly wrong for a show encoded across many discs over hours: with two
# lanes writing continuously into `The Saint (1962)` there was almost always one partial file, so
# the publish aborted on essentially every pass - 115 of them - while 39 finished episodes sat local
# and only 21 reached the NAS. Seasons 02/03/04 had NOTHING published.
#
# That directly defeats the project's own rule, "publish immediately, gate only the reclaim": the
# user cannot confirm a unit is in Plex until it is on the NAS, so holding everything back stalls
# the pipeline exactly when it is busiest. The colour run published fine only because nothing was
# encoding into it at the time.
#
# The guard's purpose is "never publish a partial file", and skipping achieves that completely.
# Abandoning the work achieves it too, but at the cost of everything else in the folder. The
# reclaim stays safe either way: `_release-published.ps1` gates per file on a byte-identical NAS
# copy, so a partly-published work simply does not fully reclaim.
#
# Say what was skipped and why. A silent skip would read as "published everything".
$partial = @()
foreach ($f in $local | Where-Object { $_.Extension -eq '.mkv' }) {
  $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null)".Trim()
  if (-not $d -or $d -eq 'N/A') { $partial += $f }
}
if ($partial.Count) {
  foreach ($f in $partial) {
    Write-Output "SKIPPING (still encoding): $($f.Name) has no duration - it is a partial file"
  }
  # Drop them from this pass; the loop re-publishes when they finalise.
  $local = @($local | Where-Object { $partial.FullName -notcontains $_.FullName })
  if (-not $local) { throw "every file in $src is still partial - nothing to publish yet" }
}

# Refuse to publish AHEAD of the OCR pass. The documented order is encode -> OCR -> publish, and
# publishing early is not harmless: the .mkv lands without its sidecar, so every one of them needs
# a second, individual copy afterwards to carry the .srt up. It is easy to do by accident because
# the encode finishing feels like the work being finished, and nothing downstream complains - the
# film plays, with blocky bitmap subtitles, exactly as if no OCR had been intended.
#
# A file with a BITMAP subtitle track (dvd_subtitle / hdmv_pgs_subtitle) and no matching sidecar is
# the signature. Text subtitle tracks and files with no subtitles at all are fine.
#
# But wait only for a sidecar that CAN exist. A declared bitmap track carrying no packets (a silent
# film's empty subtitle shell) can never produce one, and blocking on it strands the work here
# permanently - see lib-subtitles.ps1.
#
# The load is VERIFIED for the same reason as the track guard above: if this dot-source fails,
# Test-BitmapSubsPopulated is simply undefined, every call errors WITHOUT stopping the script,
# $awaiting stays empty - and the subtitle gate approves everything it exists to block.
. (Join-Path $PSScriptRoot 'lib-subtitles.ps1')
if (-not (Get-Command Test-BitmapSubsPopulated -ErrorAction SilentlyContinue)) {
  throw 'lib-subtitles.ps1 failed to load - refusing to publish with the subtitle gate undefined'
}
if (-not $SkipSubtitleCheck) {
  $awaiting = @()
  foreach ($f in $local | Where-Object { $_.Extension -eq '.mkv' }) {
    $sidecar = [IO.Path]::ChangeExtension($f.FullName, $null) + 'eng.srt'
    if (Test-Path -LiteralPath $sidecar) { continue }
    if (Test-BitmapSubsPopulated -Path $f.FullName -Ffprobe $ffprobe) { $awaiting += $f.Name }
  }
  if ($awaiting) {
    Write-Warning ("REFUSING: {0} file(s) have bitmap subtitles but no OCR sidecar yet - run ocr-subtitles.ps1 first, or pass -SkipSubtitleCheck:" -f $awaiting.Count)
    $awaiting | ForEach-Object { Write-Warning "    $_" }
    exit 2
  }
}

Write-Host ("publishing {0} file(s), {1} GB" -f $local.Count, [math]::Round(($local | Measure-Object Length -Sum).Sum / 1GB, 2))
$local | Group-Object Extension | ForEach-Object { "   {0,-6} {1}" -f $_.Name, $_.Count }

# /E = whole tree, ALL file types. Without -Overwrite keep the no-clobber flags so a re-run is safe.
#
# ALWAYS LOG, because an exit >=8 CANNOT BE DIAGNOSED AFTER THE FACT. Rome season 2 threw
# `exit 11` on two separate publishes (2026-08-21). Both times every file verified byte-identical
# on the NAS, and a re-run reported FAILED=0 with everything already present - because by then
# there was nothing left to copy, so the failing pass could never be reproduced. Exit 11 is
# 1 (copied) + 2 (extras in destination, normal - the target holds earlier discs) + 8 (something
# failed). Without the log from the FAILING pass, the 8 is unattributable.
$rcLog  = Join-Path $env:TEMP ("robocopy_{0}_{1}.log" -f ($Work -replace '[^\w]','_'), $PID)
$flags = @('/E','/R:3','/W:5','/NP','/NFL','/NDL',"/LOG:$rcLog")
if (-not $Overwrite) { $flags += @('/XC','/XN','/XO') }
# EXCLUDE THE PARTIALS FROM THE COPY ITSELF, not merely from the verification list.
#
# `/E` copies the whole tree regardless of what $local holds, so dropping a partial file from that
# list alone would let it reach the NAS while the report counted only the complete ones - a silent
# half-file on the server, which is strictly worse than the stall this change fixes. /XF takes full
# paths and is the only thing that actually keeps them back.
if ($partial.Count) { $flags += '/XF'; $flags += @($partial | ForEach-Object { $_.FullName }) }
# SAME REASONING FOR -SubtitlesOnly. robocopy's file spec is positional, before the switches, and
# it is the only thing that stops /E dragging the .mkv along. Narrowing $local above governs what
# is REPORTED and VERIFIED; this governs what actually moves.
$fileSpec = if ($SubtitlesOnly) { @('*.srt') } else { @() }
robocopy $src $dst @fileSpec @flags | Out-Null
$rcExit = $LASTEXITCODE
if ($rcExit -ge 8) {
  Write-Warning "robocopy exit $rcExit - the >=8 bit means at least one item failed. Log: $rcLog"
  # Surface the actual errors AND the summary, then let the per-file byte check below decide.
  # A failure here does NOT necessarily mean data loss: verify before concluding either way.
  Get-Content -LiteralPath $rcLog -EA SilentlyContinue |
    Select-String -Pattern 'ERROR|Access is denied|The process cannot access' |
    Select-Object -First 10 | ForEach-Object { Write-Warning "    $_" }
  Get-Content -LiteralPath $rcLog -EA SilentlyContinue | Select-Object -Last 8 |
    ForEach-Object { Write-Warning "    $_" }
  Write-Warning "continuing to the byte-for-byte verification - it, not the exit code, decides."
}

$ok = 0; $bad = 0
foreach ($f in $local) {
  $t = $f.FullName.Replace($src, $dst)
  if ((Test-Path -LiteralPath $t) -and ((Get-Item -LiteralPath $t).Length -eq $f.Length)) { $ok++ }
  else { $bad++; Write-Warning "MISMATCH $($f.Name)" }
}
Write-Host ("verified {0}/{1}{2}" -f $ok, $local.Count, $(if ($bad) { ", $bad MISMATCHED" } else { '' }))
if ($bad) { exit 1 }

# REINDEX IS PART OF PUBLISHING, not a separate thing to remember.
#
# A Plex SECTION scan does not index local movie extras - only a forced ITEM refresh does. Leaving
# that in a separate script meant it ran only when somebody remembered to run it, and on 2026-08-22
# Stravinsky shipped with one extra Plex never indexed; it was caught solely because the user
# counted them. A publish nobody can see is not a publish, so the copy and the refresh are one step.
if (-not $NoIndex) {
  $token = [Environment]::GetEnvironmentVariable('PLEX_TOKEN','User')
  $base  = [Environment]::GetEnvironmentVariable('PLEX_BASEURL','User')
  if (-not $token -or -not $base) {
    Write-Host '   (PLEX_TOKEN / PLEX_BASEURL not set - skipping reindex)'
  } elseif (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'plex-index-work.ps1'))) {
    Write-Warning "   reindex script not found: (Join-Path $PSScriptRoot 'plex-index-work.ps1')"
  } else {
    $plexKind = if ($Kind -eq 'Movies') { 'Movies' } else { 'TV' }
    # Never pipe this through Select-Object -First N: closing the pipe kills the child mid-run.
    $ixOut = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'plex-index-work.ps1') -Work $Work -Kind $plexKind 2>&1
    $verdict = @($ixOut | Select-String 'OK - every shipped extra|NOT indexed|missing|NOT FOUND')
    if ($verdict) { $verdict | ForEach-Object { "   $_" } }
    else { Write-Warning "   reindex produced no verdict - check manually"; @($ixOut)[-3..-1] | ForEach-Object { "   $_" } }
  }
}
