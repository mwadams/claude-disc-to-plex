# NAS track: keep publishing, one work at a time, forever.
#
# SERIAL by design - concurrent robocopy jobs contend on the same NAS spindles and link, and with
# several running nothing completes. publish-work.ps1 refuses anything unfinished (no duration) or
# awaiting OCR (bitmap subs, no sidecar), so this loop can run continuously and simply skips what
# is not ready yet, picking it up on a later pass once OCR catches up.
#
# EVERY PARAMETER DEFAULTS TO PRODUCTION. They exist so that publish-loop.tests.ps1 can run THIS
# script - not a copy of its logic - against a scratch local root, a scratch "NAS" and a stub
# publish script, and prove the circuit breaker from the outside. _bounce-track.ps1 relaunches the
# loop with no arguments, i.e. these defaults.
param(
  [string]$LocalRoot       = 'D:\video',
  [string]$NasRoot         = '\\NASTEAMV\Multimedia',
  [string]$PublishScript   = 'D:\video\_publish.ps1',
  [string]$LogDir          = 'D:\video\_logs',
  [string]$Register        = 'D:/video/_awaiting-verification.txt',
  [string]$BreakerRegister = 'D:/video/_publish-breaker.txt',
  # THE CIRCUIT BREAKER (lib-publish-state.ps1). A work whose publish attempt changes nothing on
  # the NAS $MaxNoProgress times in a row is refused until its outstanding set changes; after
  # $MaxNoProgressLifetime fruitless attempts in this process it is refused until the track is
  # bounced. 2,166 attempts (Boston Legal, 2026-09-02) must be structurally impossible.
  [int]$MaxNoProgress         = 5,
  [int]$MaxNoProgressLifetime = 40,
  [int]$IdleSleepSeconds  = 90,
  # THE PASS-RATE FLOOR. The 2026-09-02 hot loop ran passes 5 s apart for three hours because a
  # pass that "published" skipped the idle sleep entirely. A pass that landed something still
  # sleeps this long before the next - a floor on the rate, not a delay on the work.
  [int]$MinPassSeconds    = 10,
  [int]$MaxPasses         = 0,          # 0 = forever; tests use a finite number
  [switch]$NoDownstream,                # skip the subtitle-coverage / retire-list children (tests)
  [string]$MutexName      = 'video-publish-loop'
)

# A NON-DEFAULT MUTEX NAME IS FOR TESTS ONLY, and a test never runs on the production root. Two
# loops on the real library racing the same work is the exact contention this loop's serialness
# exists to avoid, so the override is refused unless the root is somewhere else.
$prodRoot = 'D:\video'
$isProduction = ($LocalRoot.TrimEnd([char]92, [char]47) -ieq $prodRoot)
if ($isProduction -and $MutexName -ne 'video-publish-loop') {
  Write-Output "refusing a non-default mutex name ('$MutexName') on the production root - that would allow two publish loops on the live library"
  exit 1
}

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
$mutexFull = 'Global' + [char]92 + $MutexName
$mutex = New-Object System.Threading.Mutex($false, $mutexFull)
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
if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir | Out-Null }
try { Start-Transcript -Path (Join-Path $LogDir '_publish-loop.log') -Append | Out-Null } catch { }
Write-Output ("=== publish loop up {0} ===" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
if (-not $isProduction) {
  Write-Output ("    TEST MODE: local {0} | nas {1} | publish {2} | breaker {3}/{4} | passes {5}" -f `
    $LocalRoot, $NasRoot, $PublishScript, $MaxNoProgress, $MaxNoProgressLifetime, $MaxPasses)
}

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
. 'D:/video/.claude/skills/disc-to-plex/scripts/lib-nas-governor.ps1'
if (-not (Get-Command Wait-NasHold -ErrorAction SilentlyContinue)) {
  Write-Output 'lib-nas-governor.ps1 failed to load - refusing to run a NAS-writing track without the kill switch'
  exit 1
}
foreach ($fn in 'Get-WorkOutstanding', 'Get-OutstandingFingerprint', 'New-PublishBreaker',
                'Get-PublishBreakerVerdict', 'Register-PublishBreakerAttempt', 'Write-PublishBreakerRegister') {
  if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
    # A dot-source failure is NON-TERMINATING: without this check the function would simply be
    # undefined and every call would error and carry on - for the breaker, that is "no breaker".
    Write-Output "lib-publish-state.ps1 failed to load ($fn undefined) - refusing to run without the definition of 'published' and its circuit breaker"
    exit 1
  }
}

# THE CIRCUIT BREAKER. Per-process state; the register file is the durable, operator-visible view.
$breaker = New-PublishBreaker -MaxNoProgress $MaxNoProgress -MaxNoProgressLifetime $MaxNoProgressLifetime
Write-PublishBreakerRegister -Breaker $breaker -Path $BreakerRegister

$pass = 0
while ($MaxPasses -le 0 -or $pass -lt $MaxPasses) {
  $pass++
  $published = 0
  foreach ($kind in @('Movies', 'Television Shows')) {
    $root = Join-Path $LocalRoot $kind
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
      $nas = Join-Path (Join-Path $NasRoot $kind) $w.Name
      $subsOnly = Test-Path -LiteralPath (Join-Path $w.FullName '.subtitles-only')
      $outstanding = @(Get-WorkOutstanding -WorkDir $w.FullName -NasDir $nas)
      if ($outstanding.Count -eq 0) { continue }
      $before = Get-OutstandingFingerprint $outstanding

      # THE BREAKER, CONSULTED BEFORE ANYTHING IS PRINTED OR INVOKED. A refused work prints one
      # throttled reminder rather than a "republishing" line it is not going to act on - the
      # 2,166-line band this guards against was made of exactly such lines.
      $verdict = Get-PublishBreakerVerdict -Breaker $breaker -Work $w.Name -Fingerprint $before
      if (-not $verdict.Allow) {
        if ($verdict.Skipped -eq 1 -or ($verdict.Skipped % 20) -eq 0) {
          "{0,-46} BREAKER OPEN ({1}) - NOT re-publishing; {2} pass(es) refused so far, {3} file(s) outstanding and unchanged. See {4}" -f `
            $w.Name, $verdict.State, $verdict.Skipped, $outstanding.Count, $BreakerRegister
        }
        continue
      }
      if ($verdict.State -eq 'rearmed') {
        "{0,-46} breaker RE-ARMED - the outstanding set has changed since it tripped; trying once more" -f $w.Name
        Write-PublishBreakerRegister -Breaker $breaker -Path $BreakerRegister
      }

      $stale = @($outstanding | Where-Object { $_.Reason -ne 'missing' }).Count -gt 0
      foreach ($o in @($outstanding | Where-Object { $_.Reason -eq 'timestamp' })) {
        "{0,-46} '{1}' differs by TIMESTAMP not size - re-publishing" -f $w.Name, $o.Name
      }

      # -NoProfile: avoids the Terminal-Icons half-written-theme Import-Clixml noise on concurrent
      # pwsh starts; _publish.ps1 has no profile dependence (checked 2026-09-02).
      $args = @('-NoProfile', '-File', $PublishScript, '-Work', $w.Name, '-Kind', $kind)
      if ($stale) { $args += '-Overwrite'; "{0,-46} wrong-size copy on NAS -> republishing with -Overwrite" -f $w.Name }

      # THE NAS KILL SWITCH (lib-nas-governor.ps1, 2026-09-04): while D:/video/_nas-hold exists
      # nothing new is pushed to the NAS. Checked HERE, between works, because a robocopy already
      # running must finish its work (a kill mid-copy is the partial-file-on-the-NAS risk this loop
      # exists to avoid). This is the only governor touch on the publish path: robocopy itself
      # cannot be rate-limited (/IPG measured to do nothing on this link), so the upload direction
      # is stop/go, not paced.
      [void](Wait-NasHold -Say { param($m) Write-Output ("    {0}" -f $m) } -Who 'publish')

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
      if ($landed -gt 0) { $published++ }

      # THE BREAKER, FED. "Progress" is the outstanding set having changed at all - a file landed,
      # or a new one appeared - measured by the same function that decided there was work to do.
      $afterFp = Get-OutstandingFingerprint $after
      $trip = Register-PublishBreakerAttempt -Breaker $breaker -Work $w.Name -Before $before -After $afterFp
      if ($trip -ne 'ok') {
        $bw = Get-PublishBreakerWork $breaker $w.Name
        Write-PublishBreakerRegister -Breaker $breaker -Path $BreakerRegister
        if ($trip -eq 'hard-tripped') {
          "    *** CIRCUIT BREAKER HARD-TRIPPED: '{0}' - {1} publish attempts in this loop's lifetime changed NOTHING on the NAS ({2} attempts in all)." -f $w.Name, $bw.NoProgressLifetime, $bw.Attempts
          "        REFUSING to re-publish it again until the publish track is bounced (pwsh -File D:/video/_bounce-track.ps1 -Track publish)."
        } else {
          "    *** CIRCUIT BREAKER TRIPPED: '{0}' - {1} consecutive publish attempts changed NOTHING on the NAS." -f $w.Name, $bw.NoProgress
          "        REFUSING to re-publish it until its outstanding set changes (a file arrives locally, or the NAS copy is replaced)."
        }
        "        Something is stopping the copy from taking effect - a refusal upstream (see the line above), a locked or unreplaceable NAS file,"
        "        or a comparison the copy can never satisfy. Investigate; do not just bounce. Register: {0}" -f $BreakerRegister
        foreach ($o in ($after | Select-Object -First 5)) {
          "{0,-46}    {1} ({2}, local {3} / nas {4})" -f '', $o.Name, $o.Reason, $o.LocalLength, $o.NasLength
        }
      }

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
      if ($landed -gt 0 -and -not $NoDownstream) {
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
        $already = @()
        if (Test-Path -LiteralPath $Register) {
          $already = @(Get-Content -LiteralPath $Register | ForEach-Object { ($_ -split '\|')[-1].Trim() })
        }
        if ($already -notcontains $w.Name) {
          Add-Content -LiteralPath $Register -Value ("{0}|{1}" -f (Get-Date -Format s), $w.Name)
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
  if ($published -gt 0 -and -not $NoDownstream) {
    Write-Output '--- refreshing NAS retire list (supersedes -> verified replacement) ---'
    try {
      & pwsh -NoProfile -File 'D:\video\.claude\skills\disc-to-plex\scripts\build-retire-list.ps1' 2>&1 |
        ForEach-Object { "    $_" }
    } catch {
      Write-Output "    build-retire-list.ps1 threw: $($_.Exception.Message)"
    }

    # THE FULL LIBRARY-WIDE COVERAGE SWEEP NO LONGER RUNS HERE. It is its own track,
    # D:/video/_coverage-loop.ps1 ('coverage' in _loops.ps1 and _bounce-track.ps1).
    #
    # It was a 30-55 minute SYNCHRONOUS child of this SERIAL loop, so for its whole duration
    # nothing published. That stalled the line twice on 2026-09-04: once starting four minutes
    # before the Fight Club feature finished encoding (2.86 GB still local at 01:22, disk 10 GB
    # under its fetch floor, 19 discs waiting), and once starting at 01:53:15 with Fight Club
    # Disk 2's 27 extras completing at 02:12:53, twenty minutes into it.
    #
    # A "defer the sweep while work is outstanding" guard was tried first and is NOT ENOUGH: it can
    # stop a sweep STARTING, never interrupt one already under way, and encodes finish at arbitrary
    # times - so any batch landing mid-sweep recreates the stall. The window cannot be tightened
    # shut. A library-wide REPORT has no business on the critical path of the loop that ships the
    # deliverable, so it now lives entirely off that path; the coverage track owns the throttle,
    # the checkpoint and the single-instance guard. See its header.
    #
    # WHAT STAYS HERE is the SCOPED per-work `subtitle-coverage.ps1 -Works X -Queue` call above:
    # it is about the one work that just published, it is the event that creates the coverage gap,
    # and it is the only place anything is ever QUEUED.
  }

  # SLEEP: the idle interval when nothing landed, and NEVER LESS THAN THE FLOOR when something did.
  # The 2026-09-02 Boston Legal band was 1,441 zero-byte robocopy runs at a median 5 s apart: the
  # old rule ("published something -> go straight round again") turned a work that could never
  # settle into a spin. Progress still shortens the wait; it no longer removes it.
  if ($published -eq 0) { Start-Sleep -Seconds $IdleSleepSeconds }
  elseif ($MinPassSeconds -gt 0) { Start-Sleep -Seconds $MinPassSeconds }
}
