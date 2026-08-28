# Report when the OCR track or the NAS track goes idle WHILE WORK IS STILL PENDING.
#
# An idle track is only worth waking someone for if there is something it could be doing - "no
# robocopy running" is the normal state once everything is published. So each check pairs
# "nothing running" with "work outstanding", and prints only on transition.
param([string]$StateFile = 'D:\video\.transcode-tools\idlestate.txt')

$paths   = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'
$msgs    = @()

# COUNT ENCODE LANES BY WHAT THEY WRITE, NOT BY WHAT THEY READ.
#
# A lane is an ffmpeg writing into the library. Matching on `_stage` instead counts every other
# ffmpeg that READS staging, and identification work is full of them - the disposition agents
# extract frames and probe titles out of _stage constantly. On 2026-08-25 that reported a busy
# lane, repeatedly, while both lanes were genuinely idle and nothing was queued.
#
# Defined ONCE and used at both call sites below. The same predicate lives in _lanewatch.ps1,
# which is a separate process and cannot dot-source this one; if you change the rule, change both.
# NORMALISE THE SLASHES. ffmpeg is invoked with FORWARD-slash paths here (the manifests use them,
# because a backslash in a generated string literal silently becomes a control character), so a
# backslash-only comparison matches nothing. The first version of this function did exactly that
# and reported "NOTHING is encoding" while two encodes were running - a false negative in the very
# check that had just been fixed for a false positive. Compare on one canonical separator.
function Get-EncodeLaneCount {
  $roots = @('d:\video\movies', 'd:\video\television shows')
  @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
    Where-Object {
      $c = $_.CommandLine
      if (-not $c) { return $false }
      $n = ($c -replace '/', '\').ToLowerInvariant()
      [bool]($roots | Where-Object { $n.Contains($_) })
    }).Count
}

# Load VERIFIED - an undefined predicate would error per-file and the OCR-pending count would
# silently read as zero, i.e. the monitor would report a healthy pipeline it never measured.
. 'D:\video\.claude\skills\disc-to-plex\scripts\lib-subtitles.ps1'
if (-not (Get-Command Get-BitmapSubsVerdict -ErrorAction SilentlyContinue)) {
  throw 'lib-subtitles.ps1 failed to load - the monitor cannot measure without it'
}

# ---- OCR: idle with files still carrying bitmap subs and no sidecar -------------------------
# Ask whether the OCR JOB is running, not whether a particular tool is.
#
# A single file goes ffmpeg -> mkvextract -> seconv -> tesseract, with pwsh doing the work between
# stages, so watching for tesseract (or even all three tools) reports "OCR IDLE" during whichever
# stage happens not to be active. That fired twice against a loop that was working perfectly and
# had just written a 691-cue sidecar. A monitor that cries wolf trains you to ignore the one time
# it is right - which is precisely how an idle pipeline went unnoticed for two hours.
#
# ocr-subtitles.ps1 runs as a child pwsh for the whole job, so its presence covers every stage.
# Match EVERY OCR entry point, not just the original one. `ocr-paddle.ps1` (render + batch OCR,
# the path for discs the seconv/Tesseract route reads badly) drives the same work through a
# different script, and a check hard-coded to 'ocr-subtitles' reported "OCR IDLE" while a 27-episode
# rebuild was running flat out. Same shape of blind spot as the fetch track had: watch the WORK,
# not one process name.
$ocrBusy = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -match 'ocr-subtitles|ocr-paddle|vobsub-render' }).Count -gt 0
if (-not $ocrBusy) {
    # Matching wrapper NAMES is fragile and was proved so: a batch that dot-invokes ocr-paddle.ps1
    # from another script shows the DRIVER's command line, so the pattern above misses it entirely.
    # These are the processes that do the actual work, whoever launched them - including paddleocr
    # and the python renderer, which the original list predates.
    $ocrBusy = @(Get-Process tesseract, seconv, mkvextract, paddleocr -ErrorAction SilentlyContinue).Count -gt 0
    if (-not $ocrBusy) {
        $ocrBusy = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
                     Where-Object { $_.CommandLine -match 'vobsub-render|srt-from-paddle|paddleocr' }).Count -gt 0
    }
}
if (-not $ocrBusy) {
  $pending = 0; $ocrBlocked = 0
  foreach ($f in Get-ChildItem 'D:\video\Movies','D:\video\Television Shows' -Recurse -File -Filter *.mkv -ErrorAction SilentlyContinue) {
    $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null)".Trim()
    if (-not $d -or $d -eq 'N/A') { continue }          # still encoding - not OCR's turn yet
    # Use the SHARED verdict, not a private re-implementation. A DECLARED bitmap track is not a
    # PENDING one: an empty shell (Spartacus's 57 s teaser, Camille 1921) and a track OCR has already
    # run on and rejected both count as finished. Checking only "has a bitmap stream, has no sidecar"
    # made this monitor report "OCR IDLE with 1 file(s)" forever against a file that was correctly
    # done and already published - the same duplicate-logic trap as _publish.ps1 vs publish-work.ps1.
    #
    # BLOCKED is counted separately from PENDING: a blocked file (wrong-language track, quality
    # defect - see Resolve-OcrOutcome) is not something the OCR track can act on, so calling it
    # "awaiting a sidecar" makes this monitor cry wolf forever. It still holds publish; what it
    # needs is a re-encode, and the alarm should say so.
    if (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($f.FullName, $null) + 'eng.srt')) { continue }
    $v = Get-BitmapSubsVerdict -Path $f.FullName -Ffprobe $ffprobe
    if ($v -eq 'populated') { $pending++ }
    elseif ($v -like 'blocked:*') { $ocrBlocked++ }
  }
  if ($pending -gt 0) { $msgs += "OCR IDLE with $pending file(s) awaiting a sidecar" }
  if ($ocrBlocked -gt 0) { $msgs += "$ocrBlocked file(s) OCR-BLOCKED (wrong track / quality defect) - publish held; these need a re-encode, not an OCR retry" }
}

# ---- NAS: idle with work that is ACTUALLY publishable ---------------------------------------
#
# Only alarm when the NAS track could be doing something. publish-work.ps1 treats a work
# atomically, so a work containing ANY file still encoding or awaiting an OCR sidecar is correctly
# held back - reporting that as "NAS IDLE" is a false alarm, and a monitor that cries wolf gets
# ignored, which defeats the point of having one.
$nasBusy = @(Get-Process robocopy -ErrorAction SilentlyContinue).Count -gt 0
if (-not $nasBusy) {
  $ready = 0; $blocked = 0
  foreach ($kind in 'Movies','Television Shows') {
    $lroot = "D:\video\$kind"; $nroot = "\\NASTEAMV\Multimedia\$kind"
    if (-not (Test-Path -LiteralPath $lroot)) { continue }
    foreach ($w in Get-ChildItem -LiteralPath $lroot -Directory -ErrorAction SilentlyContinue) {
      $needs = $false; $hold = $false
      foreach ($f in Get-ChildItem -LiteralPath $w.FullName -Recurse -File -ErrorAction SilentlyContinue) {
        $t = $f.FullName.Replace($lroot, $nroot)
        if (-not (Test-Path -LiteralPath $t) -or (Get-Item -LiteralPath $t).Length -ne $f.Length) { $needs = $true }
        if ($f.Extension -ne '.mkv') { continue }
        $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null)".Trim()
        if (-not $d -or $d -eq 'N/A') { $hold = $true; continue }        # still encoding
        $codecs = @(& $ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 $f.FullName 2>$null)
        if ($codecs | Where-Object { $_ -match 'dvd_subtitle|hdmv_pgs' }) {
          if (-not (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($f.FullName, $null) + 'eng.srt'))) { $hold = $true }
        }
      }
      if ($needs) { if ($hold) { $blocked++ } else { $ready++ } }
    }
  }
  if ($ready -gt 0) { $msgs += "NAS IDLE with $ready work(s) READY to publish ($blocked more blocked on OCR/encode)" }
}

# ---- THE GAP: a disc is staged but no manifest exists for it -------------------------------
#
# The lane-runner drains a queue of manifests; nothing FILLS that queue. Authoring a manifest is
# the judgement step (which title is the feature, does it need a MakeMKV rip, what is the original
# language, how is it named) and deliberately stays manual - automating it is what produced a
# Japanese film shipped with only its English dub, and a film filed as a TV series.
#
# So the gap cannot be closed, but it must not be INVISIBLE: staging finishing while the queue is
# empty is precisely when lanes go idle unnoticed. Report it as work waiting for a decision.
$queued = @(Get-ChildItem 'D:\video\_queue' -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
$busyLanes = Get-EncodeLaneCount
if ($queued -eq 0 -and $busyLanes -lt 2) {
  # A staged folder that an encode is CURRENTLY READING is not awaiting a manifest - it already
  # has one and is in flight. Counting it produces exactly the false alarm this check exists to
  # avoid.
  $inUse = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
             ForEach-Object { $_.CommandLine })
  # And only count a disc as AWAITING A MANIFEST once its copy is byte-complete. Reporting a
  # half-copied disc as ready invites exactly the mistake the gate exists to prevent: enumerating
  # early, where MakeMKV returns a plausible feature runtime from the titles that happen to have
  # arrived. A disc still copying is the source track working, not a decision waiting on anyone.
  # 🔴 SOURCE ROOT MUST COME FROM _fetch-one.ps1, NOT BE HARD-CODED.
  # This read `Join-Path 'E:\' $n`, which was right for Media10 (discs at the drive root) and
  # WRONG for Media9, which keeps them under `E:\Movies`. The effect was silent and bad: Test-Path
  # failed for every disc, the still-copying comparison was SKIPPED entirely, and a disc that was
  # only part-copied got reported as "staged and awaiting a manifest". On 2026-08-20 that reading
  # is what convinced me R&H Disk 2 had finished; I restarted the fetch on the strength of it and
  # briefly had TWO concurrent robocopies off the same USB spindle - the exact thing one-disc-at-
  # a-time exists to prevent. `assert-staged-complete.ps1` caught the disc; nothing caught the
  # monitor. Derive the root so a drive swap cannot desynchronise the two files again.
  $srcRoot = 'E:\Movies'
  try {
    $fAst = [System.Management.Automation.Language.Parser]::ParseFile('D:\video\_fetch-one.ps1', [ref]$null, [ref]$null)
    $sp   = $fAst.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'SrcRoot' }
    if ($sp) { $srcRoot = $sp.DefaultValue.SafeGetValue() }
  } catch { }

  # A staged folder is only AWAITING A MANIFEST if the judgement step has not been taken for it.
  # Two independent signatures say it HAS been, and BOTH are needed because they cover different
  # folders:
  #   (a) a dispositions file - written by the author step, named for the DISC folder, and the
  #       thing `assert-accounted.ps1` gates on. A disc folder is never a manifest `src` (the
  #       manifest reads the MakeMKV rip), so nothing else identifies a disc as decided.
  #   (b) a manifest naming the folder as a `src` - this is what covers the `*-rip` folders, which
  #       have no dispositions file of their own.
  # Neither existed here, so on 2026-08-28 four folders whose work had been authored, encoded and
  # published - The Edge of the World, The Guardians D4, The Innocents, theedgeoftheworld-rip -
  # were named as "awaiting a manifest" on every poll. The in-flight ffmpeg test below only ever
  # catches the ONE item a lane is reading this second; it cannot see a finished unit. A monitor
  # that cries wolf is not consulted on the day it is right.
  # RESIDUAL RISK, accepted and deliberate: a unit whose dispositions were written but whose
  # manifest was then abandoned is hidden by (a). Catching an abandoned unit is `_stallwatch.ps1`'s
  # job; this check is about whether a DECISION is outstanding, and that decision was taken.
  $decided = @{}
  foreach ($dp in Get-ChildItem 'D:/video/_catalogue' -Filter '*.dispositions.txt' -ErrorAction SilentlyContinue) {
    $decided[($dp.Name -replace '\.dispositions\.txt$', '')] = $true
  }
  # Normalise separators once, so the membership test needs only the forward-slash form. A literal
  # "_stage\$n\" in a PowerShell double-quoted string is a backslash-escape hazard for no gain.
  # RECURSE `_queue`. It has FOUR states - the root, running/, done/ and failed/ - and naming them
  # individually is how this bug survived its own fix: the first version listed root and running/
  # only, so the alarm simply moved one stage later. `theinnocents-rip` came back as "awaiting a
  # manifest" the moment its two manifests completed into done/. A manifest in ANY of those states
  # is proof the decision was taken; failed/ included, because a failure is `_stallwatch.ps1`'s
  # business, not an outstanding decision.
  $manifestText = (@(
      Get-ChildItem 'D:/video/_manifests' -File -Filter '*.json' -Recurse -ErrorAction SilentlyContinue
      Get-ChildItem 'D:/video/_queue'     -File -Filter '*.json' -Recurse -ErrorAction SilentlyContinue
    ) | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue }
  ) -join "`n"
  $manifestText = $manifestText.Replace('\', '/')

  $staged = @()
  foreach ($d in Get-ChildItem 'D:\video\_stage' -Directory -ErrorAction SilentlyContinue) {
    $n = $d.Name
    # Cheap, decisive, and ahead of the slow E: byte-count read below.
    if ($decided.ContainsKey($n)) { continue }
    if ($manifestText.Contains("_stage/$n/")) { continue }
    # A unit with a .HOLD file is DELIBERATELY parked by the user (the Mumins discs, awaiting a
    # missing disc). It is not awaiting a manifest and never will be until the hold is lifted, so
    # naming it every 90 seconds is a permanent false alarm - and this monitor's whole value is
    # being believed on the day it means something. _stallwatch.ps1 already honours .HOLD; this
    # did not, so the same three units were reported as work-waiting for two days.
    if (Test-Path -LiteralPath (Join-Path $d.FullName '.HOLD')) { continue }
    if ($inUse | Where-Object { $_ -match [regex]::Escape("_stage\$n") -or $_ -match [regex]::Escape("_stage/$n") }) { continue }
    # A live robocopy into this folder means it is still being written, whatever the byte counts
    # say - and it needs no slow E: read to detect.
    if (Get-CimInstance Win32_Process -Filter "Name='robocopy.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -match [regex]::Escape("_stage\$n") }) { continue }
    $srcDir = Join-Path $srcRoot $n
    if (Test-Path -LiteralPath $srcDir) {
      $sv = Get-ChildItem -LiteralPath $srcDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
      $tv = Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
      if ($sv.Count -ne $tv.Count -or $sv.Sum -ne $tv.Sum) { continue }   # still copying
    }
    $staged += $n
  }
  if ($staged.Count) {
    $msgs += "QUEUE EMPTY, $busyLanes/2 lanes busy - staged and awaiting a manifest: $($staged -join ', ')"
  } else {
    # "NOTHING staged" was literally false the moment the decided/.HOLD filters above started
    # doing their job: folders ARE staged, they just have no decision outstanding. Say what is
    # actually being claimed, or the next reader checks _stage, sees eight folders, and stops
    # trusting the line that follows the semicolon.
    $held = @(Get-ChildItem 'D:/video/_stage' -Directory -ErrorAction SilentlyContinue).Count
    $msgs += "QUEUE EMPTY, $busyLanes/2 lanes busy - nothing staged AWAITING A DECISION ($held staged folder(s), all decided or held); the source track is the constraint"
  }
}

# ---- FETCH TRACK IDLE: discs still to stage and nothing copying ------------------------------
#
# WHY THIS EXISTS. `_fetch-one.ps1` stages exactly ONE disc and exits, by design - continuous
# copying saturates the USB spindle and wedges Explorer. So the fetch track ALWAYS stops, and the
# only thing restarting it is somebody remembering to. On 2026-08-20 it sat idle twice (once from
# Gangsters D4 until noticed much later) while encode/OCR/NAS all reported healthy, because those
# three were the only tracks this monitor watched. An idle SOURCE track starves every track
# downstream of it, and it was the one track with no alarm.
#
# Read the disc list from _fetch-one.ps1 itself via the AST rather than duplicating it here - a
# second copy of the list would drift, and a drifted list reports "nothing left to fetch" while
# discs remain.
$fetchScript = 'D:\video\_fetch-one.ps1'
# Same AST-derived source root the staged check uses, so a drive swap cannot desynchronise them.
$srcRootForFetch = 'E:\Movies'
try {
  $fAst2 = [System.Management.Automation.Language.Parser]::ParseFile($fetchScript, [ref]$null, [ref]$null)
  $sp2   = $fAst2.ParamBlock.Parameters | Where-Object { $_.Name.VariablePath.UserPath -eq 'SrcRoot' }
  if ($sp2) { $srcRootForFetch = $sp2.DefaultValue.SafeGetValue() }
} catch { }
$doneFile    = 'D:\video\_fetch-done.txt'
if (Test-Path -LiteralPath $fetchScript) {
  # A FETCH robocopy, not just any robocopy. publish-work.ps1 uses robocopy too, so
  # `Get-Process robocopy` treats a NAS publish as "the fetch is busy" and silently suppresses
  # this alarm for the whole publish - a false negative on exactly the track this check exists to
  # watch. Observed live: a 12 GB Rome publish hid a genuine FETCH BLOCKED ON SPACE.
  # Tell them apart by SOURCE: a fetch reads from the source drive, a publish reads from D:\video.
  $copying = @(Get-CimInstance Win32_Process -Filter "Name='robocopy.exe'" -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -match [regex]::Escape($srcRootForFetch) }).Count -gt 0
  if (-not $copying) {
    try {
      # THE BATCH LIST IS THE AUTHORITY - not a default baked into _fetch-one.ps1.
      #
      # This used to read the -Discs DEFAULT out of _fetch-one.ps1 via the AST, on the reasoning
      # that a second copy of the list would drift. Right instinct, wrong source: the script's
      # default WAS the duplicate, and `listN.txt` is the actual batch definition. On 2026-08-23
      # the default was removed (it had rotted to batch-5 leftovers, and running the script bare
      # after a drive swap hunted for discs that had left with the old drive) - and this monitor
      # broke instantly with "You cannot call a method on a null-valued expression", because
      # DefaultValue was now null.
      #
      # Read the HIGHEST-NUMBERED list file, so a new batch is picked up without editing this.
      $listFile = Get-ChildItem 'D:/video/list*.txt' -ErrorAction SilentlyContinue |
                  Sort-Object { $m=[regex]::Match($_.BaseName,'\d+'); if($m.Success){[int]$m.Value}else{0} } |
                  Select-Object -Last 1
      $all   = @(Get-Content -LiteralPath $listFile.FullName |
                 Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') } |
                 ForEach-Object { $_.Trim() })
      $done  = if (Test-Path -LiteralPath $doneFile) { @(Get-Content -LiteralPath $doneFile | Where-Object { $_ -and $_.Trim() }) } else { @() }
      $left  = @($all | Where-Object { $done -notcontains $_ -and -not (Test-Path -LiteralPath (Join-Path 'D:\video\_stage' $_)) })
      if ($left.Count -gt 0) {
        # Distinguish "nobody restarted it" from "it stopped itself on the space floor" - those
        # need different actions, and conflating them sends you looking in the wrong place.
        $freeGB = [System.IO.DriveInfo]::new('D').AvailableFreeSpace / 1GB
        # READ THE FLOOR FROM THE LOOP THAT ENFORCES IT - never duplicate the number. When the
        # fetch floor rose from 80 to 120 GB, a hard-coded 80 here would have reported "blocked,
        # floor 80" at 100 GB free, implying a fetch was overdue when the loop was correctly
        # holding. A monitor that disagrees with the thing it monitors teaches you to ignore it.
        $fetchFloor = 120
        $m = [regex]::Match((Get-Content 'D:/video/_fetch-loop.ps1' -Raw -ErrorAction SilentlyContinue),
                            '\[int\]\$FloorGB\s*=\s*(\d+)')
        if ($m.Success) { $fetchFloor = [int]$m.Groups[1].Value }
        if ($freeGB -lt $fetchFloor) {
          # SELF-RESOLVING vs GENUINELY STUCK - the same distinction this block already draws
          # between "nobody restarted it" and "it hit the floor", one level finer.
          #
          # An encode reading from _stage is going to RELEASE that staging when it finishes, so
          # the floor breach is expected and temporary. Free space even FALLS while it runs,
          # because outputs are written before any source is released. Firing "BLOCKED" every 90
          # seconds through all of that trains the operator to skim the alarm - and this monitor's
          # whole value is being believed on the day it means something.
          #
          # NOT a blind suppression. The encode itself is what keeps it quiet: if ffmpeg dies or
          # the queue drains without releasing space, both tests fail and the alarm returns on the
          # next tick. That is the opposite of the Rome-publish false negative above, where an
          # UNRELATED process (a NAS publish) masked the alarm. Here the masking process is the
          # very thing that fixes the condition.
          # Same correction as $busyLanes above, and it matters more here: an agent's frame-grab
          # will never release staging, so counting it as "encoding" suppresses a real space alarm.
          $encoding = (Get-EncodeLaneCount) -gt 0
          $qDepth   = @(Get-ChildItem 'D:/video/_queue/*.json','D:/video/_queue/running/*.json' -ErrorAction SilentlyContinue).Count

          # DO NOT INFER A CONTINUOUS CONDITION FROM AN INSTANTANEOUS SAMPLE.
          #
          # `$encoding` asks whether an ffmpeg exists RIGHT NOW. Between two items a lane has
          # finished one encode and not yet launched the next, so it is briefly false while the
          # batch is plainly still running. On 2026-08-25 a tick landed in exactly that gap and
          # fired "NOTHING is encoding, so nothing will release it" over a batch that resumed two
          # seconds later. Same defect class as counting lanes by a process list: a momentary
          # sample cannot answer a question about a process that is ongoing.
          #
          # What actually predicts that space WILL be released is: manifests are in the queue AND
          # something is alive to run them. So test that instead, and keep `$encoding` only as an
          # additional way to be satisfied.
          #
          # This does NOT weaken the alarm. If the lane-runners are dead, `$runners` is 0 and the
          # alarm fires with manifests still queued - which is the genuinely stuck case, and the
          # one worth waking someone for.
          $runners  = @(Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -and $_.CommandLine -match 'lane-runner' }).Count
          $willFree = $encoding -or ($qDepth -gt 0 -and $runners -gt 0)

          # Never go INDEFINITELY silent. A long encode is normal; a six-hour one that never
          # releases anything is not, and silence would hide it. Emit a quiet heartbeat instead.
          # NOT a name that case-folds onto $StateFile. PowerShell variables are CASE-INSENSITIVE
          # and this script already has a $StateFile parameter holding the ALARM DEDUP path. The
          # two collapsed into one variable: the script's closing
          # `Set-Content -LiteralPath $StateFile -Value $now` wrote the message string into this
          # counter file, and the real dedup state was never written - silently breaking change
          # detection for EVERY alarm here, not just this one. Caught because the counter kept
          # coming back holding an alarm message. Same trap as the $t/$T note further up.
          $quietCounter = 'D:/video/_logs/.fetchblock-quiet'
          if ($willFree) {
            # DEFENSIVE PARSE. A blank or garbled counter file must never take the fetch check
            # down: [int]'' THROWS, the outer catch swallows it as "FETCH CHECK FAILED", and the
            # space alarm is then dead on every subsequent tick. Observed as a 2-byte counter file
            # holding only CRLF. A cosmetic heartbeat is not worth risking the alarm it guards.
            $n = 0
            if (Test-Path -LiteralPath $quietCounter) {
              $raw = (Get-Content -LiteralPath $quietCounter -Raw -ErrorAction SilentlyContinue)
              if ($raw) { [void][int]::TryParse($raw.Trim(), [ref]$n) }
            }
            $n++
            Set-Content -LiteralPath $quietCounter -Value $n
            if ($n % 20 -eq 0) {
              $msgs += ("fetch still waiting on space ({0:N0} GB, floor {3}) - encode in flight for {1} ticks, {2} manifest(s) in the queue. Expected; will clear when staging is released." -f $freeGB, $n, $qDepth, $fetchFloor)
            }
          } else {
            if (Test-Path -LiteralPath $quietCounter) { Set-Content -LiteralPath $quietCounter -Value 0 }
            $msgs += ("FETCH BLOCKED ON SPACE: {0:N0} GB free (floor {1}), {2} disc(s) still to stage - and NOTHING is encoding, so nothing will release it" -f $freeGB, $fetchFloor, $left.Count)
          }
        } else {
          $msgs += ("FETCH IDLE: {0} disc(s) still to stage, next = '{1}' - restart _fetch-one.ps1" -f $left.Count, $left[0])
        }
      }
    } catch {
      $msgs += "FETCH CHECK FAILED to read the disc list from _fetch-one.ps1: $($_.Exception.Message)"
    }
  }
}

# ---- SEASON 00 TITLES NOT SET+LOCKED (per-unit gate step 6) ----------------------------------
#
# WHY THIS EXISTS. This is the step that keeps getting skipped, and the user has had to ask for it
# by name repeatedly (Gangsters, then Pulling, 2026-08-20). It falls due LATE - after encode, OCR
# and publish, once attention has moved to the next disc - and "remember to run fix-plex-extras"
# was written into the batch notes TWICE and skipped anyway. Prose cannot enforce itself.
#
# The Plex agent relabels Season 00 by index against its own specials list, so extras end up with
# another show's special's name or a bare "Episode N". A library audit on 2026-08-20 found 70
# shows affected, including The West Wing with S00E05-E14 all sitting as "Episode N".
#
# Only recently-updated shows are examined: the audit costs one HTTP round-trip per Season-00
# ITEM (the locked-field list lives nowhere else), and a show fixed months ago does not un-fix
# itself. Newly published extras are exactly the set at risk.
$auditScript = 'D:\video\.claude\skills\disc-to-plex\scripts\audit-season00-titles.ps1'
if (Test-Path -LiteralPath $auditScript) {
  try {
    $out = & pwsh -NoProfile -File $auditScript -SinceDays 3 -Quiet 2>$null
    $need = @($out | Where-Object { $_ -match 'need fix-plex-extras' -and $_ -notmatch '^\d+ show' })
    if ($need.Count) {
      $names = ($need | ForEach-Object { ($_ -split ':')[0] }) -join ', '
      $msgs += "SEASON 00 TITLES UNSET on: $names - run fix-plex-extras.ps1"
    }
  } catch { }
}

$now  = ($msgs -join ' | ')

# DEDUP ON THE CONDITION, NOT ON THE PROSE.
#
# The key used to be the whole joined message, which embeds the list of staged units - so every
# disc the fetch loop landed changed the text and re-fired an alarm whose CONDITION ("queue empty,
# lanes idle, nothing to encode") had not changed at all. During a fast staging run on 2026-08-25
# that meant the same alarm every ~90 seconds with a one-word difference, which is the surest way
# to teach the reader to skim it.
#
# So normalise ONLY that volatile tail - the enumerated unit list, which runs to the next ' | ' or
# end of string. Everything else stays byte-exact, deliberately: a narrow rule cannot silence an
# alarm it was not written for, and blanket-normalising numbers would have suppressed real
# transitions like free space crossing the fetch floor.
#
# The printed message still carries the full list. Only the comparison is normalised.
$key  = $now -replace 'awaiting a manifest: [^|]*', 'awaiting a manifest: <units>'
$prev = if (Test-Path -LiteralPath $StateFile) { (Get-Content -LiteralPath $StateFile -Raw).Trim() } else { '' }
if ($key -ne $prev) {
  Set-Content -LiteralPath $StateFile -Value $key
  if ($now) { Write-Output $now }
}
