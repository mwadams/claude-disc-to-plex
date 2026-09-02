# Keep N encode lanes busy from a QUEUE of manifests, without a human noticing a lane went idle.
#
# WHY THIS EXISTS. Two GPU lanes were repeatedly left idle across a long batch. A monitor that
# reports "LANE FREE" is necessary but not sufficient: something still has to decide what goes in
# next, and that decision kept losing to whatever identification work was in front of it. The
# result was an expensive GPU sitting idle while its operator read title cards.
#
# The queue inverts that. Manifests are dropped in a folder; this drains them, oldest first, and
# always keeps $Lanes running. Identification work then happens WHILE the GPU is busy, which is
# the whole point of having separate tracks.
#
#   pwsh -File lane-runner.ps1                     # drain D:\video\_queue with 2 lanes
#   pwsh -File lane-runner.ps1 -Lanes 1            # e.g. while something else needs the GPU
#
# Drop a manifest in with any name ending .json. Done manifests move to _queue\done, failures to
# _queue\failed, so the queue folder itself is always "what is left".

param(
  [string]$Queue   = 'D:\video\_queue',
  [string]$LogRoot = 'D:\video\_logs',
  [int]$Lanes      = 2,
  [int]$PollSec    = 20,
  # Escape hatch for a manifest that genuinely cannot go through _gate-queue.ps1. It exists so the
  # ungated check below is a GUARD and not a wall, but reaching for it should be rare and should be
  # explained: every use so far would have been better served by fixing the gate.
  [switch]$AllowUngated,
  # How many times a manifest may be seen with its audio evidence still unwritten before it is
  # failed rather than deferred. Generous on purpose: _analyse-loop.ps1 transcribes each DVD title
  # in turn and a four-episode disc can take the better part of an hour, during which the manifest
  # is legitimately not ready. Each deferral also sleeps 60 s, so this is roughly an hour's grace.
  [int]$MaxDefer = 60
)

# SINGLE INSTANCE, AND VISIBLE TO _loops.ps1.
#
# This was the only track without a mutex, so it was the only track whose ABSENCE was invisible:
# _loops.ps1 reported all seven loops healthy while the encode track was not running at all, twice
# in one day. The queue happened to be empty both times, so nothing stalled - but a manifest
# dropped in would simply have sat there, which is the exact failure the queue exists to prevent.
#
# One instance manages $Lanes lanes (see the header), so a second instance is not "more capacity",
# it is two runners racing to claim the same manifest.
#
# 'Global' + [char]92 + name. Do NOT write it as one literal with a backslash escape and do NOT
# build it inside a New-Object argument list - a comma inside a concatenation makes the arguments
# parse as one ARRAY and New-Object returns $null, which fails OPEN.
$mutexName = 'Global' + [char]92 + 'video-encode-lanes'
$laneMutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $laneMutex.WaitOne(0)) {
  Write-Host 'encode lane-runner already running - exiting'
  exit 0
}

$transcode = 'D:\video\.claude\skills\disc-to-plex\scripts\transcode.ps1'
foreach ($d in @($Queue, (Join-Path $Queue 'running'), (Join-Path $Queue 'done'), (Join-Path $Queue 'failed'), $LogRoot)) {
  New-Item -ItemType Directory -Force $d | Out-Null
}

# A lane is busy if an ffmpeg is reading from _stage. Counting ffmpeg alone is wrong on a shared
# machine - other agents run ffmpeg against the NAS and must not be mistaken for an encode lane.
function Busy-Lanes {
  @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '_stage' }).Count
}

Write-Output "lane-runner: draining $Queue with $Lanes lane(s)"
$idle = 0
# How many times each manifest has been put back for want of audio evidence. In memory only, and
# deliberately so: a restart SHOULD forgive past deferrals, because the usual reason a manifest was
# waiting is that the analyse track had not caught up, and that is not a fault to carry forward.
$deferrals = @{}
# Names deferred during the current sweep of the queue, so the picker above can step past them
# instead of re-selecting the same blocked manifest for ever. Reset whenever the sweep exhausts.
$deferredThisSweep = New-Object System.Collections.Generic.HashSet[string]
while ($true) {
  $busy = Busy-Lanes
  # A DEFERRED MANIFEST MUST NOT BLOCK THE ONES BEHIND IT.
  #
  # The deferral added below returns an evidence-less manifest to the queue and sleeps. With a
  # plain "oldest first" pick that re-selects the SAME file every pass, so one manifest waiting on
  # _analyse-loop.ps1 stops the whole queue - head-of-line blocking. Observed 2026-09-01: seven
  # manifests queued, b5-s4d4 waiting on evidence, and b5-s4d6 / b5-s5d1 / b5-s5d2 / b5-s5d3 all
  # had COMPLETE evidence and sat idle behind it while no ffmpeg ran at all.
  #
  # So skip anything already deferred in this sweep and take the next candidate. When every queued
  # manifest has been deferred there is genuinely nothing to do, so clear the set and fall through
  # to the normal idle sleep - which also stops the skip list growing without bound.
  $queued = @(Get-ChildItem -LiteralPath $Queue -File -Filter '*.json' -ErrorAction SilentlyContinue |
              Sort-Object CreationTime)
  $next = $queued | Where-Object { -not $deferredThisSweep.Contains($_.Name) } | Select-Object -First 1
  if (-not $next -and $queued.Count -gt 0) {
    $deferredThisSweep.Clear()      # everything is waiting on evidence; start the sweep again
  }

  if ($next) {
    $log = Join-Path $LogRoot ([IO.Path]::GetFileNameWithoutExtension($next.Name))
    New-Item -ItemType Directory -Force $log | Out-Null

    # Claim the manifest FIRST by moving it out of the queue, so a second runner instance cannot
    # pick up the same one. The queue folder is then always "what is left".
    #
    # It is claimed into `running\`, NOT `done\`. Claiming straight into `done` made an IN-PROGRESS
    # manifest indistinguishable from a finished one: a run 20 items into 23 showed its manifest in
    # `done` with three outputs absent, which reads exactly like three items that failed silently -
    # and "MANIFEST DONE with failed items" is a real failure mode this pipeline has. Checking the
    # lane log was the only way to tell the two apart. Now the folder name states which it is.
    $claim = Join-Path $Queue "running\$($next.Name)"
    try { Move-Item -LiteralPath $next.FullName -Destination $claim -Force }
    catch { Start-Sleep -Seconds 2; continue }        # another instance claimed it first

    # DID THIS MANIFEST COME THROUGH THE GATE?
    #
    # `_gate-queue.ps1` is the only sanctioned route into the queue, and WORKING-AGREEMENT.md has
    # said so since 2026-08-23 in bold - "USE THIS instead of copying manifests into _queue". It was
    # then bypassed for the whole of that day, and three more times on 2026-09-01. Prose does not
    # enforce itself.
    #
    # What the bypass costs: the gate is where the edition-layout check runs (a fault there needs a
    # re-encode AND a NAS deletion only the user can do), and where "is the source actually complete"
    # is answered. A manifest dropped straight in skips both, and the failure is silent because a
    # half-copied disc encodes perfectly - it just encodes the wrong, shorter thing.
    #
    # Matched on CONTENT, not name: the ledger records a SHA256, so a manifest edited after gating
    # reads as ungated. That is right - the thing that was checked is not the thing about to run.
    if (-not $AllowUngated) {
      $ledgerPath = Join-Path $Queue '.gated.jsonl'
      $claimHash = (Get-FileHash -LiteralPath $claim -Algorithm SHA256).Hash
      $gated = $false
      foreach ($line in @(Get-Content -LiteralPath $ledgerPath -ErrorAction SilentlyContinue)) {
        if (-not "$line".Trim()) { continue }
        try { $e = "$line" | ConvertFrom-Json } catch { continue }
        if ($e.name -eq $next.Name -and $e.sha256 -eq $claimHash) { $gated = $true; break }
      }
      if (-not $gated) {
        Write-Output "    REFUSED: $($next.Name) is not in the gate ledger - it was written straight into _queue."
        Write-Output '    Queue it with: pwsh -File D:/video/_gate-queue.ps1 -Disc <disc name> -Manifest <path>'
        Write-Output '    (or re-run this lane with -AllowUngated if the gate genuinely cannot apply)'
        Move-Item -LiteralPath $claim -Destination (Join-Path $Queue ('failed' + [IO.Path]::DirectorySeparatorChar + $next.Name)) -Force
        $idle = 0
        continue
      }
    }

    # AUDIO CLAIMS MUST BE EVIDENCED BEFORE THE GPU IS COMMITTED.
    #
    # A manifest asserting audioTracks / commentary / audioDescription asserts facts about what is
    # on each stream. Those assertions were being made from expectation and corrected afterwards:
    # Thunderball's 'second commentary' was an ITALIAN DUB tagged eng, and its 'second mix' was a
    # LOSSY DTS CORE. Both were structurally perfect and would have shipped. analyze-tracks.py
    # measures each stream and writes <src>.tracks.json; this refuses when the two disagree.
    # -NoProfile: the profile Import-Clixml's Terminal-Icons theme files on every pwsh start, and
    # concurrent starts catch half-written files ("'Element' is an invalid XmlNodeType"). The gate
    # script has no profile dependence (checked 2026-09-02).
    $audit = & pwsh -NoProfile -File 'D:\video\.claude\skills\disc-to-plex\scripts\assert-tracks-analysed.ps1' -Manifest $claim 2>&1
    # ANY non-zero exit blocks, not just the documented refusal code 2. An exception inside
    # the gate exits 1, and treating that as 'fine' means a crashing guard silently approves
    # everything - which is exactly how the dot-source failure let publishes through earlier.
    # EXIT 4 IS "NOT YET", AND MUST NOT BE TREATED AS A REFUSAL.
    #
    # A DVD TV manifest is authored as soon as its dispositions settle, but its per-title audio
    # evidence is written afterwards by _analyse-loop.ps1's dvdvideo pass, minutes per title. So
    # the manifest ALWAYS arrives first, and while every non-zero exit meant "failed", every such
    # manifest took a guaranteed trip through _queue\failed needing a human to put it back -
    # Babylon 5 Season 4 Disk 5 on 2026-09-01, rejected while the analyse loop was mid-way through
    # the very title it was waiting for. Nothing was wrong with it.
    #
    # So: 4 = evidence absent, nothing contradicted -> put it back and let the analyse track catch
    # up. 2 (or any other non-zero, including a CRASHING guard, which exits 1) still fails closed.
    # The deferral is BOUNDED - a disc whose evidence never appears must not circle for ever, so
    # after $MaxDefer sightings it goes to failed with the reason intact.
    if ($LASTEXITCODE -eq 4) {
      $seen = 1 + [int]($deferrals[$next.Name])
      $deferrals[$next.Name] = $seen
      if ($seen -ge $MaxDefer) {
        $audit | ForEach-Object { "    $_" }
        Write-Output "    evidence still absent after $seen sighting(s) - moving to failed"
        Move-Item -LiteralPath $claim -Destination (Join-Path $Queue ('failed' + [IO.Path]::DirectorySeparatorChar + $next.Name)) -Force
      } else {
        Write-Output "    evidence not written yet (sighting $seen of $MaxDefer) - returning it to the queue"
        Move-Item -LiteralPath $claim -Destination (Join-Path $Queue $next.Name) -Force
        # Mark it for THIS sweep only, so the picker moves to the next manifest instead of
        # re-selecting this one. No sleep here: another manifest may be ready to encode right now,
        # and the sweep-exhausted path below is what provides the wait.
        [void]$deferredThisSweep.Add($next.Name)
      }
      $idle = 0
      continue
    }
    if ($LASTEXITCODE -ne 0) {
      $audit | ForEach-Object { "    $_" }
      Write-Output '    REFUSED before encoding - moving to failed'
      Move-Item -LiteralPath $claim -Destination (Join-Path $Queue ('failed' + [IO.Path]::DirectorySeparatorChar + $next.Name)) -Force
      $idle = 0
      continue
    }
    $audit | Select-String 'audio evidence OK|nothing to verify' | ForEach-Object { "    $_" }

    Write-Output "lane: running $($next.Name)"
    # RUN IT SYNCHRONOUSLY. An earlier version launched detached via Start-Process and the launch
    # silently did nothing - the manifest left the queue, no ffmpeg appeared, and the only symptom
    # was an idle GPU that looked like an empty queue. Running in-process means the exit code and
    # all output are right here, and "this instance is busy" is simply "this instance is blocked".
    # Concurrency comes from starting N instances of this script, not from N detached children.
    # WARNING is in this list because it was NOT, and that is how a Japanese subtitle track reached
    # the NAS labelled English: transcode.ps1 announced the fallback on a WARNING line, this filter
    # dropped it, and no log a human reads ever mentioned it. A filter that hides warnings turns a
    # noisy failure into a silent one.
    & pwsh -NoProfile -File $transcode -Manifest $claim -LogDir $log 2>&1 |
      Select-String 'OK |FAILED|ABORT|REFUS|WARNING|MANIFEST DONE|AUDIO REVIEW' | ForEach-Object { "    $_" }
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
      Write-Output "    lane exit $LASTEXITCODE - moving to failed"
      Move-Item -LiteralPath $claim -Destination (Join-Path $Queue "failed\$($next.Name)") -Force
    }
    else {
      # Only NOW is it done. `running\` empty + `done\` populated is the truthful resting state.
      Move-Item -LiteralPath $claim -Destination (Join-Path $Queue "done\$($next.Name)") -Force
    }
    $idle = 0
    continue
  }

  if (-not $next -and $busy -eq 0) {
    $idle++
    if ($idle -eq 1) { Write-Output 'queue empty and lanes idle - waiting for work' }
  }
  Start-Sleep -Seconds $PollSec
}
