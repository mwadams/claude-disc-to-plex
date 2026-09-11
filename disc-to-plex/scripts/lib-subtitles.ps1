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
  #
  # AND ON A NAS FILE THAT FULL PASS MUST BE GOVERNED. This ran bare, so it pulled an entire
  # multi-gigabyte container across the link at whatever speed SMB would give it - no read slot, no
  # ceiling, and no kill switch. 2026-09-11: starting the ocrqueue track took the Wi-Fi link from
  # idle to 483 Mbps in fifteen seconds, on this one line, while a properly governed transcribe read
  # sat beside it paced at `-readrate 16.532`. It is the same defect that had already been found in
  # queue-transcribable.ps1's loudness probe earlier the same evening: the governor is only as good
  # as the callers that go through it, and a cache does not help the FIRST time each file is seen -
  # which, across a 1,708-row library sweep, is every file.
  #
  # -readrate paces ffprobe itself, so the read is stretched rather than buffered: the governor's own
  # measured ceiling divided by this file's bitrate, exactly as transcribe-subtitles.py does it.
  # Falls back to the bare call only when the governor library is not loaded (a local path, or a
  # caller that never dot-sourced it) - never silently on a NAS path.
  # THE SLOT IS NOT THE THROTTLE. Invoke-NasRead takes a read slot and paces AFTERWARDS, measuring
  # what the item cost and sleeping to bring the average down. That is right for a short read, and
  # useless for a whole-file scan: the read itself still bursts at link speed, then sleeps. Measured
  # 2026-09-11 with the slot in place and nothing else changed: 480, 498, 454, 488 Mbps in
  # consecutive 15 s samples, then 83, then 239 - a sawtooth, exactly as designed, and exactly what
  # crippled the machine.
  #
  # `-readrate` is the part that paces ffprobe ITSELF, and Get-NasReadRateArgs (lib-nas-governor.ps1)
  # already computes it from this file's own bitrate against the configured ceiling - the same
  # helper transcribe-subtitles.py uses, which is why that reader sat at a well-behaved 16.532x
  # beside this one at 500 Mbps. It returns EMPTY for a local path or when size/duration cannot be
  # established, so an ungoverned read remains the failure mode rather than a refusal.
  $rateArgs = @()
  if (Get-Command Get-NasReadRateArgs -ErrorAction SilentlyContinue) {
    try { $rateArgs = @(Get-NasReadRateArgs -Path $Path -Ffprobe $Ffprobe) } catch { $rateArgs = @() }
  }
  $probeArgs = @('-v','error') + $rateArgs + @('-select_streams','s','-show_entries','packet=pts_time','-of','csv=p=0',$Path)
  # UNC is detected HERE, not via Test-NasPath, so the detection cannot depend on the very library
  # whose absence is the hazard. A caller that forgot to dot-source the governor then gets a loud
  # warning instead of a silent full-speed pull - which is exactly how this went unnoticed twice.
  $isUnc = "$Path".StartsWith('\\')
  $govReady = [bool](Get-Command Invoke-NasRead -ErrorAction SilentlyContinue) -and
              [bool](Get-Command Wait-NasHold -ErrorAction SilentlyContinue)
  if ($isUnc -and -not $govReady) {
    Write-Warning ("Get-BitmapSubsVerdict: counting packets on a NAS path with NO governor loaded - this will read the whole file at link speed. Dot-source lib-nas-governor.ps1 in the caller. Path: {0}" -f $Path)
  }
  $isNas = $isUnc -and $govReady
  if ($isNas) {
    [void](Wait-NasHold -Say { param($m) Write-Host "  [governor] $m" } -Who 'bitmap-subs-verdict')
    $lines = Invoke-NasRead -Path $Path -Label ("packet count " + (Split-Path $Path -Leaf)) -Say { param($m) Write-Host "  [governor] $m" } -Do {
      & $Ffprobe @probeArgs 2>$null
    }
    $n = @($lines).Count
  } else {
    $n = @(& $Ffprobe @probeArgs 2>$null).Count
  }
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
  if ($OutputText -match 'already has text subs') {
    # ocr-subtitles.ps1's own "nothing to gain" skip: the file already carries a text (SRT/mov_text)
    # subtitle track alongside the bitmap one. Added 2026-09-03 after Beowulf (2007).mkv - it has
    # BOTH a dvd_subtitle track AND a subrip 'eng' track already - hit exactly this skip every
    # single time, produced NO text this classifier had a pattern for, and so retried 3x and landed
    # in 'failed' with no real diagnosis, when the true, correct, PERMANENT answer was "there is
    # nothing to OCR here, this file is already covered by its own text track".
    return [pscustomobject]@{
      Status = 'already-has-text'; Verdict = 'exhausted'; BlockReason = ''
      Lines = @('already carries its own text subtitle track alongside the bitmap one - nothing to gain from OCR, marked exhausted (this is a correct outcome, not a failure)')
    }
  }
  if ($OutputText -match 'no [a-z]{3}-language bitmap subtitle stream') {
    # ocr-subtitles.ps1 selects a bitmap track "in the wanted language (untagged counts as eng)".
    # When the ONLY bitmap track(s) present carry some OTHER explicit language tag, there is no
    # candidate to OCR at all - added 2026-09-03 after Cairo Time.mkv, whose only PGS track is
    # tagged German. This is DISTINCT from 'wrong-language' above (which fires only after OCR
    # actually ran and READ text that turned out not to be English) - here OCR never runs at all.
    # BLOCKED, not exhausted: the disc may genuinely have no English subtitle option (nothing more
    # to do), or it may have one on a different, unselected track (worth a human re-rip decision) -
    # either way that is a judgement call this classifier should not make silently, so it stays
    # visible rather than being written off as settled emptiness.
    return [pscustomobject]@{
      Status = 'no-language-candidate'; Verdict = 'blocked'
      BlockReason = 'no bitmap subtitle stream in the requested language - the only bitmap track(s) present are tagged a different language; check whether the disc actually offers an English option before writing this off'
      Lines = @(
        '*** NO BITMAP SUBTITLE STREAM IN THE REQUESTED LANGUAGE - the only track(s) present carry a'
        '    different language tag. This may be the whole story (no English subs exist on this disc)'
        '    or the disc may offer one on an unselected track - worth a human look, not an automatic'
        '    write-off. No further OCR retries until the file changes.'
      )
    }
  }
  # ONLY THE FUNCTION-WORD TEST MAY DECIDE "WRONG LANGUAGE".
  #
  # This used to match 'not English text' too - and the short-track DICTIONARY message ends with
  # exactly those words ("...are in the English dictionary (9 words) - not English text"). Because
  # this branch is tested BEFORE the dictionary branch below, every short-track vocabulary miss was
  # filed as a language fault: terminal, no retries, "needs a re-encode", and no fallback attempted.
  #
  # Star Trek: The Motion Picture, 2026-09-09 - three deleted scenes held the entire work out of the
  # library for 21 hours on that verdict. Re-rendering one produced six cues of plain English
  # ("Viewer astern." / "Hold relative position here."); the words the dawg lacked were `astern` and
  # `metres`. A vocabulary gap is not a language, and the wording of a message is not a diagnosis.
  #
  # The function-word test IS a test for the thing itself - Spanish/French/German/Dutch function
  # words - and it is what actually caught Fantasia's Spanish-tagged-English extras. It keeps this
  # branch; the dictionary percentage falls through to 'quality-near-miss' below, which is retried
  # with the anti-alias-preserving renderer instead of being written off.
  if ($OutputText -match 'non-English function words') {
    # Fantasia's extras carry SPANISH subtitles tagged `eng`. OCR worked perfectly; the disc lies.
    # Marking this exhausted would have published the featurette with a Spanish track labelled
    # English and called the pipeline clean.
    #
    # WHAT THIS VERDICT MAY AND MAY NOT CLAIM. It used to end "needs a re-encode selecting the real
    # English stream", which asserts two things this evidence does not support: that an English
    # stream exists, and that a re-encode is the way to reach it. Measured 2026-09-10 across the 177
    # files carrying it, those two claims were wrong in opposite directions:
    #
    #   - 170 of the 177 published files carry EXACTLY ONE subtitle stream. There is nothing in the
    #     file to re-select, so "re-encode selecting the real English stream" is not an instruction
    #     anyone can follow - it needs the SOURCE DISC, and for 136 of those files (Deep Space Nine,
    #     The Italian Job, In the Line of Fire, Angel, Superman Returns) the library predates this
    #     pipeline: no manifest, no catalogue, no disc-identity record, no disc.
    #   - The other 7 - Monty Python's Flying Circus - carry TWENTY-ONE bitmap streams each, all
    #     untagged and all full of real packets, and stream 17 is plain English. Those needed no
    #     re-encode at all; they needed us to read a different track of the file we already had.
    #
    # So the verdict SPLITS on evidence ocr-subtitles.ps1 now prints: how many other bitmap streams
    # were in the file and never tried. Both halves stay 'blocked' - retrying would re-read the same
    # first stream and reach the same answer - but they name different remedies, and the multi-stream
    # half is clearable by sweep-subtitle-streams.ps1 without touching the media.
    if ($OutputText -match 'OTHER BITMAP STREAMS UNTRIED: (\d+)') {
      $n = $Matches[1]
      return [pscustomobject]@{
        Status = 'wrong-language-untried-streams'; Verdict = 'blocked'
        BlockReason = "read a non-English bitmap track, but $n other bitmap stream(s) in this file were never tried - run sweep-subtitle-streams.ps1 to find the English one; no re-rip needed"
        Lines = @(
          "*** WRONG-LANGUAGE TRACK, BUT $n OTHER BITMAP STREAM(S) WERE NEVER TRIED. The stream we"
          '    read is not English; the file may still hold an English one on another track (Monty'
          "    Python's Flying Circus carries 21, English at stream 17). This needs no re-rip -"
          '    run sweep-subtitle-streams.ps1 on this file, then OCR with -StreamIndex <index>.'
          '    Publishing stays blocked until then; re-OCR would re-read the same first stream.'
        )
      }
    }
    return [pscustomobject]@{
      Status = 'wrong-language'; Verdict = 'blocked'
      BlockReason = 'the only bitmap subtitle track in this file is not English - the published file cannot supply English subtitles; needs the SOURCE DISC re-ripped selecting an English stream, if the disc offers one at all'
      Lines = @(
        '*** WRONG-LANGUAGE SUBTITLE TRACK, AND IT IS THE ONLY ONE IN THE FILE. The published file'
        '    cannot supply English subtitles by any re-mux. Remedy needs the SOURCE DISC: re-rip'
        '    selecting an English stream if the disc offers one, otherwise this release has no'
        '    English subtitles and the file belongs on the transcribe route instead.'
        '    Publishing stays blocked on purpose; no further OCR retries until the file is rewritten.'
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
  if ($OutputText -match 'produced no OCR text and were dropped|No subtitles recognised in VobSub') {
    # EVERY image OCR'd to nothing, on a track that demonstrably HAS text.
    #
    # Babylon 5 S00E26 "The Universe of Babylon 5 (Season 3)": tesseract returned nothing for all
    # 118 images, while its sibling on the same disc, with a byte-identical palette, read 61 of 62.
    # Rendering the subpicture shows exactly why - these cues are set in an ITALIC face
    # ("Subject: Zack Allan.") where the sibling's are upright. The text is perfectly legible to a
    # human; our OCR path cannot read this face.
    #
    # This is 'blocked', NOT 'exhausted'. The distinction is the whole point of this function:
    # exhausted asserts THERE IS NO TEXT, which here is false and would ship an extra as
    # subtitle-less while recording that its subtitles had been checked. Blocked says the opposite
    # - there IS text and we failed to read it - so publishing stays held until someone fixes the
    # OCR path or decides the extra ships without.
    #
    # Before this pattern existed the message matched nothing and fell to the catch-all, so the
    # loop retried the same file forever while holding twelve finished files behind it.
    return [pscustomobject]@{
      Status = 'ocr-unreadable-face'; Verdict = 'blocked'
      BlockReason = 'every subtitle image OCRd to nothing though the track carries visible text - usually an italic or stylised face our tesseract path cannot read'
      Lines = @(
        '*** OCR READ NOTHING FROM ANY IMAGE, but the track is not empty. Look at the subpicture'
        '    before believing it is blank - render it with:'
        '      ffmpeg -i <file> -filter_complex "color=gray:s=720x576[bg];[bg][0:s:0]overlay" -ss <t> -frames:v 1 out.png'
        '    An ITALIC or stylised face defeats this OCR path while a human reads it easily.'
        '    Publishing stays blocked on purpose - this is NOT a finding that the track is empty.'
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
# THE SECOND-ATTEMPT RENDERER, SHARED BY BOTH OCR TRACKS.
#
# WHY THIS IS A FUNCTION AND NOT A BLOCK IN A LOOP. It used to live inline in _ocr-loop.ps1 only,
# and _ocr-queue-loop.ps1 never had it - so the SAME file got a second attempt under D:\video and
# was written off on the NAS. Both loops already share the worker (ocr-subtitles.ps1) and the
# classifier (Resolve-OcrOutcome); this was the one behaviour that had drifted, and it drifted
# precisely because it was copied into one caller instead of shared by both. Operator asked the
# right question on 2026-09-10: "are they consistent and sharing code?"
#
# WHAT IT IS FOR. 'quality-near-miss' means the text WAS read and scored below the floor - "letters
# are being split". That is a RENDERING fault with a known fix: the default path (seconv +
# Tesseract) isolates the fill colour, and its only lever is a palette DECISION taken from a
# measured ratio (Moulin Rouge measured 0.143 against a 0.15 floor, declined, and turned 1,986
# clean lines into "FES OSE t ys"). ocr-paddle.ps1 + vobsub-render.py decode the SPU directly and
# render GREYSCALE BY LUMINANCE, so there is no isolation decision to get wrong and it cannot fail
# that particular way. Slower, so it is a SECOND attempt only - the cost is paid where it is earned.
#
# 'blocked' means "stop retrying AND keep publish blocked", so recording it before trying this
# writes off a file we can still read: Star Trek The Motion Picture sat sixteen hours holding 12
# finished files, and the same render cleared it in 13 minutes once tried by hand.
#
# Returns $true if a sidecar now exists (the caller should treat the file as converted and record
# NO verdict). Returns $false otherwise, having appended to $Outcome.BlockReason so the recorded
# block carries an honest history of both attempts.
function Invoke-OcrDirectRenderFallback {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$Sidecar,
    [Parameter(Mandatory)][AllowNull()]$Outcome,
    [string]$PaddleScript = 'D:/video/.claude/skills/disc-to-plex/scripts/ocr-paddle.ps1',
    [scriptblock]$Say = $null
  )
  function Emit([string]$m) { if ($Say) { & $Say $m } else { Write-Output $m } }

  if ($null -eq $Outcome -or "$($Outcome.Status)" -ne 'quality-near-miss') { return $false }
  if (-not (Test-Path -LiteralPath $PaddleScript)) {
    Emit '    direct-render fallback not present (ocr-paddle.ps1) - recording the block as-is'
    return $false
  }
  Emit '    dictionary gate rejected it - retrying ONCE with the direct renderer (anti-alias preserved) ...'
  try {
    & pwsh -NoProfile -File $PaddleScript -Path $Path 2>&1 | ForEach-Object { Emit ("      " + $_) }
  } catch {
    Emit ("      fallback threw: " + $_.Exception.Message)
  }
  if (Test-Path -LiteralPath $Sidecar) {
    Emit '      RECOVERED by the direct renderer - no verdict recorded, publish is free'
    return $true
  }
  $Outcome.BlockReason = "$($Outcome.BlockReason); the direct-render fallback (ocr-paddle.ps1) also failed"
  return $false
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

function Test-LangTagMatches {
  <#
    .SYNOPSIS
      Does a stream's language TAG name the language we are asking for? 'en' and 'eng' both do.

    .WHY
      Discs tag subtitle streams with ISO 639-1 ('en'), ISO 639-2/T ('eng'), ISO 639-2/B ('ger' for
      German), or a region-qualified form ('en-GB', 'pt_BR') - and a plain string comparison against
      'eng' rejects most of them. ocr-subtitles.ps1 did exactly that, and recorded the result as
      "no bitmap subtitle stream in the requested language", a verdict that reads like a fact about
      the disc. Measured 2026-09-11: 44 of the 45 files carrying it were tagged `en` and were
      English all along - Studio 60's 22 episodes among them.

    .HOW
      Lowercase, drop the region suffix, then match if either code prefixes the other at >= 2 chars
      (en/eng, fr/fra, nl/nld). The bibliographic aliases do not share a prefix with their 639-1
      code, so those are listed explicitly. Unknown pairs do NOT match: the caller uses this to
      decide whether to OCR a stream as English, and a wrong yes ships a foreign track labelled eng.
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Tag,
    [Parameter(Mandatory)][AllowEmptyString()][string]$Want
  )
  function Normalise([string]$s) { (("$s".Trim().ToLowerInvariant()) -split '[-_]')[0] }
  $t = Normalise $Tag; $w = Normalise $Want
  if (-not $t -or -not $w) { return $false }
  if ($t -eq $w) { return $true }
  # ISO 639-2/B (bibliographic) forms that do NOT share a prefix with their 639-1 code.
  $alias = @{
    'ger' = 'de'; 'fre' = 'fr'; 'dut' = 'nl'; 'gre' = 'el'; 'chi' = 'zh'; 'cze' = 'cs'
    'ice' = 'is'; 'mac' = 'mk'; 'mao' = 'mi'; 'may' = 'ms'; 'per' = 'fa'; 'rum' = 'ro'
    'slo' = 'sk'; 'tib' = 'bo'; 'wel' = 'cy'; 'arm' = 'hy'; 'baq' = 'eu'; 'bur' = 'my'; 'geo' = 'ka'
  }
  if ($alias.ContainsKey($t)) { $t = $alias[$t] }
  if ($alias.ContainsKey($w)) { $w = $alias[$w] }
  if ($t -eq $w) { return $true }
  if ($t.Length -ge 2 -and $w.Length -ge 2) {
    if ($t.StartsWith($w) -or $w.StartsWith($t)) { return $true }
  }
  return $false
}

function Repair-OcrGlyphs {
  # Repair the two systematic Tesseract glyph errors on disc subtitles, in ONE definition used by
  # both the live OCR pass (ocr-subtitles.ps1) and the retroactive sweep (fix-srt-glyphs.ps1).
  # Duplicating them would rot: the two copies would drift and the sweep would stop matching what
  # new conversions produce.
  #
  # Returns a hashtable: @{ Text = <repaired text>; Pipes = n; Notes = n }. The caller decides
  # whether to write, so this function has no side effects and is trivially testable.
  #
  # PIPE -> I. "Ol! | was here before you!". Safe in one direction only: a pipe is essentially
  # never legitimate in dialogue, while I is one of the commonest characters in English.
  #
  # J -> MUSIC NOTE (U+266A). Tesseract has no glyph for it and reads it as a capital J, so a sung
  # cue ships as "J Fanfare". The OCR junk gate cannot see this - it counts lines under three
  # characters or below 65% letters, and "J Fanfare" is mostly letters, so it scores as clean.
  #
  # Unlike the pipe, a lone J is NOT always wrong: initials exist. The discriminator is the FULL
  # STOP - an initial is written "J. Smith", the mis-read note is a bare J, and OCR does not invent
  # a period. All three patterns are anchored to the ends of a line, so a J inside a word is never
  # touched. Doubled JJ is matched because some discs set the note at both ends.
  #
  # Deliberately NOT attempted: l/I and ./, are genuinely ambiguous, and a wrong "fix" corrupts
  # correct text, which is worse than leaving a visible artefact.
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

  $note  = [string][char]0x266A
  $pipes = 0
  $notes = 0
  $out   = New-Object System.Collections.Generic.List[string]

  foreach ($line in ($Text -split "`r?`n")) {
    # never touch the index or the timing lines
    if ($line -match '^\d+$' -or $line -match '-->') { $out.Add($line); continue }

    $l = $line
    $p = ([regex]::Matches($l, '\|')).Count
    if ($p -gt 0) { $pipes += $p; $l = $l -replace '\|', 'I' }

    # '^J{1,2}$' first - a line that is ONLY J needs no surrounding space, and it is the one form
    # the junk gate does see, being under three characters.
    foreach ($rx in @('^J{1,2}$', '^J{1,2}(?!\.)(?=\s)', '(?<=\s)J{1,2}$')) {
      $h = ([regex]::Matches($l, $rx)).Count
      if ($h -gt 0) { $notes += $h; $l = [regex]::Replace($l, $rx, $note) }
    }
    $out.Add($l)
  }

  return @{ Text = ($out -join "`r`n"); Pipes = $pipes; Notes = $notes }
}
