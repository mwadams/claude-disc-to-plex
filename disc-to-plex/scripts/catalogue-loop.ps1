# CATALOGUE track: sweep any staged disc that is VERIFIED-COMPLETE and has no current catalogue.
#
# WHY THIS EXISTS. Cataloguing was a hand-driven step between fetch and dispositions, and
# hand-driving it is exactly where the 2026-08-23 drift came from: a disc was swept WHILE STILL
# COPYING, enumerated 26 titles of a 51-title disc, and every subsequent title number was wrong
# by six. The fix is not care, it is a gate: a unit is eligible ONLY once _fetch-one.ps1 has
# recorded it in _fetch-done.txt, which happens only after file count AND bytes matched the
# source. That file is the ONLY trustworthy completeness signal - timestamps are useless here
# because robocopy preserves source mtimes, so a disc copied today reads as 2017.
#
# SINGLE INSTANCE ONLY. This loop is stateless - it re-derives its work list from the filesystem
# on every pass - so a second copy does not share out the work, it DUPLICATES it: both scan the
# same tree, both pick the same first unit, and both sweep it at once. Nothing here ever exits,
# so every relaunch leaves the previous copy running - by 2026-08-21 the OCR loop had accumulated
# THIRTY-SIX live instances since 17 August, and the visible symptom was not "output is wrong"
# but "everything is slow": encodes, transcriptions and OCR all crawling against a disk being
# swept by three dozen scanners. A leak that only ever costs throughput is one nobody goes
# looking for, which is why this guard exists rather than a note telling the next person to check.
#
# CONCURRENCY. catalogue-disc.ps1 holds a per-disc mutex, so a hand-run sweep of a DIFFERENT
# disc alongside this loop stays safe and supported; a second sweep of the SAME disc makes one
# of the two refuse (exit 2), which this loop reports and simply retries. The loop processes its
# own list one unit at a time because a sweep is whisper-heavy; it adds no cross-disc lock.
#
# SCOPE. This loop reads ONLY _stage, _catalogue and _fetch-done.txt. It never touches E: - the
# whole point of gating on _fetch-done.txt is that completeness was already proven against the
# source once, so no re-scan of the slow USB spindle is ever needed.

param(
  [string]$Stage           = 'D:/video/_stage',
  [string]$Catalogue       = 'D:/video/_catalogue',
  [string]$FetchDone       = 'D:/video/_fetch-done.txt',
  [string]$CatalogueScript = 'D:/video/.claude/skills/disc-to-plex/scripts/catalogue-disc.ps1',
  [string]$FailuresFile    = 'D:/video/_catalogue-failures.json',
  [string]$MakeMkv         = 'C:/Program Files (x86)/MakeMKV/makemkvcon64.exe',
  [string]$MutexName       = 'Global\video-catalogue-loop',   # tests pass their own, so they run beside the live track
  [string]$LogDir          = 'D:/video/_logs',
  [switch]$Once            # one pass then exit - for tests; production runs without it
)

$loopMutex = New-Object System.Threading.Mutex($false, $MutexName)
$loopOwned = $false
try { $loopOwned = $loopMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $loopOwned = $true }  # holder died; the lock is ours
if (-not $loopOwned) {
  Write-Output "another _catalogue-loop.ps1 already holds the lock - exiting (this is the guard working, not an error)"
  exit 0
}

# THIS LOOP WAS INVISIBLE UNTIL 2026-09-05. It only ever wrote to stdout, and _bounce-track.ps1
# starts every track with `Start-Process pwsh -WindowStyle Hidden` and NO redirection - so a
# catalogue loop started the sanctioned way threw its entire output away and _logs/_catalogue-loop.log
# had never once existed. `_tail.ps1 catalogue` therefore answered with a list of OTHER tracks'
# stale logs, which reads exactly like a report about this one. Same lesson _fetch-loop.ps1 already
# carries: a loop that cannot be observed gets misdiagnosed, and the misdiagnosis is what leads to
# restarting or "fixing" loops that were working. Transcript, not a launcher redirect, so it holds
# however the loop is started. AFTER the mutex guard, so a losing second instance writes nothing.
$logDir = $LogDir
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
try { Start-Transcript -Path (Join-Path $logDir '_catalogue-loop.log') -Append | Out-Null } catch { }

function Say($msg) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) }

# A FAILURE RECORD THE BOARD CAN READ (2026-10-16). Until now a failed sweep was written ONLY to this
# loop's log. MakeMKV's beta key expired during a two-week pause and every staged disc then failed
# in a second with "MakeMKV enumerated no titles" - 19,000 log lines, eight discs and 122.8 GB stuck,
# the fetch held at the space floor - while the board said "clears without anyone acting" and the
# alarm said clear. So: per unit, when it first and last failed and why; cleared the moment it
# sweeps (or leaves _stage). Every write is guarded - a bookkeeping failure must never stop the track.
function Read-Failures {
  $d = $null
  # Test-Path first: a caught "file not found" still prints as a TerminatingError in the transcript.
  if (Test-Path -LiteralPath $FailuresFile) {
    try { $d = Get-Content -LiteralPath $FailuresFile -Raw -ErrorAction Stop | ConvertFrom-Json -AsHashtable } catch { }
  }
  if (-not $d) { $d = @{} }
  if (-not $d.ContainsKey('units') -or -not $d.units) { $d.units = @{} }
  if (-not $d.ContainsKey('makemkvKey') -or -not $d.makemkvKey) { $d.makemkvKey = @{ expired = $false } }
  return $d
}
function Write-Failures($d) {
  try {
    $d.updatedAt = (Get-Date).ToString('s')
    $tmp = "$FailuresFile.tmp"
    ($d | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $tmp -Encoding UTF8
    Move-Item -LiteralPath $tmp -Destination $FailuresFile -Force
  } catch { Say "  (could not write $FailuresFile : $($_.Exception.Message) - the sweep result above stands)" }
}
# THE KEY IS ASKED OF MAKEMKV ITSELF, FROM THIS PROCESS. A key entered from a Claude Desktop session is
# MSIX-sandboxed (HKCU is virtualised), so a check run from the session reports a working key while this
# track - started by the supervisor, outside the package - has none. Only this process sees what the
# line sees. --noscan: never probe the optical drive (it can hang holding it).
function Test-MakeMkvKey {
  if (-not (Test-Path -LiteralPath $MakeMkv)) { return @{ known = $false; expired = $false; message = "makemkvcon not found at $MakeMkv" } }
  $o = @(& $MakeMkv -r --noscan --cache=1 info disc:9999 2>&1 | ForEach-Object { "$_" })
  $hit = @($o | Where-Object { $_ -match '(?i)key has expired|registration key|evaluation period|too old' } | Select-Object -First 1)
  if ($hit.Count) { return @{ known = $true; expired = $true; message = (($hit[0] -split '","')[0] -replace '^MSG:[^"]*"', '') } }
  return @{ known = $true; expired = $false; message = '' }
}

Say "catalogue loop: watching $Stage (gate: $FetchDone)"

while ($true) {
  $did = $false
  # Re-read the gate file every pass - fetch completions land continuously, and a list read once
  # goes stale the moment the next copy verifies.
  $verified = @(Get-Content $FetchDone -ErrorAction SilentlyContinue |
                Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })

  # A unit that has left _stage (released) can no longer be failing here.
  $fails = Read-Failures
  $gone = @($fails.units.Keys | Where-Object { -not (Test-Path -LiteralPath (Join-Path $Stage $_)) })
  if ($gone.Count) { foreach ($g in $gone) { $fails.units.Remove($g) }; Write-Failures $fails }
  $keyCheckedThisPass = $false

  foreach ($u in @(Get-ChildItem $Stage -Directory -ErrorAction SilentlyContinue)) {
    $name = $u.Name

    # Rip folders are INTERMEDIATES, not discs - they hold MakeMKV output, and cataloguing one
    # would enumerate the rips as if they were a disc. Observed convention in _stage right now:
    # `metro-x` and `mumins1-mkv`; `-main` is the third form _stallwatch.ps1 documents.
    if ($name -match '-(x|main|mkv)$') { continue }

    # Deliberately parked (e.g. the Mumins discs, awaiting a missing disc). The reason lives in
    # the .HOLD file; _stallwatch reports these, so staying silent here is not losing anything.
    if (Test-Path -LiteralPath (Join-Path $u.FullName '.HOLD')) { continue }

    # THE GATE. Not in _fetch-done.txt = mid-copy, or copied by hand and never verified. Both
    # mean "do not enumerate": a half-copied disc enumerates happily and returns a plausible,
    # WRONG title list (the 26-of-51 incident above). Silent skip - _stallwatch already reports
    # these as "still COPYING", and repeating that every 2 minutes would drown the log.
    if ($verified -notcontains $name) { continue }

    $catPath = Join-Path $Catalogue "$name.catalogue.json"
    if (Test-Path -LiteralPath $catPath) {
      $redo = $false
      try {
        $existing = Get-Content -LiteralPath $catPath -Raw -ErrorAction Stop | ConvertFrom-Json
        # sourceVerified=false means the sweep ran mid-copy and its numbering cannot be trusted -
        # assert-accounted.ps1 refuses such a catalogue, so it MUST be redone. The field being
        # ABSENT (older catalogues, pre-stamp) is tolerated as done.
        $sv = $existing.PSObject.Properties['sourceVerified']
        if ($null -ne $sv -and $sv.Value -eq $false) {
          $redo = $true
          Say "$name - catalogue records sourceVerified=false (swept mid-copy) - re-sweeping now the copy is verified"
        }
      } catch {
        # An unreadable catalogue cannot testify to anything, so re-sweep. This is safe against a
        # concurrent writer: if another sweep of this disc is live, catalogue-disc's per-disc
        # mutex makes OUR run refuse (exit 2) and we retry next pass.
        $redo = $true
        Say "$name - catalogue json UNREADABLE ($($_.Exception.Message)) - re-sweeping"
      }
      if (-not $redo) { continue }
    }

    Say "CATALOGUE: $name"
    # Capture the child's output IN FULL before filtering (piping straight into a head-style
    # cmdlet can close the pipeline early and kill the child mid-sweep - see _ocr-loop.ps1).
    $out = & pwsh -NoProfile -File $CatalogueScript -Disc $u.FullName -OutDir $Catalogue 2>&1
    $code = $LASTEXITCODE

    # THE VERDICT IS THE ARTIFACT, NOT THE EXIT CODE ALONE. Success means the catalogue json now
    # exists, parses, and holds at least one title. A failed sweep writes nothing (catalogue-disc
    # writes the json only at the end), so a failure can never look done - it is reported loudly
    # and retried next pass. Never a success message next to an operation that can fail.
    $ok = $false
    $swept = $null
    if ($code -eq 0 -and (Test-Path -LiteralPath $catPath)) {
      try {
        $swept = Get-Content -LiteralPath $catPath -Raw -ErrorAction Stop | ConvertFrom-Json
        if ([int]$swept.titleCount -ge 1) { $ok = $true }
      } catch { }
    }
    if ($ok) {
      Say ("  swept OK - {0} title(s) -> {1}" -f $swept.titleCount, $catPath)
      # Surface the sweep's own findings without letting diagnostics crowd them out.
      @($out | Where-Object { "$_" -match 'WARNING|EXTRAS LIST|needs a disposition' }) |
        Select-Object -First 5 | ForEach-Object { Say ("    " + $_) }
      # A sweep that enumerated titles proves the key works, whatever was recorded before.
      $changed = $fails.units.ContainsKey($name) -or $fails.makemkvKey.expired
      $fails.units.Remove($name)
      if ($fails.makemkvKey.expired) { $fails.makemkvKey = @{ expired = $false; checkedAt = (Get-Date).ToString('s'); message = 'a sweep enumerated titles' } }
      if ($changed) { Write-Failures $fails }
    } elseif ($code -eq 2) {
      # catalogue-disc's own per-disc mutex refused: another sweep of this same disc is live.
      # Its artifact will appear on its own; nothing to record here.
      Say "  another sweep of '$name' already holds the per-disc lock - leaving it to finish; will re-check next pass"
    } else {
      Say ("  SWEEP FAILED for {0} (exit {1}) - NOTHING recorded as done; will retry next pass. Output tail:" -f $name, $code)
      $tail = @($out | Where-Object { "$_" -match '\S' } | ForEach-Object { "$_".Trim() })
      $tail | Select-Object -Last 4 | ForEach-Object { Say ("    " + $_) }
      # The most telling line, not the last: PowerShell's error frame ends in decoration.
      $reason = @($tail | Where-Object { $_ -match 'enumerated no titles|EXIT \d|refus|not found|error|exception' -and $_ -notmatch '^\s*(Line \||\d+ \||~|\|\s*~)' } | Select-Object -Last 1)
      $reason = if ($reason.Count) { ($reason[0] -replace '^\|\s*', '') } else { @($tail | Select-Object -Last 1) -join '' }
      $now = (Get-Date).ToString('s')
      $prev = $fails.units[$name]
      $fails.units[$name] = @{ firstFailedAt = $(if ($prev -and $prev.firstFailedAt) { "$($prev.firstFailedAt)" } else { $now })
                               lastFailedAt = $now; count = $(if ($prev -and $prev.count) { [int]$prev.count + 1 } else { 1 })
                               exit = [int]$code; reason = "$reason" }
      # "No titles" from a disc that IS staged and verified is the signature of an expired key, not
      # of the disc. Ask MakeMKV once per pass rather than once per disc.
      if (-not $keyCheckedThisPass -and ($tail -join "`n") -match 'enumerated no titles') {
        $keyCheckedThisPass = $true
        $k = Test-MakeMkvKey
        if ($k.known) {
          $since = if ($fails.makemkvKey.expired -and $fails.makemkvKey.since) { "$($fails.makemkvKey.since)" } else { $now }
          $fails.makemkvKey = @{ expired = [bool]$k.expired; checkedAt = $now; message = "$($k.message)"; since = $(if ($k.expired) { $since } else { $null }) }
          if ($k.expired) { Say "  *** MAKEMKV KEY EXPIRED ($($k.message)) - no disc can be catalogued until it is re-registered (MakeMKV: Help > Register)" }
        }
      }
      Write-Failures $fails
    }
    $did = $true
  }

  if ($Once) { break }
  if (-not $did) { Start-Sleep -Seconds 120 }
}
