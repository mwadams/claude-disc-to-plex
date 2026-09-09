<#
  Build the transcription work list from CONFIRMED disc evidence - never from a library sweep.

  THE RULE (user, 2026-08-31): a file is only transcribable once we have confirmed, from the
  disc sweep, that there are DEFINITIVELY no subtitles to be had. "The NAS copy has no subtitle
  stream" does not establish that.

  WHY A LIBRARY SWEEP IS THE WRONG SOURCE
  An unsubtitled NAS file is one of three quite different things:
    1. the disc had no subtitles           -> transcription is the only option. ELIGIBLE.
    2. the disc HAS subtitles the rip lost  -> RE-RIP. On the media2 audit that was 64 titles.
    3. the disc has bitmap subtitles present in the file -> OCR, which is strictly better.
  Only (1) belongs here. A sweep that asks "does this file have subtitles?" cannot separate
  (1) from (2), and would generate a machine transcript for an episode whose own subtitles are
  sitting on a disc we hold. That is not a near-miss; it permanently substitutes worse content
  for better and then looks finished.

  SO ELIGIBILITY REQUIRES POSITIVE EVIDENCE FROM THE DISC:
    * the disc-identity register has an output for this NAS file, AND
    * every source title behind it recorded subStreams = 0 at enumeration, AND
    * the NAS file itself has no subtitle stream and no .srt sidecar, AND
    * the NAS file itself actually HAS an audio stream to transcribe.
  A work that has not been swept yet is simply not eligible. The queue therefore grows as the
  drives are worked through, which is the intended pace - it is not a backlog to be filled in.

  A VIDEO-ONLY FILE IS NOT "NOT YET ELIGIBLE" - IT IS PERMANENTLY DONE.
  A stills gallery, mute footage, or a promo reel has no dialogue track for whisper to decode,
  so enqueuing it produces a 'failed' result on every single pass forever: the ffmpeg audio
  extraction step has nothing to extract, and the loop cannot tell that failure apart from a
  transient one. Two known instances - `Survivors - S00E08 - Publicity Stills.mkv` and
  `The Champions S00E09.mkv` (aka "... - Merchandise Memorabilia Gallery.mkv") - sat in the
  failed queue this way (2026-09-02). This script therefore probes every candidate file for an
  audio stream BEFORE it is ever written to the queue; a file with none is written instead to
  `$NotApplicable` with its reason, so the disposition is visible and countable without
  polluting the transcribe loop's failure signal.

  TWO SOURCES OF THE DISC-TO-FILE LINK, and both are legitimate:

    1. the identity register's `outputs` - material WE ripped and published, so the link is
       exact and recorded.
    2. an AUDIT MATCH - a drive audit that paired a disc title with an already-published file
       by runtime and judged it as needing NO RE-RIP. Holding the disc and finding the
       published copy sound is the same evidence arrived at from the other direction, and
       restricting the queue to (1) would strand ~250 files on this drive alone, waiting for a
       re-rip that could never produce a subtitle because the disc has none.

  What is NOT sufficient, and was the original mistake: a same-named work having a
  subtitle-free disc somewhere. Danger Man's episodes were on the NAS long before this drive
  was swept; nothing says they came from these discs. The link must be to the FILE.

  Read-only. Writes D:\video\_transcribe-queue.csv and D:\video\_transcribe-not-applicable.csv
#>
param(
  [string]$Store = ([IO.Path]::Combine('\\NASTEAMV', 'Multimedia', '_disc-identity')),
  [string]$Out   = 'D:\video\_transcribe-queue.csv',
  # Terminal, non-failure dispositions: files that can never be transcribed because they carry
  # no audio stream at all (stills galleries, mute footage, promo reels). See Test-HasAudioStream
  # below - this is the "distinct from failed" record the transcribe loop's failure count must
  # not be polluted by. Countable and visible on purpose: silence here is how "we covered
  # everything" gets claimed falsely.
  [string]$NotApplicable = 'D:\video\_transcribe-not-applicable.csv',
  # An audit's transcribable set: JSON array of {work, rel, kind, disc, tid}. Produced when a
  # drive is analysed, for files judged "no re-rip needed" whose disc had zero subtitle streams.
  [string]$AuditSet = '',
  [int]$MinSeconds = 120,
  # Required to replace a populated queue (or not-applicable register) with a SMALLER one. See
  # the guards before each write.
  [switch]$Force,
  # MERGE this run's eligible rows into the existing queue rather than replacing it. Adds only
  # paths not already present, never removes. This is what the rip/publish tracks call, and what
  # to reach for whenever the intent is "add these" rather than "rebuild everything" - see the
  # long note at the write guard for why -Force is the wrong tool for that job.
  [switch]$Append
)
$ErrorActionPreference = 'Continue'

. (Join-Path $PSScriptRoot 'lib-queue-guard.ps1')

$paths   = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'
$ffmpeg  = $paths.ffmpeg          # volumedetect needs ffmpeg, not ffprobe - see Test-AudioIsSilent
if (-not (Test-Path -LiteralPath $Store)) { throw "identity register not found: $Store" }

# ONE identity table for the WHOLE run, shared by both sources below (register outputs, then the
# optional -AuditSet). Previously each source only checked membership against $rows as it stood
# BEFORE that source's own loop ran - a source could never see its own prior insertions within the
# same loop, let alone the other source's. That let two audit-set entries for the SAME published
# file both pass the check and both get added - the exact shape that put Danger Man S00E03 and
# S00E12 into the queue twice. $seenPaths is updated in place by Add-UniqueQueueRowToList on every
# successful add, so it is always current for whichever loop runs next.
$seenPaths = @{}

# A file with no audio stream at all can never be transcribed - whisper has nothing to decode.
# That is not a transient failure, it is a correct terminal outcome, and it must never reach the
# transcribe queue: enqueuing it means the loop burns a 'failed' result on every pass forever,
# because the work is permanently impossible, not permanently unlucky.
function Test-HasAudioStream([string]$Path) {
  $codecs = & $ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 -- $Path 2>$null
  return @($codecs | Where-Object { $_ }).Count -gt 0
}

# A SILENT AUDIO TRACK IS NOT AN AUDIO SOURCE, AND IT DOES NOT ANNOUNCE ITSELF.
#
# Test-HasAudioStream asks whether a stream EXISTS. Mute archival footage is routinely authored with
# a real, encoded, silent track - so it answers yes, the file is queued, and whisper is handed ten
# minutes of noise floor. Whisper does not return nothing on silence: it HALLUCINATES, emitting
# repeated plausible phrases. The result is fabricated dialogue written as a subtitle sidecar onto
# mute archival footage, which is strictly worse than no subtitle at all and looks completely
# healthy afterwards.
#
# The Power Game (1965), 2026-09-09. The operator listed the disc's specials and flagged two as
# "(mute)": `Man from Italy` and `35mm Title Footage`. Both carry TWO audio streams each, so both
# passed the existence test and both were sitting in the transcribe queue. Measured:
#
#     Man from Italy         mean -75.4 dB   max -58.7 dB
#     35mm Title Footage     mean -82.5 dB   max -66.8 dB
#     Promotional Trailers   mean -32.7 dB   max -11.2 dB   <- control, from the same disc
#
# ~50 dB between the mute pair and an ordinary track from the same source is not a marginal call.
# The threshold is set on MAX, not mean: a mean can be dragged down by a long quiet passage in a
# file that does contain speech, whereas a max below -45 dB means nothing in the whole window ever
# rose to the level of dialogue.
function Test-AudioIsSilent([string]$Path, [double]$MaxDbFloor = -45.0, [int]$Seconds = 600) {
  $out = & $ffmpeg -hide_banner -nostats -t $Seconds -i $Path -map 0:a:0 -af volumedetect -f null - 2>&1
  $m = [regex]::Match(($out -join "`n"), 'max_volume:\s*(-?\d+(?:\.\d+)?) dB')
  if (-not $m.Success) { return $false }   # unmeasurable is NOT silent - never exclude on a failed probe
  return ([double]$m.Groups[1].Value -lt $MaxDbFloor)
}

$records = @(Get-ChildItem -LiteralPath $Store -Filter *.json -File |
             Where-Object { $_.Name -ne '_index-by-output.json' })
Write-Host "identity records: $($records.Count)"

$rows   = New-Object System.Collections.Generic.List[object]
$naRows = New-Object System.Collections.Generic.List[object]
$stats = [ordered]@{
  outputs = 0; noRecordedOutput = 0; discHadSubs = 0; notPublished = 0
  hasStream = 0; hasSidecar = 0; tooShort = 0; noAudioStream = 0; eligible = 0
}

foreach ($rf in $records) {
  $rec = Get-Content -LiteralPath $rf.FullName -Raw | ConvertFrom-Json
  $byTitle = @{}
  foreach ($t in @($rec.titles)) { $byTitle[[int]$t.makemkvTitle] = $t }

  foreach ($o in @($rec.outputs)) {
    if (-not $o.outFile) { continue }
    $stats.outputs++

    # every source title must have been enumerated with ZERO subtitle streams
    $srcTitles = @($o.sources | ForEach-Object { [int]$_.makemkvTitle })
    $unknown = @($srcTitles | Where-Object { -not $byTitle.ContainsKey($_) })
    if ($unknown.Count) { $stats.noRecordedOutput++; continue }
    $withSubs = @($srcTitles | Where-Object { [int]$byTitle[$_].subStreams -gt 0 })
    if ($withSubs.Count) { $stats.discHadSubs++; continue }   # -> RE-RIP or OCR, not this

    if (-not (Test-Path -LiteralPath $o.outFile)) { $stats.notPublished++; continue }

    $f = Get-Item -LiteralPath $o.outFile
    $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    if (@(Get-ChildItem -LiteralPath $f.DirectoryName -Filter "$stem*.srt" -File -EA SilentlyContinue).Count) {
      $stats.hasSidecar++; continue
    }
    $codecs = & $ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 -- $f.FullName 2>$null
    if (@($codecs | Where-Object { $_ }).Count) { $stats.hasStream++; continue }

    $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 -- $f.FullName 2>$null)".Trim()
    $sec = 0.0; [double]::TryParse($d, [ref]$sec) | Out-Null
    if ($sec -lt $MinSeconds) { $stats.tooShort++; continue }

    # Absence of a stream, OR a stream carrying nothing but noise floor - both are terminal,
    # and only the second one lies about itself. See Test-AudioIsSilent.
    $noAudio = -not (Test-HasAudioStream $f.FullName)
    $silent  = (-not $noAudio) -and (Test-AudioIsSilent $f.FullName)
    if ($noAudio -or $silent) {
      $stats.noAudioStream++
      $naRows.Add([pscustomobject]@{
        Kind = $rec.kind; Work = $o.work; Path = $f.FullName
        Season = $o.season; Episode = $o.episode
        Minutes = [math]::Round($sec / 60, 1)
        DiscId = $rec.discId; DiscFolder = $rec.discFolder
        Reason = $(if ($noAudio) { 'no audio stream (video-only artefact) - cannot be transcribed' }
                  else { 'audio stream present but SILENT (max volume below -45 dB) - transcribing it would hallucinate dialogue onto mute footage' })
        Evidence = "disc titles $($srcTitles -join '+') enumerated with 0 subtitle streams"
        When = (Get-Date -Format s)
      })
      continue
    }

    $stats.eligible++
    [void](Add-UniqueQueueRowToList -List $rows -SeenInRun $seenPaths -Row ([ordered]@{
      Kind = $rec.kind; Work = $o.work; Path = $f.FullName
      Season = $o.season; Episode = $o.episode
      Minutes = [math]::Round($sec / 60, 1)
      DiscId = $rec.discId; DiscFolder = $rec.discFolder
      Evidence = "disc titles $($srcTitles -join '+') enumerated with 0 subtitle streams"
    }))
  }
}

# --- source 2: an audit's transcribable set ------------------------------------------------
# Re-checked here rather than trusted: the audit ran at some earlier point, and a sidecar or a
# stream may have appeared since (the OCR track is always running). The audit supplies the
# disc-to-file LINK and the "no re-rip needed" judgement; the file's current state is checked now.
if ($AuditSet) {
  if (-not (Test-Path -LiteralPath $AuditSet)) { throw "audit set not found: $AuditSet" }
  $roots = @{ 'Movies' = [IO.Path]::Combine('\\NASTEAMV','Multimedia','Movies')
              'Television Shows' = [IO.Path]::Combine('\\NASTEAMV','Multimedia','Television Shows') }
  # $seenPaths is the SAME table source 1 populated above, and stays current as THIS loop adds
  # rows too (Add-UniqueQueueRowToList updates it on every add) - this is the fix for the bug
  # that let two AuditSet entries resolving to the same $full both get added in one run: the old
  # $known table was a snapshot taken once, before this loop started, and was never updated as
  # the loop itself added rows.
  $added = 0
  foreach ($a in (Get-Content -LiteralPath $AuditSet -Raw | ConvertFrom-Json)) {
    $root = $roots[$a.kind]
    if (-not $root) { continue }
    $full = Join-Path $root $a.rel
    if ($seenPaths.ContainsKey((Get-QueueRowKey $full))) { continue }
    if (-not (Test-Path -LiteralPath $full)) { $stats.notPublished++; continue }

    $f = Get-Item -LiteralPath $full
    $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
    if (@(Get-ChildItem -LiteralPath $f.DirectoryName -Filter "$stem*.srt" -File -EA SilentlyContinue).Count) {
      $stats.hasSidecar++; continue
    }
    $codecs = & $ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 -- $f.FullName 2>$null
    if (@($codecs | Where-Object { $_ }).Count) { $stats.hasStream++; continue }

    $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 -- $f.FullName 2>$null)".Trim()
    $sec = 0.0; [double]::TryParse($d, [ref]$sec) | Out-Null
    if ($sec -lt $MinSeconds) { $stats.tooShort++; continue }

    # Absence of a stream, OR a stream carrying nothing but noise floor - both are terminal,
    # and only the second one lies about itself. See Test-AudioIsSilent.
    $noAudio = -not (Test-HasAudioStream $f.FullName)
    $silent  = (-not $noAudio) -and (Test-AudioIsSilent $f.FullName)
    if ($noAudio -or $silent) {
      $stats.noAudioStream++
      $naRows.Add([pscustomobject]@{
        Kind = $a.kind; Work = $a.work; Path = $f.FullName
        Season = ''; Episode = ''
        Minutes = [math]::Round($sec / 60, 1)
        DiscId = ''; DiscFolder = $a.disc
        Reason = $(if ($noAudio) { 'no audio stream (video-only artefact) - cannot be transcribed' }
                  else { 'audio stream present but SILENT (max volume below -45 dB) - transcribing it would hallucinate dialogue onto mute footage' })
        Evidence = "audit: no re-rip needed; disc '$($a.disc)' title t$($a.tid) has 0 subtitle streams"
        When = (Get-Date -Format s)
      })
      continue
    }

    $added2 = Add-UniqueQueueRowToList -List $rows -SeenInRun $seenPaths -Row ([ordered]@{
      Kind = $a.kind; Work = $a.work; Path = $f.FullName
      Season = ''; Episode = ''
      Minutes = [math]::Round($sec / 60, 1)
      DiscId = ''; DiscFolder = $a.disc
      Evidence = "audit: no re-rip needed; disc '$($a.disc)' title t$($a.tid) has 0 subtitle streams"
    })
    if ($added2) { $stats.eligible++; $added++ }
  }
  Write-Host "audit set contributed $added file(s)"
}

# DO NOT SHRINK A POPULATED QUEUE WITHOUT BEING TOLD TO.
#
# This overwrote a 223-row queue with ZERO rows on 2026-09-01 and reported it as success. The cause
# was benign and easy to repeat: the 223 came from a run with `-AuditSet`, and re-running WITHOUT
# that argument narrows the universe to the disc-identity register's own outputs - 20 of them, all
# of which had subtitles. The script was not wrong about what it was asked; it was asked a smaller
# question and silently replaced the answer to a bigger one.
#
# Rebuilding a work queue is normal. Destroying one is not, and "0 rows" is the shape that costs
# most - the transcribe loop would simply have found nothing to do and looked healthy doing it.
$existing = 0
if (Test-Path -LiteralPath $Out) {
  $existing = @(Import-Csv -LiteralPath $Out -ErrorAction SilentlyContinue).Count
}
# -Append: MERGE this run's rows into the queue instead of replacing it.
#
# WHY THIS IS THE RIGHT ANSWER AND -Force IS NOT. A rebuild is only ever as wide as the sources it
# was given, and the queue accumulates across many runs with different -AuditSets. On 2026-09-06,
# adding four Clayhanger episodes meant a run that produced 17 rows against a queue of 72, so the
# shrink guard refused - correctly. Measured before touching anything: 60 of those 72 already had
# their .srt and were merely stale, which makes -Force LOOK safe. It was not. Comparing the rebuilt
# set against the live one showed it would have dropped ALL ELEVEN rows that were still genuinely
# pending - Danger Man galleries, Doctor Who galleries, two film trailers, an Ultraviolet extra and
# a League of Gentlemen interview - because this run's sources did not cover them. "Most of the
# queue is done" is not evidence that the rest is disposable.
#
# So the operation actually wanted was never "replace with a smaller set". It was "add these".
# Appending keeps every existing row untouched and adds only paths not already queued - each one
# having passed the same sidecar / subtitle-stream / audio-stream / duration checks above, because
# it comes out of this very run. It is also what makes the AUTOMATIC call safe: the rip and publish
# tracks can enqueue newly published files on every pass without any risk of narrowing the queue.
if ($Append -and (Test-Path -LiteralPath $Out)) {
  $old = @(Import-Csv -LiteralPath $Out -ErrorAction SilentlyContinue)
  $have = @{}
  foreach ($o in $old) { if ("$($o.Path)") { $have["$($o.Path)".ToLowerInvariant()] = $true } }
  $add = @($rows | Where-Object { "$($_.Path)" -and -not $have.ContainsKey("$($_.Path)".ToLowerInvariant()) })
  if ($add.Count -eq 0) {
    Write-Host "APPEND: nothing new - all $($rows.Count) eligible row(s) are already queued ($($old.Count) row(s) unchanged)."
    exit 0
  }
  ($old + $add) | Sort-Object Work, Season, Episode | Export-Csv -LiteralPath $Out -NoTypeInformation -Encoding UTF8
  Write-Host "APPEND: +$($add.Count) row(s) -> $Out (was $($old.Count), now $($old.Count + $add.Count)); nothing removed"
  foreach ($a in ($add | Select-Object -First 10)) { Write-Host "   + $($a.Work) - $([IO.Path]::GetFileName($a.Path))" }
  exit 0
}
if ($existing -gt 0 -and $rows.Count -lt $existing -and -not $Force) {
  Write-Host ""
  Write-Host "REFUSING to overwrite $Out - it holds $existing row(s) and this run produced $($rows.Count)." -ForegroundColor Red
  if (-not $AuditSet) {
    Write-Host "  No -AuditSet was given, so only the identity register's own outputs were considered."
    Write-Host "  The larger queue was almost certainly built WITH an audit set; re-run with it."
  }
  Write-Host "  Pass -Force if you really mean to replace the queue with the smaller set."
  exit 2
}
$rows | Sort-Object Work, Season, Episode | Export-Csv -LiteralPath $Out -NoTypeInformation -Encoding UTF8

# Same anti-shrink protection as the queue above, and for the same reason: this run's source
# scope (identity register alone, vs identity register + an -AuditSet) decides how much of the
# not-applicable universe it can even see. A narrower run must not silently erase rows a wider
# run already proved.
$existingNA = 0
if (Test-Path -LiteralPath $NotApplicable) {
  $existingNA = @(Import-Csv -LiteralPath $NotApplicable -ErrorAction SilentlyContinue).Count
}
if ($existingNA -gt 0 -and $naRows.Count -lt $existingNA -and -not $Force) {
  Write-Host ""
  Write-Host "REFUSING to overwrite $NotApplicable - it holds $existingNA row(s) and this run produced $($naRows.Count)." -ForegroundColor Red
  Write-Host "  Pass -Force if you really mean to replace it with the smaller set." -ForegroundColor Red
} else {
  $naRows | Sort-Object Work, Path | Export-Csv -LiteralPath $NotApplicable -NoTypeInformation -Encoding UTF8
}

Write-Host ''
foreach ($k in $stats.Keys) { "  {0,-18} {1}" -f $k, $stats[$k] }
Write-Host ''
Write-Host "QUEUED: $($rows.Count) -> $Out"
if ($stats.discHadSubs) {
  Write-Host "NOTE: $($stats.discHadSubs) output(s) excluded because their disc DOES carry subtitles -" -ForegroundColor Yellow
  Write-Host "      those belong to the re-rip or OCR track, not here." -ForegroundColor Yellow
}
if ($stats.noAudioStream) {
  Write-Host "NOT APPLICABLE: $($stats.noAudioStream) file(s) have no audio stream at all (video-only" -ForegroundColor Yellow
  Write-Host "      artefacts) and can never be transcribed -> $NotApplicable" -ForegroundColor Yellow
}
