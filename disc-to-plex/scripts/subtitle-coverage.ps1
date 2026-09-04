<#
  subtitle-coverage.ps1 - the missing subtitle-coverage signal.

  WHY THIS EXISTS (user, 2026-09-03): "I am surprised it published without SRT." Four Survivors
  Season 02 episodes published to the NAS with no subtitles and nothing anywhere raised a signal -
  the publish gate only refuses a file with BITMAP subs awaiting OCR; a file with no subtitle
  stream at all sails through, because there is genuinely nothing to wait for.

  WHAT IT DOES
    1. REPORT (default): survey the NAS (read-only, never written to) and classify every media
       file's subtitle coverage into: covered / stale-provenance / not-applicable / awaiting-ocr /
       awaiting-transcription / transcription-deferred / genuinely-missed / unclassified. Writes
       ONE current CSV, D:/video/_subtitle-coverage.csv, overwritten in place.
    2. QUEUE (-Queue): append newly-eligible rows to two SEPARATE queues with two SEPARATE scope
       rules (user, 2026-09-03 - two messages, read both before changing either):
         - OCR:          D:/video/_ocr-queue.csv          - LIBRARY-WIDE. A bitmap subtitle stream
           in the published file is its own evidence, checked on the file directly - it does not
           matter which drive produced it or whether this pipeline produced it at all.
         - Transcription: D:/video/_transcribe-queue.csv  - NARROWED to files that are (a) this
           pipeline's own output (a manifest declares no subtitle source) AND (b) sourced from the
           CURRENTLY ATTACHED drive. A disc on a drive we cannot currently read may have subtitles
           we have not seen - transcribing it now risks wasted GPU time and human verification a
           future re-rip would make redundant. Those instead get recorded to
           D:/video/_transcribe-deferred.csv, NOT as a failure.
       Queueing never starts either the transcribe or the OCR track - both drain opportunistically.

  See lib-subtitle-coverage.ps1's header for the full category list and exactly what evidence
  backs each one - this script only decides what to DO with a classification, never how to make one.

  SCOPE: -Works restricts the scan to named work folders (checked under both Movies and
  Television Shows) - this is what the post-publish trigger uses, so a routine publish pass never
  re-walks the whole NAS. Omit -Works for a full sweep; only a full sweep (re)writes the report CSV
  and is eligible to run -RefilterTranscribeQueue (which needs the whole queue's files classified).

  INCREMENTAL BY DEFAULT (2026-09-04). A full sweep used to ffprobe every one of ~5,600 no-sidecar
  files on the NAS from scratch every four hours whether or not anything had changed - 30-55 min
  on a quiet link, over three hours under contention on 2026-09-04, and the sustained SMB traffic
  was one of the two reasons the machine was force-rebooted that morning. The enumeration is
  cheap (a full metadata walk of the tree is seconds); it is the per-file ffprobe that costs.

  So the report CSV now doubles as a PROBE CACHE. Each row records what ffprobe found in the media
  file (BitmapProbe, AudioProbe) together with the file's size and LastWriteTimeUtc ticks at the
  moment it was probed. On the next run the tree is walked again in full, every file's
  classification is RE-DERIVED from scratch against the current sidecars, manifests and registers,
  and only the two ffprobe answers are looked up rather than re-measured - provided the media
  file's size AND write time are unchanged. That is the whole validity argument: a file's stream
  inventory cannot change unless its bytes change, and its bytes cannot change without moving
  either figure. Everything that CAN change without the media file changing - a .srt appearing or
  disappearing beside it, a manifest completing, a register row - is never cached, because the
  classifier is re-run in full every pass; only the probe is memoised. A stale-provenance row still
  pays its duration ffprobe each pass (it is a header read, and there are ~280 of them).

    ProbeSource column   'measured'   ffprobe ran on this file THIS pass - evidence
                         'cached'     carried forward from a previous pass, file unchanged - inference
                         'not-needed' a sidecar is present, so nothing was probed
                         'unavailable' a probe was wanted but ffprobe is not installed
    ProbedAt             when the measurement actually happened (carried forward with 'cached')
    CacheSchema          'cov-probe-2' - a report written by an older script (no such column, or a
                         different value) is NOT trusted as a cache; the sweep rebuilds in full.

  The cache is also rebuilt in full when the previous report is missing or unreadable, and on
  demand with -Full (alias -NoCache). The end-of-run summary says how many rows were reused
  versus re-probed, so nobody has to infer it from the runtime.

  USAGE
    pwsh -File subtitle-coverage.ps1                                   # full report, read-only, incremental
    pwsh -File subtitle-coverage.ps1 -Full                              # same, but re-probe every file (ignore the cache)
    pwsh -File subtitle-coverage.ps1 -Queue                             # full report + enqueue (OCR library-wide, transcription narrowed)
    pwsh -File subtitle-coverage.ps1 -Works 'Survivors' -Queue          # scoped post-publish trigger
    pwsh -File subtitle-coverage.ps1 -Queue -RefilterTranscribeQueue    # also re-validate every row already in _transcribe-queue.csv
#>
param(
  [string[]]$Works = @(),
  [switch]$Queue,
  # Re-validate every row ALREADY in _transcribe-queue.csv against the current rules, moving a
  # bitmap-carrying file to the OCR queue and an off-drive file to the deferred register. Only
  # meaningful on a full sweep - a scoped run has not classified the files the other rows point at,
  # and removing rows it never looked at would be exactly the "narrower run erases a wider one's
  # answer" mistake queue-transcribable.ps1 already guards against.
  [switch]$RefilterTranscribeQueue,
  # Reuses queue-transcribable.ps1's own (disc-identity-register-driven) eligibility for TRANSCRIPTION
  # from files this manifest-based classifier cannot see at all - the wider pre-existing library.
  # Default OFF and NOT wired into the automatic trigger: committing the legacy backlog to
  # transcription is a decision for the user, not something a post-publish hook should do on its own.
  # (OCR has no such switch - OCR is library-wide unconditionally, per the user's 2026-09-03 ruling.)
  [switch]$IncludeLegacy,
  [switch]$Report,
  # Ignore the probe cache carried in the previous report and ffprobe every file again - the
  # pre-2026-09-04 behaviour. The escape hatch for "I do not trust the cache"; never the default.
  [Alias('NoCache')][switch]$Full,
  [string]$NasRoot = '\\NASTEAMV\Multimedia',
  [string]$ReportCsv = 'D:/video/_subtitle-coverage.csv',
  [string]$QueueCsv = 'D:/video/_transcribe-queue.csv',
  [string]$ProgressCsv = 'D:/video/_transcribe-progress.csv',
  [string]$NaCsv = 'D:/video/_transcribe-not-applicable.csv',
  [string]$DeferredCsv = 'D:/video/_transcribe-deferred.csv',
  [string]$OcrQueueCsv = 'D:/video/_ocr-queue.csv',
  [string]$OcrProgressCsv = 'D:/video/_ocr-progress.csv',
  [string]$DiscIdentityStore = ([IO.Path]::Combine('\\NASTEAMV', 'Multimedia', '_disc-identity')),
  # The drive currently attached and readable. User-stated fact (2026-09-03), not auto-detected -
  # see lib-subtitle-coverage.ps1's Get-SubtitleCoverageDiscDriveIndex for why the register alone
  # cannot answer this (every record swept so far already says 'media2').
  [string]$AttachedDrive = 'media2',
  [string]$QueueTranscribableScript = 'D:/video/.claude/skills/disc-to-plex/scripts/queue-transcribable.ps1',
  [int]$MinQueueSeconds = 60
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-subtitle-coverage.ps1')
. (Join-Path $PSScriptRoot 'lib-queue-guard.ps1')
. (Join-Path $PSScriptRoot 'lib-nas-governor.ps1')
if (-not (Get-Command Invoke-NasRead -ErrorAction SilentlyContinue)) { throw 'lib-nas-governor.ps1 failed to load - a full sweep must not run ungoverned' }

$fullSweep = ($Works.Count -eq 0)
$writeReport = $Report.IsPresent -or $fullSweep
if ($RefilterTranscribeQueue -and -not $fullSweep) {
  Write-Output 'REFUSING -RefilterTranscribeQueue on a scoped (-Works) run - it would judge every queued row against a partial classification and remove rows this run never looked at. Omit -Works to run it.'
  exit 2
}

$ffprobe = $null
$toolPaths = 'D:/video/.transcode-tools/tool-paths.json'
if (Test-Path -LiteralPath $toolPaths) {
  try {
    $ffprobe = Join-Path (Split-Path ((Get-Content -LiteralPath $toolPaths -Raw | ConvertFrom-Json).ffmpeg)) 'ffprobe.exe'
    if (-not (Test-Path -LiteralPath $ffprobe)) { $ffprobe = $null }
  } catch { $ffprobe = $null }
}
if (-not $ffprobe) { Write-Output 'WARNING: ffprobe not found - the bitmap-stream probe cannot run this pass, so no-sidecar files fall back to "unclassified" rather than a guess.' }

# ---------------------------------------------------------------------------------------------
# PROBE CACHE - see the header. Only the two ffprobe answers the classifier asks for are memoised
# (bitmap subtitle codec, audio present), keyed on the media file's size + LastWriteTimeUtc ticks.
#
# HOW IT PLUGS IN WITHOUT TOUCHING THE LIBRARY. lib-subtitle-coverage.ps1's classifier calls
# Test-BitmapSubtitleStream and Test-CoverageHasAudioStream BY NAME, and both are defined in this
# script's scope by the dot-source above. Re-defining a function of the same name here REPLACES it
# for every caller in this scope - the classifier included - which is exactly the shadowing hazard
# the library's own header warns about, used here on purpose. The library's originals are captured
# as script blocks FIRST so the shadows can fall through to them on a cache miss; nothing about how
# a probe is measured lives here, only whether it needs measuring again.
# ---------------------------------------------------------------------------------------------
$script:ProbeCacheSchema = 'cov-probe-2'
$script:ProbeCache = @{}    # mkv path (lower) -> @{ Size; Ticks; Bitmap; Audio; ProbedAt }  from the previous report
$script:ProbeLog   = @{}    # mkv path (lower) -> @{ Bitmap; Audio; Source; ProbedAt }        what THIS pass used
$script:FileMeta   = @{}    # mkv path (lower) -> @{ Size; Ticks }                            this pass's metadata walk
$script:ProbeStats = @{ Loaded = 0; Reused = 0; Measured = 0 }

# Load the previous report as a cache. Returns $null when it loaded, otherwise the REASON it was
# not used - printed, so a silent fall-back to a full re-probe cannot masquerade as the cache working.
function Import-CoverageProbeCache {
  param([string]$Csv, [switch]$Force)
  if ($Force) { return 'forced full rebuild (-Full / -NoCache)' }
  if (-not (Test-Path -LiteralPath $Csv)) { return "no previous report at $Csv" }
  $rows = $null
  try { $rows = @(Import-Csv -LiteralPath $Csv -ErrorAction Stop) } catch { return "previous report unreadable: $($_.Exception.Message)" }
  if ($rows.Count -eq 0) { return 'previous report is empty' }
  $cols = @($rows[0].PSObject.Properties.Name)
  foreach ($need in 'CacheSchema', 'MkvPath', 'MkvSize', 'MkvWriteTicks', 'BitmapProbe', 'AudioProbe', 'ProbeSource', 'ProbedAt') {
    if ($cols -notcontains $need) { return "previous report predates the probe cache (no '$need' column)" }
  }
  $seen = "$($rows[0].CacheSchema)"
  if ($seen -ne $script:ProbeCacheSchema) { return "previous report carries cache schema '$seen', this script writes '$($script:ProbeCacheSchema)'" }
  foreach ($r in $rows) {
    if ("$($r.ProbeSource)" -notin 'measured', 'cached') { continue }   # only rows that hold real probe evidence
    # TYPED, so TryParse's [ref] can bind (an untyped $null throws - see _coverage-loop.ps1's Read-Checkpoint).
    [long]$size = 0; [long]$ticks = 0
    if (-not [long]::TryParse("$($r.MkvSize)", [ref]$size)) { continue }
    if (-not [long]::TryParse("$($r.MkvWriteTicks)", [ref]$ticks)) { continue }
    $bitmap = $null
    switch ("$($r.BitmapProbe)") { '' { $bitmap = $null } 'none' { $bitmap = '' } default { $bitmap = $_ } }
    $audio = $null
    switch ("$($r.AudioProbe)") { 'yes' { $audio = $true } 'no' { $audio = $false } default { $audio = $null } }
    if ($null -eq $bitmap -and $null -eq $audio) { continue }
    $script:ProbeCache["$($r.MkvPath)".ToLowerInvariant()] = @{ Size = $size; Ticks = $ticks; Bitmap = $bitmap; Audio = $audio; ProbedAt = "$($r.ProbedAt)" }
  }
  $script:ProbeStats.Loaded = $script:ProbeCache.Count
  return $null
}

# A cached entry is only returned when THIS pass's metadata walk saw the file with the SAME size
# and write ticks. No metadata (file appeared between the two walks) means no cache, never a guess.
function Get-CoverageProbeCacheEntry([string]$Path) {
  $key = $Path.ToLowerInvariant()
  $meta = $script:FileMeta[$key]
  if (-not $meta) { return $null }
  $e = $script:ProbeCache[$key]
  if (-not $e) { return $null }
  if ($e.Size -ne $meta.Size -or $e.Ticks -ne $meta.Ticks) { return $null }
  return $e
}

function Add-CoverageProbeLog([string]$Path, [string]$Kind, $Value, [string]$Source, [string]$ProbedAt) {
  $key = $Path.ToLowerInvariant()
  if (-not $script:ProbeLog.ContainsKey($key)) { $script:ProbeLog[$key] = @{ Bitmap = $null; Audio = $null; Source = ''; ProbedAt = '' } }
  $l = $script:ProbeLog[$key]
  $l[$Kind] = $Value
  # 'measured' dominates: if ANY probe on this file ran fresh this pass the row is evidence, and its
  # ProbedAt is now. A row is 'cached' only when everything it needed came from the previous report.
  if ($Source -eq 'measured' -or -not $l.Source) { $l.Source = $Source; $l.ProbedAt = $ProbedAt }
}

$script:LibBitmapProbe = (Get-Command Test-BitmapSubtitleStream -CommandType Function).ScriptBlock
$script:LibAudioProbe  = (Get-Command Test-CoverageHasAudioStream -CommandType Function).ScriptBlock
if (-not $script:LibBitmapProbe -or -not $script:LibAudioProbe) { throw 'lib-subtitle-coverage.ps1 did not define the probe functions - refusing to shadow nothing' }

function Test-BitmapSubtitleStream {
  param([Parameter(Mandatory)][string]$Path, [string]$ffprobe)
  $e = Get-CoverageProbeCacheEntry $Path
  if ($e -and $null -ne $e.Bitmap) {
    $script:ProbeStats.Reused++
    Add-CoverageProbeLog $Path 'Bitmap' $e.Bitmap 'cached' $e.ProbedAt
    return $e.Bitmap
  }
  $r = & $script:LibBitmapProbe -Path $Path -ffprobe $ffprobe
  if ($null -ne $r) {   # $null = "could not check" - never cached, never counted as a measurement
    $script:ProbeStats.Measured++
    Add-CoverageProbeLog $Path 'Bitmap' $r 'measured' (Get-Date -Format s)
  }
  return $r
}
function Test-CoverageHasAudioStream {
  param([Parameter(Mandatory)][string]$Path, [string]$ffprobe)
  $e = Get-CoverageProbeCacheEntry $Path
  if ($e -and $null -ne $e.Audio) {
    $script:ProbeStats.Reused++
    Add-CoverageProbeLog $Path 'Audio' $e.Audio 'cached' $e.ProbedAt
    return $e.Audio
  }
  $r = & $script:LibAudioProbe -Path $Path -ffprobe $ffprobe
  if ($null -ne $r) {
    $script:ProbeStats.Measured++
    Add-CoverageProbeLog $Path 'Audio' $r 'measured' (Get-Date -Format s)
  }
  return $r
}

# The cheap half of the incremental sweep: one recursive METADATA walk (names, sizes, write times -
# no file is opened) so every cache lookup can be validated against what is on the NAS right now.
# Scoped to the named works on a -Works run, so the publish loop's per-work call stays cheap.
function Get-CoverageFileMeta {
  param([string]$NasRoot, [string[]]$Works = @())
  $meta = @{}
  foreach ($area in 'Movies', 'Television Shows') {
    $areaRoot = Join-Path $NasRoot $area
    if (-not (Test-Path -LiteralPath $areaRoot)) { continue }
    $roots = if ($Works.Count -eq 0) { @($areaRoot) }
             else { @($Works | ForEach-Object { Join-Path $areaRoot $_ } | Where-Object { Test-Path -LiteralPath $_ }) }
    foreach ($root in $roots) {
      foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue) {
        $meta[$f.FullName.ToLowerInvariant()] = @{ Size = [long]$f.Length; Ticks = [long]$f.LastWriteTimeUtc.Ticks }
      }
    }
  }
  return $meta
}

function Test-HasAudioStream([string]$Path) {
  if (-not $ffprobe) { return $true }   # fail open: cannot disprove audio without ffprobe
  # Through the (cache-aware) shadow above, so the -Queue pass does not re-probe a file the
  # classification pass already answered.
  $a = Test-CoverageHasAudioStream -Path $Path -ffprobe $ffprobe
  if ($null -eq $a) { return $true }
  return [bool]$a
}
function Get-DurationSeconds([string]$Path) {
  if (-not $ffprobe) { return $null }
  $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 -- $Path 2>$null)".Trim()
  $sec = 0.0
  if ([double]::TryParse($d, [ref]$sec)) { return $sec }
  return $null
}

# Every "supersedes" path named across completed manifests - files ALREADY replaced by a verified
# newer encode (build-retire-list.ps1 lists them for the user to delete once verified there). OCR
# on one of these would be extracting real subtitle data from a file about to be retired - cheap,
# but pointless. Cleanly identifiable, so excluded rather than queued-anyway. This is the "high
# quality existing file" half of the user's 2026-09-03 wording resolved via evidence, not a guess:
# a manifest's own supersedes field names EXACTLY the files it replaces.
function Get-SupersededPathSet {
  param([string]$QueueDone = 'D:/video/_queue/done')
  $set = @{}
  if (-not (Test-Path -LiteralPath $QueueDone)) { return $set }
  foreach ($mf in Get-ChildItem -LiteralPath $QueueDone -Filter *.json -File -ErrorAction SilentlyContinue) {
    $items = $null
    try { $items = Get-Content -LiteralPath $mf.FullName -Raw | ConvertFrom-Json } catch { continue }
    foreach ($it in @($items)) {
      if (-not $it.supersedes) { continue }
      foreach ($s in @($it.supersedes)) {
        foreach ($p in ("$s" -split ';')) {
          $pp = $p.Trim()
          if ($pp) { $set[$pp.ToLowerInvariant()] = $true }
        }
      }
    }
  }
  return $set
}

# The OTHER half of "high quality existing file": a re-rip already IN FLIGHT (a manifest not yet
# completed) for the same work would ship its own subtitles shortly, making OCR of the CURRENT copy
# wasted work too. Checked directly against the queue folders lane-runner itself uses.
function Get-WorksWithInFlightManifest {
  param([string]$QueueRoot = 'D:/video/_queue')
  $works = New-Object System.Collections.Generic.HashSet[string]
  foreach ($sub in 'pending', 'running') {
    $dir = Join-Path $QueueRoot $sub
    if (-not (Test-Path -LiteralPath $dir)) { continue }
    foreach ($mf in Get-ChildItem -LiteralPath $dir -Filter *.json -File -ErrorAction SilentlyContinue) {
      $items = $null
      try { $items = Get-Content -LiteralPath $mf.FullName -Raw | ConvertFrom-Json } catch { continue }
      foreach ($it in @($items)) {
        if (-not $it.out) { continue }
        $rel = ("$($it.out)" -replace '\\', '/') -replace '^[Dd]:/video/(Movies|Television Shows)/([^/]+)/.*$', '$2'
        if ($rel) { [void]$works.Add($rel) }
      }
    }
  }
  # Also directly in _queue root - a manifest dropped but not yet claimed by lane-runner.
  foreach ($mf in Get-ChildItem -LiteralPath $QueueRoot -Filter *.json -File -ErrorAction SilentlyContinue) {
    $items = $null
    try { $items = Get-Content -LiteralPath $mf.FullName -Raw | ConvertFrom-Json } catch { continue }
    foreach ($it in @($items)) {
      if (-not $it.out) { continue }
      $rel = ("$($it.out)" -replace '\\', '/') -replace '^[Dd]:/video/(Movies|Television Shows)/([^/]+)/.*$', '$2'
      if ($rel) { [void]$works.Add($rel) }
    }
  }
  # `return ,$works` - the leading comma is LOAD-BEARING. A bare `return $works` lets PowerShell
  # UNROLL the HashSet onto the output stream; with the (normal, expected) case of ZERO in-flight
  # manifests that is zero objects, and `$x = SomeFunction` assigns $null when the function's
  # output stream carried nothing - not an empty HashSet. `$inFlightWorks.Contains(...)` then
  # throws "cannot call a method on a null-valued expression". Same defect class already fixed once
  # in this codebase (ocr-subtitles.ps1's Get-EnglishWordSet) - caught here by testing this
  # function standalone against the empty case, not assumed from reading it.
  return ,$works
}

Write-Output "=== subtitle-coverage $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  scope=$(if ($fullSweep) { 'FULL' } else { $Works -join ',' })  queue=$($Queue.IsPresent)  attached=$AttachedDrive ==="

$manifestIndex = Get-SubtitleCoverageManifestIndex
$naSet = Get-SubtitleCoverageNotApplicableSet -Csv $NaCsv
$discDriveIndex = Get-SubtitleCoverageDiscDriveIndex -Store $DiscIdentityStore
Write-Output "manifest-linked outputs: $($manifestIndex.Count)   not-applicable register: $($naSet.Count)   disc-identity discFolders: $($discDriveIndex.Count)"

$cacheMiss = Import-CoverageProbeCache -Csv $ReportCsv -Force:$Full
if ($cacheMiss) { Write-Output "probe cache: NOT USED - $cacheMiss - every no-sidecar file will be ffprobed this pass" }
else { Write-Output "probe cache: loaded $($script:ProbeStats.Loaded) probe entr(y/ies) from the previous report" }

$inv = Get-SubtitleCoverageInventory -NasRoot $NasRoot
if (-not $fullSweep) { $inv = @($inv | Where-Object { $Works -contains $_.Work }) }
Write-Output "media files in scope: $($inv.Count)"

$metaSw = [Diagnostics.Stopwatch]::StartNew()
$script:FileMeta = Get-CoverageFileMeta -NasRoot $NasRoot -Works $Works
Write-Output ("metadata walk: {0} file(s) in {1:N0}s (sizes + write times, no file opened)" -f $script:FileMeta.Count, $metaSw.Elapsed.TotalSeconds)

# GOVERNED, on a full sweep (lib-nas-governor.ps1, 2026-09-04). Measured that day: one no-sidecar
# file costs ~1.8 MB and ~0.3 s of ffprobe (2 MB even on a 13.7 GB film - headers, not the file),
# so an uncached full sweep of ~5,300 such files pulls ~9.5 GB in ~30 min (~40 Mbps) with the link
# to itself; the probe cache above makes the steady state far cheaper. What saturated the link was
# not this sweep alone but this sweep running UNGOVERNED beside the OCR queue's whole-file pulls
# (435-543 Mbps) with nothing arbitrating - it was three hours in at the forced reboot. So a full
# sweep now: (1) stands down under the kill switch; (2) holds the library-wide SWEEP mutex for its
# whole run - one sweep at a time across every process; (3) classifies in batches of 50 through
# Invoke-NasRead, which takes a shared read slot and paces each batch to the ceiling; (4) prints a
# progress line every 250 files - the heartbeat the coverage loop echoes live, so a running sweep
# can never again look like a dead loop.
# A SCOPED (-Works) run is deliberately NOT put through the sweep mutex or the read slots: the
# publish loop fires one after every work (36 files, 70 MB, 45 s measured) and queueing it behind
# a 30-minute sweep would recreate the publish stall the coverage track exists to prevent. It does
# still honour the kill switch.
$govSay = { param($m) Write-Output ("subtitle-coverage: {0}" -f $m) }
$sweepSlot = $null
if ($fullSweep) {
  [void](Wait-NasHold -Say $govSay -Who 'full sweep')
  $sweepSlot = Enter-NasSweep -Name 'subtitle-coverage full sweep' -Say $govSay -MaxWaitMinutes 30
  if ($null -eq $sweepSlot) {
    Write-Output 'REFUSING to run a second library-wide NAS sweep alongside the one already in flight - nothing written; the coverage track retries next pass'
    exit 3
  }
} else {
  [void](Wait-NasHold -Say $govSay -Who 'scoped run')
}

$results = [System.Collections.Generic.List[object]]::new()
$classifyBatch = {
  param($rows)
  foreach ($r in $rows) {
    $c = Get-SubtitleCoverageClassification -Row $r -ManifestIndex $manifestIndex -NaSet $naSet -ffprobe $ffprobe `
          -DiscDriveIndex $discDriveIndex -AttachedDrive $AttachedDrive
    $key  = $r.MkvPath.ToLowerInvariant()
    $meta = $script:FileMeta[$key]
    $log  = $script:ProbeLog[$key]
    $probeSource = if ($log) { $log.Source } elseif ($r.SrtPath) { 'not-needed' } elseif (-not $ffprobe) { 'unavailable' } else { 'not-needed' }
    $bitmapCol = if ($log -and $null -ne $log.Bitmap) { if ($log.Bitmap -eq '') { 'none' } else { "$($log.Bitmap)" } } else { '' }
    $audioCol  = if ($log -and $null -ne $log.Audio)  { if ($log.Audio) { 'yes' } else { 'no' } } else { '' }
    $results.Add([pscustomobject]@{
      Area = $r.Area; Work = $r.Work; Season = $r.Season; File = (Split-Path $r.MkvPath -Leaf)
      MkvPath = $r.MkvPath; Category = $c.Category; Ours = $c.Ours
      SubTrack = $c.SubTrack; SourceDrive = $c.SourceDrive; ManifestFile = $c.ManifestFile; Evidence = $c.Evidence
      # Probe-cache columns (header: INCREMENTAL BY DEFAULT). Appended AFTER the original columns so
      # any reader keyed on the old layout still finds what it always did.
      MkvSize = $(if ($meta) { $meta.Size } else { '' }); MkvWriteTicks = $(if ($meta) { $meta.Ticks } else { '' })
      BitmapProbe = $bitmapCol; AudioProbe = $audioCol; ProbeSource = $probeSource
      ProbedAt = $(if ($log) { $log.ProbedAt } else { '' }); CacheSchema = $script:ProbeCacheSchema
    })
  }
}
$sweepT0 = Get-Date
$classified = 0
$total = $inv.Count
$batchSize = 50
try {
  for ($start = 0; $start -lt $total; $start += $batchSize) {
    $end = [math]::Min($start + $batchSize, $total) - 1
    $chunk = @($inv[$start..$end])
    if ($fullSweep) {
      [void](Wait-NasHold -Say $govSay -Who 'full sweep')
      Invoke-NasRead -Path $chunk[0].MkvPath -Label 'full sweep' -Say $govSay -Do { & $classifyBatch $chunk } | Out-Null
    } else {
      & $classifyBatch $chunk | Out-Null
    }
    $classified += $chunk.Count
    if ($fullSweep -and (($classified % 250) -eq 0 -or $classified -eq $total)) {
      $elMin = ((Get-Date) - $sweepT0).TotalMinutes
      $eta = if ($classified -gt 0) { $elMin / $classified * ($total - $classified) } else { 0 }
      Write-Output ("progress: classified {0}/{1} ({2:N0}%) - {3:N0} min elapsed, ~{4:N0} min to go, {5} probe(s) measured, {6} reused" -f $classified, $total, (100.0 * $classified / [math]::Max($total, 1)), $elMin, $eta, $script:ProbeStats.Measured, $script:ProbeStats.Reused)
    }
  }
} finally {
  Exit-NasSweep $sweepSlot
}
$probeRows = @{ measured = 0; cached = 0; 'not-needed' = 0; unavailable = 0 }
foreach ($r in $results) { $probeRows[$r.ProbeSource] = 1 + [int]$probeRows[$r.ProbeSource] }
Write-Output ("probe cache: rows reused {0} (file unchanged, evidence carried forward), re-probed {1} (ffprobe ran), not needed {2} (sidecar present), unavailable {3}   |   ffprobe calls skipped {4}, run {5}" -f `
  $probeRows['cached'], $probeRows['measured'], $probeRows['not-needed'], $probeRows['unavailable'], $script:ProbeStats.Reused, $script:ProbeStats.Measured)
# Directory -> has any covered/stale-provenance sibling. Used only to ANNOTATE an awaiting-ocr row
# (does this look like a miss from an otherwise-finished batch, or ordinary untouched backlog) -
# never changes the category or the queueing action, since every bitmap file is queued for OCR
# either way (user, 2026-09-03). See the YOLT Storyboard Sequence case this was built for.
$dirHasCoveredSibling = @{}
foreach ($r in $results) {
  if ($r.Category -in @('covered', 'stale-provenance')) { $dirHasCoveredSibling[(Split-Path $r.MkvPath)] = $true }
}

if ($writeReport) {
  # Temp file then Move-Item, local D: only. The report is now also the NEXT run's probe cache, so
  # a run killed mid-write must not leave a truncated CSV in its place: a partial cache is merely
  # slower, but Export-Csv writing straight over the live file would first empty it.
  $tmpReport = "$ReportCsv.tmp"
  $results | Export-Csv -LiteralPath $tmpReport -NoTypeInformation -Encoding UTF8
  Move-Item -LiteralPath $tmpReport -Destination $ReportCsv -Force
  Write-Output ''
  Write-Output "=== SUMMARY -> $ReportCsv ==="
  $results | Group-Object Category, Ours | Sort-Object Count -Descending |
    ForEach-Object { "  {0,-45} {1}" -f $_.Name, $_.Count }

  $legacy = @($results | Where-Object { $_.Category -eq 'unclassified' -and -not $_.Ours })
  $legacyWorks = @($legacy | Group-Object Work)
  Write-Output ''
  Write-Output ("LEGACY BACKLOG (no manifest evidence, no bitmap stream, no current .srt): {0} file(s) across {1} work(s)" -f $legacy.Count, $legacyWorks.Count)
  Write-Output "  Different scope than follow-up.md's 842/86/83 (that was one source drive); never"
  Write-Output "  queued for transcription (no positive evidence the disc lacked subtitles)."

  $deferred = @($results | Where-Object { $_.Category -eq 'transcription-deferred' })
  if ($deferred.Count) {
    Write-Output ''
    Write-Output ("TRANSCRIPTION-DEFERRED (off attached drive '$AttachedDrive', or source drive unknown): {0} file(s)" -f $deferred.Count)
  }

  foreach ($cat in 'stale-provenance', 'genuinely-missed') {
    $rows = @($results | Where-Object { $_.Category -eq $cat -and $_.Ours })
    if ($rows.Count) {
      Write-Output ''
      Write-Output "=== $cat (ours) - $($rows.Count) file(s) ==="
      foreach ($r in $rows) { Write-Output ("  {0} / {1}" -f $r.Work, $r.File); Write-Output "      $($r.Evidence)" }
    }
  }
  $ocrRows = @($results | Where-Object { $_.Category -eq 'awaiting-ocr' })
  if ($ocrRows.Count) {
    Write-Output ''
    Write-Output "=== awaiting-ocr (library-wide, Ours and not) - $($ocrRows.Count) file(s) ==="
    foreach ($r in $ocrRows) {
      $miss = if ($dirHasCoveredSibling.ContainsKey((Split-Path $r.MkvPath))) { ' [siblings in this folder already have sidecars - looks like a MISS from that pass, not ordinary backlog]' } else { '' }
      Write-Output ("  {0} / {1}  (ours={2}){3}" -f $r.Work, $r.File, $r.Ours, $miss)
    }
  }
}

if (-not $Queue) {
  Write-Output ''
  Write-Output 'subtitle-coverage: report-only run (pass -Queue to also enqueue eligible files).'
  exit 0
}

# --- OCR QUEUE (library-wide) ------------------------------------------------------------------
$existingOcrQueue = @{}
if (Test-Path -LiteralPath $OcrQueueCsv) {
  Import-Csv -LiteralPath $OcrQueueCsv | ForEach-Object { $existingOcrQueue[$_.Path] = $true }
}
$ocrProgress = @{}
if (Test-Path -LiteralPath $OcrProgressCsv) {
  Import-Csv -LiteralPath $OcrProgressCsv | ForEach-Object { $ocrProgress[$_.Path] = $_.Result }
}
$supersededSet = Get-SupersededPathSet
$inFlightWorks = Get-WorksWithInFlightManifest
Write-Output ""
Write-Output ("superseded-path register: {0} entr(y/ies)   in-flight manifests name {1} work(s)" -f $supersededSet.Count, $inFlightWorks.Count)

$ocrCandidates = @($results | Where-Object { $_.Category -eq 'awaiting-ocr' })
$ocrQueued = New-Object System.Collections.Generic.List[object]
$ocrExcludedSuperseded = New-Object System.Collections.Generic.List[object]
$ocrExcludedInFlight = New-Object System.Collections.Generic.List[object]

foreach ($c in $ocrCandidates) {
  if ($existingOcrQueue.ContainsKey($c.MkvPath)) { continue }
  if ($ocrProgress.ContainsKey($c.MkvPath)) { continue }
  if ($supersededSet.ContainsKey($c.MkvPath.ToLowerInvariant())) { $ocrExcludedSuperseded.Add($c); continue }
  if ($inFlightWorks.Contains($c.Work)) { $ocrExcludedInFlight.Add($c); continue }

  $miss = $dirHasCoveredSibling.ContainsKey((Split-Path $c.MkvPath))
  $row = [ordered]@{
    Kind = $c.Area; Work = $c.Work; Season = $c.Season; Path = $c.MkvPath
    Ours = $c.Ours; LikelyMiss = $(if ($miss) { 'yes' } else { '' })
    Evidence = $c.Evidence
  }
  [pscustomobject]$row | Export-Csv -LiteralPath $OcrQueueCsv -Append -NoTypeInformation
  $existingOcrQueue[$c.MkvPath] = $true
  $ocrQueued.Add($c)
}
Write-Output ("OCR QUEUED: {0} file(s) -> {1}  (library-wide: ours={2}, legacy={3})" -f `
  $ocrQueued.Count, $OcrQueueCsv, @($ocrQueued | Where-Object Ours).Count, @($ocrQueued | Where-Object { -not $_.Ours }).Count)
foreach ($q in $ocrQueued) { Write-Output ("  + {0} / {1}" -f $q.Work, $q.File) }
if ($ocrExcludedSuperseded.Count) {
  Write-Output ("OCR EXCLUDED (already superseded per a manifest's own supersedes field - pending retirement): {0}" -f $ocrExcludedSuperseded.Count)
  foreach ($e in $ocrExcludedSuperseded) { Write-Output ("  - {0} / {1}" -f $e.Work, $e.File) }
}
if ($ocrExcludedInFlight.Count) {
  Write-Output ("OCR EXCLUDED (a re-rip for this work is currently in flight - its own subtitles are coming): {0}" -f $ocrExcludedInFlight.Count)
  foreach ($e in $ocrExcludedInFlight) { Write-Output ("  - {0} / {1}" -f $e.Work, $e.File) }
}

# --- TRANSCRIPTION QUEUE (narrowed: ours + attached drive only) --------------------------------
# Seeded from the CSV once via the SHARED table (lib-queue-guard.ps1) that Add-UniqueQueueRow then
# keeps current on every append below - the same table queue-transcribable.ps1 uses for its own
# inserts would need to be this one too for a true cross-script guard, but a rename-shaped
# duplicate (same file, different path) is out of reach for a path-keyed table regardless; that
# needs revalidate-queue.ps1's resolution step first. See lib-queue-guard.ps1's header.
$existingQueue = Get-QueueSeenTable -Csv $QueueCsv
$progress = @{}
if (Test-Path -LiteralPath $ProgressCsv) {
  Import-Csv -LiteralPath $ProgressCsv | ForEach-Object { $progress[$_.Path] = $_.Result }
}
$existingDeferred = @{}
if (Test-Path -LiteralPath $DeferredCsv) {
  Import-Csv -LiteralPath $DeferredCsv | ForEach-Object { $existingDeferred[$_.Path] = $true }
}

$candidates = @($results | Where-Object { $_.Category -eq 'awaiting-transcription' })
$queued = New-Object System.Collections.Generic.List[object]
$skippedTooShort = New-Object System.Collections.Generic.List[object]
$divertedNa = New-Object System.Collections.Generic.List[object]

# RECORD a classifier-level 'not-applicable' in the register too.
#
# The diversion further down only fires for a file that reached the enqueue stage, i.e. one the
# classifier called 'awaiting-transcription'. Since lib-subtitle-coverage.ps1 gained its own audio
# probe (2026-09-03), a video-only artefact is recognised EARLIER and never becomes a candidate -
# so without this block it would be classified correctly in the report and recorded NOWHERE.
# That would quietly defeat the register's stated purpose: queue-transcribable.ps1 keeps it
# "countable and visible on purpose: silence here is how 'we covered everything' gets claimed
# falsely." A correct classification that leaves no trace is exactly that silence.
$recordedNa = New-Object System.Collections.Generic.List[object]
foreach ($c in @($results | Where-Object { $_.Category -eq 'not-applicable' })) {
  if ($naSet.ContainsKey($c.MkvPath.ToLowerInvariant())) { continue }
  $recordedNa.Add($c)
  [pscustomobject]@{
    Kind = $c.Area; Work = $c.Work; Path = $c.MkvPath; Season = ''; Episode = ''
    Minutes = ''; DiscId = ''; DiscFolder = ''
    Reason = 'no audio stream (video-only artefact) - cannot be transcribed'
    Evidence = $c.Evidence; When = (Get-Date -Format s)
  } | Export-Csv -LiteralPath $NaCsv -Append -NoTypeInformation
  $naSet[$c.MkvPath.ToLowerInvariant()] = $true
}
if ($recordedNa.Count) {
  Write-Output ''
  Write-Output ("RECORDED NOT-APPLICABLE (video-only, probed directly): {0}" -f $recordedNa.Count)
  foreach ($d in $recordedNa) { Write-Output ("  ~ {0} / {1}" -f $d.Work, $d.File) }
}

foreach ($c in $candidates) {
  if ($existingQueue.ContainsKey((Get-QueueRowKey $c.MkvPath))) { continue }
  if ($progress.ContainsKey($c.MkvPath)) { continue }
  if ($naSet.ContainsKey($c.MkvPath.ToLowerInvariant())) { continue }

  if (-not (Test-HasAudioStream $c.MkvPath)) {
    $divertedNa.Add($c)
    [pscustomobject]@{
      Kind = $c.Area; Work = $c.Work; Path = $c.MkvPath; Season = ''; Episode = ''
      Minutes = ''; DiscId = ''; DiscFolder = ''
      Reason = 'no audio stream (video-only artefact) - cannot be transcribed'
      Evidence = $c.Evidence; When = (Get-Date -Format s)
    } | Export-Csv -LiteralPath $NaCsv -Append -NoTypeInformation
    $naSet[$c.MkvPath.ToLowerInvariant()] = $true
    continue
  }

  $sec = Get-DurationSeconds $c.MkvPath
  if ($sec -and $sec -lt $MinQueueSeconds) { $skippedTooShort.Add($c); continue }

  $ep = [regex]::Match($c.File, 'S(\d+)E(\d+)', 'IgnoreCase')
  $season = if ($ep.Success) { [int]$ep.Groups[1].Value } else { '' }
  $episode = if ($ep.Success) { [int]$ep.Groups[2].Value } else { '' }

  $row = [ordered]@{
    Kind = $c.Area; Work = $c.Work; Path = $c.MkvPath; Season = $season; Episode = $episode
    Minutes = $(if ($sec) { [math]::Round($sec / 60, 1) } else { '' })
    DiscId = ''; DiscFolder = ''; Evidence = $c.Evidence; Redo = ''
  }
  if (Add-UniqueQueueRow -Csv $QueueCsv -Row $row -SeenInRun $existingQueue) { $queued.Add($c) }
}

Write-Output ''
Write-Output ("TRANSCRIBE QUEUED: {0} file(s) -> {1}  (attached drive '{2}' only)" -f $queued.Count, $QueueCsv, $AttachedDrive)
foreach ($q in $queued) { Write-Output ("  + {0} / {1}" -f $q.Work, $q.File) }
if ($divertedNa.Count) {
  Write-Output ("DIVERTED TO NOT-APPLICABLE (no audio stream, newly discovered): {0}" -f $divertedNa.Count)
  foreach ($d in $divertedNa) { Write-Output ("  ~ {0} / {1}" -f $d.Work, $d.File) }
}
if ($skippedTooShort.Count) { Write-Output ("SKIPPED (under ${MinQueueSeconds}s floor): {0}" -f $skippedTooShort.Count) }

# --- REFILTER the existing transcribe queue --------------------------------------------------
if ($RefilterTranscribeQueue) {
  Write-Output ''
  Write-Output '--- re-filtering existing _transcribe-queue.csv against OCR-bitmap + attached-drive rules ---'
  if (-not (Test-Path -LiteralPath $QueueCsv)) {
    Write-Output "  nothing to refilter - $QueueCsv does not exist"
  } else {
    $byPath = @{}
    foreach ($r in $results) { $byPath[$r.MkvPath] = $r }
    $existingRows = @(Import-Csv -LiteralPath $QueueCsv)
    $kept = New-Object System.Collections.Generic.List[object]
    $movedToOcr = New-Object System.Collections.Generic.List[object]
    $deferredOffDrive = New-Object System.Collections.Generic.List[object]
    $removedOther = New-Object System.Collections.Generic.List[object]
    $notFound = New-Object System.Collections.Generic.List[object]

    foreach ($row in $existingRows) {
      $cur = $byPath[$row.Path]
      if (-not $cur) { $notFound.Add($row); $kept.Add($row); continue }   # can't verify - leave alone, don't guess
      switch ($cur.Category) {
        'awaiting-transcription' { $kept.Add($row) }
        'awaiting-ocr' {
          $movedToOcr.Add($cur)
          if (-not $existingOcrQueue.ContainsKey($row.Path) -and -not $ocrProgress.ContainsKey($row.Path)) {
            $miss = $dirHasCoveredSibling.ContainsKey((Split-Path $row.Path))
            [pscustomobject]@{
              Kind = $cur.Area; Work = $cur.Work; Season = $cur.Season; Path = $row.Path
              Ours = $cur.Ours; LikelyMiss = $(if ($miss) { 'yes' } else { '' })
              Evidence = "moved from the transcription queue on re-filter: $($cur.Evidence)"
            } | Export-Csv -LiteralPath $OcrQueueCsv -Append -NoTypeInformation
            $existingOcrQueue[$row.Path] = $true
          }
        }
        'transcription-deferred' {
          $deferredOffDrive.Add($cur)
          if (-not $existingDeferred.ContainsKey($row.Path)) {
            [pscustomobject]@{
              Kind = $cur.Area; Work = $cur.Work; Path = $row.Path
              SourceDrive = $cur.SourceDrive; AttachedDrive = $AttachedDrive
              Evidence = $cur.Evidence; DeferredOn = (Get-Date -Format s)
            } | Export-Csv -LiteralPath $DeferredCsv -Append -NoTypeInformation
            $existingDeferred[$row.Path] = $true
          }
        }
        default { $removedOther.Add([pscustomobject]@{ Row = $row; NewCategory = $cur.Category }) }
      }
    }

    # ATOMIC rewrite, local D: only: temp file then Move-Item over the original. Never edit the
    # live CSV in place mid-read - _transcribe-loop.ps1 polls it every 60s.
    #
    # REFUSE to silently empty a populated queue down to zero rows - same anti-shrink instinct
    # queue-transcribable.ps1 already applies elsewhere in this pipeline (a 0-row queue looks
    # exactly like "nothing left to do" and is the shape that costs most). This is a single-pass
    # re-filter, not expected to remove every row; if it would, that is loud and unresolved rather
    # than a silent no-op that leaves stale rows in place either way.
    $tmp = [IO.Path]::Combine([IO.Path]::GetDirectoryName($QueueCsv), '_transcribe-queue.refilter.tmp.csv')
    if ($kept.Count -gt 0) {
      $kept | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8
      Move-Item -LiteralPath $tmp -Destination $QueueCsv -Force
    } elseif ($existingRows.Count -gt 0) {
      Write-Output "  *** every row was removed or moved - REFUSING to overwrite $QueueCsv with an empty file. Investigate before re-running."
    }

    Write-Output ("  kept (still awaiting-transcription): {0}" -f $kept.Count)
    Write-Output ("  moved to OCR queue (bitmap stream found on direct probe): {0}" -f $movedToOcr.Count)
    foreach ($m in $movedToOcr) { Write-Output ("    -> {0} / {1}" -f $m.Work, $m.File) }
    Write-Output ("  deferred (off attached drive '$AttachedDrive' or unknown source drive): {0}" -f $deferredOffDrive.Count)
    foreach ($d in $deferredOffDrive) { Write-Output ("    -> {0} / {1}  source={2}" -f $d.Work, $d.File, $(if ($d.SourceDrive) { $d.SourceDrive } else { 'UNKNOWN' })) }
    if ($removedOther.Count) {
      Write-Output ("  removed (now resolved another way): {0}" -f $removedOther.Count)
      foreach ($o in $removedOther) { Write-Output ("    -> {0}  (now: {1})" -f $o.Row.Path, $o.NewCategory) }
    }
    if ($notFound.Count) {
      Write-Output ("  NOT RE-CHECKED (path not seen in this sweep's inventory - left in the queue as-is): {0}" -f $notFound.Count)
    }
  }
}

if ($IncludeLegacy) {
  if (Test-Path -LiteralPath $QueueTranscribableScript) {
    Write-Output ''
    Write-Output '--- -IncludeLegacy: also running queue-transcribable.ps1 for register-evidenced legacy TRANSCRIPTION candidates ---'
    & pwsh -NoProfile -File $QueueTranscribableScript -Out $QueueCsv -NotApplicable $NaCsv 2>&1 | ForEach-Object { "    $_" }
  } else {
    Write-Output "WARNING: -IncludeLegacy given but $QueueTranscribableScript not found"
  }
}

Write-Output ''
Write-Output 'SUBTITLE-COVERAGE DONE'
