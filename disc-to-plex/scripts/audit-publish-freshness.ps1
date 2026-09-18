# Has anything been sitting ENCODED BUT UNPUBLISHED for too long?
#
# WHY THIS EXISTS
# ---------------
# On 2026-09-01 the user asked "so it has been a couple of hours since anything published." They
# were right, and nothing had noticed. Manifests were gating, encodes were completing, all nine
# loops held their mutexes, `_stallwatch.ps1` said "nothing waiting on the operator" - and the far
# end of the chain had shipped nothing since 19:30. Every signal being watched was upstream of the
# only outcome that matters, which is a file arriving on the NAS.
#
# The cause that time was benign and will RECUR: publishing is ALL-OR-NOTHING PER WORK, because
# `_publish.ps1` refuses a work while any of its local files still lacks an OCR sidecar. DVD sources
# carry bitmap subtitles, so every episode needs OCR first. While a disc encodes four episodes back
# to back, each new .mkv resets the "all ready" condition and the work never sits still long enough
# to publish. Not a stall - a starvation, invisible unless you go and look at Plex.
#
# WHAT IT MEASURES, and why not "time since last publish": a publish timestamp says nothing about
# whether there was anything TO publish. This asks the useful question instead - is there a finished
# local file with no counterpart on the NAS, and how long has it been waiting? A quiet pipeline with
# nothing to ship is healthy; one file waiting an hour is not.
#
# ...WITH ONE CORRECTION, 2026-09-18: a file the publish gate is DELIBERATELY holding answers that
# question yes while waiting perfectly correctly. publish-work.ps1 now records what it holds and
# why in _publish-holds/<work>.json, and this reads it - see -HoldsDir below and Get-PlanHold. The
# rule that came out of it: run the clock on the file that is BLOCKING, never on the finished ones
# queued behind it.
#
#   pwsh -File audit-publish-freshness.ps1 [-MaxWaitMin 45] [-Quiet]
#   pwsh -File audit-publish-freshness.ps1 -SelfTest        # the suppression rule, case by case
# exit 0 = nothing overdue, 2 = something has waited too long
param(
  [string]$VideoRoot  = 'D:/video',
  [string]$NasRoot    = '\\NASTEAMV\Multimedia',
  [int]$MaxWaitMin    = 45,
  # A file written in the last few minutes may still be growing under ffmpeg. Ignore those: a
  # half-written encode is not an unpublished one, and flagging it would train the reader to
  # ignore this check - the failure every monitor here has already had once.
  [int]$SettleMin     = 6,
  # A HOLD IS NOT A STALL. publish-work.ps1's plan gate holds a season whose declared outputs are
  # still encoding, which is correct and can last days on a dozen-disc show - but every file it
  # holds looks exactly like an overdue one from here, and past $MaxWaitMin this reported PUBLISH
  # STALLED at an operator with nothing to do about it (Friends (1994), 2026-09-18: Seasons 00, 06
  # and 07 held while their discs ripped). The gate now writes _publish-holds/<work>.json saying
  # what it is holding and WHY, so this can tell "still coming" from "stuck".
  #
  # SUPPRESSION IS NARROW and fails towards reporting: only a FRESH record, only files inside a
  # held folder, and only when every outstanding item there is 'not encoded' with its manifest
  # still queued or running. A failed manifest, an 'awaiting OCR' item, or a record older than
  # $HoldFreshMin (the loop is not re-evaluating - it may be dead) all still count as waiting.
  [string]$HoldsDir   = '',
  [int]$HoldFreshMin  = 30,
  [switch]$SelfTest,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
$now = Get-Date
$waiting = @()

# Get-BitmapSubsVerdict lives here: it is THE one place the pipeline's subtitle-state distinctions
# are made, and publish consults it - so this report must consult the same thing rather than
# re-deriving a weaker answer from the container.
. "$PSScriptRoot/lib-subtitles.ps1"

# Needed to ask a file whether it actually carries a bitmap subtitle stream - see the note where
# $why is worked out. Fail closed: without ffprobe we cannot measure, so say so rather than guess.
$toolPaths = Join-Path $VideoRoot '.transcode-tools/tool-paths.json'
$ffprobe = $null
if (Test-Path -LiteralPath $toolPaths) {
  try {
    $ffprobe = Join-Path (Split-Path ((Get-Content -LiteralPath $toolPaths -Raw | ConvertFrom-Json).ffmpeg)) 'ffprobe.exe'
    if (-not (Test-Path -LiteralPath $ffprobe)) { $ffprobe = $null }
  } catch { $ffprobe = $null }
}
if (-not $ffprobe -and -not $Quiet) {
  Write-Output 'WARNING: ffprobe not found - cannot tell a missing sidecar from a file that needs none.'
}

# ---- the plan gate's own hold records (see $HoldsDir above) ---------------------------------------
if (-not $HoldsDir) { $HoldsDir = Join-Path $VideoRoot '_publish-holds' }
$holds = @{}
if (Test-Path -LiteralPath $HoldsDir -PathType Container) {
  foreach ($h in Get-ChildItem -LiteralPath $HoldsDir -Filter *.json -File -EA SilentlyContinue) {
    try { $rec = Get-Content -LiteralPath $h.FullName -Raw | ConvertFrom-Json } catch { continue }
    if (-not "$($rec.work)") { continue }
    $holds["$($rec.work)"] = $rec
  }
}
function Get-PlanHold {
  <# What the plan gate says about the folder this file sits in. Returns $null when no fresh record
     covers it - including an unreadable or stale one, because a monitor that cannot measure must
     report, not reassure. Otherwise: .Reason always describes the hold (so the report stops saying
     "waiting on the publish loop" about a file the loop is deliberately holding), and .Suppress
     says whether this wait should drive the stall clock.

     RUN THE CLOCK ON THE BLOCKING FILE, NOT ITS SIBLINGS. Twelve finished Season 06 episodes were
     each "53 minutes overdue" while the only thing anyone could act on was ONE sibling waiting for
     an OCR sidecar. Their wait measures nothing: they are correct to wait, and they will all land
     the moment that one clears. So:
       - 'not encoded' with its manifest queued or running: no clock at all. An encode legitimately
         takes hours and the encode lane has its own watchdog; counting it here just reports the
         same backlog twice in the wrong lane.
       - 'awaiting OCR': CLOCKED, on that item's own age. Fresh means OCR simply has not reached it
         yet, which clears in minutes. Past the cap it is the Star Trek case this monitor was built
         for - a work sat sixteen hours behind one failed OCR gate - and it must alarm, naming the
         file that is actually stuck.
       - anything else (a failed manifest, an undeclared output): never suppressed. #>
  param([Parameter(Mandatory)][string]$RelPath,
        [Parameter(Mandatory)][AllowNull()][hashtable]$Holds,
        [Parameter(Mandatory)][datetime]$Now,
        [int]$FreshMin = 30,
        [int]$BlockedCapMin = 45,
        # Seam for the self-test: how old the item's own file is, in minutes. Real runs stat it.
        [scriptblock]$AgeOf = $null,
        # Seam for the self-test: has this item's OCR sidecar arrived since the record was written?
        [scriptblock]$SidecarExists = $null,
        [string]$NasRoot = '')
  $parts = @($RelPath -split '[\\/]')
  if ($parts.Count -lt 2) { return $null }
  $work = $parts[0]
  $dir  = $(if ($parts.Count -ge 3) { $parts[1] } else { '' })
  if (-not $Holds -or -not $Holds.ContainsKey($work)) { return $null }
  $rec = $Holds[$work]
  if (-not $rec.held) { return $null }
  # CONVERTFROM-JSON ALREADY PARSED THIS, AND STRINGIFYING IT AGAIN BREAKS IT. PowerShell 7 turns
  # an ISO-8601 JSON value into a real [datetime]; "$($rec.when)" then renders it in the current
  # culture as `09/18/2026 08:28:14`, and [datetime]::TryParse under en-GB reads 18 as a MONTH and
  # returns false. Every hold looked stale, nothing was ever suppressed, and the only visible
  # symptom was the audit quietly continuing to report files the gate was holding - measured
  # 2026-09-18, 23 minutes after the record was written. Take the object when it IS one, and parse
  # with the INVARIANT culture otherwise, never the ambient one.
  $when = [datetime]::MinValue
  if ($rec.when -is [datetime]) { $when = [datetime]$rec.when }
  elseif (-not [datetime]::TryParse("$($rec.when)", [System.Globalization.CultureInfo]::InvariantCulture,
                                    [System.Globalization.DateTimeStyles]::None, [ref]$when)) { return $null }
  if (($Now - $when).TotalMinutes -gt $FreshMin) { return $null }   # the gate has not run lately
  $scopeIsWork = ("$($rec.scope)" -eq 'work')
  if (-not $scopeIsWork -and @($rec.heldDirs) -notcontains $dir) { return $null }
  $items = @(@($rec.items) | Where-Object { $scopeIsWork -or "$($_.dir)" -eq $dir })
  if (-not $items.Count) { return $null }
  if (-not $AgeOf) {
    $AgeOf = {
      param($item)
      $p = Join-Path (Join-Path "$($rec.workRoot)" "$($item.dir)") "$($item.leaf)"
      if (-not (Test-Path -LiteralPath $p)) { return [double]::PositiveInfinity }   # cannot measure -> do not suppress
      ($Now - (Get-Item -LiteralPath $p).LastWriteTime).TotalMinutes
    }
  }
  # A RECORD IS A SNAPSHOT, AND OCR IS EXACTLY THE THING THAT MOVES UNDER IT. The gate writes what
  # it saw on its last pass; a sidecar that lands one minute later leaves the record saying "awaiting
  # OCR" for a file that is ready. 2026-09-18 13:47: all five OCR items in Friends' record had their
  # .eng.srt already on disk, one written 14 minutes earlier, and this reported the work as STUCK on
  # a file whose OCR had SUCCEEDED ("310 cues, 1% junk -> sidecar"). Clocking the mkv's age asks how
  # old the FILE is; the question is whether the sidecar is THERE. Ask the disk, not the record.
  if (-not $SidecarExists) {
    $SidecarExists = {
      param($item)
      $local = Join-Path (Join-Path "$($rec.workRoot)" "$($item.dir)") "$($item.leaf)"
      $srt = [IO.Path]::ChangeExtension($local, $null) + 'eng.srt'
      if (Test-Path -LiteralPath $srt) { return $true }
      # Reclaimed locally but published: the sidecar is small and ships first, so look there too.
      if ($NasRoot -and "$($rec.workRoot)" -match '(?i)\\(Television Shows|Movies)\\') {
        $rel = "$($rec.workRoot)".Substring("$($rec.workRoot)".IndexOf($Matches[1]))
        $nasSrt = [IO.Path]::ChangeExtension((Join-Path (Join-Path $NasRoot $rel) (Join-Path "$($item.dir)" "$($item.leaf)")), $null) + 'eng.srt'
        if (Test-Path -LiteralPath $nasSrt) { return $true }
      }
      return $false
    }
  }
  $encoding = @($items | Where-Object { "$($_.reason)" -eq 'not encoded' -and @('queued', 'running') -contains "$($_.manifestState)" })
  $ocrAll   = @($items | Where-Object { "$($_.reason)" -eq 'awaiting OCR' })
  $ocr      = @($ocrAll | Where-Object { -not (& $SidecarExists $_) })   # still owed; the rest have landed
  $resolved = $ocrAll.Count - $ocr.Count
  $other    = @($items | Where-Object { $encoding -notcontains $_ -and $ocrAll -notcontains $_ })
  $blocked  = @()
  foreach ($o in $ocr) { if ((& $AgeOf $o) -gt $BlockedCapMin) { $blocked += $o } }
  $where   = $(if ($scopeIsWork) { 'this work' } else { "'$dir'" })
  $suppress = (-not $other.Count) -and (-not $blocked.Count)
  $parts2 = @()
  if ($encoding.Count) { $parts2 += ("{0} still encoding" -f $encoding.Count) }
  if ($ocr.Count)      { $parts2 += ("{0} awaiting OCR" -f $ocr.Count) }
  if ($resolved -gt 0) { $parts2 += ("{0} whose sidecar has since landed - the gate has not re-run yet" -f $resolved) }
  if ($other.Count)    { $parts2 += ("{0} with no live manifest - a manifest needs correcting" -f $other.Count) }
  $reason = ("HELD by the plan gate - {0} is incomplete: {1}." -f $where, ($parts2 -join ', '))
  if ($blocked.Count) {
    $reason += (" STUCK: {0} has been awaiting an OCR sidecar for over {1} min - that one file is holding the rest." -f $blocked[0].leaf, $BlockedCapMin)
  } elseif ($suppress) {
    $reason += ' Not a stall; it ships when the folder is complete.'
  }
  [pscustomobject]@{ Suppress = $suppress; Reason = $reason }
}

if ($SelfTest) {
  # THE SUPPRESSION RULE IS THE RISKY PART OF THIS SCRIPT: every case it gets wrong silences a
  # monitor. So each way it may NOT suppress is asserted here, not just the happy path.
  $fail = 0
  function T($n, $c) { if ($c) { "  ok   $n" } else { $script:fail++; "  FAIL $n" } }
  $now = [datetime]'2026-09-18T09:00:00'
  $mk = {
    param($items, $when = '2026-09-18T08:55:00', $held = $true, $scope = 'season', $dirs = @('Season 06'))
    @{ 'Friends (1994)' = [pscustomobject]@{ work = 'Friends (1994)'; when = $when; held = $held; scope = $scope
                                             heldDirs = $dirs; items = $items } }
  }
  $inFlight = @([pscustomobject]@{ dir = 'Season 06'; leaf = 'a.mkv'; reason = 'not encoded'; manifest = 'm.json'; manifestState = 'running' },
                [pscustomobject]@{ dir = 'Season 06'; leaf = 'b.mkv'; reason = 'not encoded'; manifest = 'n.json'; manifestState = 'queued' })
  $rel = 'Friends (1994)\Season 06\Friends (1994) - S06E12.mkv'
  # The age seam: every item is $ageMin minutes old. Only 'awaiting OCR' items are clocked.
  $young = { param($i) 5 }
  $old   = { param($i) 400 }
  $noSidecar = { param($i) $false }   # nothing has landed
  $hasSidecar = { param($i) $true }   # the sidecar arrived after the record was written
  $H = { param($holds, $age = $young, $sc = $noSidecar) Get-PlanHold -RelPath $rel -Holds $holds -Now $now -BlockedCapMin 45 -AgeOf $age -SidecarExists $sc }
  T 'held season, all in flight -> suppressed' ((& $H (& $mk $inFlight)).Suppress)
  T 'the reason names the hold, not the loop'  ((& $H (& $mk $inFlight)).Reason -match '^HELD by the plan gate')
  $withFailed = @($inFlight + [pscustomobject]@{ dir = 'Season 06'; leaf = 'c.mkv'; reason = 'not encoded'; manifest = 'x.json'; manifestState = 'failed' })
  T 'a FAILED manifest is never suppressed'    (-not (& $H (& $mk $withFailed)).Suppress)
  T 'and the reason says a manifest needs correcting' ((& $H (& $mk $withFailed)).Reason -match 'no live manifest')
  $withOcr = @($inFlight + [pscustomobject]@{ dir = 'Season 06'; leaf = 'd.mkv'; reason = 'awaiting OCR'; manifest = ''; manifestState = '' })
  T 'awaiting OCR, still fresh -> suppressed'  ((& $H (& $mk $withOcr) $young).Suppress)
  T 'awaiting OCR past the cap -> NOT suppressed' (-not (& $H (& $mk $withOcr) $old).Suppress)
  T 'and the stuck file is named'              ((& $H (& $mk $withOcr) $old).Reason -match 'STUCK: d\.mkv')
  T 'an unmeasurable OCR item is not suppressed' (-not (& $H (& $mk $withOcr) { param($i) [double]::PositiveInfinity }).Suppress)
  # THE REGRESSION OF 13:47: every OCR item's sidecar had landed, and an old mkv read as STUCK.
  T 'an OCR item whose sidecar landed is suppressed' ((& $H (& $mk $withOcr) $old $hasSidecar).Suppress)
  T 'and the reason says the gate has not re-run' ((& $H (& $mk $withOcr) $old $hasSidecar).Reason -match 'sidecar has since landed')
  T 'a sidecar that has NOT landed still blocks'  (-not (& $H (& $mk $withOcr) $old $noSidecar).Suppress)
  $undeclared = @([pscustomobject]@{ dir = 'Season 06'; leaf = 'e.mkv'; reason = 'not encoded'; manifest = ''; manifestState = 'undeclared' })
  T 'an undeclared output is never suppressed' (-not (& $H (& $mk $undeclared)).Suppress)
  T 'a stale record gives no hold at all'      ($null -eq (& $H (& $mk $inFlight '2026-09-18T07:00:00')))
  T 'an unparseable timestamp gives no hold'   ($null -eq (& $H (& $mk $inFlight 'not-a-date')))
  # THE REGRESSION THAT MATTERED: ConvertFrom-Json hands back a [datetime], not a string, and the
  # first version stringified it into an en-GB-unparseable US date - so every hold read as stale.
  T 'a real [datetime] (what ConvertFrom-Json yields) is honoured' ((& $H (& $mk $inFlight ([datetime]'2026-09-18T08:55:00'))).Suppress)
  T 'a US-format string is read with the invariant culture, not en-GB' ((& $H (& $mk $inFlight '09/18/2026 08:55:00')).Suppress)
  T 'held=false gives no hold'                 ($null -eq (& $H (& $mk $inFlight '2026-09-18T08:55:00' $false)))
  T 'a season that is NOT held gives no hold'  ($null -eq (Get-PlanHold -RelPath 'Friends (1994)\Season 05\x.mkv' -Holds (& $mk $inFlight) -Now $now -AgeOf $young))
  T 'no record for the work -> no hold'        ($null -eq (Get-PlanHold -RelPath 'Spaced\Season 01\x.mkv' -Holds (& $mk $inFlight) -Now $now -AgeOf $young))
  T 'no records at all -> no hold'             ($null -eq (& $H @{}))
  $workScope = & $mk @([pscustomobject]@{ dir = ''; leaf = 'f.mkv'; reason = 'not encoded'; manifest = 'm.json'; manifestState = 'queued' }) '2026-09-18T08:55:00' $true 'work' @('')
  $wsHold = Get-PlanHold -RelPath 'Moulin Rouge\Moulin Rouge.mkv' -Holds @{ 'Moulin Rouge' = $workScope['Friends (1994)'] } -Now $now -AgeOf $young
  T 'a WORK-scope hold covers a file at the root' ($wsHold.Suppress -and $wsHold.Reason -match 'this work')
  T 'a held record with NO items gives no hold' ($null -eq (& $H (& $mk @())))
  T 'the freshness window is honoured at the boundary' ((& $H (& $mk $inFlight '2026-09-18T08:31:00')).Suppress)
  if ($fail) { "SELFTEST FAILED - $fail case(s)"; exit 1 }
  'SELFTEST OK'; exit 0
}

foreach ($area in 'Television Shows', 'Movies') {
  $local = Join-Path $VideoRoot $area
  if (-not (Test-Path -LiteralPath $local)) { continue }
  $base = (Resolve-Path -LiteralPath $local).Path
  foreach ($f in Get-ChildItem -LiteralPath $local -Recurse -File -Filter *.mkv -EA SilentlyContinue) {
    $ageMin = ($now - $f.LastWriteTime).TotalMinutes
    if ($ageMin -lt $SettleMin) { continue }                    # still being written
    $rel = $f.FullName.Substring($base.Length).TrimStart('\', '/')
    $nas = Join-Path (Join-Path $NasRoot $area) $rel
    # SUBTITLES-ONLY WORK: the .mkv is never published - the SIDECAR is the deliverable, and the
    # local mkv is deliberately a different encode from the NAS file of the same name (same root
    # cause as the publish-loop churn fixed 2026-09-02). Measure the sidecar, or this monitor
    # flags the work as overdue forever and teaches the reader to ignore it.
    if (Test-Path -LiteralPath (Join-Path (Join-Path $base (($rel -split '[\\/]')[0])) '.subtitles-only')) {
      $srtLocal = [IO.Path]::ChangeExtension($f.FullName, $null) + 'eng.srt'
      if (Test-Path -LiteralPath $srtLocal) {
        $srtItem = Get-Item -LiteralPath $srtLocal
        $srtNas  = [IO.Path]::ChangeExtension($nas, $null) + 'eng.srt'
        if ((Test-Path -LiteralPath $srtNas) -and (Get-Item -LiteralPath $srtNas).Length -eq $srtItem.Length) { continue }
        $srtAge = ($now - $srtItem.LastWriteTime).TotalMinutes
        if ($srtAge -ge $SettleMin) {
          $waiting += [pscustomobject]@{ File = $rel; WaitedMin = [int]$srtAge
                                         Why = 'subtitles-only: sidecar made but not on the NAS yet - waiting on the publish loop' }
        }
      } else {
        $waiting += [pscustomobject]@{ File = $rel; WaitedMin = [int]$ageMin
                                       Why = 'subtitles-only: NO OCR SIDECAR yet - the mkv exists solely to produce one' }
      }
      continue
    }
    if ((Test-Path -LiteralPath $nas) -and (Get-Item -LiteralPath $nas).Length -eq $f.Length) { continue }

    # WHY is it waiting? MEASURE IT - do not infer it from the absence of a sidecar.
    #
    # The first version said "NO OCR SIDECAR yet" for every unpublished file without an .eng.srt,
    # and was wrong on the first one it met: `S00E33 - Season 4 Episode Previews` is a concat of
    # four preview clips whose declared subtitle streams were empty, so it was manifested
    # `subTrack: "none"` and HAS NO SUBTITLE STREAM AT ALL. It needs no sidecar and was never
    # blocked - the check invented a cause and stated it as fact, which is the exact fault this
    # pipeline keeps having to catch elsewhere.
    #
    # `_publish.ps1` refuses on a BITMAP subtitle stream with no sidecar beside it. So ask the file.
    # ...AND THE SAME FAULT WAS STILL HERE, ONE LAYER UP. Asking ffprobe "does a bitmap stream
    # exist" is not the same question as "is this file waiting on OCR", because a stream that OCR
    # HAS ALREADY READ AND FOUND EMPTY is settled: Set-BitmapSubsExhausted records that, and it
    # explicitly stops blocking publish. 2026-09-07: six of The Song Remains The Same's featurettes
    # are wordless performance items whose subtitle streams carry no usable text - all six settled
    # `exhausted` - and the board named every one of them as "NO OCR SIDECAR yet (publish refuses
    # the whole work until every file has one)". That sends the next reader to check the OCR track,
    # which is draining perfectly, while the actual reason the work has not published is that its
    # manifest is still in _queue.
    #
    # So ask the VERDICT, which is the thing publish actually consults, not the container.
    $srt = [IO.Path]::ChangeExtension($f.FullName, $null) + 'eng.srt'
    if (Test-Path -LiteralPath $srt) {
      $why = 'ready - waiting on the publish loop'
    } else {
      $verdict = try { Get-BitmapSubsVerdict -Path $f.FullName -Ffprobe $ffprobe } catch { $null }
      $why = switch -Wildcard ("$verdict") {
        'none'      { 'ready - no subtitle stream, so no sidecar is needed' }
        'empty'     { 'ready - subtitle stream declared but carries no packets, so no sidecar is possible' }
        'exhausted' { 'ready - OCR ran and found no usable text; settled, and NOT blocking publish' }
        'blocked:*' { "BLOCKED - $($verdict -replace '^blocked:','') (publish refuses the work until this is resolved)" }
        'populated' { 'NO OCR SIDECAR yet (publish refuses the whole work until every file has one)' }
        default     {
          # No verdict cached at all - fall back to the container, and say that is what this is.
          $bitmap = @(& $ffprobe -v error -select_streams s -show_entries stream=codec_name `
                        -of csv=p=0 $f.FullName 2>$null) -match 'dvd_subtitle|hdmv_pgs_subtitle|dvb_subtitle'
          if ($bitmap) { 'NO OCR SIDECAR yet (publish refuses the whole work until every file has one)' }
          else { 'ready - no subtitle stream, so no sidecar is needed' }
        }
      }
    }
    $waiting += [pscustomobject]@{ File = $rel; WaitedMin = [int]$ageMin; Why = $why }
  }
}

if ($waiting.Count -eq 0) {
  # THE MARKER IS EMITTED HERE TOO, and it was not until 2026-09-18. This script's own rule is that
  # "absence of the marker means the audit did not RUN - a different thing from nothing is stalled,
  # and it must not read as reassurance" - yet the healthiest path of all, nothing waiting, printed
  # no marker under -Quiet and was therefore indistinguishable from a crash to anything parsing it.
  Write-Output 'PUBLISH-STALL-STATE stalled=0 minutes=0 waiting=0 held=0'
  if (-not $Quiet) { Write-Output 'PUBLISH FRESHNESS OK - no finished local file is waiting to be published.' }
  exit 0
}

# WHICH OF THESE IS ACTUALLY STALLING? A file the plan gate is deliberately holding, whose missing
# siblings are still queued or encoding, is waiting correctly - it is counted and NAMED, but it
# does not drive the clock. Everything else does, exactly as before.
foreach ($w in $waiting) {
  $hold = Get-PlanHold -RelPath $w.File -Holds $holds -Now $now -FreshMin $HoldFreshMin -BlockedCapMin $MaxWaitMin -NasRoot $NasRoot
  $w | Add-Member -NotePropertyName Held -NotePropertyValue ([bool]($hold -and $hold.Suppress)) -Force
  # The REASON is taken whenever the gate has one, suppressed or not: "ready - waiting on the
  # publish loop" is false about a file the loop is deliberately holding, and it sent the reader to
  # the wrong lane.
  if ($hold) { $w | Add-Member -NotePropertyName Why -NotePropertyValue $hold.Reason -Force }
}
$stalling = @($waiting | Where-Object { -not $_.Held })
$heldCount = $waiting.Count - $stalling.Count

if ($stalling.Count -eq 0) {
  $worstHeld = ($waiting | Measure-Object WaitedMin -Maximum).Maximum
  Write-Output ("PUBLISH-STALL-STATE stalled=0 minutes=0 waiting=0 held={0}" -f $heldCount)
  if (-not $Quiet) {
    Write-Output ("publish held by the plan gate - {0} file(s), longest {1} min, every one waiting on a declared output that is still queued or encoding." -f $heldCount, $worstHeld)
    foreach ($g in ($waiting | Group-Object { ($_.File -split '[\\/]')[0] })) {
      Write-Output ("    {0}: {1} file(s) - {2}" -f $g.Name, $g.Count, $g.Group[0].Why)
    }
  }
  exit 0
}
$worst = ($stalling | Measure-Object WaitedMin -Maximum).Maximum
if ($worst -le $MaxWaitMin) {
  # The healthy verdict is stated too. Absence of the marker then means the audit did not RUN -
  # which is a different thing from "nothing is stalled" and must not read as reassurance.
  Write-Output ("PUBLISH-STALL-STATE stalled=0 minutes={0} waiting={1} held={2}" -f $worst, $stalling.Count, $heldCount)
  if (-not $Quiet) {
    Write-Output ("publishing in progress - {0} file(s) waiting, longest {1} min (cap {2}){3}" -f `
                  $stalling.Count, $worst, $MaxWaitMin, $(if ($heldCount) { " - plus $heldCount held by the plan gate, still encoding" } else { '' }))
  }
  exit 0
}

# MACHINE-READABLE FIRST, PROSE AFTER - so _stallwatch.ps1 can publish this and _stall-alarm.ps1
# can raise it, instead of it existing only as a sentence nobody is watching.
#
# This line was printed and nothing else for months. On 2026-09-08 Star Trek The Motion Picture's
# OCR failed a dictionary gate at 84.8% ("letters are being split"), publish correctly held the
# whole work, and it sat for SIXTEEN HOURS holding 12 finished files - while every alarm stayed
# correctly silent, because none of them covers this: `fullyStopped` needs `-not busy` and the
# optical lane was ripping all night; `encodersStarved` needs work awaiting authoring and there was
# none; `manifestFailed` was clean because the manifest succeeded and the OCR did not. The operator
# found it by asking. That is the SAME defect already recorded against failed manifests in
# _stallwatch.ps1 - "the line went into $stalls as prose, and the alarm raises only on the NAMED
# lists" - fixed there and not asked of anything else in the same position.
#
# Anchored at line start and emitted even under -Quiet: a verdict is an assertion, not a mention,
# and a caller that filters output must still be able to find it.
Write-Output ("PUBLISH-STALL-STATE stalled=1 minutes={0} waiting={1} held={2}" -f $worst, $stalling.Count, $heldCount)

if (-not $Quiet) {
  Write-Output ''
  Write-Output ("*** NOTHING HAS PUBLISHED FOR {0} MINUTES and {1} finished file(s) are waiting:" -f $worst, $stalling.Count)
  foreach ($w in ($stalling | Sort-Object WaitedMin -Descending | Select-Object -First 12)) {
    Write-Output ("    {0,4} min  {1}" -f $w.WaitedMin, $w.File)
    Write-Output ("             {0}" -f $w.Why)
  }
  if ($heldCount) {
    Write-Output ("    ({0} further file(s) are held by the plan gate with their siblings still encoding - not part of this stall.)" -f $heldCount)
  }
  $noSrt = @($stalling | Where-Object { $_.Why -like 'NO OCR*' }).Count
  if ($noSrt -gt 0) {
    Write-Output ''
    Write-Output ("    {0} of them have no sidecar. Check the OCR track is running and draining -" -f $noSrt)
    Write-Output '    publish refuses a WORK while ANY of its files lacks one, so one stuck file'
    Write-Output '    holds back every finished episode beside it.'
  }
}
exit 2
