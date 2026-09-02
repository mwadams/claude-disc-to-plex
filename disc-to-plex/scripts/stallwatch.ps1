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
  [switch]$Quiet          # print nothing when every unit is either busy or held
)

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

foreach ($u in $units) {
  $name = $u.Name

  $hold = Join-Path $u.FullName '.HOLD'
  if (Test-Path -LiteralPath $hold) {
    $why = (Get-Content -LiteralPath $hold -Raw -ErrorAction SilentlyContinue).Trim()
    $held += "{0,-28} HELD - {1}" -f $name, $(if ($why) { $why } else { 'no reason recorded' })
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
      if (Test-Path -LiteralPath (Join-Path $Pending ($name + '.dispositioning'))) {
        $moving += "{0,-28} dispositions being written (subagent working)" -f $name
      } else {
        $stalls += "{0,-28} needs DISPOSITIONS -> write {1}" -f $name, (Split-Path $disp -Leaf)
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
    if ($isRip) {
      $moving += "{0,-28} redundant rip - no manifest reads it; release it with its disc" -f $name
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
      if (Test-Path -LiteralPath (Join-Path $Pending ($name + '.authoring'))) {
        $moving += "{0,-28} manifest being authored (subagent working)" -f $name
      } else {
        $stalls += "{0,-28} needs MANIFEST     -> author one and drop it in _queue" -f $name
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
    $stalls += "{0,-28} manifest AUTHORED BUT NEVER QUEUED -> _gate-queue.ps1 ({1})" -f $name, ($orphan -join ", ")
  } elseif ($live.Count -gt 0) {
    $moving += "{0,-28} in the queue / encoding" -f $name
  } elseif ($done.Count -eq $mNames.Count) {
    $moving += "{0,-28} encoded - awaiting OCR/publish/confirmation" -f $name
  } else {
    $moving += "{0,-28} manifest state unclear - check _queue by hand" -f $name
  }
}

if ($stalls.Count -eq 0 -and $Quiet) { return }

$stamp = Get-Date -Format 'HH:mm:ss'
if ($stalls.Count -gt 0) {
  Write-Output "[$stamp] PIPELINE WAITING ON THE OPERATOR - $($stalls.Count) unit(s):"
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
if (Test-Path -LiteralPath $spaceaudit) { & pwsh -NoProfile -File $spaceaudit }

# AND THE RECLAIM QUEUE: a FAILED reclaim is a user confirmation that did NOT execute, and a
# queued artefact with no loop behind it sits forever looking like it is being handled. Both are
# invisible everywhere else - the release scripts only speak when invoked, and the whole point of
# the reclaim track is that nobody invokes them by hand any more. (Added 2026-09-02 with
# _reclaim-loop.ps1; the artefact format is documented in that loop's header.)
$rqRoot = 'D:/video/_reclaim-queue'
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
  foreach ($f in $rqFailed) {
    Write-Output ("*** RECLAIM FAILED: {0} - a CONFIRMED reclaim did not complete. Read {1}/failed/{2}.result.txt, fix the cause, move the .json back into _reclaim-queue/ to retry." -f $f.Name, $rqRoot, $f.BaseName)
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
