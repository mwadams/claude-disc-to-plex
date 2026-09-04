# NAS track: keep publishing, one work at a time, forever.
#
# SERIAL by design - concurrent robocopy jobs contend on the same NAS spindles and link, and with
# several running nothing completes. publish-work.ps1 refuses anything unfinished (no duration) or
# awaiting OCR (bitmap subs, no sidecar), so this loop can run continuously and simply skips what
# is not ready yet, picking it up on a later pass once OCR catches up.
#
# SINGLE INSTANCE. This was the only loop without a mutex, and the absence bit twice in one minute
# on 2026-08-25: probing for a mutex that did not exist reported the loop DEAD while it had been
# running since 04:55, and starting a "replacement" then succeeded - twice - because nothing
# refused. Two publish loops racing the same work is the exact contention this loop's serialness
# exists to avoid. The mutex is now both the guard AND the liveness probe: a monitor can ask
# TryOpenExisting instead of guessing from a process list.
#
# NOTE the string build: `'Global' + [char]92 + 'name'`. Written as New-Object with a comma inside
# a concatenation, the arguments parse as one 4-element ARRAY and New-Object returns $null - which
# fails OPEN. That is why the null check below is not decoration.
$mutexName = 'Global' + [char]92 + 'video-publish-loop'
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if ($null -eq $mutex) {
  Write-Output 'could not create the single-instance mutex - refusing to run unguarded'
  exit 1
}
if (-not $mutex.WaitOne(0)) {
  Write-Output 'another publish loop already holds the mutex - exiting'
  exit 0
}

# LOG FOR YOURSELF - never depend on how you were launched.
#
# This loop ran from 2026-08-25 11:09 started as `pwsh -File _publish-loop.ps1` with NO redirection,
# so every line it printed went to a console nobody was attached to and was lost. The newest file in
# _logs was then two days old, and on 2026-08-27 I read that stale log as the live one and announced
# the loop was jammed retrying Goodnight Sweetheart - a work that had in fact published cleanly and
# been reclaimed days earlier. It was idling correctly the whole time.
#
# A loop that cannot be observed gets misdiagnosed, and the misdiagnosis is what leads to killing
# healthy pipeline processes. Transcript, not redirection, so it holds however it is started - and
# it captures a terminating error too, which a `> log` from the launcher would also have lost.
$logDir = 'D:\video\_logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
try { Start-Transcript -Path (Join-Path $logDir '_publish-loop.log') -Append | Out-Null } catch { }
Write-Output ("=== publish loop up {0} ===" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

# THE DEFINITION OF "PUBLISHED", loaded FAIL-CLOSED.
#
# Get-WorkOutstanding (lib-publish-state.ps1) answers one question - which files of this work are
# not yet correctly on the NAS - and this loop uses it TWICE per work: once to decide whether to
# invoke a publish at all, and once AFTERWARDS to decide whether the work may be called published.
# It carries the artefact-type test with it (lib-artefact-types.ps1), which is what keeps quarantine
# litter such as `X.mkv.wrong-length` out of the comparison: such a file is never published, so it
# is never on the NAS, so counting it would read as "work to do" on EVERY pass and the loop would
# re-invoke the publish forever without ever sleeping.
#
# This used to be a fail-OPEN load of lib-artefact-types.ps1 alone, on the reasoning that the worst
# case was a few extra publish attempts. That is no longer the worst case: without this function
# the loop cannot tell a published work from a half-published one, which is precisely the claim the
# Fight Club incident (2026-09-04) proved must never be guessed. If it will not load, refuse to run.
$stateLib = 'D:/video/.claude/skills/disc-to-plex/scripts/lib-publish-state.ps1'
if (-not (Test-Path -LiteralPath $stateLib)) {
  Write-Output "publish-state library missing: $stateLib - refusing to run without the definition of 'published'"
  exit 1
}
. $stateLib
if (-not (Get-Command Get-WorkOutstanding -ErrorAction SilentlyContinue)) {
  # A dot-source failure is NON-TERMINATING: without this check the function would simply be
  # undefined and every call would error and carry on.
  Write-Output 'lib-publish-state.ps1 failed to load - refusing to run without the definition of "published"'
  exit 1
}

while ($true) {
  $published = 0
  # Files that STILL have to reach the NAS when this pass ends, across every work. It gates the
  # expensive full subtitle-coverage sweep at the bottom of the pass - see there for why.
  $stillOutstanding = 0
  $worksOutstanding = @()
  foreach ($kind in @('Movies', 'Television Shows')) {
    $root = Join-Path 'D:\video' $kind
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($w in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
      # cheap pre-check: is anything actually missing on the NAS for this work?
      #
      # MISSING and WRONG-SIZE are different faults and need different flags. Without -Overwrite
      # _publish.ps1 runs robocopy with /XC /XN /XO, which SKIP any file already present at the
      # destination - so a file that landed TRUNCATED can never be repaired by this loop: the
      # pre-check sees the size mismatch every pass, robocopy skips it, verify fails, forever.
      # That happened on 2026-08-19 (Danger UXB S01E10-E13, e.g. The Pier 27 MB of 1.25 GB), and
      # it is silent - the loop just prints a failing verify line each cycle.
      #
      # So: absent -> normal no-clobber copy. Present but wrong size -> pass -Overwrite for THIS
      # work only, which is exactly the documented "replace a bad copy" case.
      # SUBTITLES-ONLY, quarantine litter, size AND timestamp: all of it now lives in ONE shared
      # definition, Get-WorkOutstanding (lib-publish-state.ps1), because this loop needs the same
      # answer again after the publish and a second inline copy of the rule would drift from this
      # one. Its header carries the reasoning that used to sit here: the Boston Legal scaffolding
      # hot-loop (the local .mkv of a `.subtitles-only` work differs from the NAS copy permanently
      # and by design), and the Michael J. Fox Interview re-encode that came out byte-for-byte the
      # SAME SIZE at a different aspect ratio, which is why an mtime difference counts too.
      $nas = Join-Path (Join-Path '\\NASTEAMV\Multimedia' $kind) $w.Name
      $subsOnly = Test-Path -LiteralPath (Join-Path $w.FullName '.subtitles-only')
      $outstanding = @(Get-WorkOutstanding -WorkDir $w.FullName -NasDir $nas)
      if ($outstanding.Count -eq 0) { continue }
      $stale = @($outstanding | Where-Object { $_.Reason -ne 'missing' }).Count -gt 0
      foreach ($o in @($outstanding | Where-Object { $_.Reason -eq 'timestamp' })) {
        "{0,-46} '{1}' differs by TIMESTAMP not size - re-publishing" -f $w.Name, $o.Name
      }

      # -NoProfile: avoids the Terminal-Icons half-written-theme Import-Clixml noise on concurrent
      # pwsh starts; _publish.ps1 has no profile dependence (checked 2026-09-02).
      $args = @('-NoProfile', '-File', 'D:\video\_publish.ps1', '-Work', $w.Name, '-Kind', $kind)
      if ($stale) { $args += '-Overwrite'; "{0,-46} wrong-size copy on NAS -> republishing with -Overwrite" -f $w.Name }

      # SIDECARS ONLY, IF THE WORK SAYS SO. A `.subtitles-only` marker in the work folder means the
      # media is ALREADY on the NAS and correct, and only the .srt should travel - the case where a
      # legacy encode published the episodes with no subtitle stream, so the library OCR campaign
      # can never reach them (it reads tracks from inside files that are already published).
      # The local encode exists solely to produce the subtitle; shipping it again would push GBs
      # back over SMB and disturb a published file that is already right.
      #
      # A MARKER FILE, not a flag here, because the fact belongs to the WORK and must survive a
      # loop restart, a context compaction and whoever looks next. Dropped by whoever authors the
      # manifest - which is already the one manual step in this pipeline.
      if ($subsOnly) {
        $args += '-SubtitlesOnly'
        "{0,-46} .subtitles-only marker -> publishing sidecars only, leaving the NAS media alone" -f $w.Name
      }
      $out = & pwsh @args 2>&1
      # MATCH THE MESSAGE, NOT THE SOURCE LINE THAT RAISED IT.
      #
      # When _publish.ps1 throws, PowerShell renders the error with the offending SOURCE LINE
      # attached, and that source line contains the word REFUSING because it is the throw itself.
      # A bare match therefore logged `53 | . eq 'N/A') { throw "REFUSING: $($f.Name) has no dur .`
      # - the code, truncated, with the filename still an unexpanded variable - instead of the
      # actual reason. Every refusal in this log read like that, so the log could not answer the
      # one question it exists to answer: WHICH file, and WHY.
      #
      # PowerShell prefixes those source echoes with `<line number> | `, so drop them and keep the
      # rendered message.
      # 'NOT PUBLISHING' is the artefact-type gate skipping a file (quarantine litter) while the
      # rest of the work publishes - it must be surfaced ALONGSIDE the 'verified' line, not instead
      # of it, hence keeping every match rather than the first: the downstream `-join ' '` renders
      # an array as one line, and `$line -match 'verified'` is array-safe, so the verified
      # bookkeeping is unchanged.
      $line = $out |
              Where-Object { "$_" -notmatch '^\s*\d+\s*\|' } |
              Select-String 'verified|REFUSING|NOT PUBLISHING'
      # `-replace '^\s*\|\s*'` drops the leading pipe of PowerShell's error continuation line, which
      # survives the source-line filter above because it carries no line number.
      if ($line) { "{0,-46} {1}" -f $w.Name, ((($line -join ' ') -replace '\s+', ' ') -replace '^\s*\|\s*', '') }
      elseif ($LASTEXITCODE -ne 0) {
        # A publish that CRASHES (guard failed to load, robocopy exit >= 8, a throw before the
        # verify) prints neither 'verified' nor 'REFUSING', and this loop used to say NOTHING -
        # the work just silently never reached the NAS, pass after pass. A refusal is expected
        # and quiet; a crash must be loud, with enough of the tail to see why.
        "{0,-46} PUBLISH CRASHED (exit {1}) - last output:" -f $w.Name, $LASTEXITCODE
        @($out | Where-Object { "$_" -match '\S' })[-3..-1] | ForEach-Object { "    $_" }
      }
      # ASK THE NAS, DO NOT READ THE CHILD'S ADJECTIVE.
      #
      # `verified N/N` is publish-work.ps1's honest summary OF THE LIST IT CHOSE TO COPY - and that
      # list has already had the partial (still-encoding) files, the quarantine litter and, for a
      # marked work, every non-.srt removed from it. So the ratio cannot fall below 1.0 however much
      # was skipped, and `verified 1/1` is exactly what a work publishes when ONE 5 MB extra landed
      # and its 2.86 GB feature did not (Fight Club, 2026-09-04). Matching that word was this loop
      # deciding a WORK-level fact from a FILE-level report.
      #
      # Re-measure instead. The same function that decided there was work to do decides whether the
      # work was done, so the claim cannot outrun the files by construction. Two different questions
      # come out of it and they must not be conflated:
      #
      #   $landed  - files that went from outstanding to correct on the NAS THIS PASS. This is "the
      #              NAS changed", and it is what the downstream refreshes below key on: a retire
      #              list is only worth rebuilding when a replacement actually arrived.
      #   $after   - what is STILL outstanding. Empty, and only empty, means the work is published.
      #
      # A pass can easily have $landed -gt 0 and $after -gt 0 (a growing TV show, or this exact
      # incident) - which is a real, useful publish AND a work that is not published. Publishing
      # early stays exactly as it was; only the CLAIM now waits for the files.
      $after  = @(Get-WorkOutstanding -WorkDir $w.FullName -NasDir $nas)
      $landed = $outstanding.Count - $after.Count
      $stillOutstanding += $after.Count
      if ($after.Count -gt 0) { $worksOutstanding += $w.Name }
      if ($landed -gt 0) { $published++ }

      if ($after.Count -gt 0) {
        # SAY WHAT IS MISSING, EVERY PASS. The old code said nothing here at all - a partly
        # published work looked identical to a finished one in this log, which is how the feature
        # sat unpublished for 50 minutes with 'IS PUBLISHED' above it.
        "{0,-46} PARTIAL: {1} file(s) still not on the NAS ({2} landed this pass) - NOT recording it as published" -f `
          $w.Name, $after.Count, $landed
        foreach ($o in ($after | Select-Object -First 5)) {
          "{0,-46}    {1} ({2})" -f '', $o.Name, $o.Reason
        }
      }

      # SCOPED SUBTITLE-COVERAGE runs on $landed, not on the word 'verified': the event that creates
      # a coverage gap is a file ARRIVING on the NAS, and that is true of a partial publish too.
      if ($landed -gt 0) {
        # SUBTITLE-COVERAGE TRIGGER, right at the event that creates the gap. "I am surprised it
        # published without SRT" (user, 2026-09-03): the publish gate only refuses a file with a
        # BITMAP subtitle awaiting OCR - a file with no subtitle stream at all sails through,
        # because there is genuinely nothing to wait for. Four Survivors S02 episodes did exactly
        # that the same day, and nothing noticed.
        #
        # SCOPED to the work that just published, not a full-library sweep - a routine pass here
        # must stay cheap. The full picture is refreshed separately and less often, below.
        #
        # QUEUEING IS NOT RUNNING. Two SEPARATE queues, two separate scope rules (user, 2026-09-03):
        #   - OCR (_ocr-queue.csv): LIBRARY-WIDE - a bitmap subtitle stream found by probing the
        #     published file directly is its own evidence; it does not matter which drive produced
        #     it or whether this pipeline produced it.
        #   - Transcription (_transcribe-queue.csv): NARROWED - only 'awaiting-transcription' (this
        #     pipeline's own manifest declares no subtitle source AND the file is sourced from the
        #     CURRENTLY ATTACHED drive). A disc on a drive not attached may have subtitles never
        #     seen yet, so transcribing now risks GPU + verification effort a future re-rip would
        #     waste; those go to _transcribe-deferred.csv instead, NOT as a failure.
        # Never 'not-applicable' (routed to its own register) and never 'genuinely-missed' (a real
        # subtitle source that failed to ship - reported, not papered over). Neither track is ever
        # STARTED by this - both drain opportunistically and OCR/transcribe stand down for encodes.
        try {
          $covOut = & pwsh -NoProfile -File 'D:\video\.claude\skills\disc-to-plex\scripts\subtitle-coverage.ps1' -Works $w.Name -Queue 2>&1
          $covLine = $covOut | Select-String 'QUEUED: [1-9]|DIVERTED TO NOT-APPLICABLE|EXCLUDED|awaiting-ocr|genuinely-missed|transcription-deferred'
          if ($covLine) { $covLine | ForEach-Object { "    [subtitle-coverage] $_" } }
        } catch {
          Write-Output "    subtitle-coverage.ps1 threw: $($_.Exception.Message)"
        }
      }

      # THE WORK IS PUBLISHED ONLY WHEN NOTHING IS OUTSTANDING.
      if ($after.Count -eq 0) {

        # A COMPLETED PUBLISH IS THE MOMENT TO ASK FOR A VERIFICATION - and while the disk is
        # below the fetch floor, it is the ONLY thing that can unblock the line.
        #
        # Reclaiming a published local copy is gated on the user confirming the unit in Plex, and
        # nothing was asking. On 2026-09-01, 48.74 GB of already-confirmed Babylon 5 accumulated
        # locally, the fetch sat under its floor for over an hour, and _stallwatch.ps1 reported
        # "no unit is waiting on the operator" throughout. The user had to ask why they were not
        # notified. The consequence was visible; the REQUEST never was.
        #
        # This is the request, raised at the event that creates it. The register is what
        # audit-space-block.ps1 reads to name units rather than guess at them, and it is the queue
        # the reclaim drains: a work leaves it when its disc is written to _completed.txt.
        $reg = 'D:/video/_awaiting-verification.txt'
        $already = @()
        if (Test-Path -LiteralPath $reg) {
          $already = @(Get-Content -LiteralPath $reg | ForEach-Object { ($_ -split '\|')[-1].Trim() })
        }
        if ($already -notcontains $w.Name) {
          Add-Content -LiteralPath $reg -Value ("{0}|{1}" -f (Get-Date -Format s), $w.Name)
        }
        $freeGB = [math]::Round([IO.DriveInfo]::new('D').AvailableFreeSpace / 1GB, 1)
        if ($freeGB -lt 120) {
          Write-Output ("    *** {0} IS PUBLISHED AND THE DISK IS BELOW THE FETCH FLOOR ({1} GB)." -f $w.Name, $freeGB)
          Write-Output  '        Confirm it in Plex so its local copy can be reclaimed - the line is waiting on this.'
        }
      }
    }
  }

  # RETIRE LIST: refresh the hand-over list the moment a publish changes what is on the NAS.
  #
  # build-retire-list.ps1 only lists a superseded file once ITS REPLACEMENT is verified on the
  # NAS, and this loop is the one place that just put a replacement there - so a publish is the
  # earliest correct moment to refresh it. Leaving that to someone remembering to run the script
  # by hand is exactly the manual step the user objected to for reclaim on 2026-09-02: "This
  # should be driven by a manifest-like process so it is running in a loop and you provide the
  # required reclaim, rather than hand running scripts." The reclaim track (_reclaim-loop.ps1) is
  # the wrong home for this - it deletes LOCAL D: copies on a user-authored confirmation artefact
  # and never touches the NAS at all; this is a read-only NAS-side listing, and publish is what
  # changes NAS state.
  #
  # GATED ON $published -gt 0, not run every idle poll: the script rescans every manifest under
  # _queue (480+) plus a Get-Item per candidate on the NAS for each pass, and nothing changes on
  # the NAS between successful publishes, so an unconditional call would be pure NAS traffic for
  # no new information every 90 s.
  #
  # ALWAYS THE SAME TWO FILES (its defaults, D:\video\_nas-retire.txt and
  # D:\video\_nas-retire-detail.tsv) - one current hand-over list, overwritten in place, never a
  # new timestamped file. It is READ-ONLY: it never deletes, moves or renames anything anywhere -
  # removal on the NAS stays the user's. The other *-retire-*.txt files already in D:\video
  # (VERIFIED / renamed / extras / dm-s00, plus the Boston Legal / Danger Man
  # _nas-superseded-*.txt files) are one-off deliverables from earlier hand investigations
  # (renames, extras re-homing, Season 00 identification) - they are history, not live output,
  # and this loop does not touch them.
  if ($published -gt 0) {
    Write-Output '--- refreshing NAS retire list (supersedes -> verified replacement) ---'
    try {
      & pwsh -NoProfile -File 'D:\video\.claude\skills\disc-to-plex\scripts\build-retire-list.ps1' 2>&1 |
        ForEach-Object { "    $_" }
    } catch {
      Write-Output "    build-retire-list.ps1 threw: $($_.Exception.Message)"
    }

    # FULL SUBTITLE-COVERAGE REPORT - refreshed periodically, not every pass. The per-work trigger
    # above catches what THIS loop just published; this is the wider "one current picture" (every
    # work, both areas, the legacy backlog total, stale-provenance and genuinely-missed lists) that
    # D:/video/_subtitle-coverage.csv is supposed to be.
    #
    # COST WENT UP 2026-09-03: a full sweep now ffprobes EVERY file with no current sidecar for a
    # bitmap subtitle stream (the awaiting-ocr check, widened to the whole library per the user's
    # ruling that OCR eligibility must be probed on the file, not inferred from a manifest) - about
    # 5,600 files, ~25-30 minutes, not the ~30-40s a metadata-only sweep took before. Raised the
    # throttle from 30 to 240 minutes accordingly - at 30 the sweep would have been running back to
    # back, which is exactly the "NAS is remote and slow, don't rescan on every idle poll" guard
    # this loop otherwise follows everywhere else.
    #
    # REPORT ONLY - never -Queue here. The 'awaiting-transcription' backlog across the WHOLE
    # library this pipeline has ever produced runs into four figures - committing that to the
    # transcribe queue in one shot is the kind of decision this loop must surface, not make
    # unattended. Only the scoped per-work call above queues anything, and only for the work that
    # just published (both its OCR and its transcription eligibility).
    $coverageFullSweepEveryMin = 240
    $coverageCheckpoint = 'D:/video/_subtitle-coverage-last-full.txt'
    $dueForFullSweep = $true
    # How long since the last CLEAN sweep. Also used by the deliverable-first gate below, so it is
    # computed here rather than inside the throttle's own if.
    $sinceLastSweepMin = [double]::MaxValue
    if (Test-Path -LiteralPath $coverageCheckpoint) {
      $last = Get-Content -LiteralPath $coverageCheckpoint -Raw -ErrorAction SilentlyContinue
      # MUST BE TYPED. `$lastTime = $null` is untyped, and TryParse's [ref] parameter needs a
      # [DateTime]-typed variable to bind to - an untyped $null cannot bind, so the call THROWS
      # (MethodException: "Cannot find an overload for TryParse and the argument count: 2") on
      # EVERY pass, regardless of what $last contains. Confirmed live in _publish-loop.log at
      # 18:20 today, repeating on every publish cycle since this block was written.
      #
      # That throw is NON-TERMINATING at script scope (no try/catch here previously, and none
      # needed to reach the next statement) - PowerShell prints the error and moves on, so the
      # loop never crashed and nothing looked broken. But it aborts the `if` before
      # $dueForFullSweep is ever reassigned away from its default $true, so the 240-minute
      # throttle silently never engaged: the 30-45 minute full sweep ran on EVERY publish pass
      # instead of every 4 hours, and the loop's log has sat frozen mid-sweep since 18:20 while
      # this checkpoint still read 17:32 - Edge of Darkness work queued behind it the whole time.
      [DateTime]$lastTime = [DateTime]::MinValue
      try {
        if ([DateTime]::TryParse($last, [ref]$lastTime)) {
          $sinceLastSweepMin = ((Get-Date) - $lastTime).TotalMinutes
          $dueForFullSweep = $sinceLastSweepMin -ge $coverageFullSweepEveryMin
        } else {
          # Same failure class as the TV-reindex incident (follow-up.md, 2026-09-03): a throttle
          # that degrades silently into "always run" reads as ordinary slowness for days, not as
          # a defect. This loop keeps operator-log lines only where they match this script's own
          # 'verified|REFUSING|NOT PUBLISHING' convention (see the per-work publish block above),
          # so reuse REFUSING here too even though this path never touches that filter directly -
          # it is the greppable word this pipeline already looks for.
          Write-Output ("    REFUSING to trust subtitle-coverage checkpoint '{0}' - content is not a parseable date ('{1}') - forcing a full sweep this pass" -f $coverageCheckpoint, $last)
        }
      } catch {
        Write-Output ("    REFUSING to trust subtitle-coverage checkpoint '{0}' - {1} - forcing a full sweep this pass" -f $coverageCheckpoint, $_.Exception.Message)
      }
    }
    # THE DELIVERABLE COMES BEFORE THE REPORT.
    #
    # This sweep is a synchronous child of a SERIAL loop, so for its whole 30-55 minutes nothing is
    # published. On 2026-09-04 it started at 00:27:25 - four minutes before the Fight Club feature
    # finished encoding at 00:31:38 - and the film was still not on the NAS at 01:22, on a disk
    # 10 GB under its fetch floor with 19 discs waiting. Nothing was wedged; the publish was simply
    # queued behind a report. That is the wrong priority in a pipeline whose stated rule is
    # "publish immediately, gate only the reclaim": the user cannot confirm a unit in Plex until it
    # is on the NAS, and the coverage CSV helps nobody while the line is stopped.
    #
    # So: if any work still has files to publish, defer. The sweep is report-only, it is
    # interrupt-safe by design (it accumulates in memory and writes the CSV exactly once at the
    # end), and being 90 seconds later costs nothing.
    #
    # BUT NEVER SILENTLY FOREVER. A work with a permanently partial file (a show encoding across
    # hours, or an abandoned output) would otherwise starve the sweep indefinitely and the coverage
    # report would quietly rot - the same "degrades silently into never" failure the throttle bug
    # above was. At twice the throttle the sweep runs anyway, and says that it is doing so.
    if ($dueForFullSweep -and $stillOutstanding -gt 0) {
      if ($sinceLastSweepMin -ge (2 * $coverageFullSweepEveryMin)) {
        Write-Output ("--- full subtitle-coverage sweep deferred behind unpublished files for {0:N0} min (2x the {1} min throttle) - running it now anyway; {2} file(s) still outstanding in: {3} ---" -f `
                      $sinceLastSweepMin, $coverageFullSweepEveryMin, $stillOutstanding, (($worksOutstanding | Select-Object -Unique) -join ', '))
      } else {
        Write-Output ("--- DEFERRING the full subtitle-coverage sweep: {0} file(s) still have to reach the NAS in {1} - publishing comes first, and this sweep blocks this loop for 30-55 min ---" -f `
                      $stillOutstanding, (($worksOutstanding | Select-Object -Unique) -join ', '))
        $dueForFullSweep = $false
      }
    }
    if ($dueForFullSweep) {
      Write-Output '--- refreshing full subtitle-coverage report (report-only, no auto-queue) ---'
      try {
        & pwsh -NoProfile -File 'D:\video\.claude\skills\disc-to-plex\scripts\subtitle-coverage.ps1' 2>&1 |
          Select-String 'unclassified,|awaiting-transcription,|awaiting-ocr,|LEGACY BACKLOG|TRANSCRIPTION-DEFERRED|genuinely-missed \(ours\)|stale-provenance \(ours\)' |
          ForEach-Object { "    $_" }
        # STAMP ONLY ON A CLEAN EXIT. subtitle-coverage.ps1 runs with $ErrorActionPreference =
        # 'Stop' and exits 2 on a refused/invalid run, 0 on a completed sweep - so $LASTEXITCODE
        # is a real signal here, not prose to match. Stamping unconditionally would let a failed
        # sweep look identical to a good one for the next 240 minutes; not stamping at all would
        # otherwise re-run every pass forever exactly like the bug above, which is why this checks
        # the code instead of assuming the pipeline reaching Set-Content means success.
        if ($LASTEXITCODE -eq 0) {
          Set-Content -LiteralPath $coverageCheckpoint -Value (Get-Date -Format s)
        } else {
          Write-Output ("    REFUSING to stamp the coverage checkpoint - subtitle-coverage.ps1 exited {0} - next pass will retry the full sweep" -f $LASTEXITCODE)
        }
      } catch {
        Write-Output "    subtitle-coverage.ps1 (full sweep) threw: $($_.Exception.Message)"
      }
    }
  }

  if ($published -eq 0) { Start-Sleep -Seconds 90 }
}
