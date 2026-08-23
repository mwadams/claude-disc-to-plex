<#
  lib-subtitles.ps1 — shared subtitle-stream predicates and evidence-verdict helpers.
  Dot-source this; it defines functions and does nothing on its own.

  WHY THIS EXISTS. A DECLARED bitmap subtitle track is not necessarily a POPULATED one. Camille
  (1921) is a silent film whose DVD declares a `dvd_subtitle` stream carrying ZERO packets. Every
  consumer that reasons from the stream LIST rather than its CONTENTS gets this wrong:

    - ocr-subtitles.ps1 extracts a 70-minute track and produces nothing,
    - no sidecar is written, so
    - publish-work.ps1 refuses the work "awaiting OCR" - forever, and
    - the OCR loop re-picks the same file on every pass, spinning on it.

  Nothing errors. The work simply never reaches the NAS, and the only symptom is a title that
  quietly fails to appear in Plex.

  This was met before and recorded in follow-up.md as a LIST OF AFFECTED WORKS rather than as a
  behaviour change, which is why it recurred - a note describes a problem, a predicate prevents it.
#>

# Internal: the cache file for a media path. Keyed on path+size+mtime so any rewrite of the
# media (a re-encode selecting a different track, a remux) invalidates every stored verdict.
function Get-BitmapSubsCachePath {
  param(
    [Parameter(Mandatory)][string]$Path,
    [string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'disc-to-plex\subcache')
  )
  $item = Get-Item -LiteralPath $Path
  $key  = '{0}|{1}|{2}' -f $item.FullName, $item.Length, $item.LastWriteTimeUtc.Ticks
  $md5  = [Security.Cryptography.MD5]::Create()
  $hash = [BitConverter]::ToString($md5.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))).Replace('-','')
  Join-Path $CacheDir "$hash.txt"
}

# THE one place the pipeline's subtitle state distinctions live. Four verdicts:
#
#   none       - no bitmap subtitle stream at all. Nothing to OCR, nothing to wait for.
#   empty      - a bitmap stream is DECLARED but carries no packets (Camille 1921). Positive
#                finding of emptiness: stop waiting.
#   populated  - packets exist and no settled verdict has been recorded. OCR should attempt (or
#                retry) this file; publish must wait for a sidecar or a settled verdict.
#   exhausted  - OCR RAN and POSITIVELY found nothing usable (wordless short - Knick Knack).
#                Stop attempting AND stop blocking publish.
#   blocked:*  - OCR RAN and hit a defect that retrying cannot fix while the file stays the same
#                (wrong-language track, dictionary near-miss, unreadable bitmaps). Stop burning
#                CPU on re-attempts, but KEEP PUBLISH BLOCKED so the defect stays visible instead
#                of shipping quietly. The text after 'blocked:' says why.
#
# A verdict must be EARNED by a positive finding. An unexplained failure writes NOTHING here, so
# the file stays 'populated' and is retried - failure is never allowed to look like emptiness.
function Get-BitmapSubsVerdict {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Ffprobe,
    [string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'disc-to-plex\subcache')
  )

  $codecs = @(& $Ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 $Path 2>$null)
  if (-not ($codecs | Where-Object { $_ -match 'dvd_subtitle|hdmv_pgs_subtitle' })) { return 'none' }

  $cache = Get-BitmapSubsCachePath -Path $Path -CacheDir $CacheDir
  if (Test-Path -LiteralPath $cache) {
    $v = (Get-Content -LiteralPath $cache -Raw).Trim()
    if ($v) { return $v }
  }

  # Counting packets means a full pass over the file, so the answer is cached: it can only change
  # if the media file itself is rewritten, which is why the cache key includes size and mtime.
  $n = @(& $Ffprobe -v error -select_streams s -show_entries packet=pts_time -of csv=p=0 $Path 2>$null).Count
  $verdict = if ($n -gt 0) { 'populated' } else { 'empty' }
  New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
  Set-Content -LiteralPath $cache -Value $verdict
  return $verdict
}

# True when the file still OWES the pipeline a decision: either OCR has not produced a settled
# verdict yet ('populated') or it hit a defect that must not ship quietly ('blocked:*').
# _publish.ps1 keys its "awaiting OCR" refusal off this, so BLOCKED KEEPS PUBLISH BLOCKED -
# that is the fail-closed direction and it is deliberate.
function Test-BitmapSubsPopulated {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Ffprobe,
    [string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'disc-to-plex\subcache')
  )
  $v = Get-BitmapSubsVerdict -Path $Path -Ffprobe $Ffprobe -CacheDir $CacheDir
  return ($v -eq 'populated' -or $v -like 'blocked:*')
}

# True only when another OCR ATTEMPT could change anything. 'blocked:*' files return false here:
# re-running OCR on the same bytes reproduces the same defect, so the loop must stop re-picking
# them every pass (the wrong-language and dictionary-near-miss branches used to say "stop
# attempting" in prose while the code retried forever). The fix is a re-encode, which changes
# size/mtime and so invalidates the cached verdict automatically.
function Test-BitmapSubsAttemptable {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Ffprobe,
    [string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'disc-to-plex\subcache')
  )
  return ((Get-BitmapSubsVerdict -Path $Path -Ffprobe $Ffprobe -CacheDir $CacheDir) -eq 'populated')
}

# Record that OCR RAN on this file and produced nothing usable, so the pipeline stops waiting for
# a sidecar that is never coming.
#
# The empty-stream case above is not the only dead end. Knick Knack (1989) is a WORDLESS short: its
# bitmap track carries packets (signs and gags, not dialogue), OCR converts them to noise, and the
# dictionary gate correctly refuses to write a sidecar - "0% of lines contain a common English
# word". Correct on its own terms, but the consequences were identical to Camille (1921): no
# sidecar, so publish-work held back the ENTIRE work (a 3-minute short blocking all of Finding
# Nemo), and the OCR loop re-attempted it on every pass forever.
#
# A rejected OCR is a RESULT, not an absence of one. Recording it is what separates "not tried yet"
# from "tried, and there is nothing here" - the distinction the pipeline kept failing to make.
function Set-BitmapSubsExhausted {
  param(
    [Parameter(Mandatory)][string]$Path,
    [string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'disc-to-plex\subcache')
  )
  $cache = Get-BitmapSubsCachePath -Path $Path -CacheDir $CacheDir
  New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
  Set-Content -LiteralPath $cache -Value 'exhausted'
}

# Record that OCR RAN and hit a defect a retry cannot fix (wrong-language track, dictionary
# near-miss, unreadable bitmaps). Distinct from 'exhausted' in exactly one way: publish STAYS
# BLOCKED. The Pulling episodes (2026-08-20) are why that distinction exists - a quality
# near-miss recorded as "no text" shipped fourteen episodes with no sidecar and nothing saying so.
function Set-BitmapSubsBlocked {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Reason,
    [string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'disc-to-plex\subcache')
  )
  $cache = Get-BitmapSubsCachePath -Path $Path -CacheDir $CacheDir
  New-Item -ItemType Directory -Path $CacheDir -Force | Out-Null
  # single line: the verdict reader trims and compares the whole content
  Set-Content -LiteralPath $cache -Value ('blocked:' + ($Reason -replace '\s+', ' ').Trim())
}

# ---------------------------------------------------------------------------------------------
# THE SHARED OUTCOME CLASSIFIER for an OCR attempt that produced no sidecar.
#
# This logic lived inline in _ocr-loop.ps1, where the same defect was fixed four separate times as
# one more elseif: any outcome the chain did not anticipate fell into a catch-all that recorded
# the PERMANENT verdict "no text here" - marking a feature with 2002 subtitle packets as having
# nothing, publishing Japanese subs stamped eng, and shipping fourteen episodes sidecar-less.
# Classification now lives HERE so every consumer distinguishes the same three things the same
# way:  a positive finding of emptiness / a defect that must not ship / an unexplained failure.
#
# Returns an object:
#   Status        no-text | wrong-language | quality-near-miss | recognition-failed |
#                 vanished | unexplained
#   Verdict       what to record: 'exhausted' (only for no-text), 'blocked' (defects), or
#                 '' (record NOTHING - unexplained failures and vanished files must retry)
#   BlockReason   short reason string for Set-BitmapSubsBlocked when Verdict is 'blocked'
#   Lines         human-readable explanation for the loop's log
function Resolve-OcrOutcome {
  param(
    # the OCR run's captured output, as one string (pipe it through Out-String first)
    [Parameter(Mandatory)][AllowEmptyString()][string]$OutputText,
    # does the source media file still exist? (a vanished file is not a subtitle verdict)
    [Parameter(Mandatory)][bool]$SourceExists
  )

  # ORDER MATTERS. The defect patterns are checked before the no-text patterns because several
  # gate messages mention cues in both directions, and the catch-all must stay LAST and must
  # never record anything.
  if ($OutputText -match 'not English text|non-English function words') {
    # Fantasia's extras carry SPANISH subtitles tagged `eng`. OCR worked perfectly; the disc lies.
    # Marking this exhausted would have published the featurette with a Spanish track labelled
    # English and called the pipeline clean. Needs a re-encode selecting the real English stream.
    return [pscustomobject]@{
      Status = 'wrong-language'; Verdict = 'blocked'
      BlockReason = 'wrong-language subtitle track - disc mislabels it; needs a re-encode selecting the real English stream'
      Lines = @(
        '*** WRONG-LANGUAGE SUBTITLE TRACK - the disc mislabels it. Needs a re-encode selecting'
        '    the real English stream. Publishing stays blocked on purpose; no further OCR retries'
        '    until the file is rewritten.'
      )
    }
  }
  if ($OutputText -match 'in the English dictionary') {
    # The dictionary gate rejects a conversion scoring below its floor on well-recognised words
    # ("letters are being split"). A QUALITY NEAR-MISS is the opposite of "no text", yet the old
    # catch-all recorded it as exhausted - which is how fourteen Pulling episodes shipped with
    # bitmap-only subtitles (2026-08-20, user reported).
    return [pscustomobject]@{
      Status = 'quality-near-miss'; Verdict = 'blocked'
      BlockReason = 'dictionary gate rejected the conversion (quality near-miss, letters split) - fix the source or OCR path'
      Lines = @(
        '*** DICTIONARY GATE REJECTED THE CONVERSION - the text WAS read but scored below the'
        '    floor (letters being split). This is a quality near-miss, NOT "no text".'
        '    Publishing stays blocked on purpose; no further OCR retries until the file changes.'
      )
    }
  }
  if ($OutputText -match 'recognition failed|1-2 chars|nOCR signature') {
    # Cloud Atlas: seven untagged PGS streams, s:0 was JAPANESE; an English engine handed Japanese
    # glyphs recognises no words at all. A recognition failure means the picture could not be
    # read - a reason to STOP, not a verdict that there is nothing there.
    return [pscustomobject]@{
      Status = 'recognition-failed'; Verdict = 'blocked'
      BlockReason = 'OCR could not read the bitmaps at all - usually the wrong track was selected (untagged streams)'
      Lines = @(
        '*** OCR RECOGNITION FAILED - the bitmaps could not be read at all. This usually means the'
        '    WRONG TRACK was selected (untagged PGS: check every stream, do not trust the tag).'
        '    Publishing stays blocked on purpose; no further OCR retries until the file changes.'
      )
    }
  }
  if (-not $SourceExists) {
    # A rename or reclaim between the directory scan and the OCR attempt is not a verdict about
    # the file's subtitles. Record NOTHING (recording anything would pin a verdict to a path that
    # may reappear with the same size/mtime).
    return [pscustomobject]@{
      Status = 'vanished'; Verdict = ''; BlockReason = ''
      Lines = @('source vanished mid-pass (renamed or reclaimed) - nothing recorded, will retry if it reappears')
    }
  }
  if ($OutputText -match 'no usable text|no subtitle packets|0 cues|produced no cues|subtitle track is empty|track is empty') {
    # 'subtitle track is empty - N bytes extracted' IS a positive finding: the track exists and
    # has packets, but carries no renderable text. This list must contain EVERY genuine
    # emptiness verdict the OCR gate can emit - a retry default only works if it does (You Only
    # Live Twice's Storyboard Sequence retried forever when this one was missing).
    return [pscustomobject]@{
      Status = 'no-text'; Verdict = 'exhausted'; BlockReason = ''
      Lines = @('no usable text - marked exhausted, will not be retried and no longer blocks publishing')
    }
  }
  # THE DEFAULT IS RETRY, NOT A VERDICT. Contention, a partially written file, a crashed child, a
  # locked temp dir - anything unclassified is just a failure. It is the worst possible thing to
  # write down as "there is no text here": irreversible, silently unblocks publishing, invisible.
  return [pscustomobject]@{
    Status = 'unexplained'; Verdict = ''; BlockReason = ''
    Lines = @(
      '*** OCR PRODUCED NO SIDECAR AND GAVE NO REASON - nothing recorded, will retry.'
      '    If this repeats for the same file, read the gate output rather than assuming.'
    )
  }
}

# ---------------------------------------------------------------------------------------------
# THE SHARED CLASSIFIER for transcribe-wav.py output (speech samples in the catalogues).
#
# transcribe-wav.py emits a POSITIVE marker for every outcome: text, '[no-speech]' when it ran
# and heard nothing, '[transcription-failed] ...' when it crashed. That leaves exactly one
# meaning for EMPTY output: the transcriber never ran at all (python missing, faster-whisper not
# installed, the process killed) - which the old `if ($txt)` check silently recorded as "this
# title has no speech". On Witness the feature came back speech=False while every short title
# succeeded, and the cause was contention, not the disc.
#
# Returns an object:  Status = ok | no-speech | failed ;  Text = the transcript ('' otherwise) ;
#                     Detail = the failure marker line when Status is failed
function Resolve-TranscribeOutput {
  param([AllowNull()][AllowEmptyCollection()][object[]]$OutputLines)

  $joined = (@($OutputLines) | ForEach-Object { "$_" }) -join ' '
  $joined = ($joined -replace '\s+', ' ').Trim()
  if (-not $joined) {
    return [pscustomobject]@{ Status = 'failed'; Text = ''
      Detail = 'transcriber produced NO output at all - it never ran (python/faster-whisper missing, or the process died)' }
  }
  if ($joined -match '\[transcription-failed\]') {
    return [pscustomobject]@{ Status = 'failed'; Text = ''; Detail = $joined }
  }
  if ($joined -match '\[no-speech\]') {
    return [pscustomobject]@{ Status = 'no-speech'; Text = ''; Detail = '' }
  }
  return [pscustomobject]@{ Status = 'ok'; Text = $joined; Detail = '' }
}
