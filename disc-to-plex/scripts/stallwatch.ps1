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
  [string]$StateFile = 'D:/video/_stallwatch-state.json',
  [string]$ReclaimRoot = 'D:/video/_reclaim-queue',
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
$needsValidation = @(); $briefsReady = @(); $reclaimFailed = @(); $reclaimFailedStale = @(); $dischargePendingNames = @()
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
      #   brief, no marker  the track has NO AUTHENTICATED RUNNER and wrote the brief for someone
      #                     to hand to an agent - a stall whose remedy is one line.
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
        $bh = (Get-FileHash -LiteralPath $brief -Algorithm SHA256).Hash
        if (-not $briefBatches.Contains($bh)) { $briefBatches[$bh] = @{ Units = @(); Brief = $brief; Phase = 'dispositions' }; $stalls += ('{{BRIEF-BATCH:' + $bh + '}}') }
        $briefBatches[$bh].Units += $name
        $briefsReady += $name
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
    # not waiting on anyone, the rip is carrying it. The rip folder is the unit name with every
    # non-alphanumeric character dropped, which is how _rip-loop.ps1 names it (and how
    # _release-completed.ps1 finds it again).
    $slug = ($name -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
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
        $bh2 = (Get-FileHash -LiteralPath $brief2 -Algorithm SHA256).Hash
        if (-not $briefBatches.Contains($bh2)) { $briefBatches[$bh2] = @{ Units = @(); Brief = $brief2; Phase = 'manifest' }; $stalls += ('{{BRIEF-BATCH:' + $bh2 + '}}') }
        $briefBatches[$bh2].Units += $name
        $briefsReady += $name
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
  if ($failed.Count -gt 0) {
    $stalls += "{0,-28} manifest FAILED the gate or the encode -> {1}" -f $name, ($failed -join ", ")
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
    try { ([ordered]@{ at = (Get-Date).ToString('s'); stalls = @(); moving = @($moving); held = @($held); busy = [bool]$busy; queued = [int]$queued; running = [int]$running; unitsStaged = [int]$units.Count; fullyStopped = $false; nothingStaged = [bool]($units.Count -eq 0 -and -not $busy); spaceBlocked = $false; reclaimFailed = @(); reclaimFailedStale = @(); needsValidation = @(); briefsReady = @(); briefBatches = @(); dischargePending = @(); quietRun = $true } | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $StateFile -Encoding UTF8 } catch { }
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
$freshaudit = 'D:/video/.claude/skills/disc-to-plex/scripts/audit-publish-freshness.ps1'
if (Test-Path -LiteralPath $freshaudit) { & pwsh -NoProfile -File $freshaudit }

# AND RE-RIP OBLIGATIONS THAT PUBLISHED BUT DID NOT CLOSE. discharge-rerip.ps1 runs after every
# completed publish and closes a register row only on NAS-verified evidence; a row that published
# and still could not close (fewer verified than owed, or a candidate row) is written here so it
# is NAMED rather than discovered at the next refused reclaim.
if ($DischargePending -and (Test-Path -LiteralPath $DischargePending -PathType Leaf)) {
  try {
    $dp = Get-Content -LiteralPath $DischargePending -Raw | ConvertFrom-Json
    foreach ($p in $dp.PSObject.Properties) {
      $e = $p.Value
      Write-Output ("*** RE-RIP NOT DISCHARGED: '{0}' published into '{1}' but delivered {2} of {3} owed ({4}). The register row stays {5}, so its staging cannot release - settle it by hand in D:/video/_rerip-worklist.tsv, or supply the missing evidence. Details: D:/video/_rerip-discharge-pending.json" -f `
                    $p.Name, "$($e.work)", $e.delivered, $e.owed, "$($e.reason)", "$($e.status)")
      $dischargePendingNames += $p.Name
    }
  } catch { Write-Output "   re-rip discharge report unreadable ($DischargePending): $($_.Exception.Message)" }
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
    nothingStaged  = [bool]($units.Count -eq 0 -and -not $busy)
    spaceBlocked   = [bool]$spaceBlocked
    reclaimFailed  = @($reclaimFailed)
    reclaimFailedStale = @($reclaimFailedStale)
    needsValidation = @($needsValidation)
    briefsReady    = @($briefsReady)
    briefBatches   = @($briefBatchDocs)
    dischargePending = @($dischargePendingNames)
  }
  try { ($stateDoc | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $StateFile -Encoding UTF8 } catch { }
}
