# NAS bandwidth governor - shared, CROSS-PROCESS admission control for anything that reads the
# published library over SMB.
#
# WHY THIS EXISTS (2026-09-04). The machine was force-rebooted at 11:47 because the NAS link had
# been busy all day and stopping the session did not stop it: the tracks are detached pwsh
# processes holding named mutexes, and three of them read the NAS with no coordination at all -
#   - the full subtitle-coverage sweep (ffprobe on ~5,300 no-sidecar files; measured 1.8 MB and
#     0.3 s per file when alone, ~40 Mbps for 30-55 min; it was 3 h in and still running at reboot),
#   - the OCR queue drain (mkvextract pulls EVERY BYTE of each file, measured 435-543 Mbps - the
#     only reader here that reaches link speed - 28.6 GB across 36 rows that day),
#   - the correction loop's per-pass rescan (a full SMB walk of Television Shows every pass;
#     measured 2.5-3.2 MB and 17-26 s, cheap in bytes but a whole-library metadata sweep).
# Each had its own idea of courtesy (the OCR queue stands down while publish is robocopying; the
# coverage loop waits for a foreign sweep) and none of them could see the others. This library is
# the one place they all go through.
#
# THREE GUARANTEES, each an OS-level object so separate processes share it:
#   1. AT MOST ONE LIBRARY-WIDE SWEEP at a time            - named mutex   Global\video-nas-sweep
#   2. A HARD CAP ON CONCURRENT GOVERNED NAS READS         - named mutexes Global\video-nas-read-<n>
#      (N slot mutexes rather than one semaphore, so the cap can be LOWERED live in the config
#      without every holder first releasing - a semaphore's maximum is fixed by its creator.)
#   3. A THROUGHPUT CEILING, not merely a concurrency cap - three mechanisms, all measured:
#      - Copy-NasFileThrottled copies a whole file as a LEVEL stream at the ceiling (4 MB chunks,
#        sleep to stay under) - what the OCR worker's staging copy now uses;
#      - ffmpeg readers get `-readrate` computed from the file's own bitrate so the read itself
#        runs at the ceiling (measured 50.6 Mbps against a 50 Mbps target on a 625 MB file);
#      - every governed item is followed by a PACING SLEEP so that bytes / (elapsed + sleep) never
#        exceeds the ceiling, using the adapter's own receive counter - so a reader this library
#        cannot slow down (mkvextract, ffprobe) is still held to the ceiling ON AVERAGE.
#      robocopy /IPG was tested as a candidate and does NOTHING here (543 Mbps with /IPG:10), so it
#      is not used. Windows QoS policies shape OUTBOUND traffic only and cannot cap a read.
# PLUS A KILL SWITCH the user can throw without an agent: while D:/video/_nas-hold exists, every
# governed caller stands down at its next safe boundary; the throttled copy stops within one
# chunk and Invoke-NasReadProcess kills a child reader in flight (its output is local scratch, so
# that is safe) - both restart from the beginning when the hold lifts.
#   pwsh -File D:/video/_nas-hold.ps1 -On -Reason "network hammering"     # or just create the file
#   pwsh -File D:/video/_nas-hold.ps1 -Off
#
# ONE CONFIGURABLE PLACE: D:/video/_nas-governor.json, re-read on every call (cached by mtime), so
# a change takes effect without bouncing anything. Missing file = the defaults below. An
# UNPARSEABLE file = the defaults too, said loudly once - never "governor off".
#
# ONLY NAS PATHS ARE GOVERNED. Test-NasPath decides; a local D:\ path passes straight through every
# function here untouched, so the local rip/encode/OCR tracks are never paced by mistake.
#
# TWO DESIGN RULES, both learned the hard way on the first integration run:
#   - NARRATION GOES TO THE HOST, never to the output stream. `$sweepSlot = Enter-NasSweep ...`
#     captured every "waiting" line INTO the handle, and `[void](Wait-NasHold ...)` swallowed
#     them; the waits happened (timings proved it) and nobody could see why. Every `& $Say` here
#     is piped to Out-Host, which Start-Transcript and `& pwsh` capture alike.
#   - STATE LIVES IN ONE PER-PROCESS $global: TABLE, not $script: variables. `$script:` inside a
#     function resolves to the CALLER's script scope when the library was dot-sourced from an
#     interactive/global scope, so a harness that loaded it then called it from another script
#     read $null for every setting. Each track is its own process, so global is per-track.
#
# Dot-source it:   . (Join-Path $PSScriptRoot 'lib-nas-governor.ps1')
# Tests:           pwsh -File lib-nas-governor.tests.ps1

$global:NasGovernorState = @{
  Defaults = [ordered]@{
    # THE ceiling: megabits per second, NAS -> this machine, that a governed reader may average.
    readCeilingMbps     = 50
    # Aggregate cap on governed NAS readers across every process on this machine.
    maxConcurrentReads  = 2
    # Kill switch: while this file exists every governed caller stands down.
    holdFile            = 'D:/video/_nas-hold'
    # Only paths matching this are governed (case-insensitive regex on the path as written).
    nasPathPattern      = '^\\\\NASTEAMV\\'
    # A governed read also waits while a robocopy to the NAS is running (the ocr-queue precedent).
    standDownForPublish = $true
    # Upper bound on one pacing sleep, seconds. 0 = uncapped: the honest ceiling, however long a
    # 13 GB film pulled at link speed then has to sit idle for.
    maxPaceSeconds      = 0
    # Names of the OS objects (without the 'Global\' prefix). Tests override these.
    sweepMutex          = 'video-nas-sweep'
    readSlotPrefix      = 'video-nas-read-'
  }
  ConfigPath = $(if ($env:NAS_GOVERNOR_CONFIG) { $env:NAS_GOVERNOR_CONFIG } else { 'D:/video/_nas-governor.json' })
  Cache      = $null
  CacheStamp = $null
  Warned     = $false
  Adapters   = $null
  # Names this PROCESS currently holds. A Win32 mutex is re-entrant for its owning thread, so a
  # WaitOne(0) probe reports our own holdings as "free" - the status functions consult this first.
  HeldNames  = @{}
}

function Write-NasSay {
  # Narration, to the HOST. See the design rule in the header.
  param([scriptblock]$Say, [string]$Message)
  if ($null -eq $Say) { Write-Host $Message; return }
  & $Say $Message | Out-Host
}

function Get-NasGovernorConfig {
  # Defaults overlaid with whatever the JSON file supplies. Re-read when the file's mtime changes.
  $st = $global:NasGovernorState
  $path = $st.ConfigPath
  $stamp = if ($path -and (Test-Path -LiteralPath $path)) { (Get-Item -LiteralPath $path).LastWriteTimeUtc.Ticks } else { 0 }
  if ($st.Cache -and $st.CacheStamp -eq $stamp) { return $st.Cache }
  $cfg = [ordered]@{}
  foreach ($k in $st.Defaults.Keys) { $cfg[$k] = $st.Defaults[$k] }
  if ($stamp -ne 0) {
    try {
      $json = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
      foreach ($p in $json.PSObject.Properties) {
        if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value }
      }
      $st.Warned = $false
    } catch {
      if (-not $st.Warned) {
        Write-Warning "nas-governor: '$path' is not valid JSON ($($_.Exception.Message)) - using the built-in defaults (ceiling $($cfg.readCeilingMbps) Mbps, $($cfg.maxConcurrentReads) reads)"
        $st.Warned = $true
      }
    }
  }
  # Types: JSON may hand back strings/doubles; the arithmetic below wants numbers.
  $cfg.readCeilingMbps    = [double]$cfg.readCeilingMbps
  $cfg.maxConcurrentReads = [int]$cfg.maxConcurrentReads
  $cfg.maxPaceSeconds     = [double]$cfg.maxPaceSeconds
  $cfg.standDownForPublish = [bool]$cfg.standDownForPublish
  $st.Cache = $cfg
  $st.CacheStamp = $stamp
  return $cfg
}

function Test-NasPath {
  param([AllowEmptyString()][string]$Path)
  if (-not $Path) { return $false }
  return [bool]($Path -match (Get-NasGovernorConfig).nasPathPattern)
}

function New-NasGovernorMutex {
  # 'Global' + [char]92 + name - never a literal backslash escape, never built inside the
  # New-Object argument list (see _loops.ps1: a comma inside a concatenation there makes the
  # arguments parse as one ARRAY and New-Object returns $null, which fails OPEN).
  param([Parameter(Mandatory)][string]$Name)
  $full = 'Global' + [char]92 + $Name
  $m = New-Object System.Threading.Mutex($false, $full)
  if ($null -eq $m) { throw "could not create mutex $full" }
  return $m
}

function Test-NasGovernorMutexHeld {
  # Is anyone holding it right now? Opens the mutex and tries a zero-wait acquire; if that
  # succeeds the mutex was free and is released again immediately. Read-only in effect.
  param([Parameter(Mandatory)][string]$Name)
  if ($global:NasGovernorState.HeldNames.ContainsKey($Name)) { return $true }   # held by THIS process
  $h = $null
  $full = 'Global' + [char]92 + $Name
  if (-not [System.Threading.Mutex]::TryOpenExisting($full, [ref]$h)) { return $false }
  try {
    $got = $false
    try { $got = $h.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if ($got) { $h.ReleaseMutex(); return $false }
    return $true
  } finally { $h.Dispose() }
}

function Get-NasHold {
  # $null when no hold; otherwise a one-line description (reason + when the file was dropped).
  $cfg = Get-NasGovernorConfig
  if (-not $cfg.holdFile -or -not (Test-Path -LiteralPath $cfg.holdFile)) { return $null }
  $f = Get-Item -LiteralPath $cfg.holdFile
  $why = ''
  try { $why = (Get-Content -LiteralPath $cfg.holdFile -Raw -ErrorAction Stop).Trim() } catch { }
  $age = (Get-Date) - $f.LastWriteTime
  return ('NAS HOLD active since {0} ({1:N0} min){2}' -f $f.LastWriteTime.ToString('HH:mm:ss'), $age.TotalMinutes, $(if ($why) { " - $why" } else { '' }))
}

function Wait-NasHold {
  # Block while the hold file exists. Narrates once on entry, then roughly every 5 minutes, then
  # once on release. Returns the seconds waited (0 when there was no hold).
  param([scriptblock]$Say = $null, [int]$PollSeconds = 15, [string]$Who = '')
  $hold = Get-NasHold
  if (-not $hold) { return 0 }
  $t0 = Get-Date
  $tag = if ($Who) { "$Who " } else { '' }
  Write-NasSay $Say ("{0}standing down: {1} - waiting for the hold file to be removed (pwsh -File D:/video/_nas-hold.ps1 -Off)" -f $tag, $hold)
  $lastSaid = Get-Date
  while ($true) {
    Start-Sleep -Seconds $PollSeconds
    if (-not (Get-NasHold)) { break }
    if (((Get-Date) - $lastSaid).TotalMinutes -ge 5) {
      Write-NasSay $Say ("{0}still held ({1:N0} min so far)" -f $tag, ((Get-Date) - $t0).TotalMinutes)
      $lastSaid = Get-Date
    }
  }
  $waited = ((Get-Date) - $t0).TotalSeconds
  Write-NasSay $Say ("{0}hold released after {1:N0} s - resuming" -f $tag, $waited)
  return $waited
}

function Test-NasPublishBusy {
  # A robocopy whose command line names the NAS root - fetch's own robocopy (E: -> _stage) never
  # touches the NAS and must not count. Lifted verbatim from _ocr-queue-loop.ps1's precedent.
  $cfg = Get-NasGovernorConfig
  $host_ = ($cfg.nasPathPattern -replace '[\^\\$]', '') -replace '/', ''
  if (-not $host_) { $host_ = 'nasteamv' }
  return @(Get-CimInstance Win32_Process -Filter "Name='robocopy.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and (($_.CommandLine -replace '\\', '/') -match ('(?i)' + [regex]::Escape($host_))) }).Count -gt 0
}

function Get-NasBytesReceived {
  # Cumulative bytes received across the machine's PHYSICAL adapters, via .NET (13 ms) rather than
  # Get-NetAdapterStatistics (166 ms per call - measured). The filter-driver pseudo-interfaces
  # report the SAME counters as the adapter they wrap, so summing everything would multiply the
  # real number by five; Get-NetAdapter -Physical (one CIM call, cached) names the real ones.
  $st = $global:NasGovernorState
  if ($null -eq $st.Adapters) {
    try { $st.Adapters = @(Get-NetAdapter -Physical -ErrorAction Stop | ForEach-Object { $_.Name }) } catch { $st.Adapters = @() }
  }
  $total = [long]0
  foreach ($ni in [System.Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
    if ($st.Adapters.Count -gt 0 -and $st.Adapters -notcontains $ni.Name) { continue }
    if ($st.Adapters.Count -eq 0 -and $ni.NetworkInterfaceType -notin 'Ethernet', 'Wireless80211') { continue }
    try { $total += $ni.GetIPv4Statistics().BytesReceived } catch { }
  }
  return $total
}

function Get-NasPaceSeconds {
  # PURE: how long to sleep after an item that pulled $Bytes in $ElapsedSeconds so that the item's
  # average never exceeds $CeilingMbps. 0 when it was already under the ceiling.
  param([Parameter(Mandatory)][long]$Bytes, [Parameter(Mandatory)][double]$ElapsedSeconds,
        [Parameter(Mandatory)][double]$CeilingMbps, [double]$MaxPaceSeconds = 0)
  if ($CeilingMbps -le 0 -or $Bytes -le 0) { return 0.0 }
  $need = ($Bytes * 8.0) / ($CeilingMbps * 1e6)
  $sleep = $need - $ElapsedSeconds
  if ($sleep -le 0) { return 0.0 }
  if ($MaxPaceSeconds -gt 0 -and $sleep -gt $MaxPaceSeconds) { $sleep = $MaxPaceSeconds }
  return [math]::Round($sleep, 1)
}

function Get-NasReadRate {
  # PURE: the ffmpeg -readrate multiplier that makes a file of $Bytes lasting $DurationSeconds read
  # at $CeilingMbps. -readrate is RELATIVE to the stream's native rate, so a 2.9 Mbps DVD episode
  # needs ~17 for a 50 Mbps ceiling and a 40 Mbps Blu-ray ~1.25. $null when it cannot be computed.
  param([long]$Bytes, [double]$DurationSeconds, [double]$CeilingMbps)
  if ($CeilingMbps -le 0 -or $Bytes -le 0 -or $DurationSeconds -le 0) { return $null }
  $native = ($Bytes * 8.0) / $DurationSeconds / 1e6
  if ($native -le 0) { return $null }
  return [math]::Round($CeilingMbps / $native, 3)
}

function Get-NasReadRateArgs {
  # ffmpeg INPUT options (they must precede -i) that hold this file's read to the ceiling.
  # Empty for a local path, for a ceiling of 0, or when size/duration cannot be established -
  # an ungoverned read is the safe failure here, never a refused one.
  param([Parameter(Mandatory)][string]$Path, [string]$Ffprobe)
  if (-not (Test-NasPath $Path)) { return @() }
  $cfg = Get-NasGovernorConfig
  if ($cfg.readCeilingMbps -le 0) { return @() }
  if (-not $Ffprobe -or -not (Test-Path -LiteralPath $Ffprobe)) { return @() }
  $bytes = 0; $dur = 0.0
  try { $bytes = (Get-Item -LiteralPath $Path -ErrorAction Stop).Length } catch { return @() }
  $d = "$(& $Ffprobe -v error -show_entries format=duration -of csv=p=0 -- $Path 2>$null)".Trim()
  if (-not [double]::TryParse($d, [ref]$dur)) { return @() }
  $rate = Get-NasReadRate -Bytes $bytes -DurationSeconds $dur -CeilingMbps $cfg.readCeilingMbps
  if ($null -eq $rate) { return @() }
  # Invariant culture: a comma decimal separator would be read by ffmpeg as "40" and a stray arg.
  return @('-readrate', $rate.ToString([cultureinfo]::InvariantCulture), '-readrate_initial_burst', '2')
}

# ---------------------------------------------------------------------------------------------
# Guarantee 1: one library-wide sweep at a time.
# ---------------------------------------------------------------------------------------------
function Enter-NasSweep {
  # Acquire the sweep mutex. Waits (narrating) up to $MaxWaitMinutes; 0 = wait indefinitely.
  # Returns a handle for Exit-NasSweep, or $null on timeout - the caller then SKIPS its sweep this
  # pass and says so; it never proceeds unguarded.
  param([string]$Name = 'sweep', [scriptblock]$Say = $null, [double]$MaxWaitMinutes = 0, [int]$PollSeconds = 10)
  $cfg = Get-NasGovernorConfig
  $m = New-NasGovernorMutex -Name $cfg.sweepMutex
  $t0 = Get-Date
  $said = $false
  while ($true) {
    $got = $false
    try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
    if ($got) {
      if ($said) { Write-NasSay $Say ("{0}: sweep slot acquired after {1:N0} s" -f $Name, ((Get-Date) - $t0).TotalSeconds) }
      $global:NasGovernorState.HeldNames[$cfg.sweepMutex] = $true
      return [pscustomobject]@{ Mutex = $m; MutexName = $cfg.sweepMutex; Name = $Name; Since = Get-Date }
    }
    if (-not $said) { Write-NasSay $Say ("{0}: another library-wide NAS sweep holds Global\{1} - waiting rather than running two at once" -f $Name, $cfg.sweepMutex); $said = $true }
    if ($MaxWaitMinutes -gt 0 -and ((Get-Date) - $t0).TotalMinutes -ge $MaxWaitMinutes) {
      Write-NasSay $Say ("{0}: gave up waiting for the sweep slot after {1} min - skipping this pass" -f $Name, $MaxWaitMinutes)
      $m.Dispose()
      return $null
    }
    Start-Sleep -Seconds $PollSeconds
  }
}

function Exit-NasSweep {
  param($Handle)
  if ($null -eq $Handle) { return }
  try { $Handle.Mutex.ReleaseMutex() } catch { }
  try { $Handle.Mutex.Dispose() } catch { }
  if ($Handle.MutexName) { $global:NasGovernorState.HeldNames.Remove($Handle.MutexName) }
}

# ---------------------------------------------------------------------------------------------
# Guarantee 2: at most maxConcurrentReads governed readers, machine-wide.
# ---------------------------------------------------------------------------------------------
function Enter-NasReadSlot {
  # Take one of the N read-slot mutexes. Honours the hold and the publish stand-down BEFORE
  # taking a slot (so a waiting reader never sits on a slot while standing down). Returns a handle
  # for Exit-NasReadSlot, or $null after $MaxWaitMinutes (0 = indefinitely).
  param([string]$Name = 'read', [scriptblock]$Say = $null, [double]$MaxWaitMinutes = 0, [int]$PollSeconds = 5)
  $t0 = Get-Date
  $saidSlots = $false; $saidPublish = $false
  while ($true) {
    [void](Wait-NasHold -Say $Say -Who $Name)
    $cfg = Get-NasGovernorConfig
    if ($cfg.standDownForPublish -and (Test-NasPublishBusy)) {
      if (-not $saidPublish) { Write-NasSay $Say ("{0}: publish is copying to the NAS - standing down until it finishes" -f $Name); $saidPublish = $true }
    } else {
      $saidPublish = $false
      $n = [math]::Max(1, $cfg.maxConcurrentReads)
      for ($i = 0; $i -lt $n; $i++) {
        $m = New-NasGovernorMutex -Name ($cfg.readSlotPrefix + $i)
        $got = $false
        try { $got = $m.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
        if ($got) {
          if ($saidSlots) { Write-NasSay $Say ("{0}: read slot {1} acquired after {2:N0} s" -f $Name, $i, ((Get-Date) - $t0).TotalSeconds) }
          $global:NasGovernorState.HeldNames[$cfg.readSlotPrefix + $i] = $true
          return [pscustomobject]@{ Mutex = $m; MutexName = ($cfg.readSlotPrefix + $i); Slot = $i; Name = $Name; Since = Get-Date }
        }
        $m.Dispose()
      }
      if (-not $saidSlots) { Write-NasSay $Say ("{0}: all {1} NAS read slot(s) are taken by other processes - waiting" -f $Name, $n); $saidSlots = $true }
    }
    if ($MaxWaitMinutes -gt 0 -and ((Get-Date) - $t0).TotalMinutes -ge $MaxWaitMinutes) {
      Write-NasSay $Say ("{0}: no read slot within {1} min - giving up this attempt" -f $Name, $MaxWaitMinutes)
      return $null
    }
    Start-Sleep -Seconds $PollSeconds
  }
}

function Exit-NasReadSlot {
  param($Handle)
  if ($null -eq $Handle) { return }
  try { $Handle.Mutex.ReleaseMutex() } catch { }
  try { $Handle.Mutex.Dispose() } catch { }
  if ($Handle.MutexName) { $global:NasGovernorState.HeldNames.Remove($Handle.MutexName) }
}

function Copy-NasFileThrottled {
  # A whole-file copy that IS the ceiling: 4 MB chunks, and after each chunk it sleeps until the
  # bytes so far divided by the elapsed time is back under $CeilingMbps - a level stream, never a
  # burst-then-idle. The hold file is checked between chunks, so the kill switch stops the copy
  # within one chunk (~0.6 s at 50 Mbps), the partial destination is removed, and the copy starts
  # again from byte 0 once the hold lifts. Verifies the byte count at the end. Returns an object
  # {Seconds, Bytes, Mbps, Restarts}; throws on a copy that cannot complete.
  # Take a read slot around it with Invoke-NasRead (its post-pacing then costs ~nothing, because
  # the copy already ran at the ceiling). The destination MUST be local - asserted.
  param(
    [Parameter(Mandatory)][string]$Source,
    [Parameter(Mandatory)][string]$Destination,
    [double]$CeilingMbps = -1,          # -1 = the config's readCeilingMbps; 0 = no pacing
    [int]$ChunkBytes = 4MB,
    [scriptblock]$Say = $null,
    [string]$Label = 'nas copy'
  )
  if (Test-NasPath $Destination) { throw "Copy-NasFileThrottled: refusing a destination on the NAS ($Destination)" }
  if ($CeilingMbps -lt 0) { $CeilingMbps = (Get-NasGovernorConfig).readCeilingMbps }
  $bytesPerSec = if ($CeilingMbps -gt 0) { $CeilingMbps * 1e6 / 8.0 } else { 0 }
  $restarts = -1
  while ($true) {
    $restarts++
    [void](Wait-NasHold -Say $Say -Who $Label)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $copied = [long]0
    $inS = $null; $outS = $null
    $interrupted = $false
    try {
      $inS  = [IO.FileStream]::new($Source, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, $ChunkBytes, [IO.FileOptions]::SequentialScan)
      $outS = [IO.FileStream]::new($Destination, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None, $ChunkBytes)
      $buf = [byte[]]::new($ChunkBytes)
      while ($true) {
        $n = $inS.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $outS.Write($buf, 0, $n)
        $copied += $n
        if ($bytesPerSec -gt 0) {
          $ahead = ($copied / $bytesPerSec) - $sw.Elapsed.TotalSeconds
          if ($ahead -gt 0.02) { Start-Sleep -Milliseconds ([int][math]::Min(5000, $ahead * 1000)) }
        }
        if (Get-NasHold) {
          Write-NasSay $Say ("{0}: NAS hold dropped mid-copy at {1:N0} MB - discarding the partial copy; will restart when the hold lifts" -f $Label, ($copied / 1MB))
          $interrupted = $true
          break
        }
      }
    } finally {
      if ($inS) { $inS.Dispose() }
      if ($outS) { $outS.Dispose() }
    }
    if ($interrupted) {
      Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
      continue
    }
    $want = (Get-Item -LiteralPath $Source).Length
    $got  = (Get-Item -LiteralPath $Destination).Length
    if ($got -ne $want) {
      Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
      throw "Copy-NasFileThrottled: copied $got bytes, source is $want - discarded"
    }
    $sec = $sw.Elapsed.TotalSeconds
    return [pscustomobject]@{ Seconds = $sec; Bytes = $got; Mbps = [math]::Round($got * 8 / [math]::Max($sec, 0.001) / 1e6, 1); Restarts = $restarts }
  }
}

# ---------------------------------------------------------------------------------------------
# Guarantee 3: the ceiling. Bracket one NAS-reading item: hold, slot, measure, pace.
# ---------------------------------------------------------------------------------------------
function Invoke-NasRead {
  # Run $Do as ONE governed item against $Path. A local path runs $Do straight through - no slot,
  # no measurement, no pacing. Output of $Do is returned as-is. The pacing sleep uses the adapter's
  # receive counter, which counts EVERYONE's traffic during the item - deliberately: it is the LINK
  # being protected, so a concurrent reader makes this one pace more, never less.
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][scriptblock]$Do,
    [string]$Label = 'nas read',
    [scriptblock]$Say = $null,
    [double]$MaxWaitMinutes = 0
  )
  if (-not (Test-NasPath $Path)) { return (& $Do) }
  $slot = Enter-NasReadSlot -Name $Label -Say $Say -MaxWaitMinutes $MaxWaitMinutes
  if ($null -eq $slot) { Write-NasSay $Say ("{0}: proceeding WITHOUT a read slot (timed out) - still paced" -f $Label) }
  $b0 = Get-NasBytesReceived
  $t0 = Get-Date
  try { $out = & $Do }
  finally {
    $elapsed = ((Get-Date) - $t0).TotalSeconds
    $bytes = (Get-NasBytesReceived) - $b0
    Exit-NasReadSlot $slot
    $cfg = Get-NasGovernorConfig
    $pace = Get-NasPaceSeconds -Bytes $bytes -ElapsedSeconds $elapsed -CeilingMbps $cfg.readCeilingMbps -MaxPaceSeconds $cfg.maxPaceSeconds
    # ALWAYS SAY WHAT THE ITEM COST - one line per governed item, pacing or not. The earlier
    # version only spoke when it had to pace 10 s or more, so a reader that was already under the
    # ceiling (the whole point) left no trace at all, and "is the governor working?" could only be
    # answered with a stopwatch and a directory listing (2026-09-04).
    Write-NasSay $Say ("[governor] {0}: pulled {1:N0} MB in {2:N0} s = {3:N1} Mbps (adapter total; ceiling {4} Mbps){5}" -f
      $Label, ($bytes / 1MB), $elapsed, ($bytes * 8 / [math]::Max($elapsed, 0.001) / 1e6), $cfg.readCeilingMbps,
      $(if ($pace -gt 0) { " - pacing {0:N0} s to hold the ceiling on average" -f $pace } else { ' - under the ceiling, no pacing' }))
    if ($pace -gt 0) {
      $end = (Get-Date).AddSeconds($pace)
      while ((Get-Date) -lt $end) { Start-Sleep -Seconds ([math]::Min(5, [math]::Max(1, [int]($end - (Get-Date)).TotalSeconds))) }
    }
  }
  return $out
}

function ConvertTo-NasProcessArgument {
  # Quote one argument for Start-Process -ArgumentList, which joins the array with spaces and
  # does NOT quote for you: a NAS path with spaces would otherwise arrive as several arguments.
  param([AllowEmptyString()][string]$Arg)
  if ($Arg -notmatch '[\s"]') { return $Arg }
  return '"' + ($Arg -replace '(\\*)"', '$1$1\"') + '"'
}

function Invoke-NasReadProcess {
  # Run a whole-file NAS reader (ffmpeg, mkvextract) as a child process that the KILL SWITCH can
  # stop in flight: while it runs the hold file is polled every $PollSeconds; if the hold appears
  # the child is stopped, its partial $OutputPath (which MUST be local scratch - asserted) is
  # removed, and the read is restarted from the beginning once the hold lifts. So "the network is
  # hammering" is answered within seconds, not "when this 13 GB film finishes".
  # Returns the child's exit code. Wrap the CALL in Invoke-NasRead for the slot and the pacing.
  param(
    [Parameter(Mandatory)][string]$FilePath,
    [Parameter(Mandatory)][string[]]$ArgumentList,
    [Parameter(Mandatory)][string]$OutputPath,
    [scriptblock]$Say = $null,
    [string]$Label = 'nas read',
    [int]$PollSeconds = 2
  )
  if (Test-NasPath $OutputPath) { throw "Invoke-NasReadProcess: refusing an output path on the NAS ($OutputPath) - scratch is local only" }
  $argString = ($ArgumentList | ForEach-Object { ConvertTo-NasProcessArgument $_ }) -join ' '
  $attempt = 0
  while ($true) {
    $attempt++
    [void](Wait-NasHold -Say $Say -Who $Label)
    $errFile = [IO.Path]::Combine([IO.Path]::GetTempPath(), ('nasread-' + [guid]::NewGuid().ToString('N') + '.err'))
    $p = Start-Process -FilePath $FilePath -ArgumentList $argString -WindowStyle Hidden -PassThru -RedirectStandardError $errFile
    $killed = $false
    while (-not $p.HasExited) {
      if (Get-NasHold) {
        Write-NasSay $Say ("{0}: NAS hold dropped mid-read - stopping pid {1} and discarding its partial output; will restart when the hold lifts" -f $Label, $p.Id)
        try { Stop-Process -Id $p.Id -Force -ErrorAction Stop } catch { }
        $killed = $true
        break
      }
      Start-Sleep -Seconds $PollSeconds
    }
    if ($killed) {
      Start-Sleep -Seconds 1
      if (Test-Path -LiteralPath $OutputPath) { Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue }
      Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
      continue
    }
    $p.WaitForExit()
    $code = $p.ExitCode
    if ($code -ne 0) {
      $err = ''
      try { $err = (Get-Content -LiteralPath $errFile -Raw -ErrorAction Stop).Trim() } catch { }
      if ($err) { Write-NasSay $Say ("{0}: {1} exited {2}: {3}" -f $Label, (Split-Path -Leaf $FilePath), $code, (($err -split "`n" | Select-Object -Last 2) -join ' | ')) }
    }
    Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue
    return $code
  }
}

function Get-NasGovernorStatus {
  # For _nas-hold.ps1 and _loops.ps1: one object describing the governor right now.
  $cfg = Get-NasGovernorConfig
  $slots = @()
  for ($i = 0; $i -lt [math]::Max(1, $cfg.maxConcurrentReads); $i++) {
    $slots += [pscustomobject]@{ Slot = $i; Held = (Test-NasGovernorMutexHeld -Name ($cfg.readSlotPrefix + $i)) }
  }
  [pscustomobject]@{
    Hold            = Get-NasHold
    HoldFile        = $cfg.holdFile
    ConfigFile      = $global:NasGovernorState.ConfigPath
    ReadCeilingMbps = $cfg.readCeilingMbps
    MaxReads        = $cfg.maxConcurrentReads
    SweepHeld       = (Test-NasGovernorMutexHeld -Name $cfg.sweepMutex)
    ReadSlots       = $slots
    PublishBusy     = (Test-NasPublishBusy)
  }
}
