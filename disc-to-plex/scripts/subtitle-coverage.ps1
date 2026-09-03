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

  USAGE
    pwsh -File subtitle-coverage.ps1                                   # full report, read-only
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

function Test-HasAudioStream([string]$Path) {
  if (-not $ffprobe) { return $true }   # fail open: cannot disprove audio without ffprobe
  $codecs = & $ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 -- $Path 2>$null
  return @($codecs | Where-Object { $_ }).Count -gt 0
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

$inv = Get-SubtitleCoverageInventory -NasRoot $NasRoot
if (-not $fullSweep) { $inv = @($inv | Where-Object { $Works -contains $_.Work }) }
Write-Output "media files in scope: $($inv.Count)"

$results = New-Object System.Collections.Generic.List[object]
foreach ($r in $inv) {
  $c = Get-SubtitleCoverageClassification -Row $r -ManifestIndex $manifestIndex -NaSet $naSet -ffprobe $ffprobe `
        -DiscDriveIndex $discDriveIndex -AttachedDrive $AttachedDrive
  $results.Add([pscustomobject]@{
    Area = $r.Area; Work = $r.Work; Season = $r.Season; File = (Split-Path $r.MkvPath -Leaf)
    MkvPath = $r.MkvPath; Category = $c.Category; Ours = $c.Ours
    SubTrack = $c.SubTrack; SourceDrive = $c.SourceDrive; ManifestFile = $c.ManifestFile; Evidence = $c.Evidence
  })
}
# Directory -> has any covered/stale-provenance sibling. Used only to ANNOTATE an awaiting-ocr row
# (does this look like a miss from an otherwise-finished batch, or ordinary untouched backlog) -
# never changes the category or the queueing action, since every bitmap file is queued for OCR
# either way (user, 2026-09-03). See the YOLT Storyboard Sequence case this was built for.
$dirHasCoveredSibling = @{}
foreach ($r in $results) {
  if ($r.Category -in @('covered', 'stale-provenance')) { $dirHasCoveredSibling[(Split-Path $r.MkvPath)] = $true }
}

if ($writeReport) {
  $results | Export-Csv -LiteralPath $ReportCsv -NoTypeInformation -Encoding UTF8
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
