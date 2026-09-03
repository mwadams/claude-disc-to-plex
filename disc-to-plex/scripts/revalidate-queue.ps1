<#
  Revalidate a path-keyed pipeline queue CSV against the CURRENT filesystem, and de-duplicate it.

  WHY THIS EXISTS (2026-09-03): nothing in this pipeline re-checks a queued PATH against a rename.
  Season 00 retitling is routine here (39 Danger Man items + 10 The Champions items renamed in one
  day), and every track that persists a path in a queue or register is exposed the same way - a
  queued row silently stops describing anything once its file is renamed. _transcribe-queue.csv
  held 12 such rows (of 29) the day this was written, 2 of them exact-duplicate PATHS inserted
  independently by two different enqueue routes with no shared identity check (see
  lib-queue-guard.ps1, which fixes the insertion side; this script is the drain-time / write-time
  check that catches renames the guard cannot).

  WHAT THIS DOES, per row:
    1. LIVE       - Test-Path succeeds. Left completely untouched - no re-probing, no re-ordering.
    2. Missing -> attempt RESOLUTION, evidence-based, never a name-similarity guess:
       a. The filename must carry a SxxEyy marker (Season 00 extras and numbered episodes both do,
          under this pipeline's own naming convention) - that number is the stable identity a
          rename-by-retitling preserves; only the descriptive title portion changes. No marker ->
          UNRESOLVABLE (reported, not guessed).
       b. Search the SAME parent directory (retitling does not move files between folders here)
          for exactly one current file whose name contains that SxxEyy tag. Zero or more-than-one
          match -> UNRESOLVABLE (ambiguity is refused, never picked from).
       c. If the row records Minutes, corroborate the candidate's ACTUAL duration (ffprobe) against
          it within tolerance. A mismatch means this candidate is almost certainly a different
          item that happens to share the tag - UNRESOLVABLE, not force-matched. Movies rows (no
          SxxEyy at all - a film title carries no episode slot) never reach this far; they fail (a)
          and report UNRESOLVABLE honestly rather than guessing from name similarity.
       d. A resolved candidate is then re-classified against what it ACTUALLY carries right now -
          the check is QueueType-specific, because "still needs the work" means something different
          per track (see -QueueType below):
          - a sidecar already exists                   -> RETIRE (covered - the work is already done)
          - [Transcribe only] a bitmap subtitle stream  -> RETIRE (belongs on the OCR queue instead -
                                                          this script never writes there; report it)
          - [Transcribe] no audio stream at all         -> RETIRE + divert to the not-applicable CSV
          - [OCR] no bitmap subtitle stream at all      -> RETIRE + divert to the not-applicable CSV
                                                          (nothing left to OCR - text subs, or the
                                                          disc's own stream is simply gone)
          - none of the above                          -> REPOINT: rewrite Path to the resolved
                                                          file, keep every other column, note the
                                                          resolution as evidence.
    3. DEDUPLICATE the surviving (Live + Repoint) rows by their EFFECTIVE current path
       (case-insensitive) - two rows that resolve to the same file collapse to one, with the
       dropped row(s) logged as RETIRE (duplicate-of).

  NEVER touches the NAS beyond reading it (Test-Path, ffprobe, dir listings). NEVER deletes or
  renames a file anywhere. The only write is the local D: queue CSV itself (plus, for a diverted
  na resolution, the local D: not-applicable CSV) - and only when -Apply is passed; without it this
  is a dry-run report.

  -QueueType Transcribe (default) | OCR - selects the reclassification rules in step 2d above and
  the not-applicable row's shape (see below). The SxxEyy+duration resolution engine (2a-2c) and the
  dedup pass (3) are identical either way - only "what does this file still need" differs.

  USAGE
    pwsh -File revalidate-queue.ps1 -Queue D:/video/_transcribe-queue.csv                                    # report only
    pwsh -File revalidate-queue.ps1 -Queue D:/video/_transcribe-queue.csv -Apply                              # write the cleaned CSV
    pwsh -File revalidate-queue.ps1 -Queue D:/video/_transcribe-queue.csv -Apply -ReportCsv D:/video/_queue-revalidation-report.csv
    pwsh -File revalidate-queue.ps1 -Queue D:/video/_ocr-queue.csv -QueueType OCR -Apply `
         -NotApplicableCsv D:/video/_ocr-queue-not-applicable.csv -ReportCsv D:/video/_ocr-queue-revalidation-report.csv

  REUSE: written against _transcribe-queue.csv's schema (Kind,Work,Path,Season,Episode,Minutes,
  DiscId,DiscFolder,Evidence,Redo) but every column beyond Path/Minutes is passed through
  unexamined, so it applies as-is to any CSV with a Path column and optionally a Minutes column -
  e.g. _transcribe-deferred.csv, or _ocr-queue.csv (Kind,Work,Season,Path,Ours,LikelyMiss,Evidence -
  no Minutes at all, so OCR resolutions currently rely on tag+uniqueness alone with no duration
  corroboration; state that plainly rather than silently pretending it happened). -QueueType OCR
  makes the schema-SPECIFIC parts (2d's reclassification, and the not-applicable row it writes)
  aware of _ocr-queue.csv's shape and ownership; the REPORT written to -ReportCsv is NOT append-only
  (Export-Csv overwrites), so two tracks must never be pointed at the same -ReportCsv path or each
  run destroys the other's evidence trail - give each queue its own file.
#>
param(
  [Parameter(Mandatory)][string]$Queue,
  [ValidateSet('Transcribe', 'OCR')][string]$QueueType = 'Transcribe',
  [string]$NotApplicableCsv = 'D:/video/_transcribe-not-applicable.csv',
  [string]$ReportCsv = '',
  [switch]$Apply,
  [double]$DurationToleranceMin = 0.2,
  [string]$ffprobe = ''
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-subtitle-coverage.ps1')
. (Join-Path $PSScriptRoot 'lib-queue-guard.ps1')

if (-not $ffprobe) {
  $toolPaths = 'D:/video/.transcode-tools/tool-paths.json'
  if (Test-Path -LiteralPath $toolPaths) {
    try {
      $ffprobe = Join-Path (Split-Path ((Get-Content -LiteralPath $toolPaths -Raw | ConvertFrom-Json).ffmpeg)) 'ffprobe.exe'
      if (-not (Test-Path -LiteralPath $ffprobe)) { $ffprobe = $null }
    } catch { $ffprobe = $null }
  }
}
if (-not $ffprobe) { Write-Output 'WARNING: ffprobe not found - duration corroboration and audio/subtitle checks on resolved candidates will be skipped, which makes every resolution UNRESOLVABLE rather than guessed.' }

function Test-HasAudioStreamRQ([string]$Path) {
  if (-not $ffprobe) { return $null }
  $codecs = & $ffprobe -v error -select_streams a -show_entries stream=codec_name -of csv=p=0 -- $Path 2>$null
  return (@($codecs | Where-Object { $_ }).Count -gt 0)
}
function Get-DurationMinutesRQ([string]$Path) {
  if (-not $ffprobe) { return $null }
  $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 -- $Path 2>$null)".Trim()
  $sec = 0.0
  if ([double]::TryParse($d, [ref]$sec)) { return [math]::Round($sec / 60, 1) }
  return $null
}

if (-not (Test-Path -LiteralPath $Queue)) { throw "queue not found: $Queue" }
$rows = @(Import-Csv -LiteralPath $Queue)
Write-Output "=== revalidate-queue $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  queue=$Queue  rows=$($rows.Count)  apply=$($Apply.IsPresent) ==="

$dispositions = New-Object System.Collections.Generic.List[object]   # one per ORIGINAL row

foreach ($row in $rows) {
  $path = "$($row.Path)"
  if (Test-Path -LiteralPath $path) {
    $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'live'; EffectivePath = $path; Reason = 'file exists at its recorded path - untouched' })
    continue
  }

  # --- resolution ---
  $dir = Split-Path $path -Parent
  if (-not (Test-Path -LiteralPath $dir)) {
    $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'retire'; EffectivePath = $path
      Reason = "UNRESOLVABLE: parent folder no longer exists: $dir" })
    continue
  }
  $leaf = Split-Path $path -Leaf
  $m = [regex]::Match($leaf, 'S(\d{1,2})E(\d{1,3})', 'IgnoreCase')
  if (-not $m.Success) {
    $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'retire'; EffectivePath = $path
      Reason = 'UNRESOLVABLE: filename carries no SxxEyy marker to anchor a search - cannot resolve without guessing from name similarity' })
    continue
  }
  $tag = 'S{0:D2}E{1:D2}' -f [int]$m.Groups[1].Value, [int]$m.Groups[2].Value
  # NOT filtered to '*.mkv' - that hardcoded filter made every renamed .mp4 row silently
  # UNRESOLVABLE regardless of how clean the rename was. Found 2026-09-03 testing -QueueType OCR
  # against a live .mp4 rip (A Horseman Riding By): the real renamed file sat right there in the
  # directory and the search still reported "no current file matches S01E01", because it was never
  # looking at .mp4 files at all. This queue is not transcribe-only any more - _ocr-queue.csv is
  # library-wide and 269 of its 1,767 rows (2026-09-03) are legacy .mp4 DVD rips - so the media
  # extension list has to match what Get-SubtitleCoverageInventory (lib-subtitle-coverage.ps1)
  # itself treats as media, not just this pipeline's own .mkv output.
  $mediaExt = '.mkv', '.mp4', '.m4v', '.avi'
  $candidates = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
    Where-Object { $mediaExt -contains $_.Extension.ToLowerInvariant() -and $_.Name -match [regex]::Escape($tag) })
  if ($candidates.Count -eq 0) {
    $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'retire'; EffectivePath = $path
      Reason = "UNRESOLVABLE: no current file in '$dir' matches $tag" })
    continue
  }
  if ($candidates.Count -gt 1) {
    $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'retire'; EffectivePath = $path
      Reason = "UNRESOLVABLE: AMBIGUOUS - $($candidates.Count) current files in '$dir' match $tag ($(($candidates.Name) -join '; ')) - refusing to guess" })
    continue
  }
  $cand = $candidates[0]

  # Duration is always fetched (not only when Minutes was recorded) so the eventual repoint/retire
  # message can always cite it, not just when corroboration was possible.
  $actualMin = Get-DurationMinutesRQ $cand.FullName
  if ("$($row.Minutes)") {
    $expect = 0.0
    if ([double]::TryParse("$($row.Minutes)", [ref]$expect)) {
      if ($null -eq $actualMin) {
        $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'retire'; EffectivePath = $path
          Reason = "UNRESOLVABLE: found candidate '$($cand.Name)' but could not verify its duration (ffprobe unavailable) against the queue's recorded $expect min - refusing to guess" })
        continue
      }
      if ([math]::Abs($actualMin - $expect) -gt $DurationToleranceMin) {
        $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'retire'; EffectivePath = $path
          Reason = "UNRESOLVABLE: candidate '$($cand.Name)' duration ${actualMin}m does not match the queue's recorded ${expect}m (tag $tag matched, content does not) - refusing to guess" })
        continue
      }
    }
  }

  # Candidate identity confirmed (tag + duration, when the row carries Minutes to check against).
  # Now ask what it ACTUALLY needs right now - the sidecar check is shared, everything after it is
  # QueueType-specific (see the header: "still needs the work" means a different thing per track).
  $stem = [IO.Path]::GetFileNameWithoutExtension($cand.Name)
  $hasSrt = @(Get-ChildItem -LiteralPath $dir -Filter "$stem*.srt" -File -ErrorAction SilentlyContinue).Count -gt 0
  if ($hasSrt) {
    $verb = if ($QueueType -eq 'OCR') { 'OCR' } else { 'transcription' }
    $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'retire'; EffectivePath = $cand.FullName
      Reason = "RESOLVED to '$($cand.Name)' (matched $tag, duration confirmed) but it already carries a .srt sidecar - already covered, no longer awaiting $verb" })
    continue
  }

  if ($QueueType -eq 'OCR') {
    # Inverted from Transcribe's check below: for THIS queue a bitmap stream is exactly what makes
    # the row still eligible, not a reason to retire it.
    $bitmap = if ($ffprobe) { Test-BitmapSubtitleStream -Path $cand.FullName -ffprobe $ffprobe } else { $null }
    if ($bitmap) {
      $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'repoint'; EffectivePath = $cand.FullName
        Reason = "RESOLVED to '$($cand.Name)' (matched $tag, duration confirmed $actualMin min, no sidecar, carries a bitmap subtitle stream ($bitmap)) - still eligible for OCR" })
      continue
    }
    if ($null -eq $bitmap) {
      $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'retire'; EffectivePath = $cand.FullName
        Reason = "RESOLVED to '$($cand.Name)' but could not verify its subtitle streams (ffprobe unavailable) - refusing to re-point blind" })
      continue
    }
    $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'retire-na'; EffectivePath = $cand.FullName
      Reason = "RESOLVED to '$($cand.Name)' (matched $tag, duration confirmed) but it carries no bitmap subtitle stream - nothing to OCR" })
    continue
  }

  # QueueType Transcribe (default) - unchanged from before -QueueType existed.
  $bitmap = if ($ffprobe) { Test-BitmapSubtitleStream -Path $cand.FullName -ffprobe $ffprobe } else { $null }
  if ($bitmap) {
    $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'retire'; EffectivePath = $cand.FullName
      Reason = "RESOLVED to '$($cand.Name)' but it carries a bitmap subtitle stream ($bitmap) - belongs on the OCR queue, not here (not written there by this script)" })
    continue
  }
  $hasAudio = Test-HasAudioStreamRQ $cand.FullName
  if ($hasAudio -eq $false) {
    $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'retire-na'; EffectivePath = $cand.FullName
      Reason = "RESOLVED to '$($cand.Name)' (matched $tag, duration confirmed) but it has no audio stream - video-only, cannot be transcribed" })
    continue
  }
  if ($null -eq $hasAudio) {
    $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'retire'; EffectivePath = $cand.FullName
      Reason = "RESOLVED to '$($cand.Name)' but could not verify it has an audio stream (ffprobe unavailable) - refusing to re-point blind" })
    continue
  }

  $dispositions.Add([pscustomobject]@{ Row = $row; Action = 'repoint'; EffectivePath = $cand.FullName
    Reason = "RESOLVED to '$($cand.Name)' (matched $tag, duration confirmed $actualMin min, no sidecar, no bitmap stream, has audio) - still eligible for transcription" })
}

# --- dedup the survivors (live + repoint) by effective path -------------------------------------
$seenEffective = @{}
$final = New-Object System.Collections.Generic.List[object]
foreach ($d in $dispositions) {
  if ($d.Action -notin @('live', 'repoint')) { continue }
  $key = Get-QueueRowKey $d.EffectivePath
  if ($seenEffective.ContainsKey($key)) {
    $d | Add-Member -NotePropertyName Action -NotePropertyValue 'retire-dup' -Force
    $d | Add-Member -NotePropertyName Reason -NotePropertyValue "DUPLICATE: another surviving row already resolves to '$($d.EffectivePath)' - dropped, not two rows for one file" -Force
    continue
  }
  $seenEffective[$key] = $true
  $final.Add($d)
}

# --- report ---------------------------------------------------------------------------------
Write-Output ''
Write-Output '=== per-row disposition ==='
foreach ($d in $dispositions) {
  $tag = if ($d.Action -eq 'live') { 'LIVE' }
         elseif ($d.Action -eq 'repoint') { 'REPOINT' }
         elseif ($d.Action -eq 'retire-dup') { 'RETIRE (duplicate)' }
         elseif ($d.Action -eq 'retire-na') { 'RETIRE (-> not-applicable)' }
         else { 'RETIRE' }
  Write-Output ("  [{0,-26}] {1}" -f $tag, (Split-Path $d.Row.Path -Leaf))
  Write-Output ("      {0}" -f $d.Reason)
}

$live = @($dispositions | Where-Object { $_.Action -eq 'live' })
$repointed = @($final | Where-Object { $_.Action -eq 'repoint' })
# $dispositions holds each row's FINAL action - the dedup pass above mutated retire-dup entries
# in place (same object references), so this reflects post-dedup reality, not a stale snapshot.
$retiredAll = @($dispositions | Where-Object { $_.Action -in @('retire', 'retire-na', 'retire-dup') })

Write-Output ''
Write-Output ("SUMMARY: {0} live, {1} repointed, {2} retired  ->  {3} row(s) in the revalidated queue" -f `
  $live.Count, $repointed.Count, $retiredAll.Count, $final.Count)

if ($ReportCsv) {
  $reportRows = foreach ($d in $dispositions) {
    [pscustomobject]@{
      OriginalPath = $d.Row.Path; Action = $d.Action; EffectivePath = $d.EffectivePath
      Reason = $d.Reason; When = (Get-Date -Format s)
    }
  }
  $reportRows | Export-Csv -LiteralPath $ReportCsv -NoTypeInformation -Encoding UTF8
  Write-Output "report written -> $ReportCsv"
}

if (-not $Apply) {
  Write-Output ''
  Write-Output 'DRY RUN - pass -Apply to write the revalidated queue and divert not-applicable rows.'
  exit 0
}

# --- divert no-audio resolutions to the not-applicable CSV, guarded against re-adding a path ---
$naRowsToAdd = @($dispositions | Where-Object { $_.Action -eq 'retire-na' })
if ($naRowsToAdd.Count) {
  $naSeen = Get-QueueSeenTable -Csv $NotApplicableCsv
  foreach ($d in $naRowsToAdd) {
    # Row SHAPE is QueueType-specific: _ocr-queue-not-applicable.csv has no Episode/Minutes/DiscId/
    # DiscFolder columns at all (_ocr-queue.csv never carried them to begin with), so building the
    # Transcribe shape unconditionally would write four columns of nothing into a CSV whose own
    # loop (_ocr-queue-loop.ps1's Write-NaRow) never puts anything there - harmless to Import-Csv
    # but a silent schema mismatch is exactly the kind of thing that looks fine until something
    # reads it expecting one shape and gets the other.
    if ($QueueType -eq 'OCR') {
      $naRow = [ordered]@{
        Kind = $d.Row.Kind; Work = $d.Row.Work; Path = $d.EffectivePath; Season = $d.Row.Season
        Reason = 'no bitmap subtitle stream (video-only, text-subtitled, or the disc stream is gone) - nothing to OCR'
        Evidence = "$($d.Row.Evidence); revalidate-queue.ps1: $($d.Reason)"
        When = (Get-Date -Format s)
      }
    } else {
      $naRow = [ordered]@{
        Kind = $d.Row.Kind; Work = $d.Row.Work; Path = $d.EffectivePath
        Season = $d.Row.Season; Episode = $d.Row.Episode; Minutes = $d.Row.Minutes
        DiscId = $d.Row.DiscId; DiscFolder = $d.Row.DiscFolder
        Reason = 'no audio stream (video-only artefact) - cannot be transcribed'
        Evidence = "$($d.Row.Evidence); revalidate-queue.ps1: $($d.Reason)"
        When = (Get-Date -Format s)
      }
    }
    [void](Add-UniqueQueueRow -Csv $NotApplicableCsv -Row $naRow -SeenInRun $naSeen)
  }
  Write-Output ("diverted {0} row(s) to not-applicable -> $NotApplicableCsv" -f $naRowsToAdd.Count)
}

# --- write the revalidated queue, atomically, local D: only -----------------------------------
# A REPOINT clones the ORIGINAL row's own columns (whatever schema this CSV happens to have -
# _transcribe-queue.csv and _transcribe-deferred.csv do not match) rather than rebuilding a
# hard-coded column set, so this stays genuinely reusable across queues instead of silently
# dropping a column a different queue relies on (e.g. _transcribe-deferred.csv's SourceDrive /
# AttachedDrive / DeferredOn have no equivalent in _transcribe-queue.csv's schema).
$outRows = foreach ($d in $final) {
  $r = $d.Row
  if ($d.Action -eq 'repoint') {
    $clone = [ordered]@{}
    foreach ($p in $r.PSObject.Properties) { $clone[$p.Name] = $p.Value }
    $clone['Path'] = $d.EffectivePath
    if ($clone.Contains('Evidence')) {
      $clone['Evidence'] = "$($clone['Evidence']); revalidate-queue.ps1 $(Get-Date -Format 'yyyy-MM-dd'): $($d.Reason)"
    }
    [pscustomobject]$clone
  } else {
    $r
  }
}

if ($final.Count -eq 0 -and $rows.Count -gt 0) {
  Write-Output ''
  Write-Output '*** every row was retired - REFUSING to overwrite the queue with an empty file. Investigate before re-running.'
  exit 2
}

$tmp = [IO.Path]::Combine([IO.Path]::GetDirectoryName($Queue), [IO.Path]::GetFileNameWithoutExtension($Queue) + '.revalidate.tmp.csv')
$outRows | Export-Csv -LiteralPath $tmp -NoTypeInformation -Encoding UTF8
Move-Item -LiteralPath $tmp -Destination $Queue -Force

Write-Output ''
Write-Output "REVALIDATED QUEUE WRITTEN -> $Queue ($($final.Count) row(s))"
