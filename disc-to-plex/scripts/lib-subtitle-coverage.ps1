# Shared subtitle-coverage classification - the ONE place that decides, for a published NAS
# media file, whether its subtitle situation is:
#
#   covered              - a current (non-stale) .srt sidecar sits beside it
#   stale-provenance     - a .srt sidecar exists but PRE-DATES the .mkv it sits beside, i.e. it
#                           describes a source that has since been overwritten by a re-rip. This
#                           is reported, never auto-fixed: a re-rip that lands the SAME cut can
#                           leave the old transcript's timing still valid (confirmed by content,
#                           not assumed), and silently re-transcribing would throw that away for
#                           nothing. See references/gotchas.md 2026-09-03 Survivors S02E12.
#   not-applicable       - a video-only artefact (stills gallery, mute footage) with no audio to
#                           transcribe. Sourced from D:/video/_transcribe-not-applicable.csv,
#                           never re-derived here - that CSV is the one place this determination
#                           is made (queue-transcribable.ps1, _transcribe-loop.ps1's own re-check).
#   awaiting-ocr          - the PUBLISHED FILE ITSELF carries a bitmap subtitle stream (PGS/VOBSUB)
#                           and no sidecar yet. Checked by probing the file directly with ffprobe -
#                           NEVER inferred from a manifest field, and NEVER scoped to "ours": the
#                           user's own words (2026-09-03), after finding
#                           `You Only Live Twice (1967)/Featurettes/Storyboard Sequence - The Plane
#                           Crash.mkv` carrying an untouched `hdmv_pgs_subtitle` stream while every
#                           sibling in the same folder already had a sidecar - "if there is a PGS or
#                           VOBSUB stream in the published file then yes, it can be queued
#                           immediately for OCR... It does not matter whether the source disc is
#                           still available; the subtitle data is in the published file." This is
#                           the ONE category the manifest-vs-legacy ("ours") boundary does not
#                           apply to - OCR is queued for the WHOLE library, because the subtitle
#                           data already exists in the file and costs little to extract, unlike
#                           transcription's GPU/verification cost.
#   awaiting-transcription- the disc genuinely had no subtitle source (manifest subTrack:"none" or
#                           the omitted-subTrack inference below) AND the file was probed directly
#                           and carries no bitmap stream AND it is sourced from the CURRENTLY
#                           ATTACHED drive (see $AttachedDrive / Get-SubtitleCoverageDiscDriveIndex).
#                           A machine transcript is the only route -> eligible for the transcribe
#                           queue.
#   transcription-deferred - same evidence as awaiting-transcription EXCEPT the source drive is not
#                           the one currently attached (or is unknown). User's reasoning (2026-09-03):
#                           "a file from a drive we cannot currently read may well have subtitles on
#                           its disc that we simply have not seen yet. Transcribing it now spends GPU
#                           time and human verification effort on a machine transcript that a future
#                           re-rip will make redundant." NOT a failure and never recorded as one - it
#                           is a queued-when-the-drive-returns state, so a future pass does not have
#                           to re-derive the question.
#   genuinely-missed      - the manifest kept a real subtitle track (subTrack != "none") but the
#                           published file has NEITHER a sidecar NOR a bitmap stream: a subtitle
#                           source existed and shipping it failed somewhere. This must never be
#                           silently papered over with a machine transcript - it is a defect to
#                           surface, not to enqueue.
#   unclassified          - no manifest evidence links this NAS file to anything this pipeline
#                           produced (a legacy library file, or a gap in our own bookkeeping), AND
#                           it carries no bitmap stream (if it did, it would already be
#                           'awaiting-ocr' - see above, that category is checked first and applies
#                           library-wide). Reported honestly rather than guessed into a bucket:
#                           there is no positive evidence either way for these, so they are never
#                           queued for transcription (no proof the disc lacked subtitles) and there
#                           is nothing to OCR (no bitmap stream in the file).
#
# EVIDENCE SOURCES:
#  - D:/video/_queue/done/*.json - the manifests lane-runner has actually completed. Each item's
#    "out" is the Plex-named path it wrote; "subTrack" is a declaration made at manifest-authoring
#    time from the disc's own enumeration; "src" is used below to guess which disc folder produced
#    it, for the source-drive check.
#  - THE FILE ITSELF, via ffprobe, for the ONE question that determines both awaiting-ocr and the
#    negative half of awaiting-transcription/transcription-deferred: does the published file
#    currently carry a bitmap subtitle stream? A manifest's subTrack is a claim about the past; the
#    file is the authority on what it contains now. This was previously checked only for manifest-
#    linked ("ours") files that declared a kept subTrack - the user's 2026-09-03 finding showed that
#    under-covers the library, and it is now checked for every file that has no current sidecar,
#    regardless of manifest evidence.
#  - D:/video/.claude/skills/disc-to-plex/scripts' disc-identity register (\\NASTEAMV\Multimedia\
#    _disc-identity\*.json) for the source-drive check ONLY - its `outputs` link is too sparse to
#    use for the awaiting-ocr/transcription split itself (checked 2026-09-03: nearly all Survivors-
#    family records have outputs=[]), but every record's `discFolder` + `sourceDrive` pair is
#    populated, and a manifest's `src` can usually be matched back to one.
#
# "OURS" = a NAS path that appears as some manifest's "out". Anything else is pre-existing library
# content this pipeline has never touched. This boundary still gates TRANSCRIPTION (only a
# manifest's own subTrack declaration is positive evidence the disc had no subtitle source) but no
# longer gates OCR (a bitmap stream is its own evidence, found by looking at the file).

function Get-SubtitleCoverageManifestIndex {
  param(
    [string]$QueueDone = 'D:/video/_queue/done',
    [string]$NasRoot   = '\\NASTEAMV\Multimedia'
  )
  $index = @{}   # NAS path (lower) -> {subTrack, work, kind, src, manifestFile, manifestTime, localOut}
  if (-not (Test-Path -LiteralPath $QueueDone)) { return $index }
  foreach ($mf in Get-ChildItem -LiteralPath $QueueDone -Filter *.json -File -ErrorAction SilentlyContinue) {
    $items = $null
    try { $items = Get-Content -LiteralPath $mf.FullName -Raw | ConvertFrom-Json } catch { continue }
    foreach ($it in @($items)) {
      if (-not $it.out) { continue }
      $local = "$($it.out)" -replace '\\', '/'
      if ($local -notmatch '^[Dd]:/video/(.+)$') { continue }
      $rel = $Matches[1] -replace '/', '\'
      $nas = Join-Path $NasRoot $rel
      $key = $nas.ToLowerInvariant()
      # LATER MANIFEST WINS. A re-rip drops a new manifest with the same "out" (same Plex name,
      # publish-work.ps1 -Overwrite replaces in place) - see survivors-s2d3.json's own comment on
      # this exact pattern. The newer manifest describes what is actually on the NAS now.
      $prev = $index[$key]
      if ($prev -and $prev.manifestTime -gt $mf.LastWriteTimeUtc) { continue }
      $index[$key] = [pscustomobject]@{
        NasPath      = $nas
        SubTrack     = "$($it.subTrack)"
        Kind         = "$($it.kind)"
        Src          = "$($it.src)"
        ManifestFile = $mf.Name
        manifestTime = $mf.LastWriteTimeUtc
        LocalOut     = $it.out
      }
    }
  }
  return $index
}

function Get-SubtitleCoverageNotApplicableSet {
  param([string]$Csv = 'D:/video/_transcribe-not-applicable.csv')
  $set = @{}
  if (Test-Path -LiteralPath $Csv) {
    foreach ($r in Import-Csv -LiteralPath $Csv -ErrorAction SilentlyContinue) {
      if ($r.Path) { $set["$($r.Path)".ToLowerInvariant()] = $true }
    }
  }
  return $set
}

# discFolder (lower) -> sourceDrive, read once from the disc-identity register. Used ONLY to answer
# "is this manifest-linked file's disc on the CURRENTLY ATTACHED drive" - see
# Get-ManifestSourceDrive below for how a manifest item is matched into this table.
function Get-SubtitleCoverageDiscDriveIndex {
  param([string]$Store = ([IO.Path]::Combine('\\NASTEAMV', 'Multimedia', '_disc-identity')))
  $map = @{}
  if (-not (Test-Path -LiteralPath $Store)) { return $map }
  foreach ($f in Get-ChildItem -LiteralPath $Store -Filter *.json -File -ErrorAction SilentlyContinue |
                 Where-Object { $_.Name -ne '_index-by-output.json' }) {
    $rec = $null
    try { $rec = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    if ($rec.discFolder) { $map[$rec.discFolder.ToLowerInvariant()] = "$($rec.sourceDrive)" }
  }
  return $map
}

# Guess which disc folder produced a manifest item, from its own "src" + "kind" - the same two
# fields recorded in the manifest index above. EXACT match only against the disc-identity
# register's discFolder keys; no fuzzy matching, because a wrong attribution here would wrongly
# CLEAR a file for transcription that the register never actually vouched for.
#   DVD kind: "src" IS the disc folder itself (e.g. "D:/video/_stage/Survivors Series 2 Disk 3"),
#             so its own leaf name is the disc folder - this is the reliable case.
#   BD/MKV kind: "src" is a ripped file INSIDE a staging subfolder (e.g.
#             "D:/video/_stage/b5-s1d3-rip/C1_t00.mkv"), whose leaf ("b5-s1d3-rip") is a shorthand
#             the operator chose and routinely does NOT match the register's disc-title-style
#             folder name ("Babylon 5 Season 1 Disk 3") - this case mostly fails to match, and
#             correctly falls back to "unknown source drive" rather than guessing.
function Get-ManifestSourceDrive {
  param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][hashtable]$DiscDriveIndex)
  if (-not $Manifest.Src) { return $null }
  $src = $Manifest.Src -replace '\\', '/'
  $guess = if ($Manifest.Kind -eq 'DVD') { Split-Path $src -Leaf }
           else { Split-Path (Split-Path $src -Parent) -Leaf }
  if (-not $guess) { return $null }
  return $DiscDriveIndex[$guess.ToLowerInvariant()]
}

# Full NAS media inventory, ONE recursive pass per kind - the caller keeps this and never
# re-walks per file. Returns file objects for .mkv/.mp4/.m4v/.avi plus their sibling .srt files,
# indexed by directory so sidecar matching never re-lists a folder.
function Get-SubtitleCoverageInventory {
  param(
    [string]$NasRoot = '\\NASTEAMV\Multimedia',
    [string[]]$Areas = @('Movies', 'Television Shows')
  )
  $mediaExt = '.mkv', '.mp4', '.m4v', '.avi'
  $files = New-Object System.Collections.Generic.List[object]
  foreach ($area in $Areas) {
    $root = Join-Path $NasRoot $area
    if (-not (Test-Path -LiteralPath $root)) { continue }
    $all = Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue
    $byDir = $all | Group-Object DirectoryName -AsHashTable -AsString
    foreach ($f in $all) {
      if ($mediaExt -notcontains $f.Extension.ToLowerInvariant()) { continue }
      $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
      $siblings = @($byDir[$f.DirectoryName])
      $srt  = $siblings | Where-Object { $_.Extension -eq '.srt' -and $_.Name.StartsWith($stem) } |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
      $prov = $siblings | Where-Object { $_.Name -like "$stem*.provenance.json" } |
              Sort-Object LastWriteTime -Descending | Select-Object -First 1
      $relParts = $f.FullName.Substring($root.Length).TrimStart('\').Split('\')
      $work = $relParts[0]
      $season = if ($area -eq 'Television Shows' -and $relParts.Count -gt 2) { $relParts[1] } else { '' }
      $files.Add([pscustomobject]@{
        Area = $area; Work = $work; Season = $season
        MkvPath = $f.FullName; MkvWriteUtc = $f.LastWriteTimeUtc
        SrtPath = $(if ($srt) { $srt.FullName } else { $null })
        SrtWriteUtc = $(if ($srt) { $srt.LastWriteTimeUtc } else { $null })
        ProvPath = $(if ($prov) { $prov.FullName } else { $null })
        ProvWriteUtc = $(if ($prov) { $prov.LastWriteTimeUtc } else { $null })
      })
    }
  }
  # `return ,$files` for the same reason as Get-WorksWithInFlightManifest in subtitle-coverage.ps1:
  # List[object] is enumerable, so a bare `return $files` unrolls it and an EMPTY result becomes
  # $null rather than an empty list. Defensive here (every real call matches many files) but the
  # caller does not always wrap the result in @(), so this is the correct fix at the source.
  return ,$files
}

function Get-SrtLastCueEndSeconds {
  param([Parameter(Mandatory)][string]$SrtPath)
  try {
    $lines = Get-Content -LiteralPath $SrtPath -Encoding UTF8 -ErrorAction Stop
  } catch { return $null }
  $last = $lines | Select-String '\d\d:\d\d:\d\d,\d+ --> (\d\d):(\d\d):(\d\d),(\d+)' | Select-Object -Last 1
  if (-not $last) { return $null }
  $m = $last.Matches[0]
  return [double]$m.Groups[1].Value * 3600 + [double]$m.Groups[2].Value * 60 +
         [double]$m.Groups[3].Value + [double]$m.Groups[4].Value / 1000
}

# Probe the FILE ITSELF for a bitmap subtitle stream. This is the one ffprobe call every no-sidecar
# file now pays (previously only "ours + kept-subTrack" files did) - see the header comment on why
# that widening is deliberate and unavoidable: a manifest field is a claim, the file is the
# authority, and the whole point of this check is to route on what is ACTUALLY in the file.
function Test-BitmapSubtitleStream {
  param([Parameter(Mandatory)][string]$Path, [string]$ffprobe)
  if (-not $ffprobe -or -not (Test-Path -LiteralPath $ffprobe)) { return $null }   # $null = "could not check", never a guessed $false
  $codecs = & $ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 -- $Path 2>$null
  $hit = @($codecs | Where-Object { $_ }) -match 'dvd_subtitle|hdmv_pgs_subtitle|dvb_subtitle'
  if ($hit) { return $hit[0] }
  return ''   # empty string = "checked, none found" - distinct from $null ("could not check")
}

function Get-SubtitleCoverageClassification {
  param(
    [Parameter(Mandatory)]$Row,
    [Parameter(Mandatory)]$ManifestIndex,
    [Parameter(Mandatory)]$NaSet,
    [string]$ffprobe,
    # discFolder(lower) -> sourceDrive, from Get-SubtitleCoverageDiscDriveIndex. Omit to skip the
    # source-drive split entirely (every eligible file then reports 'awaiting-transcription' with
    # SourceDrive unknown) - used by callers that only care about the OCR half of this function.
    [hashtable]$DiscDriveIndex = @{},
    # The drive currently attached and readable, e.g. 'media2' - user-supplied fact (2026-09-03),
    # not auto-detected: every disc-identity record swept so far already carries sourceDrive
    # 'media2' (all 203 of them, checked 2026-09-03), so the register alone cannot distinguish
    # "attached" from "not" - it would need a record from a DIFFERENT drive to do that itself.
    [string]$AttachedDrive = 'media2',
    [int]$StaleToleranceSec = 60,
    # A stale-by-MTIME sidecar is not necessarily a WRONG one: a cosmetic re-publish (aspect-ratio
    # fix, audio-track fix) touches the .mkv's timestamp without changing its cut, and the old
    # transcript's timing still holds - Michael J. Fox Interview (Δ=4.5s) and Babylon 5 S01 (Δ=0.6s)
    # are exactly this. Only a duration MISMATCH between the current file and the sidecar's own
    # last cue means the sidecar describes a different cut. 180s tolerance covers a normal
    # trailing-credits tail a transcript legitimately never reaches (coverage < 100% is routine).
    [int]$DurationMismatchToleranceSec = 180
  )
  $key = $Row.MkvPath.ToLowerInvariant()
  $manifest = $ManifestIndex[$key]
  $isOurs = [bool]$manifest

  if ($Row.SrtPath) {
    $stale = $false
    if ($Row.SrtWriteUtc -and $Row.MkvWriteUtc) {
      $stale = ($Row.SrtWriteUtc - $Row.MkvWriteUtc).TotalSeconds -lt (-$StaleToleranceSec)
    }
    if (-not $stale) {
      return [pscustomobject]@{
        Category = 'covered'; Ours = $isOurs; Evidence = 'current .srt sidecar present'
        ManifestFile = $(if ($manifest) { $manifest.ManifestFile } else { $null })
        SubTrack = $(if ($manifest) { $manifest.SubTrack } else { $null }); SourceDrive = $null
      }
    }
    # STALE by mtime. Measure it, don't guess: does the sidecar's own timing still fit the file?
    $detail = 'duration check not available (ffprobe/srt unreadable) - verify by hand before trusting or discarding this sidecar'
    if ($ffprobe -and (Test-Path -LiteralPath $ffprobe)) {
      $dur = $null
      try { $dur = [double](& $ffprobe -v error -show_entries format=duration -of csv=p=0 -- $Row.MkvPath 2>$null) } catch { }
      $lastCue = Get-SrtLastCueEndSeconds -SrtPath $Row.SrtPath
      if ($dur -and $lastCue) {
        $gap = $dur - $lastCue
        if ([Math]::Abs($gap) -le $DurationMismatchToleranceSec) {
          $detail = "duration matches the current file (video {0:N0}s, last cue at {1:N0}s, {2:N0}s tail) - the re-publish looks cosmetic; timing is LIKELY STILL VALID but the provenance record now names a superseded source and should be regenerated" -f $dur, $lastCue, $gap
        } else {
          $detail = "DURATION MISMATCH: video is {0:N0}s, sidecar's last cue ends at {1:N0}s ({2:N0}s apart) - this sidecar almost certainly describes a DIFFERENT CUT; do not trust it without checking" -f $dur, $lastCue, $gap
        }
      }
    }
    return [pscustomobject]@{
      Category = 'stale-provenance'; Ours = $isOurs
      Evidence = "sidecar dated $($Row.SrtWriteUtc) predates the .mkv ($($Row.MkvWriteUtc)) - describes a superseded source. $detail"
      ManifestFile = $(if ($manifest) { $manifest.ManifestFile } else { $null })
      SubTrack = $(if ($manifest) { $manifest.SubTrack } else { $null }); SourceDrive = $null
    }
  }

  # No sidecar at all from here on. FIRST QUESTION, for every file regardless of manifest evidence:
  # does the file itself carry a bitmap subtitle stream right now? This is checked ahead of
  # not-applicable/ours/subTrack on purpose - a bitmap stream is real disc-authored subtitle data
  # sitting in the published file, independent of whether the file has an audio track (NA) or a
  # manifest link (ours), and it routes to OCR library-wide (user, 2026-09-03).
  $bitmap = Test-BitmapSubtitleStream -Path $Row.MkvPath -ffprobe $ffprobe
  if ($bitmap) {
    return [pscustomobject]@{
      Category = 'awaiting-ocr'; Ours = $isOurs
      Evidence = "bitmap subtitle stream ($bitmap) present in the published file, no sidecar yet$(if ($manifest) { " (manifest $($manifest.ManifestFile) subTrack:$($manifest.SubTrack))" } else { ' (no manifest evidence - checked directly on the file)' })"
      ManifestFile = $(if ($manifest) { $manifest.ManifestFile } else { $null })
      SubTrack = $(if ($manifest) { $manifest.SubTrack } else { $null }); SourceDrive = $null
    }
  }
  $bitmapChecked = ($null -ne $bitmap)   # $bitmap -eq '' means "checked, none found"; $null means "could not check"

  if ($NaSet.ContainsKey($Row.MkvPath.ToLowerInvariant())) {
    return [pscustomobject]@{
      Category = 'not-applicable'; Ours = $isOurs
      Evidence = 'listed in _transcribe-not-applicable.csv (no audio stream)'
      ManifestFile = $(if ($manifest) { $manifest.ManifestFile } else { $null })
      SubTrack = $(if ($manifest) { $manifest.SubTrack } else { $null }); SourceDrive = $null
    }
  }

  if (-not $isOurs) {
    return [pscustomobject]@{
      Category = 'unclassified'; Ours = $false
      Evidence = 'no manifest in _queue/done covers this path, and the file carries no bitmap subtitle stream - not something this pipeline is known to have produced, and there is no positive evidence the disc lacked subtitles, so this is never queued for transcription'
      ManifestFile = $null; SubTrack = $null; SourceDrive = $null
    }
  }

  # subTrack:'none', or an omitted subTrack that transcode.ps1's own logic proves is equivalent
  # (see the long comment further down) - either way, POSITIVE evidence the disc had no subtitle
  # source. Confirmed a moment ago the FILE also carries no bitmap - so the only remaining question
  # is whether this disc is one we can currently re-examine, i.e. whether transcribing now is safe
  # from being made redundant by a future re-rip.
  $subtrackOmitted = [string]::IsNullOrEmpty($manifest.SubTrack)
  $noSourceDeclared = ($manifest.SubTrack -eq 'none') -or $subtrackOmitted

  if ($noSourceDeclared -and -not $bitmapChecked) {
    return [pscustomobject]@{
      Category = 'unclassified'; Ours = $true
      Evidence = "manifest $($manifest.ManifestFile) declares subTrack:$($manifest.SubTrack) - could not confirm no bitmap stream (ffprobe unavailable), so this is left unclassified rather than assumed eligible"
      ManifestFile = $manifest.ManifestFile; SubTrack = $manifest.SubTrack; SourceDrive = $null
    }
  }

  if ($noSourceDeclared) {
    $sourceDrive = Get-ManifestSourceDrive -Manifest $manifest -DiscDriveIndex $DiscDriveIndex
    $attached = ($sourceDrive -and $sourceDrive -eq $AttachedDrive)
    $omitNote = if ($subtrackOmitted) {
      " (subTrack was OMITTED, not declared - INFERRED equivalent to 'none' because transcode.ps1 would have aborted to _queue/failed had the source carried an unmatched subtitle stream)"
    } else { '' }
    if ($attached) {
      return [pscustomobject]@{
        Category = 'awaiting-transcription'; Ours = $true
        Evidence = "manifest $($manifest.ManifestFile) declares subTrack:$($manifest.SubTrack)$omitNote - disc had no subtitle source, file confirmed to carry no bitmap stream, and its disc is on the currently attached drive ($AttachedDrive)"
        ManifestFile = $manifest.ManifestFile; SubTrack = $manifest.SubTrack; SourceDrive = $sourceDrive
      }
    }
    return [pscustomobject]@{
      Category = 'transcription-deferred'; Ours = $true
      Evidence = "manifest $($manifest.ManifestFile) declares subTrack:$($manifest.SubTrack)$omitNote - disc had no subtitle source and the file carries no bitmap stream, but its source drive is $(if ($sourceDrive) { "'$sourceDrive'" } else { 'UNKNOWN (no disc-identity record matched this manifest''s src)' }), not the currently attached '$AttachedDrive' - deferred, not queued, until that drive can be re-checked for subtitles we may not have seen"
      ManifestFile = $manifest.ManifestFile; SubTrack = $manifest.SubTrack; SourceDrive = $sourceDrive
    }
  }

  # subTrack explicitly declared a KEPT track (not 'none', not omitted) and the file has neither a
  # bitmap stream nor a sidecar: a real subtitle source existed and was not shipped.
  return [pscustomobject]@{
    Category = 'genuinely-missed'; Ours = $true
    Evidence = "manifest $($manifest.ManifestFile) declares subTrack:$($manifest.SubTrack) (a kept track) but the published file has NO subtitle stream and no sidecar - a real subtitle source was not shipped"
    ManifestFile = $manifest.ManifestFile; SubTrack = $manifest.SubTrack; SourceDrive = $null
  }
}
