# Refuse hand-invocation of a worker that a self-draining track already owns.
#
# WHY THIS EXISTS. The batch runs as four independent tracks (encode / source / OCR / publish),
# and exactly ONE step in the whole pipeline is manual: authoring a manifest. Everything after
# `_queue` drains itself. That is written down in the skill and in memory, and it was still
# improvised around twice within one hour on 2026-08-23 - once for OCR, once for publish.
#
# The OCR case is not a style complaint, it is a correctness bug. `_ocr-loop.ps1` is STATELESS:
# it re-derives its work list from the filesystem on every pass. So a hand-run of
# `ocr-subtitles.ps1` does not "help" - both the loop and the manual run scan the same tree, pick
# the SAME first file, and race to write ONE sidecar. On 2026-08-23 that produced two live workers
# on `Thunderball (1965).mkv` (PIDs 39520 and 37224) writing the same `.eng.srt`.
#
# The loop's own mutex cannot catch this: it guards against a second _ocr-loop, and a human
# invoking the worker directly walks straight past it. Hence a guard on the WORKER.
#
# A rule that lives only in prose gets violated after a context compaction - including rules
# written in capitals. A guard that aborts survives it. See references/gotchas-process.md.

function Get-AncestorCommandLines {
  param([int]$StartPid = $PID, [int]$MaxDepth = 8)
  $lines = @()
  $cur = $StartPid
  for ($i = 0; $i -lt $MaxDepth; $i++) {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$cur" -ErrorAction SilentlyContinue
    if (-not $p) { break }
    $lines += "$($p.CommandLine)"
    $parent = [int]$p.ParentProcessId
    if ($parent -le 0 -or $parent -eq $cur) { break }
    $cur = $parent
  }
  $lines
}

function Assert-TrackOwner {
  param(
    [Parameter(Mandatory)][ValidateSet('OCR', 'Publish')][string]$Track,
    [switch]$Manual
  )

  # BOTH OCR TRACKS COUNT. There are two self-draining OCR loops, not one: `_ocr-loop.ps1` (local
  # D:\video\Movies|Television Shows, stateless rescan) and `_ocr-queue-loop.ps1` (library-wide,
  # draining _ocr-queue.csv, every row a \\NASTEAMV path). This pattern used to name only the first,
  # with two consequences, both observed live on 2026-09-04:
  #   - A hand-run of ocr-subtitles.ps1 while ONLY the queue track was draining sailed straight past
  #     the guard at the `$live.Count -eq 0` return - unguarded against exactly the two-workers-one-
  #     sidecar race this file exists to prevent, and a hand-run on a NAS file is precisely how that
  #     campaign is worked.
  #   - The queue loop's own worker child was classified as a HAND-RUN (its ancestor command line
  #     says `_ocr-queue-loop.ps1`, which this pattern did not match), so it could only run by
  #     hard-coding -Manual - which printed "refusing to hand-run" above 544 successful conversions.
  # Matching both names fixes both: the queue loop's child is now recognised as the track doing its
  # job, and a real hand-run is refused whichever OCR track is live.
  # It stays deliberately COARSE - "is an OCR track alive", never "does its work overlap mine". The
  # two loops' roots are disjoint by construction, but this guard cannot prove that for an arbitrary
  # hand-run path, and refusing a disjoint hand-run (escapable with -Manual) is the cheap error.
  $loopRx = if ($Track -eq 'OCR') { '_ocr(-queue)?-loop\.ps1' } else { '_publish-loop\.ps1' }
  $worker = if ($Track -eq 'OCR') { 'ocr-subtitles.ps1' } else { '_publish.ps1 / publish-work.ps1' }

  # Classify by HOW the process was launched, not by whether the name appears in its arguments.
  # `-match '_fetch-one'` once matched the MONITOR, whose inline -Command text merely mentions the
  # script in a hint string - a check that reads a description of the thing rather than the thing.
  $live = @(
    Get-CimInstance Win32_Process -Filter "Name='pwsh.exe'" -ErrorAction SilentlyContinue |
      Where-Object { $_.CommandLine -notmatch '\s-Command\s' -and $_.CommandLine -match $loopRx }
  )
  if ($live.Count -eq 0) { return }   # no track running - a hand-run is the correct way to do this

  # Launched BY the loop? Then this is the track doing its job.
  if (@(Get-AncestorCommandLines) -match $loopRx) { return }

  $pids = ($live | ForEach-Object { $_.ProcessId }) -join ', '
  $msg = @(
    "$Track TRACK IS ALREADY RUNNING (pid $pids) - refusing to hand-run $worker."
    ""
    "The $Track track drains itself; it will pick this up on its next pass. The ONLY manual step"
    "in the pipeline is authoring a manifest and dropping it in D:\video\_queue."
    ""
    $(if ($Track -eq 'OCR') {
      "_ocr-loop.ps1 is stateless and re-derives its work list every pass, so a second worker does"
      "not share the work - it duplicates it, and both race to write the same sidecar."
    } else {
      "_publish-loop.ps1 is strictly serial by design; concurrent robocopy jobs contend on the same"
      "NAS link and nothing completes."
    })
    ""
    "If the track is genuinely wedged, diagnose it - do not run alongside it. Pass -Manual only"
    "after stopping the loop."
  ) -join "`n"

  # SAY WHAT ACTUALLY HAPPENS NEXT. `$msg` is the REFUSAL, and it must only ever be printed when
  # something is genuinely refused. Prefixing it with "OVERRIDDEN:" and returning left a warning
  # reading "refusing to hand-run ocr-subtitles.ps1" one line above the successful conversion it
  # claimed to have prevented - 544 times in _ocr-queue-loop.log before anyone read it closely
  # (2026-09-04). Nothing was corrupted, but a guard whose output contradicts the next line teaches
  # a reader to stop believing guard output, which is the whole value of having guards.
  if ($Manual) {
    Write-Warning ("$Track track is running (pid $pids) - PROCEEDING ANYWAY because -Manual was " +
      "passed. Nothing was refused: $worker runs alongside the track, so it is the caller's job to " +
      "know this work does not overlap it.")
    return
  }
  throw $msg
}
