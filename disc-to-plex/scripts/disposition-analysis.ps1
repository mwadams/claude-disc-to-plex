<#
.SYNOPSIS
  Turn ONE disc's evidence pack (disposition-evidence.ps1) into FINDINGS a disposition agent can
  audit and use directly: a verdict, a confidence, and the evidence that produced it - never a
  bare number and never a bare verdict.

.REACH FOR THIS WHEN
  A staged DVD is about to be dispositioned. Run this FIRST (it runs disposition-evidence.ps1 for
  you if the pack is missing or stale). Read the .txt; write the dispositions file from its
  findings; measure by hand only what a finding marks UNAVAILABLE or NEEDS JUDGEMENT.

.WHY THIS EXISTS
  disposition-evidence.ps1 gathers FACTS ONLY, by design - packet counts, IFO attribute tables,
  MakeMKV log lines, NAS probes, cell-set relations. That pack still made a disposition agent do
  all the INTERPRETING: is a zero-packet subtitle "not a source"? is a 49.76s title next to a
  "cells removed" log line "truncated"? is a shared sector set a "second door"? Those calls are
  deterministic - the same reasoning was done by hand, identically, on every disc dispositioned
  2026-09-04 (Don't Look Now, HMS Defiant, The League of Gentlemen S2D2, ...). This script does
  that reasoning once, in code, and cites the fact(s) it used for every verdict.

.RULES IT KEEPS
  - EVERY FINDING CARRIES THE EVIDENCE THAT PRODUCED IT. A bare verdict is as bad as a bare number.
  - EVERY FINDING CARRIES A CONFIDENCE. Genuinely ambiguous evidence gets verdict "NEEDS JUDGEMENT"
    with the competing readings stated - never a guessed pick.
  - A CHECK THAT COULD NOT RUN IS A FINDING WITH verdict UNAVAILABLE AND A REASON. Never omitted -
    "measured false" and "not measured" must stay distinguishable, all the way through.
  - No writes to _stage, _queue, the NAS, or any dispositions file. Writes ONLY to
    _catalogue/<unit>.analysis.{json,txt}. NAS reads happen only inside disposition-evidence.ps1
    (which governs them); this script does not read the NAS itself except via that pack.
  - Idempotent: skipped if the analysis file is newer than the evidence pack, unless -Force.
  - COMPOSES existing scripts; the only new measurement here is OCR of frames disposition-
    evidence.ps1 already carved (dvd-ifo-facts.py --classify), via a small tesseract helper - nothing
    here re-derives a packet count, an IFO fact, or a NAS probe that the pack already took.

.EXAMPLE
  pwsh -NoProfile -File disposition-analysis.ps1 -Unit "Don't Look Now"
  pwsh -NoProfile -File disposition-analysis.ps1 -Unit "HMS Defiant" -Correlate -Force
#>
param(
  [Parameter(Mandatory)][string]$Unit,
  [string]$Stage      = 'D:/video/_stage',
  [string]$Catalogue  = 'D:/video/_catalogue',
  [string]$DiscInfo   = 'D:/video/_disc-info',
  [string]$VideoRoot  = 'D:/video',
  [string]$NasRoot    = '\\NASTEAMV\Multimedia',
  [string]$Work = '',
  [ValidateSet('', 'Movies', 'Television Shows')][string]$Kind = '',
  [switch]$Force,
  [switch]$Correlate,
  [switch]$NoNas,
  [switch]$NoPlex,
  [switch]$NoOcr,             # skip the card-OCR pass over classified menu/title PGCs (faster re-runs)
  [int]$NasProbeMax = 40,
  [double]$CandidateWindowSec = 120,
  [double]$ExactMatchSec = 2.0,
  [int]$CorrelateOffsets = 3,
  [int]$CorrelateWindowSec = 20
)

$ErrorActionPreference = 'Continue'
$script:Sw = [Diagnostics.Stopwatch]::StartNew()
$script:Version = 'disposition-analysis/1'
$scriptsDir = $PSScriptRoot
$evidenceScript = Join-Path $scriptsDir 'disposition-evidence.ps1'
if (-not (Test-Path -LiteralPath $evidenceScript)) { Write-Output "FATAL: disposition-evidence.ps1 missing beside this script"; exit 1 }

$unit = $Unit
$outJson = Join-Path $Catalogue ($unit + '.analysis.json')
$outTxt  = Join-Path $Catalogue ($unit + '.analysis.txt')
$evJson  = Join-Path $Catalogue ($unit + '.evidence.json')
$toolPathsFile = Join-Path $VideoRoot '.transcode-tools/tool-paths.json'
$ffmpeg = $null; $tesseract = $null
if (Test-Path -LiteralPath $toolPathsFile) {
  $tp = Get-Content -LiteralPath $toolPathsFile -Raw | ConvertFrom-Json
  $ffmpeg = $tp.ffmpeg; $tesseract = $tp.tesseract
}

function Read-JsonFile([string]$path) {
  try { return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}

# ============================================================================ 1. GET THE EVIDENCE PACK
$evArgs = @('-NoProfile', '-File', $evidenceScript, '-Unit', $unit, '-Stage', $Stage, '-Catalogue', $Catalogue,
            '-DiscInfo', $DiscInfo, '-VideoRoot', $VideoRoot, '-NasRoot', $NasRoot,
            '-NasProbeMax', "$NasProbeMax", '-CandidateWindowSec', "$CandidateWindowSec", '-ExactMatchSec', "$ExactMatchSec",
            '-CorrelateOffsets', "$CorrelateOffsets", '-CorrelateWindowSec', "$CorrelateWindowSec")
if ($Work) { $evArgs += @('-Work', $Work) }
if ($Kind) { $evArgs += @('-Kind', $Kind) }
if ($Force) { $evArgs += '-Force' }
if ($Correlate) { $evArgs += '-Correlate' }
if ($NoNas) { $evArgs += '-NoNas' }
if ($NoPlex) { $evArgs += '-NoPlex' }
Write-Host ("[analysis] ensuring evidence pack: pwsh {0}" -f ($evArgs -join ' '))
& pwsh @evArgs | ForEach-Object { Write-Host ('[evidence] ' + $_) }
$evExit = $LASTEXITCODE
if (-not (Test-Path -LiteralPath $evJson)) {
  Write-Output ("FATAL: disposition-evidence.ps1 exit {0} and no {1} was produced" -f $evExit, $evJson)
  exit 1
}

# Idempotency: skip regenerating the ANALYSIS if it is newer than the evidence pack.
if (-not $Force -and (Test-Path -LiteralPath $outJson)) {
  $aTime = (Get-Item -LiteralPath $outJson).LastWriteTime
  $eTime = (Get-Item -LiteralPath $evJson).LastWriteTime
  if ($aTime -ge $eTime) {
    Write-Output ("CACHED: {0} (written {1}, evidence pack unchanged since); -Force to regenerate. Read: {2}" -f $outJson, $aTime.ToString('s'), $outTxt)
    exit 0
  }
}

$pack = Read-JsonFile $evJson
if (-not $pack) { Write-Output "FATAL: $evJson did not parse as JSON"; exit 1 }

# ============================================================================ 2. FINDINGS FRAMEWORK
$findings = [System.Collections.Generic.List[object]]::new()
function Add-Finding {
  param(
    [Parameter(Mandatory)][string]$Topic,
    [Parameter(Mandatory)][string]$Verdict,        # short caps verdict, e.g. REAL / NOT A SOURCE / TRUNCATED / GAIN AVAILABLE / NO GAIN / NEEDS JUDGEMENT / UNAVAILABLE
    [Parameter(Mandatory)][ValidateSet('HIGH', 'MEDIUM', 'LOW', 'NEEDS JUDGEMENT', 'UNAVAILABLE')][string]$Confidence,
    [Parameter(Mandatory)][string[]]$Evidence,      # the measurement(s) that produced the verdict, cite numbers
    [string]$Subject = '',                          # e.g. a dv/title id this finding is about
    [string]$Detail = '',                            # optional extra prose (competing readings for NEEDS JUDGEMENT)
    [string]$Reason = ''                              # required content when Confidence -eq UNAVAILABLE
  )
  $findings.Add([ordered]@{
      topic = $Topic; subject = $Subject; verdict = $Verdict; confidence = $Confidence
      evidence = @($Evidence); detail = $Detail; reason = $Reason
    }) | Out-Null
}

$ocrCache = @{}
function Invoke-CardOcr([string]$png) {
  # A small brightness-sweep + tesseract OCR of an ALREADY-CARVED still frame (dvd-ifo-facts.py
  # --classify wrote it; nothing here re-carves or re-decodes disc video). Same preprocessing
  # trick read-card.ps1 measured as necessary for text-over-picture: binarise luma, invert,
  # upscale, sweep thresholds brightest-first. Returns the longest card-like OCR text found, or
  # $null if nothing legible turned up at any threshold.
  if ($NoOcr) { return $null }
  if (-not $png -or -not (Test-Path -LiteralPath $png)) { return $null }
  if ($ocrCache.ContainsKey($png)) { return $ocrCache[$png] }
  if (-not $ffmpeg -or -not $tesseract -or -not (Test-Path -LiteralPath $tesseract)) { $ocrCache[$png] = $null; return $null }
  $best = $null; $bestLen = 0
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('card-ocr-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  try {
    foreach ($thr in @(225, 180, 140)) {
      $bin = Join-Path $tmp ('t{0}.png' -f $thr)
      & $ffmpeg -hide_banner -loglevel error -y -i $png -vf "format=gray,lutyuv=y='if(gt(val,$thr),0,255)',scale=iw*2:ih*2" -q:v 3 $bin 2>&1 | Out-Null
      if (-not (Test-Path -LiteralPath $bin)) { continue }
      $base = Join-Path $tmp ('t{0}' -f $thr)
      & $tesseract $bin $base --psm 6 -c tessedit_char_whitelist='ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .,-' 2>&1 | Out-Null
      $txtFile = "$base.txt"
      if (-not (Test-Path -LiteralPath $txtFile)) { continue }
      $txt = (Get-Content -LiteralPath $txtFile -Raw)
      if (-not $txt) { continue }
      $clean = (($txt -split "`r?`n" | Where-Object { $_.Trim().Length -ge 4 }) -join ' | ').Trim()
      if ($clean.Length -gt $bestLen) { $best = $clean; $bestLen = $clean.Length }
    }
  } finally { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  $ocrCache[$png] = $best
  return $best
}
function Normalize-Words([string]$s) {
  if (-not $s) { return @() }
  @(($s.ToLowerInvariant() -replace "[^a-z0-9 ]", ' ') -split '\s+' | Where-Object { $_.Length -ge 3 })
}

# ============================================================================ 3. SUBTITLES
$discNameClaims = @()
if ($pack.claims.mymovies.LocalTitle) { $discNameClaims += $pack.claims.mymovies.LocalTitle }
if ($pack.claims.nfo.title) { $discNameClaims += $pack.claims.nfo.title }
$discNameWords = @($discNameClaims | ForEach-Object { Normalize-Words $_ } | Sort-Object -Unique)

if (-not $pack.titles -or -not @($pack.titles).Count) {
  Add-Finding -Topic 'subtitles' -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() `
    -Reason 'pack.titles is empty - no per-title packet probe ran (see pack.unavailable for titles/*)'
} else {
  $anySubpDeclared = $false
  foreach ($t in @($pack.titles)) {
    $dv = $t.dvdvideoTitle
    $subpDeclared = 0
    if ($null -ne $t.ifoSubpDeclared) { try { $subpDeclared = @($t.ifoSubpDeclared).Count } catch { $subpDeclared = 0 } }
    $subStreams = @($t.streams | Where-Object { $_.type -eq 'subtitle' })
    if (-not $t.measured) {
      Add-Finding -Topic 'subtitles' -Subject "dv$dv" -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() -Reason $t.unavailable
      continue
    }
    if ($subStreams.Count -eq 0 -and $subpDeclared -eq 0) {
      Add-Finding -Topic 'subtitles' -Subject "dv$dv" -Verdict 'NONE DECLARED' -Confidence 'HIGH' `
        -Evidence @(("dv{0}: IFO declares 0 subpicture streams; ffprobe -f dvdvideo -title {0} exposes no subtitle stream" -f $dv))
      continue
    }
    $anySubpDeclared = $true
    $totalPkts = ($subStreams | ForEach-Object { [int]$_.packets } | Measure-Object -Sum).Sum
    if ($totalPkts -gt 0) {
      $langs = @($subStreams | Where-Object { $_.packets -gt 0 } | ForEach-Object { ('s:{0} {1}={2} pkts' -f $_.index, $(if ($_.lang) { $_.lang } else { '?' }), $_.packets) })
      Add-Finding -Topic 'subtitles' -Subject "dv$dv" -Verdict 'REAL' -Confidence 'HIGH' `
        -Evidence (@(("dv{0}: {1} declared subpicture stream(s), packet-walked - populated: {2}" -f $dv, $subStreams.Count, ($langs -join '; '))))
    } else {
      Add-Finding -Topic 'subtitles' -Subject "dv$dv" -Verdict 'NOT A SUBTITLE SOURCE' -Confidence 'HIGH' `
        -Evidence (@(("dv{0}: {1} declared subpicture stream(s) (available bit set), ffprobe -f dvdvideo -title {0} -count_packets walked the WHOLE title and every one emitted 0 packets" -f $dv, $subStreams.Count)))
    }
  }
  if (-not $anySubpDeclared) {
    Add-Finding -Topic 'subtitles' -Subject '(disc)' -Verdict 'NONE OFFERED — TRANSCRIPTION ONLY' -Confidence 'HIGH' `
      -Evidence @('nr_subp = 0 on every title probed on this disc - no VTS declares a subpicture stream; transcription is the only route to subtitles for anything published from this disc')
  }
}

# ============================================================================ 4. TRUNCATION
if ($pack.makemkvLog -and $pack.makemkvLog.titlesAdded) {
  $added = @($pack.makemkvLog.titlesAdded)
  $removed = @($pack.makemkvLog.cellsRemovedWarnings)
  foreach ($rw in $removed) {
    $mkTitleNo = $rw.afterTitleAdded
    if ($null -eq $mkTitleNo) { continue }
    $addRec = @($added | Where-Object { $_.makemkvTitleNumber -eq $mkTitleNo }) | Select-Object -Last 1
    if (-not $addRec) { continue }
    # Match this MakeMKV title number to a catalogue row / dv title to find the FULL duration.
    $catRow = @($pack.catalogue.rows | Where-Object { [int]$_.title -eq [int]$mkTitleNo }) | Select-Object -First 1
    $dv = $(if ($catRow) { $catRow.dvdvideoTitle } else { $null })
    $probe = $(if ($dv) { @($pack.titles | Where-Object { $_.dvdvideoTitle -eq $dv }) | Select-Object -First 1 } else { $null })
    $fullSec = $(if ($probe -and $probe.emittedSec) { [double]$probe.emittedSec } else { $null })
    $truncSec = $null
    if ($addRec.duration -match '^(\d+):(\d+):(\d+)') { $truncSec = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3] }
    if ($fullSec -and $truncSec -and $fullSec -gt $truncSec) {
      $pct = [math]::Round(100.0 * $truncSec / $fullSec, 1)
      # Is the truncated fragment what actually got published?
      $pubHit = $null
      if ($pack.library -and $pack.library.durationCandidates) {
        foreach ($row in @($pack.library.durationCandidates.rows)) {
          foreach ($c in @($row.candidates)) { if ([math]::Abs([double]$c.durationSec - $truncSec) -le 1.0) { $pubHit = $c; break } }
          if ($pubHit) { break }
        }
      }
      $ev = @(
        ("MakeMKV log: `"Title #{0} was added ({1})`" then `"{2}`"" -f $mkTitleNo, $addRec.duration, $rw.text),
        ("ffprobe -f dvdvideo -title {0} -count_packets (full walk, not the MakeMKV enumeration): {1:N2} s emitted" -f $dv, $fullSec)
      )
      if ($pubHit) { $ev += ("published NAS file duration {0:N3} s matches the TRUNCATED {1} s fragment, not the full {2:N2} s - {3}" -f $pubHit.durationSec, $truncSec, $fullSec, $pubHit.path) }
      Add-Finding -Topic 'truncation' -Subject "dv$dv (makemkv t$('{0:D2}' -f $mkTitleNo))" -Verdict 'TRUNCATED' -Confidence 'HIGH' -Evidence $ev `
        -Detail ("published/enumerated is {0}% of the full reel" -f $pct)
    }
  }
}
if (-not ($findings | Where-Object { $_.topic -eq 'truncation' })) {
  Add-Finding -Topic 'truncation' -Subject '(disc)' -Verdict 'NONE DETECTED' -Confidence 'MEDIUM' `
    -Evidence @('no "Cells N-M were removed from title end" warning in the MakeMKV log tied to a Title-added line (or no MakeMKV log at all)') `
    -Detail 'MEDIUM, not HIGH: this rule only catches MakeMKV cell-dedup truncation; a seam overshoot from a different cause (see check-cfr-frame-count.ps1) is not checked here'
}

# ============================================================================ 5. QUALITY (disc vs published)
if ($pack.library -and $pack.library.durationCandidates -and $pack.library.durationCandidates.rows) {
  foreach ($row in @($pack.library.durationCandidates.rows)) {
    $exact = @($row.candidates | Where-Object { $_.withinExact })
    if (-not $exact.Count) { continue }
    $cand = $exact[0]
    $probe = @($pack.library.nas.probes | Where-Object { $_.path -eq $cand.path }) | Select-Object -First 1
    $tp = @($pack.titles | Where-Object { $_.dvdvideoTitle -eq $row.dvdvideoTitle }) | Select-Object -First 1
    if (-not $probe -or -not $tp) {
      Add-Finding -Topic 'quality' -Subject ("dv{0} vs {1}" -f $row.dvdvideoTitle, $cand.path) -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() `
        -Reason 'exact-duration NAS candidate found but the disc title packet-probe or the NAS ffprobe did not run for it (see pack.unavailable)'
      continue
    }
    $vstream = @($tp.streams | Where-Object { $_.type -eq 'video' }) | Select-Object -First 1
    $nasVideo = @($probe.streams | Where-Object { $_.type -eq 'video' }) | Select-Object -First 1
    if (-not $vstream -or -not $nasVideo) { continue }
    $discW = [int]$vstream.width; $discH = [int]$vstream.height
    $nasW = $(if ($nasVideo.width) { [int]$nasVideo.width } else { 0 }); $nasH = $(if ($nasVideo.height) { [int]$nasVideo.height } else { 0 })
    $discBitrateMbps = $(if ($tp.cellBytes -and $tp.declaredSec) { [math]::Round(([double]$tp.cellBytes * 8 / [double]$tp.declaredSec) / 1e6, 2) } else { $null })
    $nasBitrateMbps = $(if ($probe.bitRate) { [math]::Round([double]$probe.bitRate / 1e6, 2) } else { $null })
    $sameDurationMs = [math]::Abs([double]$cand.deltaSec) -le 0.05
    $gain = ($discW -gt $nasW) -or ($discH -gt $nasH) -or ($discBitrateMbps -and $nasBitrateMbps -and $discBitrateMbps -gt ($nasBitrateMbps * 1.15))
    $ev = @(
      ("NAS {0}: {1}x{2} @ {3} Mb/s, {4:N3} s" -f (Split-Path $cand.path -Leaf), $nasW, $nasH, $(if ($nasBitrateMbps) { $nasBitrateMbps } else { '?' }), $cand.durationSec),
      ("disc dv{0}: {1}x{2} @ {3} Mb/s, {4:N2} s (delta {5:N3} s)" -f $row.dvdvideoTitle, $discW, $discH, $(if ($discBitrateMbps) { $discBitrateMbps } else { '?' }), $row.discSec, $cand.deltaSec)
    )
    if ($gain) {
      Add-Finding -Topic 'quality' -Subject ("dv{0} vs {1}" -f $row.dvdvideoTitle, (Split-Path $cand.path -Leaf)) -Verdict 'GAIN AVAILABLE' -Confidence 'HIGH' -Evidence $ev
    } elseif ($sameDurationMs) {
      Add-Finding -Topic 'quality' -Subject ("dv{0} vs {1}" -f $row.dvdvideoTitle, (Split-Path $cand.path -Leaf)) -Verdict 'NO GAIN — SAME ENCODE' -Confidence 'HIGH' -Evidence $ev
    } else {
      Add-Finding -Topic 'quality' -Subject ("dv{0} vs {1}" -f $row.dvdvideoTitle, (Split-Path $cand.path -Leaf)) -Verdict 'NEEDS JUDGEMENT' -Confidence 'NEEDS JUDGEMENT' -Evidence $ev `
        -Detail 'duration matches within the exact window but not to the millisecond, and resolution/bitrate do not clearly favour either side - could be a different pressing or a re-encode with different settings'
    }
  }
} else {
  Add-Finding -Topic 'quality' -Subject '(disc)' -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() `
    -Reason 'no NAS duration candidates - either the work was not resolved in the library, -NoNas was set, or nothing published is within the candidate window of any disc title'
}

# ============================================================================ 6. SECOND DOORS (identical cell sector sets)
if ($pack.ifo -and $pack.ifo.cellSetRelations) {
  $doors = @($pack.ifo.cellSetRelations | Where-Object { $_.relation -match 'second door|IDENTICAL' })
  if ($doors.Count) {
    foreach ($d in $doors) {
      Add-Finding -Topic 'second-door' -Subject ("VTS_{0:D2} titles {1}/{2}" -f $d.vtsn, $d.titleA, $d.titleB) -Verdict 'IDENTICAL SECTORS — SECOND DOOR' -Confidence 'HIGH' `
        -Evidence @(("VTS_{0:D2} title {1} and title {2}: {3} shared sectors of {4}/{5} - identical cell-sector sets (checked on SECTORS, never durations)" -f $d.vtsn, $d.titleA, $d.titleB, $d.sharedSectors, $d.sectorsA, $d.sectorsB))
    }
  } else {
    Add-Finding -Topic 'second-door' -Subject '(disc)' -Verdict 'NONE' -Confidence 'HIGH' `
      -Evidence @('dvd-ifo-facts.py cellSetRelations: no two TT_SRPT titles in any VTS share a sector - all enumerated titles are structurally disjoint')
  }
  $playAll = @($pack.ifo.pgcsNotReferencedByAnyTitle | Where-Object { $_.identicalToTitle -and @($_.identicalToTitle).Count -gt 0 })
  foreach ($p in $playAll) {
    Add-Finding -Topic 'second-door' -Subject ("VTS_{0:D2} PGC {1}" -f $p.vtsn, $p.pgc) -Verdict 'UNREFERENCED PGC, SAME CELLS AS AN ENUMERATED TITLE' -Confidence 'HIGH' `
      -Evidence @(("VTS_{0:D2} PGC {1} ({2:N2} s) is not the entry PGC of any TT_SRPT title but its cell set is identical to title {3}'s - a play-all or alternate-entry PGC covering already-enumerated content, not new material" -f $p.vtsn, $p.pgc, $p.playbackSec, ($p.identicalToTitle -join ',')))
  }
} else {
  Add-Finding -Topic 'second-door' -Subject '(disc)' -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() -Reason 'pack.ifo missing - dvd-ifo-facts.py did not run (see pack.unavailable.ifo)'
}

# ============================================================================ 7. ASPECT RATIO (IFO-declared, never from cells)
if ($pack.ifo -and $pack.ifo.vts) {
  $vtsProps = $pack.ifo.vts.PSObject.Properties
  foreach ($vp in $vtsProps) {
    $v = $vp.Value
    if ($v.error) { continue }
    $titleAsp = $(if ($v.videoAttr) { $v.videoAttr.aspect } else { $null })
    $menuAsp = $(if ($v.vtsmVideoAttr) { $v.vtsmVideoAttr.aspect } else { $null })
    if ($titleAsp) {
      Add-Finding -Topic 'aspect-ratio' -Subject ("VTS_{0} title domain" -f $vp.Name) -Verdict $titleAsp -Confidence 'HIGH' `
        -Evidence @(("VTS_{0}_0.IFO offset 0x200 (VTS video_attr, title domain): declares {1}" -f $vp.Name, $titleAsp))
    }
    if ($menuAsp -and $menuAsp -ne $titleAsp) {
      Add-Finding -Topic 'aspect-ratio' -Subject ("VTS_{0} menu domain" -f $vp.Name) -Verdict $menuAsp -Confidence 'HIGH' `
        -Evidence @(("VTS_{0}_0.IFO offset 0x100 (VTSM video_attr, menu domain): declares {1} — DIFFERENT from the title domain's {2}; do not inherit one for the other" -f $vp.Name, $menuAsp, $titleAsp))
    }
  }
  if ($pack.ifo.vmg -and $pack.ifo.vmg.vmgmVideoAttr -and $pack.ifo.vmg.vmgmVideoAttr.aspect) {
    Add-Finding -Topic 'aspect-ratio' -Subject 'VMGM' -Verdict $pack.ifo.vmg.vmgmVideoAttr.aspect -Confidence 'HIGH' `
      -Evidence @(("VIDEO_TS.IFO offset 0x100 (VMGM video_attr): declares {0}" -f $pack.ifo.vmg.vmgmVideoAttr.aspect))
  }
} else {
  Add-Finding -Topic 'aspect-ratio' -Subject '(disc)' -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() -Reason 'pack.ifo missing - dvd-ifo-facts.py did not run'
}

# ============================================================================ 8. BYTE PROOF (verbatim passthrough)
if ($pack.byteProof) {
  $bp = $pack.byteProof
  if ($null -ne $bp.textExit -and $bp.textExit -eq 0) {
    Add-Finding -Topic 'byte-proof' -Subject '(disc)' -Verdict 'PROVEN' -Confidence 'HIGH' -Evidence @($bp.textVerbatim) `
      -Detail 'prove-dvd-mapping.py exit 0 - every enumerated row proven by cell-sector byte totals, duration not consulted'
  } elseif ($null -ne $bp.textExit -and $bp.textExit -eq 2) {
    Add-Finding -Topic 'byte-proof' -Subject '(disc)' -Verdict 'PARTIAL — SEE PRECONDITION FAILURE' -Confidence 'NEEDS JUDGEMENT' -Evidence @($bp.textVerbatim) `
      -Detail 'prove-dvd-mapping.py exit 2 typically means a title with a second PTT failed the entry-PGC precondition for at least one row - read the verbatim output for which row and resolve by hand'
  } elseif ($null -ne $bp.textExit) {
    Add-Finding -Topic 'byte-proof' -Subject '(disc)' -Verdict 'FAILED' -Confidence 'HIGH' -Evidence @($bp.textVerbatim) `
      -Detail ("prove-dvd-mapping.py exit {0}" -f $bp.textExit)
  } else {
    Add-Finding -Topic 'byte-proof' -Subject '(disc)' -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() -Reason 'byteProof section did not run (see pack.unavailable.byteProof)'
  }
} else {
  Add-Finding -Topic 'byte-proof' -Subject '(disc)' -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() -Reason 'pack.byteProof missing'
}

# ============================================================================ 9. SUPERSEDES CANDIDATES
if ($pack.supersedes -and $pack.supersedes.candidates) {
  foreach ($c in @($pack.supersedes.candidates)) {
    if ($null -eq $c.path) {
      Add-Finding -Topic 'supersedes' -Subject $c.source -Verdict 'NO PATH NAMED' -Confidence 'MEDIUM' -Evidence @($c.text)
    } elseif ($c.exists -eq $true) {
      Add-Finding -Topic 'supersedes' -Subject $c.source -Verdict 'EXISTS — CANDIDATE TO SUPERSEDE' -Confidence 'HIGH' `
        -Evidence @(("{0}: Test-Path TRUE, {1} bytes, mtime {2}" -f $c.path, $c.bytes, $c.mtime))
    } elseif ($c.exists -eq $false) {
      Add-Finding -Topic 'supersedes' -Subject $c.source -Verdict 'DOES NOT EXIST' -Confidence 'HIGH' -Evidence @(("{0}: Test-Path FALSE - not a live supersedes target" -f $c.path))
    } else {
      Add-Finding -Topic 'supersedes' -Subject $c.source -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() -Reason ($c.note ? $c.note : 'existence not checked')
    }
  }
} else {
  Add-Finding -Topic 'supersedes' -Subject '(disc)' -Verdict 'NONE NAMED' -Confidence 'MEDIUM' -Evidence @('no supersedes candidate in the worklist row, the attribution audit, the identity register outputs[], or legacy non-.mkv media in the work folder')
}

# ============================================================================ 10. MENU DOMAIN (luma class + OCR of already-carved frames)
if ($pack.ifo -and $pack.ifo.classification -and $pack.ifo.classification.pgcs) {
  foreach ($p in @($pack.ifo.classification.pgcs)) {
    $subj = ("{0} VTS_{1:D2} PGC {2}" -f $p.domain, $p.vts, $p.pgc)
    if ($p.unavailable) {
      Add-Finding -Topic 'menu-domain' -Subject $subj -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() -Reason $p.unavailable
      continue
    }
    $lumaClass = $(if ($p.luma) { $p.luma.class } else { $null })
    if ($lumaClass -eq 'padding/black') {
      Add-Finding -Topic 'menu-domain' -Subject $subj -Verdict 'PADDING' -Confidence 'HIGH' `
        -Evidence @(("luma yMin={0} yMax={1} range={2} (< threshold {3}) over {4} frame(s), {5:N2} s" -f $p.luma.yMin, $p.luma.yMax, $p.luma.lumaRange, $pack.ifo.classification.lumaPaddingThreshold, $p.luma.frames, $p.playbackSec))
      continue
    }
    if ($lumaClass -eq 'content') {
      $ocrText = $null
      if ($p.firstFrame) { $ocrText = Invoke-CardOcr $p.firstFrame }
      $ev = @(("luma yMin={0} yMax={1} range={2} (>= threshold {3}) over {4} frame(s), {5:N2} s - not uniform black" -f $p.luma.yMin, $p.luma.yMax, $p.luma.lumaRange, $pack.ifo.classification.lumaPaddingThreshold, $p.luma.frames, $p.playbackSec))
      if ($ocrText) {
        $ev += ("OCR of {0}: `"{1}`"" -f (Split-Path $p.firstFrame -Leaf), $ocrText)
        $ocrWords = Normalize-Words $ocrText
        $matchesDisc = $discNameWords.Count -gt 0 -and (@($ocrWords | Where-Object { $discNameWords -contains $_ }).Count -gt 0)
        if ($discNameWords.Count -eq 0) {
          Add-Finding -Topic 'menu-domain' -Subject $subj -Verdict 'CONTENT' -Confidence 'NEEDS JUDGEMENT' -Evidence $ev `
            -Detail 'card OCR succeeded but there is no disc-claimed title (mymovies/nfo) to compare it against for boilerplate-vs-content'
        } else {
          Add-Finding -Topic 'menu-domain' -Subject $subj -Verdict 'CONTENT' -Confidence 'MEDIUM' -Evidence $ev `
            -Detail $(if ($matchesDisc) { 'OCR text shares a word with the disc''s own claimed title - consistent with in-programme content (menu page, chapter list, etc.)' } else { 'OCR text does NOT share a word with the disc''s own claimed title - read it: could be a different-programme promo/boilerplate, or simply a menu page (Scene Selection, credits) that never repeats the title' })
        }
      } else {
        Add-Finding -Topic 'menu-domain' -Subject $subj -Verdict 'CONTENT' -Confidence 'NEEDS JUDGEMENT' -Evidence $ev `
          -Detail 'not uniform black, so it is not padding, but OCR returned nothing legible at any threshold - read the frame/contact sheet by eye'
      }
      continue
    }
    Add-Finding -Topic 'menu-domain' -Subject $subj -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() -Reason 'luma classification did not run for this PGC'
  }
  if ($pack.ifo.classification.capped) {
    Add-Finding -Topic 'menu-domain' -Subject '(disc)' -Verdict 'PARTIAL — PGC LIST CAPPED' -Confidence 'NEEDS JUDGEMENT' -Evidence @() `
      -Detail ("{0} PGC(s) were jobs found but only {1} (maxPgcs) were classified - re-run dvd-ifo-facts.py --classify with a higher --max-pgcs to cover the rest" -f $pack.ifo.classification.jobsFound, $pack.ifo.classification.maxPgcs)
  }
} else {
  Add-Finding -Topic 'menu-domain' -Subject '(disc)' -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() -Reason 'pack.ifo.classification missing - dvd-ifo-facts.py --classify did not run (see pack.unavailable.ifo)'
}

# ============================================================================ 11. BOILERPLATE vs GENUINE (declared-but-uncatalogued / sub-floor titles)
# These are the SAME classified PGCs as menu-domain when domain=TITLE (dv titles below the 10s
# floor, or declared-but-not-enumerated by MakeMKV) - dvd-ifo-facts.py classified them because
# disposition-evidence.ps1 asked for --title-pgcs on exactly those. Re-key them here as their own
# topic so a reader does not have to infer "TITLE domain in menu-domain" means "boilerplate check".
if ($pack.ifo -and $pack.ifo.classification -and $pack.ifo.classification.pgcs) {
  $titlePgcs = @($pack.ifo.classification.pgcs | Where-Object { $_.domain -eq 'TITLE' })
  foreach ($p in $titlePgcs) {
    $subj = ("VTS_{0:D2} PGC {1} ({2:N2} s)" -f $p.vts, $p.pgc, $p.playbackSec)
    if ($p.unavailable) {
      Add-Finding -Topic 'boilerplate-vs-genuine' -Subject $subj -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() -Reason $p.unavailable
      continue
    }
    $lumaClass = $(if ($p.luma) { $p.luma.class } else { $null })
    if ($lumaClass -eq 'padding/black') {
      Add-Finding -Topic 'boilerplate-vs-genuine' -Subject $subj -Verdict 'PADDING / PLACEHOLDER — EXCLUDE' -Confidence 'HIGH' `
        -Evidence @(("luma yMin={0} yMax={1} range={2}, {3} frame(s) - uniform black, no picture, no audio content implied" -f $p.luma.yMin, $p.luma.yMax, $p.luma.lumaRange, $p.luma.frames))
      continue
    }
    $ocrText = $(if ($p.firstFrame) { Invoke-CardOcr $p.firstFrame } else { $null })
    if (-not $ocrText) {
      Add-Finding -Topic 'boilerplate-vs-genuine' -Subject $subj -Verdict 'NEEDS JUDGEMENT' -Confidence 'NEEDS JUDGEMENT' `
        -Evidence @(("not uniform black (luma range {0}); OCR returned nothing legible at thresholds 225/180/140" -f $p.luma.lumaRange)) `
        -Detail 'look at the frame/contact sheet by eye before excluding or keeping this title'
      continue
    }
    $ocrWords = Normalize-Words $ocrText
    $matchesDisc = $discNameWords.Count -gt 0 -and (@($ocrWords | Where-Object { $discNameWords -contains $_ }).Count -gt 0)
    $legalHints = @('prohibited', 'copyright', 'unauthorised', 'unauthorized', 'copying', 'recording', 'broadcasting', 'licence', 'license', 'warning', 'fbi')
    $looksLegal = @($ocrWords | Where-Object { $legalHints -contains $_ }).Count -gt 0
    if ($discNameWords.Count -gt 0 -and -not $matchesDisc -and -not $looksLegal -and $ocrWords.Count -ge 2) {
      Add-Finding -Topic 'boilerplate-vs-genuine' -Subject $subj -Verdict 'NEEDS JUDGEMENT — CARD NAMES A DIFFERENT TITLE?' -Confidence 'NEEDS JUDGEMENT' `
        -Evidence @(("OCR: `"{0}`"; disc's own claimed title: `"{1}`" - no shared word" -f $ocrText, ($discNameClaims -join ' / '))) `
        -Detail 'the signature of a promo for another release is a short title whose card names a DIFFERENT film - confirm by eye before excluding as boilerplate'
    } elseif ($looksLegal) {
      Add-Finding -Topic 'boilerplate-vs-genuine' -Subject $subj -Verdict 'BOILERPLATE — LEGAL/RIGHTS NOTICE' -Confidence 'MEDIUM' `
        -Evidence @(("OCR: `"{0}`" - contains legal/rights-notice vocabulary" -f $ocrText))
    } else {
      Add-Finding -Topic 'boilerplate-vs-genuine' -Subject $subj -Verdict 'NEEDS JUDGEMENT' -Confidence 'NEEDS JUDGEMENT' `
        -Evidence @(("OCR: `"{0}`"" -f $ocrText)) -Detail 'not clearly legal boilerplate and not clearly a match or mismatch against the disc''s own title - read it'
    }
  }
} else {
  Add-Finding -Topic 'boilerplate-vs-genuine' -Subject '(disc)' -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() -Reason 'pack.ifo.classification missing'
}

# ============================================================================ 12. EPISODE / CANDIDATE IDENTITY (audio envelope correlation)
if ($pack.correlate -and $pack.correlate.rows -and @($pack.correlate.rows).Count) {
  $byPair = @{}
  foreach ($r in @($pack.correlate.rows)) {
    if ($r.unavailable) { continue }
    $key = "$($r.dvdvideoTitle)|$($r.nasPath)"
    if (-not $byPair.ContainsKey($key)) { $byPair[$key] = [System.Collections.Generic.List[object]]::new() }
    $byPair[$key].Add($r)
  }
  $byTitle = @{}
  foreach ($k in $byPair.Keys) { $dv = $k.Split('|')[0]; if (-not $byTitle.ContainsKey($dv)) { $byTitle[$dv] = @() }; $byTitle[$dv] += $k }
  foreach ($dv in $byTitle.Keys) {
    $pairs = $byTitle[$dv] | ForEach-Object {
      $rows = $byPair[$_]
      $rVals = @($rows | ForEach-Object { $_.r } | Where-Object { $null -ne $_ })
      [ordered]@{ key = $_; nasPath = $rows[0].nasPath; n = $rows.Count; rMin = $(if ($rVals.Count) { ($rVals | Measure-Object -Minimum).Minimum } else { $null }); rMax = $(if ($rVals.Count) { ($rVals | Measure-Object -Maximum).Maximum } else { $null }); rAvg = $(if ($rVals.Count) { [math]::Round(($rVals | Measure-Object -Average).Average, 3) } else { $null }) }
    } | Sort-Object { -$_.rAvg }
    if (-not $pairs.Count) { continue }
    $winner = $pairs[0]
    $offDiag = @($pairs | Select-Object -Skip 1)
    $worstOffDiag = $(if ($offDiag.Count) { ($offDiag | ForEach-Object { $_.rMax } | Measure-Object -Maximum).Maximum } else { $null })
    $margin = $(if ($null -ne $worstOffDiag -and $null -ne $winner.rAvg) { [math]::Round($winner.rAvg - $worstOffDiag, 3) } else { $null })
    $ev = @(("winner: {0} r={1}-{2} (avg {3}) over {4} offset(s)" -f (Split-Path $winner.nasPath -Leaf), $winner.rMin, $winner.rMax, $winner.rAvg, $winner.n))
    foreach ($o in $offDiag) { $ev += ("off-diagonal: {0} r={1}-{2} (avg {3}) over {4} offset(s)" -f (Split-Path $o.nasPath -Leaf), $o.rMin, $o.rMax, $o.rAvg, $o.n) }
    if ($null -eq $margin) {
      Add-Finding -Topic 'episode-identity' -Subject "dv$dv" -Verdict 'CANDIDATE ONLY' -Confidence 'LOW' -Evidence $ev -Detail 'only one NAS candidate was correlated - nothing to compare it against'
    } elseif ($margin -ge 0.3 -and $winner.rAvg -ge 0.7) {
      Add-Finding -Topic 'episode-identity' -Subject "dv$dv" -Verdict ("CONFIDENT: {0}" -f (Split-Path $winner.nasPath -Leaf)) -Confidence 'HIGH' -Evidence $ev
    } elseif ($margin -ge 0.1 -and $winner.rAvg -ge 0.5) {
      Add-Finding -Topic 'episode-identity' -Subject "dv$dv" -Verdict ("LIKELY: {0}" -f (Split-Path $winner.nasPath -Leaf)) -Confidence 'MEDIUM' -Evidence $ev `
        -Detail 'diagonal wins but not by a wide margin - corroborate with a content check (frame/speech) before relying on this alone'
    } else {
      Add-Finding -Topic 'episode-identity' -Subject "dv$dv" -Verdict 'NEEDS JUDGEMENT' -Confidence 'NEEDS JUDGEMENT' -Evidence $ev `
        -Detail 'the correlation does not cleanly separate the winner from an off-diagonal candidate - competing readings stated above; resolve from content (frame/speech), not from this number alone'
    }
  }
} else {
  Add-Finding -Topic 'episode-identity' -Subject '(disc)' -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() `
    -Reason $(if ($pack.unavailable -and (@($pack.unavailable | Where-Object { $_.measurement -eq 'correlate' }).Count)) { (@($pack.unavailable | Where-Object { $_.measurement -eq 'correlate' })[0]).reason } else { 'no correlation rows in the evidence pack' })
}

# ============================================================================ 13. DECLARED vs ENUMERATED (accounting)
if ($pack.ifo -and $pack.ifo.vmg -and $pack.ifo.vmg.ttSrpt) {
  $declared = @($pack.ifo.vmg.ttSrpt | ForEach-Object { [int]$_.title })
  $enumerated = @($pack.catalogue.rows | ForEach-Object { $_.dvdvideoTitle } | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ })
  $missing = @($declared | Where-Object { $enumerated -notcontains $_ })
  if ($missing.Count) {
    Add-Finding -Topic 'accounting' -Subject '(disc)' -Verdict ("{0} DECLARED-BUT-UNENUMERATED TITLE(S)" -f $missing.Count) -Confidence 'HIGH' `
      -Evidence @(("VIDEO_TS.IFO TT_SRPT declares {0} titles: {1}. Catalogue enumerates {2}: {3}. Missing (need a dv line): {4}" -f $declared.Count, ($declared -join ','), $enumerated.Count, ($enumerated -join ','), ($missing -join ',')))
  } else {
    Add-Finding -Topic 'accounting' -Subject '(disc)' -Verdict 'ALL DECLARED TITLES ENUMERATED' -Confidence 'HIGH' `
      -Evidence @(("VIDEO_TS.IFO TT_SRPT declares {0} titles, catalogue enumerates all {1}" -f $declared.Count, $enumerated.Count))
  }
} else {
  Add-Finding -Topic 'accounting' -Subject '(disc)' -Verdict 'UNAVAILABLE' -Confidence 'UNAVAILABLE' -Evidence @() -Reason 'pack.ifo.vmg.ttSrpt missing'
}

# ============================================================================ CARRY FORWARD EVERY UNAVAILABLE FROM THE EVIDENCE PACK
# disposition-evidence.ps1's own UNAVAILABLE list names measurements this script never touched
# (e.g. NAS listing failures, Plex resolution failures) - carry every one forward as a finding so
# nothing silently disappears between the two files.
$coveredReasons = @($findings | Where-Object { $_.confidence -eq 'UNAVAILABLE' } | ForEach-Object { $_.reason })
foreach ($u in @($pack.unavailable)) {
  if ($coveredReasons -contains $u.reason) { continue }
  Add-Finding -Topic 'evidence-pack' -Subject $u.measurement -Verdict 'UNAVAILABLE (from evidence pack)' -Confidence 'UNAVAILABLE' -Evidence @() -Reason $u.reason
}

# ============================================================================ WRITE OUTPUT
$runtimeSec = [math]::Round($script:Sw.Elapsed.TotalSeconds, 1)
$doc = [ordered]@{
  schema = $script:Version; unit = $unit; generated = (Get-Date -Format 's')
  evidencePack = $evJson; evidencePackGenerated = $pack.meta.generated
  runtimeSeconds = $runtimeSec
  findingCounts = [ordered]@{
    total = $findings.Count
    byConfidence = ($findings | Group-Object confidence | ForEach-Object { [ordered]@{ confidence = $_.Name; count = $_.Count } })
    byTopic = ($findings | Group-Object topic | ForEach-Object { [ordered]@{ topic = $_.Name; count = $_.Count } })
    needsJudgement = @($findings | Where-Object { $_.confidence -eq 'NEEDS JUDGEMENT' }).Count
    unavailable = @($findings | Where-Object { $_.confidence -eq 'UNAVAILABLE' }).Count
  }
  findings = $findings
}
New-Item -ItemType Directory -Force -Path $Catalogue | Out-Null
$tmpJson = $outJson + '.tmp'
$doc | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $tmpJson -Encoding UTF8
Move-Item -LiteralPath $tmpJson -Destination $outJson -Force

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# $unit - disposition ANALYSIS (generated $($doc.generated) by disposition-analysis.ps1, runtime ${runtimeSec}s)")
$lines.Add("# evidence pack: $evJson (generated $($pack.meta.generated))")
$lines.Add("# $($findings.Count) findings: $($doc.findingCounts.needsJudgement) NEEDS JUDGEMENT, $($doc.findingCounts.unavailable) UNAVAILABLE")
$lines.Add("# Read this before measuring anything by hand. Every verdict below carries the evidence that produced it.")
$lines.Add('')
$byTopic = $findings | Group-Object topic
foreach ($grp in $byTopic) {
  $lines.Add(("=" * 40 + " " + $grp.Name.ToUpper()))
  foreach ($f in $grp.Group) {
    $subjTxt = $(if ($f.subject) { "[$($f.subject)] " } else { '' })
    $lines.Add(("- {0}{1}  (confidence: {2})" -f $subjTxt, $f.verdict, $f.confidence))
    foreach ($e in $f.evidence) { $lines.Add(("    evidence: {0}" -f $e)) }
    if ($f.detail) { $lines.Add(("    detail: {0}" -f $f.detail)) }
    if ($f.reason) { $lines.Add(("    reason: {0}" -f $f.reason)) }
  }
  $lines.Add('')
}
Set-Content -LiteralPath $outTxt -Value $lines -Encoding UTF8

Write-Output ("WROTE {0} findings ({1} NEEDS JUDGEMENT, {2} UNAVAILABLE) in {3}s -> {4}" -f $findings.Count, $doc.findingCounts.needsJudgement, $doc.findingCounts.unavailable, $runtimeSec, $outTxt)
exit 0
