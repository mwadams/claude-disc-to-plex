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
  [switch]$Once            # one pass then exit - for tests; production runs without it
)

$loopMutex = New-Object System.Threading.Mutex($false, 'Global\video-catalogue-loop')
$loopOwned = $false
try { $loopOwned = $loopMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $loopOwned = $true }  # holder died; the lock is ours
if (-not $loopOwned) {
  Write-Output "another _catalogue-loop.ps1 already holds the lock - exiting (this is the guard working, not an error)"
  exit 0
}

function Say($msg) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) }

Say "catalogue loop: watching $Stage (gate: $FetchDone)"

while ($true) {
  $did = $false
  # Re-read the gate file every pass - fetch completions land continuously, and a list read once
  # goes stale the moment the next copy verifies.
  $verified = @(Get-Content $FetchDone -ErrorAction SilentlyContinue |
                Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })

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
    } elseif ($code -eq 2) {
      # catalogue-disc's own per-disc mutex refused: another sweep of this same disc is live.
      # Its artifact will appear on its own; nothing to record here.
      Say "  another sweep of '$name' already holds the per-disc lock - leaving it to finish; will re-check next pass"
    } else {
      Say ("  SWEEP FAILED for {0} (exit {1}) - NOTHING recorded as done; will retry next pass. Output tail:" -f $name, $code)
      @($out | Where-Object { "$_" -match '\S' }) | Select-Object -Last 4 | ForEach-Object { Say ("    " + $_) }
    }
    $did = $true
  }

  if ($Once) { break }
  if (-not $did) { Start-Sleep -Seconds 120 }
}
