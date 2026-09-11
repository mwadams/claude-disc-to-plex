# Report which PIPELINE STAGE is waiting on the OPERATOR, per staged unit.
#
# WHY THIS EXISTS
# ---------------
# `_lanewatch` and `_idlewatch` say that something is idle. They do not say WHICH STEP is blocked,
# and every stall on 2026-08-23 was a specific missing step that only the operator could take:
#
#   - the GPU sat idle 07:57-10:30 because no MANIFEST had been authored
#   - batch 7 made zero progress because no FETCH had been started, twice announced as started
#   - a staged disc sat un-CATALOGUED while its lane was free
#   - a disc had a catalogue but no DISPOSITIONS, so nothing could be manifested
#
# "LANE FREE" was firing throughout and was true but useless: it names a symptom several steps
# downstream of the cause. This names the cause.
#
# The self-draining tracks (encode / OCR / publish) need no prompting - they are loops. The chain
# BEFORE them is all manual:
#
#     fetch -> catalogue -> dispositions -> rip -> analyse -> manifest -> queue
#
# Each staged unit sits at exactly one point in that chain. Print it.
#
# HOLDS: a unit with a `.HOLD` file in its staging folder is deliberately parked (e.g. Mumins,
# awaiting a missing disc) and is reported separately, never as a stall. Put the reason in the file.

param(
  [string]$Stage     = 'D:/video/_stage',
  [string]$Catalogue = 'D:/video/_catalogue',
  [string]$Manifests = 'D:/video/_manifests',
  # Where subagents write a finished manifest before the main session gates it. Also holds
  # `<disc>.authoring` markers for one currently being written - see below.
  [string]$Pending   = 'D:/video/_pending',
  [string]$Queue     = 'D:/video/_queue',
  # Parameterised for the same reason as the directories above: the ships-nothing branch below is
  # tested against a sandbox, and a hard-coded register would force every fixture disc to be
  # written into the REAL verified-copies file to be seen at all.
  [string]$FetchDoneFile = 'D:/video/_fetch-done.txt',
  # Parameterised for the same reason as $FetchDoneFile: the redundant-rip branch below asks
  # lib-disk.ps1 whether the rip lane would re-create an intermediate, and that question reads the
  # confirmation register.
  [string]$CompletedFile = 'D:/video/_completed.txt',
  # A MACHINE-READABLE COPY OF THIS RUN'S VERDICT (2026-09-04). Everything this board knows was
  # only ever printed, so nothing could ACT on "the line is FULLY STOPPED" unless a human ran the
  # script and read it - and on 2026-09-04 the line stood for six hours while nobody did.
  # _stall-alarm.ps1 reads this file and raises a toast. '' disables the write; every existing
  # caller sees exactly the same printed output as before.
  # _dispositions-loop.ps1's own state, read ONLY for its recorded auth probe (auth.ok) - see
  # $dispRunnerOk below. A PARAMETER rather than a hard-coded path so tests can state whether a
  # runner exists instead of inheriting whatever the real machine happens to be doing.
  [string]$DispositionsState = 'D:/video/_dispositions-state.json',
  [string]$StateFile = 'D:/video/_stallwatch-state.json',
  [string]$ReclaimRoot = 'D:/video/_reclaim-queue',
  # Hours a CONFIRMED reclaim may sit in RETRY before the board calls it stuck. 6 h is comfortably
  # longer than any legitimate wait for a publish or an OCR pass, and far shorter than the four
  # DAYS Azkaban went unnoticed on 2026-09-07.
  [double]$ReclaimRetryWarnHours = 6,
  # Written by discharge-rerip.ps1: re-rip rows that PUBLISHED but delivered fewer than owed.
  [string]$DischargePending = 'D:/video/_rerip-discharge-pending.json',
  # A .dispositioning / .authoring marker older than this with nothing written reads as an agent
  # that died, not one still working - and is reported as a stall rather than as "moving".
  [double]$MarkerStaleHours = 6,
  [switch]$Quiet          # print nothing when every unit is either busy or held
)

# LOAD VERIFIED. A dot-source of a bad path raises a NON-TERMINATING error, so the function would
# simply be undefined and the redundant-rip branch below would print an error instead of a verdict -
# and a monitor that prints half an answer is worse than one that stops (see _release-completed.ps1).
. 'D:/video/.claude/skills/disc-to-plex/scripts/lib-disk.ps1'
if (-not (Get-Command Get-RipRecreationRisk -ErrorAction SilentlyContinue)) {
  throw 'lib-disk.ps1 failed to load - refusing to report on rip intermediates without Get-RipRecreationRisk'
}

function Test-AnythingRunning {
  $names = 'ffmpeg', 'makemkvcon64', 'robocopy', 'tesseract', 'seconv', 'mkvextract'
  foreach ($n in $names) { if (@(Get-Process $n -ErrorAction SilentlyContinue).Count -gt 0) { return $true } }
  # a catalogue or analysis launched with -File (NOT a shell command that merely mentions the name -
  # that false positive has bitten this project repeatedly; classify by HOW it was launched)
  $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '\s-Command\s' -and
                            ($_.CommandLine -match 'catalogue-d|analyze-tracks|_fetch-one\.ps1') })
  return ($procs.Count -gt 0)
}

# Liveness of a TRACK is its mutex - the rule every loop here follows; never a process match.
function Test-TrackAlive([string]$mutexShortName) {
  $h = $null; $alive = $false
  try { $alive = [System.Threading.Mutex]::TryOpenExisting(('Global' + [char]92 + $mutexShortName), [ref]$h) } catch { $alive = $false }
  if ($h) { $h.Dispose() }
  return $alive
}
function Get-FirstLine([string]$path) {
  $l = @(Get-Content -LiteralPath $path -ErrorAction SilentlyContinue | Where-Object { "$_".Trim() } | Select-Object -First 1)
  if ($l.Count) { return "$($l[0])".Trim() } else { return '' }
}

$busy       = Test-AnythingRunning
$queued     = @(Get-ChildItem "$Queue/*.json" -ErrorAction SilentlyContinue).Count
$running    = @(Get-ChildItem "$Queue/running/*.json" -ErrorAction SilentlyContinue).Count
$units      = @(Get-ChildItem $Stage -Directory -ErrorAction SilentlyContinue)
# Only VERIFIED copies appear here - _fetch-one.ps1 writes a line after matching count and bytes.
$fetchDone  = @(Get-Content -LiteralPath $FetchDoneFile -ErrorAction SilentlyContinue |
                Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })

$stalls = @()
$held   = @()
$moving = @()
# Collected for the state file (see -StateFile): what the alarm can name without re-parsing prose.
$needsValidation = @(); $briefsReady = @(); $reclaimFailed = @(); $reclaimFailedStale = @(); $reclaimStuck = @(); $manifestFailed = @(); $manifestFailedStale = @(); $dischargePendingNames = @()
# The publish-stall verdict, lifted from audit-publish-freshness.ps1's anchored marker.
$publishStalled = $false; $publishStallMin = 0; $publishStallFiles = 0
# UNITS THAT HAVE NOT YET REACHED THE ENCODERS - the input to "encodersStarved" below. Incremented
# once per unit that still needs dispositions or a manifest, whichever branch it lands in.
$awaitingAuthoring = 0
# ONE BRIEF READY LINE PER BATCH, NOT PER UNIT (2026-09-04). _dispositions-loop.ps1 briefs the discs
# of one work to ONE agent and saves the SAME brief under each member's name, so this board saw a
# brief per unit and printed a "spawn an agent with: Follow the brief at ..." line per unit - two
# identical instructions for one batch, inviting a human to spawn two agents for work the batching
# exists to give to one. Members are folded by the brief's content hash (identical bytes = one
# batch; a brief names its units, so two batches can never collide) and the batch is printed once,
# naming every unit. A batch of one prints the line it always did. Keyed by hash -> @{ Units;
# Brief; Phase }; a placeholder holds the batch's place in $stalls until the sweep has seen every
# member, then it is expanded below. $briefsReady stays per unit - _stall-alarm.ps1 keys on it.
$briefBatches = [ordered]@{}
$spaceBlocked = $false
$dispTrackAlive = Test-TrackAlive 'video-dispositions-loop'
# ALIVE IS NOT THE SAME AS ABLE TO RUN A BRIEF, and conflating them broke this both ways in one day.
#
# _dispositions-loop.ps1 runs in BRIEF-ONLY mode when the Windows claude CLI is not logged in: the
# track is alive, it writes every brief, and NOTHING will ever pick them up - that is precisely the
# case "BRIEF READY, no authenticated runner" exists to report. But an AUTHENTICATED loop also
# writes a brief before launching its agent, and reporting THAT as a stall produced five false
# alerts on 2026-09-08 while the loop drained them correctly at -MaxConcurrent 1.
#
# So the discriminator is the loop's own recorded auth probe, not its liveness. Absent or unreadable
# state = not authenticated: a brief nobody can be shown to be running is worth reporting.
$dispRunnerOk = $false
if ($dispTrackAlive) {
  try { $dispRunnerOk = [bool]((Get-Content -LiteralPath $DispositionsState -Raw -ErrorAction Stop | ConvertFrom-Json).auth.ok) } catch { $dispRunnerOk = $false }
}

foreach ($u in $units) {
  $name = $u.Name

  $hold = Join-Path $u.FullName '.HOLD'
  if (Test-Path -LiteralPath $hold) {
    $why = (Get-Content -LiteralPath $hold -Raw -ErrorAction SilentlyContinue).Trim()
    # A HOLD WRITTEN BY THE DISPOSITIONS TRACK IS A STALL, NOT A PARK. _dispositions-loop.ps1 parks
    # a unit whose agent output a guard refused or whose agent reported low confidence, so that the
    # rip/analyse tracks do not act on it - but that unit is WAITING ON THE OPERATOR to validate,
    # which is exactly this board's definition of a stall. The hold text says which it is.
    if ($why -match '(?i)^NEEDS VALIDATION') {
      $stalls += "{0,-28} needs VALIDATION - {1}" -f $name, ($why -replace '\s+', ' ')
      $needsValidation += $name
    } else {
      $held += "{0,-28} HELD - {1}" -f $name, $(if ($why) { $why } else { 'no reason recorded' })
    }
    continue
  }

  # A rip folder (…-x, …-main) is an INTERMEDIATE, not a disc: judge it by whether its analysis and
  # manifest exist, not by whether it has a catalogue.
  $isRip = $name -match '-(x|main|mkv|rip)$'   # mumins1-mkv is a rip folder too - the -x|-main pair did not match reality

  $cat  = Join-Path $Catalogue "$name.catalogue.json"
  $disp = Join-Path $Catalogue "$name.dispositions.txt"

  if (-not $isRip) {
    # STILL COPYING is not a stall - but do NOT prove that by scanning the source drive.
    #
    # The first version compared this unit against E:/Movies recursively, per unit, per tick. E: is
    # a slow USB spindle and this project forbids broad recursive scans of it; the check took so
    # long the monitor never printed. The right signal is already local and free:
    #
    #   _fetch-one.ps1 appends a unit to _fetch-done.txt ONLY after verifying file count AND bytes
    #   against the source. So "is it complete?" is exactly "is it recorded there?".
    #
    # A staged unit absent from that file is either mid-copy or was copied by hand and never
    # verified. Both mean "do not catalogue it yet", and both are reported the same way.
    if ($fetchDone -notcontains $name) {
      $moving += "{0,-28} still COPYING (or never verified) - not yet in _fetch-done.txt" -f $name
      continue
    }

    if (-not (Test-Path -LiteralPath $cat)) {
      # If _catalogue-loop is alive it will sweep this within ~2 minutes, so it is NOT waiting on
      # the operator. Reporting it as a stall would train the reader to ignore this tool, which is
      # exactly how the older monitors lost their value.
      $catLoopAlive = $false
      try {
        $tmp = $null
        $mutexName = 'Global' + [char]92 + 'video-catalogue-loop'
        $catLoopAlive = [System.Threading.Mutex]::TryOpenExisting($mutexName, [ref]$tmp)
        if ($tmp) { $tmp.Dispose() }
      } catch { $catLoopAlive = $false }
      if ($catLoopAlive) {
        $moving += "{0,-28} queued for _catalogue-loop" -f $name
      } else {
        $stalls += "{0,-28} needs CATALOGUE   -> start _catalogue-loop.ps1 (or sweep by hand)" -f $name
      }
      continue
    }
    if (-not (Test-Path -LiteralPath $disp)) {
      $awaitingAuthoring++          # no dispositions yet => no manifest yet => the encoders cannot see it
      # SAME MARKER RULE AS MANIFESTS. A disposition subagent takes MINUTES - on a 35-title extras
      # disc it took forty - and writes nothing until it finishes. Without a marker that is
      # indistinguishable from "nobody has started", so the monitor reported discs as blocked on a
      # four-minute cycle while agents were actively working them. A monitor that cries wolf gets
      # skimmed, and then the one real stall is skimmed too.
      # THE DISPOSITIONS TRACK (2026-09-04) drives this step itself. Four states it can leave a
      # unit in, each reported differently because each needs a different response:
      #   NEEDS-VALIDATION  the track gave up (guard refused twice / low confidence) - a STALL that
      #                     names the operator's validation, which is the one review left to them;
      #   marker, fresh     an agent is working (the track's, or one the main session spawned);
      #   marker, STALE     nothing written for hours - the agent died; a stall, not "moving";
      #   brief, no marker  the brief is written and waiting. If the dispositions track is ALIVE
      #                     this is simply QUEUED - the track runs one agent at a time
      #                     (-MaxConcurrent 1) and will pick it up. Only when that track is DOWN is
      #                     it a stall whose remedy is one line. Reporting it as a stall regardless
      #                     of the track produced five simultaneous false "no authenticated runner"
      #                     alerts on 2026-09-08 while the loop was draining them correctly.
      $nvFile   = Join-Path $Pending ($name + '.NEEDS-VALIDATION.txt')
      $marker   = Join-Path $Pending ($name + '.dispositioning')
      $brief    = Join-Path $Pending ($name + '.dispositions-brief.md')
      if (Test-Path -LiteralPath $nvFile) {
        $stalls += "{0,-28} needs VALIDATION - {1} (see {2})" -f $name, (Get-FirstLine $nvFile), $nvFile
        $needsValidation += $name
      } elseif (Test-Path -LiteralPath $marker) {
        $mAge = (Get-Date) - (Get-Item -LiteralPath $marker).LastWriteTime
        if ($mAge.TotalHours -gt $MarkerStaleHours) {
          $stalls += "{0,-28} dispositions marker is STALE ({1:N1} h, nothing written) - the agent likely died; inspect {2}, then remove the marker" -f $name, $mAge.TotalHours, $marker
        } else {
          $moving += "{0,-28} dispositions being written (subagent working, {1:N0} min)" -f $name, $mAge.TotalMinutes
        }
      } elseif (Test-Path -LiteralPath $brief) {
        # A BRIEF IS ONLY A STALL WHEN NOTHING WILL RUN IT.
        #
        # This branch used to fire on the mere EXISTENCE of the brief file, without first asking
        # whether the dispositions track was alive - so every brief that track had written and was
        # about to pick up was reported as "BRIEF READY, no authenticated runner", and
        # _stall-alarm.ps1 raised a toast per unit. 2026-09-08: five simultaneous false alerts while
        # the loop was working through them correctly, one at a time (-MaxConcurrent 1). The
        # operator reasonably read that as "prepared briefs are not being fed to a runner"; they
        # were, in the only order the loop is allowed to run them.
        #
        # The manifest-orphan branch further down already reasons exactly this way. This file's own
        # warning applies: an alarm that cries wolf four times in five is worse than no alarm,
        # because the fifth is the one that gets ignored.
        if ($dispRunnerOk) {
          $moving += "{0,-28} brief written - queued for _dispositions-loop's authenticated runner" -f $name
        } else {
          $bh = (Get-FileHash -LiteralPath $brief -Algorithm SHA256).Hash
          if (-not $briefBatches.Contains($bh)) { $briefBatches[$bh] = @{ Units = @(); Brief = $brief; Phase = 'dispositions' }; $stalls += ('{{BRIEF-BATCH:' + $bh + '}}') }
          $briefBatches[$bh].Units += $name
          $briefsReady += $name
        }
      } elseif ($dispTrackAlive) {
        $moving += "{0,-28} queued for _dispositions-loop" -f $name
      } else {
        $stalls += "{0,-28} needs DISPOSITIONS -> write {1} (or start _dispositions-loop.ps1)" -f $name, (Split-Path $disp -Leaf)
      }
      continue
    }
    $unresolved = @(Get-Content -LiteralPath $disp -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match '^t\d\d\|\?\|' })
    if ($unresolved.Count -gt 0) {
      $stalls += "{0,-28} needs IDENTIFICATION - {1} title(s) still '?'" -f $name, $unresolved.Count
      continue
    }
  }

  # Is there a manifest that mentions this unit, and has it been queued or completed?
  #
  # SEARCH THE QUEUE TOO, NOT JUST _manifests. `_gate-queue.ps1` MOVES a manifest out of
  # `_manifests` and into `_queue` - so a unit whose manifest was queued has NO file left in
  # `_manifests`, and searching there alone reported it as "needs MANIFEST". Observed on Julius
  # Caesar and King Lear, both already encoded, with Julius Caesar's sidecar already written.
  #
  # That is the worst kind of false positive for this tool: it names finished work as waiting on
  # the operator, and this monitor's whole value is that its output can be acted on without
  # checking it first. The queue-state reporting below already knew how to describe a queued or
  # completed manifest - it simply never ran, because the search returned nothing.
  # MATCH THE STAGED PATH, NOT THE BARE NAME. A unit can be named `M` (Fritz Lang, 1931), and a
  # bare substring match on one letter hits EVERY manifest containing an "m" - which reported M as
  # having failed four unrelated manifests. Require the name to sit where a staged path puts it:
  # after `_stage/` and followed by a separator or the closing quote.
  # `_pending` IS PART OF THE SEARCH. A manifest authored by a subagent lands there and waits for
  # the main session to validate and gate it - work that is DONE, not work that is missing. Without
  # this the monitor reported four discs as "needs MANIFEST" while their manifests sat in _pending,
  # every four minutes. A monitor that cries wolf gets ignored, which is the one failure it cannot
  # afford.
  $manifestDirs = @("$Manifests/*.json", "$Pending/*.json", "$Queue/*.json", "$Queue/running/*.json",
                    "$Queue/done/*.json", "$Queue/failed/*.json")
  $pathRx = '_stage[\\/]' + [regex]::Escape($name) + '(?=["\\/])'
  $mentioned = @(Get-ChildItem $manifestDirs -ErrorAction SilentlyContinue |
                 Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match $pathRx })

  # A DISC THAT LEGITIMATELY SHIPS NOTHING IS CLOSED, NOT WAITING ON A MANIFEST.
  #
  # The Champions Disk 3 (2026-09-03): fully dispositioned, assert-accounted -RequireEvidence
  # exit 0, and its dispositions' verdict is that NOTHING on it is worth shipping (no subtitles,
  # no second audio, no tail cells, no quality gain - all already published). Correct, useful,
  # and unrepresentable: with no output there is no manifest, so this board said "needs MANIFEST"
  # forever - a PERMANENT false positive, the one failure this tool's header says it cannot
  # afford, and several sister discs are expected to repeat it.
  #
  # The closure is a POSITIVE RECORD, never an absence: close-ships-nothing.ps1 writes
  # <disc>.ships-nothing.json into _catalogue only after the dispositions carry the verdict, no
  # manifest anywhere references the disc, and the accounting gate passes with evidence. A disc
  # with no record still reads "needs MANIFEST" below - absence of a manifest must NEVER quietly
  # become "nothing to ship"; that is exactly how a disc whose manifest was simply never written
  # gets dropped (_fetch-done.txt's header records losing one that way).
  #
  # Two ways the record can be WRONG are stalls, reported louder than they'd be ignored:
  #   - the dispositions changed after closure (hash mismatch) - the record's evidence is stale;
  #   - a manifest now references the disc - "ships nothing" is contradicted by the pipeline.
  $snPath = Join-Path $Catalogue "$name.ships-nothing.json"
  if (Test-Path -LiteralPath $snPath) {
    $sn = $null
    try { $sn = Get-Content -LiteralPath $snPath -Raw | ConvertFrom-Json } catch { }
    $dispShaNow = if (Test-Path -LiteralPath $disp) { (Get-FileHash -LiteralPath $disp -Algorithm SHA256).Hash } else { '' }
    if (-not $sn -or -not $sn.dispositionsSha256) {
      $stalls += "{0,-28} ships-nothing record UNREADABLE -> inspect {1}" -f $name, $snPath
    } elseif ($sn.dispositionsSha256 -ne $dispShaNow) {
      $stalls += "{0,-28} ships-nothing record is STALE - the dispositions changed after closure -> re-run close-ships-nothing.ps1" -f $name
    } elseif ($mentioned.Count -gt 0) {
      $stalls += "{0,-28} closed SHIPS NOTHING yet {1} manifest(s) reference it ({2}) - contradiction, investigate" -f $name, $mentioned.Count, (($mentioned.Name) -join ', ')
    } else {
      $why = "$($sn.because)"
      if ($why.Length -gt 90) { $why = $why.Substring(0, 90) + '...' }
      $moving += "{0,-28} closed: SHIPS NOTHING ({1}) - {2}; staging releases via a user-confirmed reclaim artefact" -f $name, "$($sn.closedAt)", $why
    }
    continue
  }

  # A DISC WHOSE ONE SHIPPABLE ITEM WENT OUT BY A ROUTE OTHER THAN A MANIFEST IS ALSO CLOSED,
  # NOT WAITING ON A MANIFEST - BUT THIS IS NOT THE SHIPS-NOTHING CASE, AND MUST NEVER READ LIKE IT.
  #
  # Survivors Series 2 Disk 4 (2026-09-03): all 8 MakeMKV/dvdvideo titles ship nothing (published
  # already or boilerplate) - but the disc's one new item, a photo gallery, is authored as 20 still
  # MENUS in the MENU domain, invisible to MakeMKV and absent from TT_SRPT, so transcode.ps1 (which
  # only ever reads `-f dvdvideo -title N`) could never produce a manifest for it. It was carved by
  # dvd-still-cells.py --menu and published by _publish-loop.ps1 (filesystem-driven, not manifest-
  # driven), so no manifest exists and none ever will. ships-nothing.json would be FALSE here - the
  # disc shipped something - so close-shipped-outside-manifest.ps1 writes a DIFFERENT record.
  #
  # THE WORDING BELOW IS DELIBERATELY NOT THE SHIPS-NOTHING LINE. A ships-nothing disc can be
  # released at zero information cost, because by definition nothing on it was worth keeping - so
  # that line can say "releases via a user-confirmed reclaim artefact" and mean it. This disc is the
  # opposite: its raw staging may be the ONLY place the shipped item could ever be re-derived from
  # (assert-accounted.ps1 has no concept of a menu-domain item, so it exits 0 and prints "may be
  # released" regardless). Saying the same thing here would be exactly the false assurance this
  # record exists to prevent, so this board line says the staging is NOT releasable via the normal
  # route instead. _release-completed.ps1 enforces this independently of what this board prints.
  $somPath = Join-Path $Catalogue "$name.shipped-outside-manifest.json"
  if (Test-Path -LiteralPath $somPath) {
    $som = $null
    try { $som = Get-Content -LiteralPath $somPath -Raw | ConvertFrom-Json } catch { }
    $dispShaNow2 = if (Test-Path -LiteralPath $disp) { (Get-FileHash -LiteralPath $disp -Algorithm SHA256).Hash } else { '' }
    if (-not $som -or -not $som.dispositionsSha256) {
      $stalls += "{0,-28} shipped-outside-manifest record UNREADABLE -> inspect {1}" -f $name, $somPath
    } elseif ($som.dispositionsSha256 -ne $dispShaNow2) {
      $stalls += "{0,-28} shipped-outside-manifest record is STALE - the dispositions changed after closure -> re-run close-shipped-outside-manifest.ps1" -f $name
    } elseif ($mentioned.Count -gt 0) {
      $stalls += "{0,-28} closed SHIPPED OUTSIDE MANIFEST yet {1} manifest(s) reference it ({2}) - contradiction, investigate" -f $name, $mentioned.Count, (($mentioned.Name) -join ', ')
    } elseif ($som.stagingReleaseAuthorised -and "$($som.stagingReleaseAuthorised.sourceDisc.path)".Trim()) {
      # AUTHORISED (2026-09-03): the record still stands - no manifest can produce this disc's item,
      # so this line must keep reading CLOSED, never "needs MANIFEST". What has been lifted is only
      # the staging refusal, and only because the SOURCE DISC is still reachable - a different claim
      # from "no manifest can produce it", and the only one that ever justified refusing release.
      # _release-completed.ps1 re-measures that source itself, so this line reports the authorisation
      # rather than asserting the release will succeed.
      $moving += "{0,-28} closed: SHIPPED VIA NON-MANIFEST ROUTE ({1}) - {2}; staging release AUTHORISED against {3} (source still reachable is re-checked at release)" -f `
                 $name, "$($som.closedAt)", "$($som.shippedItem)", "$($som.stagingReleaseAuthorised.sourceDisc.path)"
    } else {
      $moving += "{0,-28} closed: SHIPPED VIA NON-MANIFEST ROUTE ({1}) - {2}; STAGING NOT RELEASABLE via the normal route - see {3}" -f $name, "$($som.closedAt)", "$($som.shippedItem)", (Split-Path $somPath -Leaf)
    }
    continue
  }

  if ($mentioned.Count -eq 0) {
    # A RIP FOLDER THAT NO MANIFEST READS IS REDUNDANT, NOT UNFINISHED.
    #
    # On Blu-ray the manifest reads the rip, so an unreferenced rip really is work waiting. On DVD
    # the manifest usually reads the DISC directly (`src` = the folder, plus a title number) - yet
    # dispositioning a title as `extra` makes _rip-loop.ps1 rip it anyway, producing an
    # intermediate nothing ever opens. Nanny S1 D1's picture gallery did exactly that: 1 file
    # ripped, and the manifest reads title 6 off the disc.
    #
    # Reporting that as "needs MANIFEST" sends the operator to author a manifest for a folder that
    # should simply be released with its disc. Say which it is.
    # "RELEASE IT WITH ITS DISC" IS THE WHOLE INSTRUCTION - AND THE SIZE COLUMN MAKES THE OTHER
    # READING AVAILABLE.
    #
    # On 2026-09-04 three such folders (20.81 + 7.11 + 2.31 GB) were read off this board as 30.2 GB
    # of recoverable space while the volume sat at 94 GB against a 120 GB floor with 17 discs unable
    # to start. Releasing them on their own would have freed NOTHING: _rip-loop.ps1's "have I ripped
    # this title?" test is the PRESENCE OF A `*_t<NN>.mkv` FILE IN THAT DIRECTORY, and none of its
    # stop conditions (raw staging gone, .HOLD, unit in _completed.txt, no dispositions, an
    # unresolved '?', no keep rows) hold for a disc that is mid-flight - so within one 90 s pass it
    # re-rips every keep-title off the same staging, contending with the live encodes.
    #
    # Both halves of that are real and they read differently, so ASK rather than assert: once a
    # unit's raw staging is already released, a stranded intermediate (the 13 "Danger Man Series
    # 1964-1968" -rip folders, ~15 GB) genuinely can be released on its own by naming the unit in a
    # reclaim artefact, because the disc the loop would rip from is gone.
    if ($isRip) {
      $risk = Get-RipRecreationRisk -Dir $name -Stage $Stage -Catalogue $Catalogue -Completed $CompletedFile
      if ($risk.WouldRecreate) {
        $moving += ("{0,-28} redundant rip - no manifest reads it; release it WITH its disc ('{1}'). NOT recoverable space on its own: _rip-loop.ps1 would re-rip {2} keep-title(s) off the still-staged disc within one pass" -f `
                    $name, $risk.Unit, $risk.Titles)
      } else {
        $moving += ("{0,-28} redundant rip - no manifest reads it; releasable on its own ({1}) - name '{2}' in a reclaim artefact; the release gates still apply" -f `
                    $name, $risk.Reason, $(if ($risk.Unit) { $risk.Unit } else { '<unit unknown>' }))
      }
      continue
    }

    # AND THE MIRROR CASE: a Blu-ray DISC whose manifest reads its RIP, not the disc. `M` reported
    # "needs MANIFEST" while `m.json` sat in _manifests pointing at `_stage/m-rip` - the disc is
    # not waiting on anyone, the rip is carrying it.
    #
    # THE COMMENT HERE USED TO SAY the rip folder is "the unit name with every non-alphanumeric
    # character dropped, which is how _rip-loop.ps1 names it". That was asserted, never checked, and
    # WRONG. _rip-loop.ps1 line 124 builds it as `$disc.ToLower().Replace(' ', '') + '-rip'` -
    # spaces only, hyphens KEPT. Every optical unit carries a hyphen (the fingerprint is appended as
    # `<label>-<8 hex>`), so for those the derived name never matched anything:
    #     real folder : atasteofhoney-e56427db-rip
    #     looked for  : atasteofhoneye56427db-rip
    # which is how this board came to print "redundant rip - no manifest reads it" about rips that
    # were carrying their disc's manifest. The same defect in _dispositions-loop.ps1 re-briefed an
    # already-gated unit and escalated it (2026-09-11, The Rubber Keyed Wonder D2).
    #
    # ConvertTo-RipSlug (lib-disk.ps1, already dot-sourced at the top of this file) is THE authority,
    # written 2026-09-02 for this exact defect after 13 Danger Man rip folders were stranded by a
    # hand-rolled copy of it. Its own header says: "ONE function, used everywhere a rip-slug is
    # computed, makes that class of drift structurally impossible instead of merely documented."
    # This line re-derived it by hand twelve lines below the dot-source, and drifted anyway.
    $slug = ConvertTo-RipSlug -Name $name
    $viaRip = @(Get-ChildItem $manifestDirs -ErrorAction SilentlyContinue | Where-Object {
      $raw = Get-Content -LiteralPath $_.FullName -Raw
      foreach ($sfx in @('-rip', '-x', '-main', '-mkv')) {
        if ($raw -match ('_stage[\\/]' + [regex]::Escape($slug + $sfx) + '(?=["\\/])')) { return $true }
      }
      $false
    })
    if ($viaRip.Count -gt 0) {
      $moving += "{0,-28} its RIP carries the manifest ({1})" -f $name, (($viaRip.Name) -join ', ')
    } else {
      $awaitingAuthoring++          # dispositions exist but no manifest yet - still short of the encoders
      # IS SOMEONE ALREADY WRITING IT? A manifest subagent takes minutes, and during that time
      # nothing exists to find - so this looked exactly like "nobody has started", and the monitor
      # said so on a four-minute cycle. The marker is dropped when the agent is briefed.
      # Same four states as the dispositions step above; same reasons.
      $nvFile2  = Join-Path $Pending ($name + '.NEEDS-VALIDATION.txt')
      $marker2  = Join-Path $Pending ($name + '.authoring')
      $brief2   = Join-Path $Pending ($name + '.manifest-brief.md')
      if (Test-Path -LiteralPath $nvFile2) {
        $stalls += "{0,-28} needs VALIDATION - {1} (see {2})" -f $name, (Get-FirstLine $nvFile2), $nvFile2
        $needsValidation += $name
      } elseif (Test-Path -LiteralPath $marker2) {
        $mAge2 = (Get-Date) - (Get-Item -LiteralPath $marker2).LastWriteTime
        if ($mAge2.TotalHours -gt $MarkerStaleHours) {
          $stalls += "{0,-28} manifest marker is STALE ({1:N1} h, nothing written) - the agent likely died; inspect {2}, then remove the marker" -f $name, $mAge2.TotalHours, $marker2
        } else {
          $moving += "{0,-28} manifest being authored (subagent working, {1:N0} min)" -f $name, $mAge2.TotalMinutes
        }
      } elseif (Test-Path -LiteralPath $brief2) {
        # Same rule as the dispositions-phase brief above: queued behind a live track is not stalled.
        if ($dispRunnerOk) {
          $moving += "{0,-28} manifest brief written - queued for _dispositions-loop's authenticated runner" -f $name
        } else {
          $bh2 = (Get-FileHash -LiteralPath $brief2 -Algorithm SHA256).Hash
          if (-not $briefBatches.Contains($bh2)) { $briefBatches[$bh2] = @{ Units = @(); Brief = $brief2; Phase = 'manifest' }; $stalls += ('{{BRIEF-BATCH:' + $bh2 + '}}') }
          $briefBatches[$bh2].Units += $name
          $briefsReady += $name
        }
      } elseif ($dispTrackAlive) {
        $moving += "{0,-28} queued for _dispositions-loop (manifest step)" -f $name
      } else {
        $stalls += "{0,-28} needs MANIFEST     -> author one and drop it in _queue (or start _dispositions-loop.ps1)" -f $name
      }
    }
    continue
  }
  # A MANIFEST FILE EXISTING IS NOT THE SAME AS IT BEING QUEUED.
  #
  # This used to report "manifest exists, in the queue" whenever a manifest merely MENTIONED the
  # unit. METROPOLIS sat like that for an hour: its manifest was authored, REFUSED by the evidence
  # gate, and never re-queued - while this tool called it queued. A trigger that misreports a
  # blocked unit as moving is worse than no trigger, because the operator then decides by feel
  # instead of by signal. Report where the manifest ACTUALLY is.
  $inQueue  = @(Get-ChildItem "$Queue/*.json" -ErrorAction SilentlyContinue).Name
  $inRun    = @(Get-ChildItem "$Queue/running/*.json" -ErrorAction SilentlyContinue).Name
  $inDone   = @(Get-ChildItem "$Queue/done/*.json" -ErrorAction SilentlyContinue).Name
  $inFailed = @(Get-ChildItem "$Queue/failed/*.json" -ErrorAction SilentlyContinue).Name
  $mNames   = @($mentioned.Name)
  $failed   = @($mNames | Where-Object { $inFailed -contains $_ })
  $done     = @($mNames | Where-Object { $inDone   -contains $_ })
  $live     = @($mNames | Where-Object { $inQueue -contains $_ -or $inRun -contains $_ })
  $orphan   = @($mNames | Where-Object { $inQueue -notcontains $_ -and $inRun -notcontains $_ -and
                                          $inDone -notcontains $_ -and $inFailed -notcontains $_ })
  # A FAILURE THAT WAS SINCE RETRIED AND SUCCEEDED IS HISTORY, NOT AN OPEN FAULT.
  #
  # `failed\` is never emptied, so a manifest that failed once is reported for ever - even after a
  # corrected copy has gone all the way through. The reclaim half of this board already makes this
  # comparison ("FAILED at X but a LATER retry completed at Y"); the encode half did not, and I
  # added an ALARM on top of it the same morning, which turned a stale line into a toast.
  #
  # 2026-09-07, the first run after that alarm went in reported FIVE failures. THREE were spent:
  # moulin-rouge-extras.json had been superseded by moulin-rouge-extras.retry.json (its Costume
  # Gallery built at 10:18), and both Sherlock discs had published under differently-named
  # manifests. Only one was real. An alarm that cries wolf four times out of five is worse than no
  # alarm, because the fifth is the one that gets ignored.
  #
  # THE TEST IS THE UNIT, NOT THE FILENAME. A retry is deliberately given a new name
  # (`*.retry.json`, `*.fixed.json`, `*.named.json`) so it cannot collide with the artefact it
  # replaces, so comparing names would find nothing. What matters is whether ANY manifest for this
  # unit reached done\ AFTER the newest failed one - that is the same shape of question, asked of
  # the unit rather than the file.
  if ($failed.Count -gt 0) {
    $newestFail = ($mentioned | Where-Object { $failed -contains $_.Name } |
                   Sort-Object LastWriteTime -Descending | Select-Object -First 1).LastWriteTime
    $laterDone  = @($mentioned | Where-Object { $inDone -contains $_.Name -and $_.LastWriteTime -ge $newestFail })
    # ...AND A RE-GATED MANIFEST THAT IS IN FLIGHT RIGHT NOW IS EVEN LESS "waiting on the operator"
    # than one that already finished.
    #
    # This asked only whether a later manifest reached done\. A unit whose failure has been FIXED and
    # re-queued is sitting in _queue or _queue\running - not done\ - so it still read as FAILED, the
    # board still listed it under PIPELINE WAITING ON THE OPERATOR, and _stall-alarm.ps1 kept the
    # toast and _LINE-STOPPED.txt entry open for it.
    #
    # 2026-09-11: BBCBD0610_D2 and DOCTOR_WHO-fdc8e9fb were both diagnosed, corrected and re-gated;
    # D2 was actively ENCODING while the alarm still named it as a failure needing a human. An alarm
    # that keeps firing about work already in hand is the cry-wolf failure this very block was
    # written to prevent - the comment above it says so about the retry-rename case, and this is the
    # same defect reached from the other side.
    $laterLive  = @($mentioned | Where-Object { $live -contains $_.Name -and $_.LastWriteTime -ge $newestFail })
    if ($laterDone.Count -eq 0 -and $laterLive.Count -gt 0) {
      $moving += "{0,-28} a manifest FAILED ({1}) but a LATER one is IN FLIGHT ({2}) - already fixed and re-queued; nothing to do" -f `
                 $name, ($failed -join ', '), (($laterLive | ForEach-Object { $_.Name }) -join ', ')
      # NOT added to manifestFailedStale: the failed/ copy must stay until the retry SUCCEEDS, or a
      # sweep would archive the evidence of a failure that might be about to happen again.
      continue
    }
    if ($laterDone.Count -gt 0) {
      $moving += "{0,-28} a manifest FAILED ({1}) but a LATER one completed ({2}) - the failed/ copy is stale history; nothing to do" -f `
                 $name, ($failed -join ', '), (($laterDone | ForEach-Object { $_.Name }) -join ', ')
      # MACHINE-READABLE, exactly as reclaimFailedStale already is, so a sweep can ARCHIVE these
      # without re-implementing the test. The resolution question - "did a LATER manifest for this
      # UNIT reach done\" - is subtle (a retry is deliberately renamed, so comparing filenames finds
      # nothing) and a second copy of it would drift from this one. Whoever tidies the folder must
      # be answering the same question the board answers, or the board will keep reporting what the
      # sweep just moved, or worse the sweep will move something the board still considers open.
      #
      # WHY TIDY AT ALL: this line is re-derived on EVERY board run and never goes away. 17 failed
      # manifests on 2026-09-08, 7 of them producing one of these lines each, six of those from that
      # day alone - and a board whose output is mostly explained noise is one whose real lines get
      # skimmed. That is the crowding-out failure this project has already had once, when error
      # records drowned the OCR gate.
      foreach ($fn in @($failed)) { $manifestFailedStale += $fn }
      continue
    }
  }
  if ($failed.Count -gt 0) {
    $stalls += "{0,-28} manifest FAILED the gate or the encode -> {1}" -f $name, ($failed -join ", ")
    # MACHINE-READABLE, so the alarm can raise it. This was printed and nothing else: the line went
    # into $stalls as prose, and _stall-alarm.ps1 raises only on the NAMED lists below it
    # (reclaimFailed, needsValidation, briefsReady, dischargePending) plus the space/stopped states.
    # A failed encode therefore alerted NOBODY. 2026-09-07: moulin-rouge-extras.json failed at 07:44
    # on one still-gallery item out of 55, and sat in _queue\failed for over two hours holding the
    # whole work back, while the board printed this line on every run and no toast ever fired. The
    # operator asked "how do you pick up those failures automatically so it doesn't block the
    # process like it has this morning" - this is the missing half of the answer.
    $manifestFailed += $name
  } elseif ($orphan.Count -gt 0) {
    # A manifest sitting in _pending while the dispositions track is alive is about to be validated
    # and gated by that track (its manifest step) - not waiting on the operator. Anywhere else, or
    # with the track down, it is the stall it always was.
    $pendingN = (($Pending -replace '\\', '/').TrimEnd('/')) + '/'
    $orphanElsewhere = @($mentioned | Where-Object { $orphan -contains $_.Name -and -not (($_.FullName -replace '\\', '/').StartsWith($pendingN, [StringComparison]::OrdinalIgnoreCase)) })
    if ($dispTrackAlive -and $orphanElsewhere.Count -eq 0) {
      $moving += "{0,-28} manifest in _pending - queued for _dispositions-loop to validate and gate ({1})" -f $name, ($orphan -join ", ")
    } else {
      $stalls += "{0,-28} manifest AUTHORED BUT NEVER QUEUED -> _gate-queue.ps1 ({1})" -f $name, ($orphan -join ", ")
    }
  } elseif ($live.Count -gt 0) {
    $moving += "{0,-28} in the queue / encoding" -f $name
  } elseif ($done.Count -eq $mNames.Count) {
    $moving += "{0,-28} encoded - awaiting OCR/publish/confirmation" -f $name
  } else {
    $moving += "{0,-28} manifest state unclear - check _queue by hand" -f $name
  }
}

# EXPAND THE BATCH PLACEHOLDERS (see $briefBatches above). A batch of one prints exactly the line
# it always did; a batch of several prints ONE line naming every member, with the same
# "spawn ... Follow the brief at <path> exactly" instruction pointing at the first member's copy.
$folded = @()
foreach ($s in $stalls) {
  if ("$s" -match '^\{\{BRIEF-BATCH:([0-9A-Fa-f]+)\}\}$') {
    $bb = $briefBatches[$Matches[1]]
    $bbUnits = @($bb.Units)
    if ($bbUnits.Count -le 1) {
      $folded += "{0,-28} BRIEF READY, no authenticated runner -> spawn an agent with: Follow the brief at {1} exactly" -f $bbUnits[0], $bb.Brief
    } else {
      $folded += "{0,-28} BRIEF READY (ONE brief for {1} units), no authenticated runner -> spawn ONE agent with: Follow the brief at {2} exactly" -f ($bbUnits -join ' + '), $bbUnits.Count, $bb.Brief
    }
  } else { $folded += "$s" }
}
$stalls = @($folded)
# Lines are not units any more: a batch line stands for several. The header counts units.
$stallUnitCount = $stalls.Count + [int](@($briefBatches.Values | ForEach-Object { @($_.Units).Count - 1 } | Measure-Object -Sum).Sum)
$briefBatchDocs = @($briefBatches.Values | ForEach-Object { [ordered]@{ units = @($_.Units); brief = "$($_.Brief)"; phase = "$($_.Phase)" } })

if ($stalls.Count -eq 0 -and $Quiet) {
  # The -Quiet early exit skips the audits below, so the state file is written here with what is
  # known - a quiet, un-stalled board - rather than left stale from an earlier, louder run.
  if ($StateFile) {
    try { ([ordered]@{ at = (Get-Date).ToString('s'); stalls = @(); moving = @($moving); held = @($held); busy = [bool]$busy; queued = [int]$queued; running = [int]$running; unitsStaged = [int]$units.Count; fullyStopped = $false; nothingStaged = [bool]($units.Count -eq 0 -and -not $busy); spaceBlocked = $false; awaitingAuthoring = 0; encodersStarved = $false; reclaimFailed = @(); reclaimFailedStale = @(); manifestFailed = @(); manifestFailedStale = @(); publishStalled = $false; publishStallMinutes = 0; publishStallFiles = 0; needsValidation = @(); briefsReady = @(); briefBatches = @(); dischargePending = @(); quietRun = $true } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $StateFile -Encoding UTF8 } catch { }
  }
  return
}

$stamp = Get-Date -Format 'HH:mm:ss'
if ($stalls.Count -gt 0) {
  Write-Output "[$stamp] PIPELINE WAITING ON THE OPERATOR - $stallUnitCount unit(s):"
  $stalls | ForEach-Object { Write-Output "   $_" }
  # The distinction that matters: is the machine busy anyway, or is EVERYTHING stopped?
  if (-not $busy -and $queued -eq 0 -and $running -eq 0) {
    Write-Output "   *** nothing is encoding, ripping, cataloguing or copying - the line is FULLY STOPPED ***"
  } else {
    Write-Output "   (other work is in flight; these are queued behind it)"
  }
} elseif (-not $Quiet) {
  Write-Output "[$stamp] no unit is waiting on the operator."
}

if ($moving.Count -gt 0 -and -not $Quiet) { $moving | ForEach-Object { Write-Output "   $_" } }
if ($held.Count   -gt 0 -and -not $Quiet) { $held   | ForEach-Object { Write-Output "   $_" } }

# Nothing staged at all, and nothing running, is its own stall: the SOURCE track needs kicking.
if ($units.Count -eq 0 -and -not $busy) {
  Write-Output "[$stamp] NOTHING STAGED and nothing running - start a fetch (_fetch-one.ps1 -Discs <list>)"
}

# WHAT DOES THE WORK LIST SAY IS LEFT?
#
# This runs LAST and unconditionally, because the failure it exists to catch does not look like a
# stall at all: on 2026-09-01 the batch list ran dry, every track drained correctly, every loop
# reported healthy - and the pipeline was simply finished with everything it had been told about.
# The operator read "queue empty" four times as a clean resting state, and then chose the next work
# by looking at the NAS instead of at updates_media2.txt.
#
# So the entry point now always says which work list is in force, whether the batch is exhausted,
# and which categories of work have nothing pointing at them. A reminder that only fires when
# someone remembers to ask for it is not a reminder.
$worklist = 'D:/video/worklist-status.ps1'
if (Test-Path -LiteralPath $worklist) { & pwsh -NoProfile -File $worklist }
else { Write-Output 'worklist-status.ps1 is MISSING - the work list is not being checked at all' }

# And whether anything was released WITHOUT the confirmation being written down. The release
# scripts gate on _completed.txt, but a hand-deletion walks straight past that gate leaving no
# trace - which is what happened on 2026-09-01. This is the trace.
$relaudit = 'D:/video/.claude/skills/disc-to-plex/scripts/audit-release-records.ps1'
if (Test-Path -LiteralPath $relaudit) { & pwsh -NoProfile -File $relaudit }

# AND WHETHER THE LINE IS STOPPED FOR SPACE ONLY THE OPERATOR CAN RELEASE.
#
# This script printed "no unit is waiting on the operator" for over an hour on 2026-09-01 while the
# fetch loop sat below its floor with 16 discs waiting, blocked on nothing but a Plex confirmation.
# The user asked "why did you not notify me?" and the answer was that nothing did: the monitor
# watches THIS script's output for operator-blocked units, so a condition named nowhere here is a
# condition nobody is ever told about. Silence through a real stop is worse than a false alarm,
# because it actively reassures.
$spaceaudit = 'D:/video/.claude/skills/disc-to-plex/scripts/audit-space-block.ps1'
if (Test-Path -LiteralPath $spaceaudit) {
  # Captured then re-printed unchanged, so the state file can carry the verdict too.
  $spaceOut = @(& pwsh -NoProfile -File $spaceaudit 2>&1 | ForEach-Object { "$_" })
  foreach ($l in $spaceOut) { Write-Output $l }
  $spaceBlocked = @($spaceOut | Where-Object { $_ -match 'SPACE-BLOCKED' }).Count -gt 0
}

# AND THE OPTICAL ARCHIVE TRACK: ITS SPACE WARNING AND ITS DRIVE (2026-09-04, a user requirement).
#
# _optical-loop.ps1 archives DVDs to C:\Users\matth\Videos\DVD and writes _optical-status.json after
# every pass. The user asked for a WARNING when that drive drops below ~10 GB free, DISTINCT from
# the floor that refuses to start a backup, and for it to reach THIS board - "not just a log line
# nobody reads". Eight Jeeves discs at DVD9 are ~60 GB against ~70 GB free, so it will fire.
#
# Free space is RE-MEASURED here rather than trusted from the file, so a stale file cannot
# reassure; the file supplies only what cannot be measured from outside: the thresholds the track
# is running with, the drive having dropped off the bus, a read in flight, what is quarantined.
# The block prints nothing when there is nothing to say, and it is additive: nothing above it
# changes for any existing caller.
$optStatusPath = 'D:/video/_optical-status.json'
if (Test-Path -LiteralPath $optStatusPath) {
  try {
    $os = Get-Content -LiteralPath $optStatusPath -Raw | ConvertFrom-Json
    $optAlive = $false
    try {
      $optH = $null
      $optAlive = [System.Threading.Mutex]::TryOpenExisting(('Global' + [char]92 + 'video-optical-loop'), [ref]$optH)
      if ($optH) { $optH.Dispose() }
    } catch { $optAlive = $false }
    $optRoot = "$($os.archive)"
    $optQual = (Split-Path -Qualifier $optRoot)
    $optWarnGB = [double]$os.warnGB; $optFloorGB = [double]$os.floorGB
    $optFreeGB = [math]::Round(([IO.DriveInfo]::new($optQual + '\')).AvailableFreeSpace / 1GB, 1)
    $optQuar = @($os.quarantined)
    $optLines = @()
    if ($optFreeGB -lt $optWarnGB) {
      $optLines += ("*** OPTICAL ARCHIVE LOW SPACE: {0} has {1} GB free - below the {2} GB warning line (the {3} GB floor refuses the next disc). Free space on {0}; the archive is {4}." -f $optQual, $optFreeGB, $optWarnGB, $optFloorGB, $optRoot)
    }
    if ($optAlive) {
      if ($os.driveAbsent) {
        $optLines += ("*** OPTICAL DRIVE GONE: {0}: is not enumerated (USB drop). The track is waiting for it - nothing was killed; re-seat the cable / power-cycle the drive. Last seen: '{1}'." -f "$($os.driveLetter)", "$($os.disc.label)")
      }
      if ("$($os.action)" -eq 'space-hold') {
        $optLines += ("*** OPTICAL SPACE-HOLD: '{0}' is in the drive and cannot start - {1} is under the {2} GB floor ({3} GB free)." -f "$($os.disc.label)", $optQual, $optFloorGB, $optFreeGB)
      }
      if (-not $Quiet -and $os.inFlight) {
        $optLines += ("   optical: {0} '{1}' since {2}" -f "$($os.inFlight.mode)", "$(if ($os.inFlight.mode -eq 'verify') { $os.inFlight.partial } else { $os.inFlight.target })", "$($os.inFlight.since)")
      }
    }
    # A dvdbackup.exe running while the track is NOT alive is a hand-run (backup-dvd-folder.ps1
    # by hand); its ".partial-" is in flight, not stranded, and must not be reported as waiting.
    $optHandRun = @(Get-Process -Name dvdbackup -ErrorAction SilentlyContinue)
    if ($optQuar.Count -gt 0) {
      $optNames = @($optQuar | ForEach-Object { "$($_.name)" + $(if ($_.failed) { ' [FAILED]' } else { '' }) }) -join ', '
      if ($optAlive) { if (-not $Quiet) { $optLines += ("   optical: {0} quarantined partial(s) under {1} - resumed by fingerprint when their disc is back, else read afresh; never deleted by the track: {2}" -f $optQuar.Count, $optRoot, $optNames) } }
      elseif ($optHandRun.Count -gt 0) { if (-not $Quiet) { $optLines += ("   optical track not running; a hand-run dvdbackup.exe (pid {0}) is reading the drive - {1} partial(s) under {2}, at least one in flight: {3}" -f $optHandRun[0].Id, $optQuar.Count, $optRoot, $optNames) } }
      else { $optLines += ("   optical track NOT running; {0} quarantined partial(s) wait under {1} (start the track and re-insert their disc to finish them by fingerprint): {2}" -f $optQuar.Count, $optRoot, $optNames) }
    }
    foreach ($l in $optLines) { Write-Output $l }
  } catch { Write-Output "   optical status unreadable ($optStatusPath): $($_.Exception.Message)" }
}

# AND THE RECLAIM QUEUE: a FAILED reclaim is a user confirmation that did NOT execute, and a
# queued artefact with no loop behind it sits forever looking like it is being handled. Both are
# invisible everywhere else - the release scripts only speak when invoked, and the whole point of
# the reclaim track is that nobody invokes them by hand any more. (Added 2026-09-02 with
# _reclaim-loop.ps1; the artefact format is documented in that loop's header.)
$rqRoot = $ReclaimRoot
if (Test-Path -LiteralPath $rqRoot) {
  $rqFailed  = @(Get-ChildItem "$rqRoot/failed/*.json"  -ErrorAction SilentlyContinue)
  $rqPending = @(Get-ChildItem "$rqRoot/*.json"         -ErrorAction SilentlyContinue)
  $rqRunning = @(Get-ChildItem "$rqRoot/running/*.json" -ErrorAction SilentlyContinue)
  $rqAlive = $false
  try {
    $rqH = $null
    $rqAlive = [System.Threading.Mutex]::TryOpenExisting(('Global' + [char]92 + 'video-reclaim-loop'), [ref]$rqH)
    if ($rqH) { $rqH.Dispose() }
  } catch { $rqAlive = $false }
  # A RETRY THAT NEVER RESOLVES IS A STALL, AND NOTHING WAS MEASURING ITS AGE.
  #
  # failed/ is watched above because a refusal is loud. RETRY is the quiet one: the artefact stays
  # in the queue, the loop rewrites its .status.txt every pass, and "will retry" at four days looks
  # identical to "will retry" at four minutes. 2026-09-07: Harry Potter and the Prisoner of Azkaban
  # was confirmed at 02:55 on 09-03 and had been returning RETRY ever since - two Deleted Scenes
  # whose OCR was already recorded EXHAUSTED, so the sidecar it waited for was never coming. The
  # operator asked the right question: "why did that not either alert you to needing to take action
  # or automatically take action". Nothing did, because RETRY was modelled as transient and no
  # clock was attached to it.
  #
  # A confirmation the operator has already given, sitting unexecuted, is exactly the class of
  # thing this board exists to surface: it is work owed by US, and every hour it waits is staging
  # not released.
  foreach ($q in $rqPending) {
    $st = Join-Path $q.DirectoryName ($q.BaseName + '.status.txt')
    $since = $q.LastWriteTime
    $why = ''
    if (Test-Path -LiteralPath $st -PathType Leaf) {
      $lines = @(Get-Content -LiteralPath $st -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*(pending|refused|blocked)\s*:' })
      if ($lines.Count) { $why = ($lines[-1] -replace '^\s*\w+\s*:\s*', '').Trim() }
    }
    $ageH = [math]::Round(((Get-Date) - $since).TotalHours, 1)
    if ($ageH -ge $ReclaimRetryWarnHours) {
      Write-Output ("*** RECLAIM STUCK: {0} - a CONFIRMED reclaim has been retrying for {1} h. This is OURS to clear, not the operator's to re-confirm." -f $q.Name, $ageH)
      if ($why) { Write-Output ("       blocked on: {0}" -f $why) }
      $reclaimStuck += $q.Name
    }
  }

  # A FAILED ARTEFACT CAN BE SUPERSEDED RATHER THAN RETRYABLE, AND SAYING "RETRY IT" IS THEN WRONG.
  #
  # This line is permanent: failed/ is never emptied, so every refusal is re-announced forever with
  # the same instruction - move the .json back and retry. For most refusals that is right (fix the
  # cause, requeue, the already-done parts no-op). But a refusal can be closed by OTHER artefacts
  # instead, and then requeueing it does damage or, at best, refuses again.
  #
  # mumins-staging-release.json (2026-09-03) is the case. Its three refusals were all correct; two
  # were satisfied hours later by mumins-disc1-only.json and mumins-disc3-discard.json, and the
  # third named a unit that DOES NOT EXIST ("Mumins 1", invented so the slug would reach
  # _stage/mumins1-mkv). Requeueing it can only refuse again, and the register write it would need
  # is precisely the false confirmation the gate refused to make. Yet the board kept telling the
  # next reader to retry it.
  #
  # So: a `<name>.superseded.txt` beside the artefact closes the line - but NEVER silently. The
  # artefact and its result file stay, the note must be written by hand and say what closed it, and
  # the board still prints a line for it, just an accurate one. Nothing is deleted and no refusal
  # is laundered: this changes the ADVICE, not the verdict.
  foreach ($f in $rqFailed) {
    $supersededNote = Join-Path $f.DirectoryName ($f.BaseName + '.superseded.txt')
    if (Test-Path -LiteralPath $supersededNote -PathType Leaf) {
      Write-Output ("   reclaim {0} - FAILED and SUPERSEDED; closed by other artefacts, do NOT requeue. Why: {1}" -f $f.Name, $supersededNote)
      $reclaimFailedStale += $f.Name
      continue
    }
    # A FAILURE THAT WAS SINCE RETRIED AND COMPLETED IS HISTORY, NOT AN OPEN FAULT. Retrying moves
    # the .json back to the queue and, on success, into done/ - but the failed/ copy of its .json
    # and .result.txt stay behind (failed/ is never emptied, by design), so this line kept shouting
    # "RECLAIM FAILED" for three reclaims that had completed at 18:13 on 2026-09-04. Equally, an
    # operator who reads only the two DONE result files reports success while three sit failed.
    # Both misreadings come from the same gap: nobody compared the two folders. Compare them.
    $failStamp  = $f.LastWriteTime
    $failResult = Join-Path $f.DirectoryName ($f.BaseName + '.result.txt')
    if (Test-Path -LiteralPath $failResult -PathType Leaf) { $failStamp = (Get-Item -LiteralPath $failResult).LastWriteTime }
    $doneResult = Join-Path (Join-Path $rqRoot 'done') ($f.BaseName + '.result.txt')
    $retriedOk  = $false
    if (Test-Path -LiteralPath $doneResult -PathType Leaf) {
      $dr = Get-Item -LiteralPath $doneResult
      if ($dr.LastWriteTime -gt $failStamp -and ((Get-Content -LiteralPath $doneResult -Raw -ErrorAction SilentlyContinue) -match 'verdict\s*:\s*DONE')) { $retriedOk = $true }
    }
    if ($retriedOk) {
      Write-Output ("   reclaim {0} - FAILED at {1:MM-dd HH:mm} but a LATER retry completed at {2:MM-dd HH:mm} (done/{3}.result.txt says DONE). The failed/ copy is stale history; nothing to do." -f $f.Name, $failStamp, (Get-Item -LiteralPath $doneResult).LastWriteTime, $f.BaseName)
      $reclaimFailedStale += $f.Name
      continue
    }
    Write-Output ("*** RECLAIM FAILED: {0} - a CONFIRMED reclaim did not complete. Read {1}/failed/{2}.result.txt, fix the cause, move the .json back into _reclaim-queue/ to retry." -f $f.Name, $rqRoot, $f.BaseName)
    $reclaimFailed += $f.Name
  }
  foreach ($f in $rqRunning) {
    if (-not $rqAlive) {
      Write-Output ("*** reclaim artefact {0} is stranded in running/ and _reclaim-loop is NOT RUNNING - it died mid-artefact. Restarting the loop requeues it automatically." -f $f.Name)
    }
  }
  foreach ($f in $rqPending) {
    $rqAge = (Get-Date) - $f.LastWriteTime
    if (-not $rqAlive) {
      Write-Output ("*** reclaim artefact {0} is QUEUED but _reclaim-loop is NOT RUNNING - nothing will drain it. Start-Process pwsh -ArgumentList '-NoProfile','-File','D:/video/_reclaim-loop.ps1' -WindowStyle Hidden" -f $f.Name)
    } elseif ($rqAge.TotalHours -gt 6) {
      Write-Output ("   reclaim artefact {0} has been retrying for {1:N1} h - upstream (publish/OCR) is not finishing what it holds; read its .status.txt in _reclaim-queue/" -f $f.Name, $rqAge.TotalHours)
    }
  }
}

# AND WHETHER ANYTHING FINISHED IS SITTING UNPUBLISHED.
#
# Every check above this line is UPSTREAM of the only outcome that matters - a file arriving on the
# NAS. On 2026-09-01 manifests gated, encodes completed, nine loops held their mutexes and this
# script said "nothing waiting on the operator" while nothing had shipped for two hours. The user
# found it by looking at Plex, which was the only place the outcome was visible.
# THE OCR QUEUE: UNATTEMPTED ROWS, AND THE FAILURES ONCE THERE ARE NONE.
#
# `ocrqueue` is a DRAINER, not a perpetual loop - it exits when every row has been attempted, so
# _loops.ps1 can never tell you whether there is work left. Only the queue can. It was authorised to
# drain unattended on 2026-09-10 with one obligation attached: review the `failed` rows AT THE END,
# not row by row. That obligation is discharged HERE rather than by anyone remembering it - the
# whole reason this board exists is that a thing nobody is shown is a thing nobody does.
$ocrQ = 'D:/video/_ocr-queue.csv'
$ocrP = 'D:/video/_ocr-queue-progress.csv'
if (Test-Path -LiteralPath $ocrQ) {
  try {
    $qRows = @(Import-Csv -LiteralPath $ocrQ)
    $seen  = @{}
    $fails = 0
    if (Test-Path -LiteralPath $ocrP) {
      foreach ($r in @(Import-Csv -LiteralPath $ocrP)) {
        $seen["$($r.Path)"] = $true
        if ("$($r.Result)" -eq 'failed') { $fails++ }
      }
    }
    # LEGACY .mp4 ROWS ARE EXCLUDED BY DEFAULT BY THE LOOP ITSELF, so they must be excluded from
    # this count too, or the board reports work that running the track cannot do. Measured within
    # minutes of writing this check: it said "251 of 1721 not yet attempted - run
    # _bounce-track.ps1", the track was started, and it printed "queue drained (251 legacy .mp4
    # row(s) excluded by default)" and exited in one second. A board that sends you to restart a
    # track that immediately exits is worse than no line at all. The filter here is the loop's own
    # (_ocr-queue-loop.ps1 ~line 253) - two guards on one quantity must agree.
    # COMPUTED ONCE. The first cut derived the COUNT here and re-derived the LIST at the print site,
    # and the two disagreed: the board said "1 of 1708 not yet attempted" and then listed nothing -
    # a claim you cannot check from the outside, about a track that exits immediately when asked to
    # act on it. Two expressions for one quantity is precisely the defect this board reports in
    # other tracks. Keep the ROWS; let .Count come off them.
    $pending  = @($qRows | Where-Object { -not $seen.ContainsKey("$($_.Path)") })
    $todoRows = @($pending | Where-Object {
      $pth = "$($_.Path)".Trim()
      if (-not $pth) { return $false }                       # a row with no path is not work
      $ext = ''
      try { $ext = [IO.Path]::GetExtension($pth) } catch { }  # an unparseable path is not an .mp4
      $ext -ne '.mp4'
    })
    $todo    = $todoRows.Count
    $mp4Left = $pending.Count - $todo
    $mp4Note = if ($mp4Left -gt 0) { "  ({0} legacy .mp4 row(s) excluded by default - -IncludeLegacyMp4 to take them)" -f $mp4Left } else { '' }
    if ($todo -gt 0) {
      # NAME THEM. A bare count invites exactly the loop this line already caused once: it said "1
      # not yet attempted", the track was started, it exited having done nothing, and the count was
      # unchanged - with no way to tell which row it meant. A count you cannot act on is a count
      # that trains you to ignore the line.
      Write-Output ("OCR QUEUE: {0} of {1} row(s) not yet attempted - run  _bounce-track.ps1 -Track ocrqueue{2}" -f $todo, $qRows.Count, $mp4Note)
      foreach ($t in @($todoRows | Select-Object -First 5)) {
        Write-Output ("     {0}" -f $t.Path)
      }
    } elseif ($fails -gt 0) {
      Write-Output ("OCR QUEUE DRAINED - every eligible row attempted{0}. {1} FAILED row(s) are now owed a review:" -f $mp4Note, $fails)
      Write-Output "   Import-Csv D:/video/_ocr-queue-progress.csv | Where-Object Result -eq 'failed' | Group-Object Reason"
      Write-Output "   (a large shared Reason is one defect, not that many; fix the cause, then reset-ocr-verdicts.ps1 and re-run)"
    } else {
      Write-Output ("OCR QUEUE DRAINED - every eligible row attempted, no failures owed.{0}" -f $mp4Note)
    }
  } catch { }
}

$freshaudit = 'D:/video/.claude/skills/disc-to-plex/scripts/audit-publish-freshness.ps1'
if (Test-Path -LiteralPath $freshaudit) {
  # CAPTURE, don't stream. The audit's prose still prints verbatim, but its anchored
  # PUBLISH-STALL-STATE line is lifted out so this board can PUBLISH the verdict and
  # _stall-alarm.ps1 can raise it. Star Trek The Motion Picture sat SIXTEEN HOURS behind a failed
  # OCR on 2026-09-08 holding 12 finished files, with every alarm correctly silent because none of
  # them covers a publish stall - the operator found it by asking.
  #
  # The marker is matched ANCHORED at line start, never as a substring: an unanchored phrase match
  # once caught an agent's DENIAL of a verdict and closed four discs as shipping nothing.
  foreach ($l in @(& pwsh -NoProfile -File $freshaudit 2>&1 | ForEach-Object { "$_" })) {
    if ($l -match '^PUBLISH-STALL-STATE\s+stalled=([01])\s+minutes=(\d+)\s+waiting=(\d+)') {
      $publishStalled    = ($Matches[1] -eq '1')
      $publishStallMin   = [int]$Matches[2]
      $publishStallFiles = [int]$Matches[3]
      continue          # the marker is for the state file, not the reader
    }
    Write-Output $l
  }
}

# AND RE-RIP OBLIGATIONS THAT PUBLISHED BUT DID NOT CLOSE. discharge-rerip.ps1 runs after every
# completed publish and closes a register row only on NAS-verified evidence; a row that published
# and still could not close (fewer verified than owed, or a candidate row) is written here so it
# is NAMED rather than discovered at the next refused reclaim.
if ($DischargePending -and (Test-Path -LiteralPath $DischargePending -PathType Leaf)) {
  try {
    $dp = Get-Content -LiteralPath $DischargePending -Raw | ConvertFrom-Json
    foreach ($p in $dp.PSObject.Properties) {
      $e = $p.Value
      Write-Output ("*** RE-RIP NOT DISCHARGED: '{0}' published into '{1}' but delivered {2} of {3} owed ({4}). The register row stays {5}, so its staging cannot release. If the obligation was never real (the commonest case - an inventory report claimed subtitles or a quality gain the disc does not actually hold), it can NEVER close by counting delivered files: put an anchored 'RE-RIP OBLIGATION REFUTED: <why, from content>' line in D:/video/_catalogue/<disc>.dispositions.txt and discharge-rerip.ps1 settles it on its next run. Otherwise supply the missing evidence. Details: D:/video/_rerip-discharge-pending.json" -f `
                    $p.Name, "$($e.work)", $e.delivered, $e.owed, "$($e.reason)", "$($e.status)")
      $dischargePendingNames += $p.Name
    }
  } catch { Write-Output "   re-rip discharge report unreadable ($DischargePending): $($_.Exception.Message)" }
}

# DOES A DRIVE IN REACH CARRY A DISC THE RE-RIP REGISTER IS STILL WAITING FOR?
#
# The register knows WHICH discs owe the library a re-rip; it does not know which drive they are on.
# Deep Space Nine's 21 OPEN rows are the case: batch 1 (2026-08-11/13) predates the disc-identity
# register and the media sweeps, and its brief never recorded the drive label - so the answer only
# arrives when the right drive is plugged in, and whoever plugs it in has no reason to think of DS9.
#
# The operator, 2026-09-11: "we need to check the DS9 case with each new drive that is attached."
# On the board is where that rule survives; anywhere else it is a thing somebody has to remember.
# -Quiet means it prints ONLY on a hit, so a drive with nothing owed adds no line.
$reripDrive = 'D:/video/find-rerip-discs-on-drive.ps1'
if (Test-Path -LiteralPath $reripDrive) {
  try { & pwsh -NoProfile -File $reripDrive -Quiet 2>&1 | ForEach-Object { Write-Output "$_" } }
  catch { Write-Output "   re-rip drive check failed: $($_.Exception.Message)" }
}

# WHAT IS AWAITING THE OPERATOR'S PLEX CONFIRMATION - carried into the state file so the ALARM can
# raise it.
#
# Confirmation is the only gate a human holds and everything queues behind it, yet it reached the
# operator only two ways: this board when someone ran it, and audit-space-block.ps1's block - which
# by construction appears ONLY when the disk is already space-blocked. With space healthy, a work
# could sit confirmable indefinitely and nothing would say so.
#
# 2026-09-11: four re-encoded Song Remains The Same extras published and waited 2.5 hours; the
# session-bound watcher meant to catch it had exited, and would have stayed silent anyway because a
# guard in approve-confirmed.ps1 was wrongly suppressing the entry. Hence BOTH fields: what is
# confirmable, and what has been SUPPRESSED as not-confirmable-yet. A suppression is a question
# somebody decided not to ask, and that decision deserves to be visible rather than silent.
# FAILURES A LANE RECORDED AND NOBODY HAS READ.
#
# Both draining lanes write a per-file result register and then move on. The OCR queue at least
# prints its owed-review count on this board; the TRANSCRIBE lane's failures appeared NOWHERE - not
# on the board, not in the alarm - so 17 of them sat unexamined and were found only because the
# operator asked (2026-09-11: "Why did nothing trigger you to do that?").
#
# A failure nobody reads is a file that quietly never gets subtitles, which is the same
# crowding-out shape this project has hit before. Counted here so the alarm can raise it; the
# COUNT is the trigger, never the contents - reading them is the review, and that is a human or
# agent job.
$failuresOwed = @()
try {
  $tp = 'D:/video/_transcribe-progress.csv'
  if (Test-Path -LiteralPath $tp) {
    $tf = @(Import-Csv -LiteralPath $tp | Where-Object { "$($_.Result)" -eq 'failed' })
    # Distinct PATHS, not rows: a file retried three times is one failure owing one review.
    $tfu = @($tf | ForEach-Object { "$($_.Path)" } | Sort-Object -Unique)
    if ($tfu.Count) { $failuresOwed += ("transcribe: {0} file(s) failed and unreviewed" -f $tfu.Count) }
  }
  $op = 'D:/video/_ocr-queue-progress.csv'
  if (Test-Path -LiteralPath $op) {
    $of = @(Import-Csv -LiteralPath $op | Where-Object { "$($_.Result)" -eq 'failed' })
    $ofu = @($of | ForEach-Object { "$($_.Path)" } | Sort-Object -Unique)
    if ($ofu.Count) { $failuresOwed += ("ocr-queue: {0} file(s) failed and unreviewed" -f $ofu.Count) }
  }
} catch { }

$awaitingConfirmation = @(); $confirmSuppressed = @()
try {
  $acScript = 'D:/video/.claude/skills/disc-to-plex/scripts/approve-confirmed.ps1'
  if (Test-Path -LiteralPath $acScript) {
    $acOut = @(& pwsh -NoProfile -File $acScript 2>&1 | ForEach-Object { "$_" })
    $currentWork = ''
    foreach ($l in $acOut) {
      if ($l -match '^\s{3}(\S.*?)\s{2,}published ') { $currentWork = $Matches[1].Trim(); continue }
      if ($l -match 'CONFIRM THESE \d+ file' -and $currentWork) { $awaitingConfirmation += $currentWork; $currentWork = '' }
      elseif ($l -match 'NOT CONFIRMABLE YET' -and $currentWork) { $confirmSuppressed += $currentWork; $currentWork = '' }
    }
    $awaitingConfirmation = @($awaitingConfirmation | Sort-Object -Unique)
    $confirmSuppressed    = @($confirmSuppressed | Sort-Object -Unique)
  }
} catch { }
if ($awaitingConfirmation.Count) {
  Write-Output ("AWAITING YOUR PLEX CONFIRMATION - {0} work(s): {1}" -f $awaitingConfirmation.Count, ($awaitingConfirmation -join '; '))
  Write-Output  '   pwsh -File D:/video/.claude/skills/disc-to-plex/scripts/approve-confirmed.ps1 -Work ''<name>'' -Note ''<their words>'''
}

# THE STATE FILE - last, so it carries every verdict above. See the -StateFile parameter.
if ($StateFile) {
  $stateDoc = [ordered]@{
    at             = (Get-Date).ToString('s')
    stalls         = @($stalls)
    moving         = @($moving)
    held           = @($held)
    busy           = [bool]$busy
    queued         = [int]$queued
    running        = [int]$running
    unitsStaged    = [int]$units.Count
    fullyStopped   = [bool]($stalls.Count -gt 0 -and -not $busy -and $queued -eq 0 -and $running -eq 0)
    # THE ENCODERS ARE THE EXPENSIVE RESOURCE AND `fullyStopped` DOES NOT SPEAK FOR THEM.
    # `busy` is true whenever ANY track is working - a disc rip, a catalogue sweep - so on
    # 2026-09-08 the GPU lanes sat idle for half an hour with `fullyStopped = False`, because the
    # optical drive was reading. That is not a stopped line, but it IS idle capacity, and the
    # operator spotted it before any instrument did.
    #
    # Starved = nothing queued, nothing encoding, and at least one staged unit still short of a
    # manifest. The last clause is what keeps this quiet when idleness is CORRECT: once everything
    # staged has been encoded, awaitingAuthoring is 0 and this never fires.
    awaitingAuthoring = [int]$awaitingAuthoring
    encodersStarved   = [bool]($queued -eq 0 -and $running -eq 0 -and $awaitingAuthoring -gt 0)
    nothingStaged  = [bool]($units.Count -eq 0 -and -not $busy)
    spaceBlocked   = [bool]$spaceBlocked
    reclaimFailed  = @($reclaimFailed)
    reclaimFailedStale = @($reclaimFailedStale)
    manifestFailed = @($manifestFailed)
    manifestFailedStale = @($manifestFailedStale)
    publishStalled = [bool]$publishStalled
    publishStallMinutes = [int]$publishStallMin
    publishStallFiles = [int]$publishStallFiles
    needsValidation = @($needsValidation)
    failuresOwed   = @($failuresOwed)
    awaitingConfirmation = @($awaitingConfirmation)
    confirmSuppressed    = @($confirmSuppressed)
    briefsReady    = @($briefsReady)
    briefBatches   = @($briefBatchDocs)
    dischargePending = @($dischargePendingNames)
  }
  try { ($stateDoc | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $StateFile -Encoding UTF8 } catch { }
}



