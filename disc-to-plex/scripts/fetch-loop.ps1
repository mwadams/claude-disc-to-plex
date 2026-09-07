# SOURCE track: keep staging discs from the current batch list, forever.
#
# WHY THIS EXISTS
# ---------------
# Every other track self-drains (two lane-runners, OCR, publish, catalogue, analyse). FETCH did
# not: `_fetch-one.ps1` takes ONE disc per run by design, so somebody had to retrigger it 175
# times. On 2026-08-23 that somebody forgot, twice announced a fetch as started that was not, and
# batch 7 made no progress for hours while the GPU sat idle behind it. A track whose only trigger
# is human memory is the track that stalls.
#
# THE LIST IS THE AUTHORITY - the highest-numbered listN.txt, re-read every pass so a drive swap
# and a new list need no edit here. `_fetch-done.txt` records only VERIFIED copies (count AND
# bytes), so "already staged?" is answered locally and never by scanning the source drive - E: is
# a slow USB spindle and this project forbids broad recursive scans of it.
#
# SPACE: stop BEFORE starting a disc, not during. A fetch that fills the volume leaves a
# half-copied disc folder that looks staged, and the catalogue step cannot tell it from a complete
# one (that exact defect produced a 26-title catalogue of a 51-title disc and a manifest pointing
# at the wrong titles). The floor is deliberately generous: encodes need working room too.

param(
  # 120, NOT 80. The floor is checked BEFORE starting a disc, and a Blu-ray disc folder is ~40 GB
  # - so an 80 GB floor permits a fetch that ends at 40 GB free. That is not enough to hold a
  # ~30 GB rip AND a ~15 GB encode of the same feature, and on 2026-08-23 it produced a genuine
  # DEADLOCK: 19 GB free, the encode preflight refusing for want of 27 GB, and no way to free
  # anything because freeing space requires publishing, which requires encoding.
  # The working set for one unit is roughly: disc 40 + rips 30 + encode 15 + headroom.
  [int]$FloorGB = 120,
  [string]$SrcRoot = 'E:\Movies'
)

# SINGLE INSTANCE. Two copies would both pick the same "next" disc and robocopy it concurrently
# into the same folder. The OCR loop's header records what unbounded relaunching cost there - by
# the time anyone looked there were thirty-six live instances, and the symptom was not "wrong"
# but "everything is slow".
# BUILD THE NAME FIRST. Inline, `New-Object System.Threading.Mutex($false, 'Global' + [char]92 +
# 'video-fetch-loop')` does NOT pass two constructor arguments: the comma binds tighter than `+`,
# so the argument list parses as an ARRAY of four elements, no constructor matches, and New-Object
# returns $null. The subsequent $mutex.WaitOne(0) then threw a non-terminating error and execution
# CARRIED ON into the loop - the guard failed OPEN, which is the one way a guard is worse than
# absent. (Observed on the very first launch, 2026-08-23.)
$mutexName = 'Global' + [char]92 + 'video-fetch-loop'
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
# FAIL CLOSED. If the mutex could not be created at all we do not know whether another copy is
# running, and "assume not" is how you end up with two robocopies writing one folder.
if ($null -eq $mutex) {
  Write-Output "could not create the single-instance mutex - refusing to run unguarded"
  exit 1
}
if (-not $mutex.WaitOne(0)) {
  Write-Output "another _fetch-loop.ps1 already holds the lock - exiting (the guard working, not an error)"
  exit 0
}

# LOG FOR YOURSELF - never depend on how you were launched.
#
# This loop was started as `pwsh -File _fetch-loop.ps1` with NO redirection, so everything it
# printed went to a console nobody was attached to. _fetch-loop.log then sat a full day stale, and
# on 2026-09-01 it was read as live: the last entries named list8a.txt, so the loop was declared
# "pointed at the wrong list" and told to the user as fact. It was doing exactly the right thing -
# idling because free space was under the floor - and the list selection below had never been
# wrong. A loop that cannot be observed gets misdiagnosed, and the misdiagnosis is what leads to
# restarting or "fixing" loops that were working.
#
# Transcript rather than a launcher redirect, so it holds however the loop is started.
$logDir = 'D:/video/_logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
try { Start-Transcript -Path (Join-Path $logDir '_fetch-loop.log') -Append | Out-Null } catch { }
Write-Output ("=== fetch loop up {0} ===" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))

while ($true) {
  $listFile = Get-ChildItem 'D:/video/list*.txt' -ErrorAction SilentlyContinue |
              Sort-Object { $m = [regex]::Match($_.BaseName, '\d+'); if ($m.Success) { [int]$m.Value } else { 0 } } |
              Select-Object -Last 1
  if (-not $listFile) { Write-Output "no listN.txt found - nothing to do"; Start-Sleep -Seconds 300; continue }

  $all  = @(Get-Content -LiteralPath $listFile.FullName |
            Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') } |
            ForEach-Object { $_.Trim() })
  $done = @(Get-Content -LiteralPath 'D:/video/_fetch-done.txt' -ErrorAction SilentlyContinue |
            Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
  # A COMPLETED UNIT IS NEVER RE-STAGED, whatever _fetch-done.txt says.
  #
  # _fetch-done.txt means "a verified copy exists locally" - a fact about STAGING. Releasing
  # staging to free space correctly removes a line from it. But for a unit whose work is already
  # published and confirmed, that reads as "needs fetching again": Back to the Future 2 was
  # re-fetched (40 GB off a USB spindle) hours after it shipped, and the rip loop then began
  # re-ripping all 19 titles of a finished film.
  $complete = @(Get-Content -LiteralPath 'D:/video/_completed.txt' -ErrorAction SilentlyContinue |
                Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') } |
                ForEach-Object { $_.Trim() })
  # A STAGED FOLDER IS NOT A STAGED DISC. This used to also skip anything merely PRESENT in
  # _stage, which meant a half-copied folder was skipped FOR EVER. On 2026-09-01 discs 4 and 5 of
  # Babylon 5 Season 4 sat at 12/24 and 13/24 files after their copies were interrupted, and the
  # loop walked past both because the directory existed - so the batch would have gone on to
  # catalogue and rip two partial discs. That is precisely the defect the header above warns
  # about ("a half-copied disc folder that looks staged"), left unguarded in the code beneath it.
  #
  # _fetch-done.txt is the ONLY record of a copy verified on count AND bytes, so it is the only
  # thing entitled to retire a disc from the list. Re-entering _fetch-one.ps1 on a partial folder
  # is safe and is the point: robocopy resumes it, and the name is appended only once it matches.
  $left = @($all | Where-Object { $done -notcontains $_ -and $complete -notcontains $_ })

  if ($left.Count -eq 0) {
    Write-Output ("[{0}] every disc in {1} is staged or fetched - idling" -f (Get-Date -Format 'HH:mm:ss'), $listFile.Name)
    Start-Sleep -Seconds 300
    continue
  }

  # The source drive may be absent between batches. That is a WAIT, not an error: say so once per
  # pass and keep looping, so a drive swap resumes the track without anyone restarting this.
  if (-not (Test-Path -LiteralPath $SrcRoot -PathType Container)) {
    Write-Output ("[{0}] source root '{1}' not present - waiting for the drive" -f (Get-Date -Format 'HH:mm:ss'), $SrcRoot)
    Start-Sleep -Seconds 180
    continue
  }

  $freeGB = [math]::Round([IO.DriveInfo]::new('D').AvailableFreeSpace / 1GB, 1)

  # RESERVE ROOM FOR A FINISHED OPTICAL RIP, OR THIS LOOP STARVES THE OPTICAL LANE FOR EVER.
  #
  # Both tracks used the same 120 GB floor but tested it differently: this loop holds when
  # `free < floor`, so it happily starts a disc at 120 GB and ends near 113; the optical handover
  # (stage-optical-archives.ps1) holds when `free - need < floor`, so for a 6.94 GB archive it
  # needs 127 GB. Our go-condition is satisfied exactly where theirs is not, so fetch wins every
  # race - not occasionally, systematically.
  #
  # 2026-09-07: DVDVolume-0e950c46 verified at 04:32 and could not be handed over. A reclaim then
  # freed 40 GB at 04:43, and this loop spent all of it on Sherlock Holmes discs 2-4 within ten
  # minutes, leaving 118.2 GB - below the optical lane's threshold again. The archive sat on C:.
  #
  # The asymmetry matters: a fetch from E: is repeatable at any time, while an optical archive is a
  # ~77-minute rip of a PHYSICAL disc sitting on a small C: volume with its own 15 GB floor. If one
  # of the two has to wait, it must be this one. So raise our floor by whatever is waiting to come
  # across, and let the optical lane through first.
  $opticalReserveGB = 0.0
  try {
    $arch = 'C:/Users/matth/Videos/DVD'
    if (Test-Path -LiteralPath $arch) {
      $stagedNames = @{}
      foreach ($ln in (Get-Content -LiteralPath 'D:/video/_optical-staged.tsv' -ErrorAction SilentlyContinue)) {
        $n = ("$ln" -split "`t")[0]; if ($n) { $stagedNames[$n.Trim()] = $true }
      }
      foreach ($d in (Get-ChildItem -LiteralPath $arch -Directory -ErrorAction SilentlyContinue)) {
        # Only COMPLETE archives count: a *.partial-* folder is a rip still running, and reserving
        # for it would hold this loop for the whole 77 minutes rather than for the handover.
        if ($d.Name -like '*.partial-*' -or $d.Name -eq '_failed') { continue }
        if ($stagedNames.ContainsKey($d.Name)) { continue }
        if (Test-Path -LiteralPath (Join-Path $d.FullName '_stage')) { continue }
        $b = (Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue |
              Measure-Object Length -Sum).Sum
        $opticalReserveGB += [double]$b / 1GB
      }
    }
  } catch { $opticalReserveGB = 0.0 }
  # Capped, so a backlog of archives can never stop fetching altogether - the reserve exists to let
  # the NEXT handover through, not to park this track behind an unbounded queue.
  if ($opticalReserveGB -gt 50) { $opticalReserveGB = 50 }
  $effectiveFloor = [math]::Round($FloorGB + $opticalReserveGB, 1)

  if ($freeGB -lt $effectiveFloor) {
    $note = if ($opticalReserveGB -gt 0) { " (floor {0} + {1:N2} GB reserved for a finished optical rip waiting to be staged)" -f $FloorGB, $opticalReserveGB } else { '' }
    Write-Output ("[{0}] {1} GB free, floor {2}{3} - holding, {4} disc(s) still to stage" -f `
                  (Get-Date -Format 'HH:mm:ss'), $freeGB, $effectiveFloor, $note, $left.Count)
    Start-Sleep -Seconds 120
    continue
  }

  $next = $left[0]
  Write-Output ("[{0}] fetching '{1}' ({2} GB free, {3} left)" -f `
                (Get-Date -Format 'HH:mm:ss'), $next, $freeGB, $left.Count)

  # IN-PROCESS, and the array built here. `pwsh -File ... -Discs @(...)` FLATTENS the array: the
  # disc name arrives split across parameters, $SrcRoot binds to a fragment, and the script throws
  # "SrcRoot is not a directory" - which is the guard _fetch-one.ps1 grew for exactly this.
  try {
    & 'D:/video/_fetch-one.ps1' -Discs @($next) -SrcRoot $SrcRoot
  } catch {
    Write-Output ("    fetch FAILED for '{0}': {1}" -f $next, $_.Exception.Message)
    Start-Sleep -Seconds 60
  }

  # Did it actually land? _fetch-one.ps1 appends to _fetch-done.txt ONLY after matching count and
  # bytes. If the name is still absent, the copy did not verify - do NOT spin on it at full speed.
  $doneNow = @(Get-Content -LiteralPath 'D:/video/_fetch-done.txt' -ErrorAction SilentlyContinue |
               Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
  if ($doneNow -notcontains $next) {
    Write-Output ("    '{0}' did not verify - backing off 60s before the next attempt" -f $next)
    Start-Sleep -Seconds 60
  }
}
