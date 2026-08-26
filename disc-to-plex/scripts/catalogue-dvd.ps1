# Sweep a DVD once and capture the CONTENT EVIDENCE needed to name its titles - the DVD equivalent
# of catalogue-disc.ps1, which only understands Blu-ray clips.
#
# WHY THIS EXISTS
# ---------------
# scan-disc.ps1 enumerates and classifies DVD titles, then prints "REVIEW titles are probable
# EXTRAS - extract a frame and decide". That is a PROSE instruction to a human standing in the
# middle of an automated pipeline, and prose instructions are what this pipeline keeps being
# bitten by. On Witness (2026-08-23) it meant hand-extracting frames for thirteen titles before
# anything could be named - the same manual pass the Blu-ray path stopped needing that morning.
#
# ffmpeg's `dvdvideo` demuxer reads these discs fine (proved on Witness), so the same evidence the
# Blu-ray sweep collects can be collected here:
#   - two sample frames per title (geometry-clamped, never past the end)
#   - a HEAD STRIP, the first 40 s at 1 fps, where title cards live
#   - a SPEECH SAMPLE, because cards are optional and speech is not
#
# TITLE NUMBERING - the trap this script also removes.
#   MakeMKV numbers DVD titles from 0; the dvdvideo demuxer numbers them from 1.
#   Verified on Witness: identical 16 titles, identical durations, offset by one.
#   This catalogue reports the MAKEMKV number, because that is what you rip with, and converts
#   internally when probing. Getting this backwards hands back the wrong title under a
#   right-looking name.
#
# ⚠ dvdvideo reads only a title's FIRST CELL on multi-cell titles, so a sample point deep into a
# long title can land short or black. Head-of-title evidence (cards, opening speech) is unaffected,
# which is what naming actually depends on. Do not use these frames to judge a title's LENGTH -
# MakeMKV's duration is the authority, and it is what this records.

param(
  [Parameter(Mandatory)][string]$Disc,
  [string]$OutDir = 'D:/video/_catalogue',
  [int]$MinLength = 10,
  [int[]]$FrameAt = @(30, 95),
  [int]$HeadSeconds = 40,
  [int]$SpeechSeconds = 45
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath (Join-Path $Disc 'VIDEO_TS'))) {
  throw "$Disc has no VIDEO_TS - this is the DVD sweep. Use catalogue-disc.ps1 for Blu-ray."
}

$discName = Split-Path $Disc -Leaf

# ---- PER-DISC LOCK + PER-RUN SCRATCH -----------------------------------------------------------
#
# WHY (2026-08-23, three concurrent catalogues). The speech wav used to be
#     Join-Path $env:TEMP ("cat-dvd-t{0:D3}.wav" -f $id)
# - keyed on the TITLE NUMBER ONLY. Concurrent runs on WITNESS, The Day the Earth Caught Fire and
# The Malta Story all wrote t011.wav to the SAME path and transcribed each other's audio: The Day
# the Earth Caught Fire's catalogue carries verbatim WITNESS trailer narration as its t11/t12
# speechSamples. This is the worst defect class in the project: not an ABSENCE but CONFIDENT
# WRONG EVIDENCE, attributed to the wrong disc, in the exact field used to NAME titles - and
# nothing downstream can tell a plausible foreign transcript from a real one. Same class as an
# Italian dub labelled "Audio Commentary", except the pipeline manufactured it itself.
#
# Two rules follow:
#   1. EVERY scratch path is unique per disc AND per run (PID + GUID - a stale file from a
#      crashed run with a recycled PID must also be impossible, hence the GUID directory).
#      Concurrency across DIFFERENT discs is explicitly supported; it is how batches run.
#   2. The SAME disc may be catalogued by only one run at a time (named mutex): a second
#      same-disc run would race the first on catalogue.json and the frames dir, and is
#      duplicate work at best - the analyze-tracks double-run showed that shape already.
$mutexName = 'Global\catalogue-' + ($discName -replace '[^\w\-\.]', '_')
$catalogueMutex = New-Object System.Threading.Mutex($false, $mutexName)
$mutexOwned = $false
try { $mutexOwned = $catalogueMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $mutexOwned = $true }  # holder died; the lock is ours
if (-not $mutexOwned) {
  Write-Output "*** another catalogue run already holds the lock for '$discName' - refusing to double-sweep."
  Write-Output "    Wait for it to finish (its catalogue.json is the artifact); this run produced NOTHING."
  exit 2
}
$runScratch = Join-Path $env:TEMP ("catalogue-dvd-{0}-{1}-{2}" -f `
                ($discName -replace '[^\w\-\.]', '_'), $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $runScratch | Out-Null

$paths    = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
$ff       = $paths.ffmpeg
$makemkv  = 'C:/Program Files (x86)/MakeMKV/makemkvcon64.exe'
$whisperPy = Join-Path $PSScriptRoot 'transcribe-wav.py'
if (-not (Test-Path -LiteralPath $whisperPy)) { $whisperPy = $null }

# Shared evidence classifiers (Resolve-TranscribeOutput), load VERIFIED - a dot-source of a bad
# path raises a NON-terminating error and the function is simply undefined.
$evidenceLib = Join-Path $PSScriptRoot 'lib-subtitles.ps1'
if (-not (Test-Path -LiteralPath $evidenceLib)) { throw "lib-subtitles.ps1 missing beside catalogue-dvd.ps1" }
. $evidenceLib
if (-not (Get-Command Resolve-TranscribeOutput -ErrorAction SilentlyContinue)) {
  throw 'lib-subtitles.ps1 loaded but Resolve-TranscribeOutput is not defined - refusing to sweep with unclassifiable speech evidence'
}

$frameDir = Join-Path $OutDir "$discName-frames"
New-Item -ItemType Directory -Force $OutDir, $frameDir | Out-Null

# ---- 1. ENUMERATE with MakeMKV, the authority on what a disc contains -------------------------
Write-Output "enumerating $discName (MakeMKV, minlength=$MinLength) ..."
$info = & $makemkv -r --cache=1 "--minlength=$MinLength" info "file:$Disc" 2>&1
$byId = @{}     # NOT $T/$t - PowerShell variables are CASE-INSENSITIVE and that pair collapses
foreach ($line in $info) {
  if ("$line" -match '^TINFO:(\d+),9,0,"([^"]+)"') {
    $id = [int]$Matches[1]
    $byId[$id] = [pscustomobject]@{
      # dvdvideoTitle starts UNKNOWN and is filled by the duration-matching in 1b. It must never
      # default to an arithmetic guess: `$id + 1` held on Witness and was WRONG on The Malta Story.
      title = $id; duration = $Matches[2]; dvdvideoTitle = $null
      mappingAmbiguous = $false; mappingTieSize = 0; mappingDeltaSec = $null
      width = $null; height = $null; frames = @(); headStrip = $null
      speechSample = $null; speechStatus = $null; speechFrom = $null; evidenceNote = $null; disposition = $null
    }
  }
}
if ($byId.Count -eq 0) { throw "MakeMKV enumerated no titles for $Disc" }
Write-Output "$($byId.Count) title(s)"

function Get-Seconds([string]$hms) {
  if ($hms -match '^(\d+):(\d\d):(\d\d)$') { return [int]$Matches[1]*3600 + [int]$Matches[2]*60 + [int]$Matches[3] }
  return 0
}

# Map MakeMKV titles onto dvdvideo titles by duration - DETERMINISTICALLY, with ties broken by
# ORDER and RECORDED as ambiguous.
#
# The first version picked the smallest delta and removed the winner from the pool, which is
# correct only when durations are unique. With ties the assignment fell out of hashtable
# iteration order: The Day the Earth Caught Fire carries FOUR 0:46 spots, and they mapped
# REVERSED (t08->12, t09->11, t10->10, t11->9) - arbitrary, changing run to run, and silent. The
# frames/speech recorded against t08 could therefore be dvdvideo title 9's content: the same
# "confident wrong evidence" class as the temp-file collision, narrower (it only scrambles
# equal-length titles among themselves) but fatal on a disc of equal-length episodes.
#
# Rules:
#   - Process MakeMKV ids in ASCENDING order; among candidates tied at the minimal delta, take
#     the LOWEST remaining dvdvideo index. Both enumerators walk the disc in authoring order, so
#     equal-duration groups map ascending-to-ascending - almost certainly correct, and stable.
#   - A mapping that involved ANY tie (several dvdvideo titles at the same delta, or several
#     MakeMKV titles wanting the same duration) is marked mappingAmbiguous with the tie size:
#     the evidence captured through it is POSITIONAL, not proven, and assert-accounted refuses
#     card:/frame:/speech: citations against such titles (corroborate from a rip instead).
function Resolve-DvdTitleMapping {
  param(
    [Parameter(Mandatory)][hashtable]$MkvSeconds,   # MakeMKV title id -> duration in seconds
    [Parameter(Mandatory)][hashtable]$DvdSeconds,   # dvdvideo title  -> duration in seconds
    [int]$ToleranceSec = 5
  )
  $remaining = @{}
  foreach ($k in $DvdSeconds.Keys) { $remaining[$k] = $DvdSeconds[$k] }
  $result = @{}
  foreach ($id in ($MkvSeconds.Keys | Sort-Object)) {
    $want = $MkvSeconds[$id]
    $entry = @{ dvdvideoTitle = $null; mappingAmbiguous = $false; mappingTieSize = 0; mappingDeltaSec = $null }
    # RELATIVE tolerance for long titles. The two enumerators genuinely disagree about long
    # PGCs: on The Day the Earth Caught Fire the FEATURE is MakeMKV 1:34:26 but dvdvideo title 1
    # reports 01:34:38 - a 12 s gap (libdvdnav counts the full cell chain; MakeMKV trims), so a
    # flat 5 s floor left the single biggest title on the disc unmatched and evidence-free.
    # 0.5% of runtime (28 s on a 94-minute feature, still 5 s under ~17 min) admits that
    # disagreement without loosening short-title matching, where the ties live. The accepted
    # delta is recorded (mappingDeltaSec) so a reader can see how hard the match was.
    $tol = [math]::Max($ToleranceSec, [int]($want * 0.005))
    $inTol = @($remaining.Keys | Where-Object { [math]::Abs($remaining[$_] - $want) -le $tol })
    if ($inTol.Count -gt 0) {
      $minDelta = ($inTol | ForEach-Object { [math]::Abs($remaining[$_] - $want) } | Measure-Object -Minimum).Minimum
      $tied = @($inTol | Where-Object { [math]::Abs($remaining[$_] - $want) -eq $minDelta } | Sort-Object)
      $entry.dvdvideoTitle = $tied[0]
      $entry.mappingDeltaSec = $minDelta
      # Ambiguity is judged against the FULL pools, not the shrinking one - by the time the last
      # of four tied titles is assigned it has only one candidate LEFT, but its mapping is no
      # less positional than its siblings'.
      $dvdTied = @($DvdSeconds.Keys | Where-Object { [math]::Abs($DvdSeconds[$_] - $want) -eq $minDelta }).Count
      $mkvTied = @($MkvSeconds.Keys | Where-Object { $MkvSeconds[$_] -eq $want }).Count
      if ($dvdTied -gt 1 -or $mkvTied -gt 1) {
        $entry.mappingAmbiguous = $true
        $entry.mappingTieSize = [math]::Max($dvdTied, $mkvTied)
      }
      $remaining.Remove($entry.dvdvideoTitle)
    }
    $result[$id] = $entry
  }

  # PAIRWISE SWAP CHECK - the greedy pass above is NOT an optimal assignment.
  #
  # Taking the per-title minimum, one title at a time, can pick a permutation that is no better
  # than its swap - and then report it as unambiguous, because at each individual step the minimum
  # was unique. The tie tests above only see EXACT ties on one title; they cannot see that the
  # TOTAL error is identical under a different pairing.
  #
  # Observed on `Out D1` (2026-08-26). MakeMKV 0:50:31 and 0:50:30 against dvdvideo titles of
  # 3035 s and 3032 s:
  #
  #     chosen : t01->3 (delta 1) + t02->2 (delta 5)  = 6
  #     swapped: t01->2 (delta 4) + t02->3 (delta 2)  = 6      <- identical
  #
  # The catalogue recorded the swapped-from-truth pairing with mappingAmbiguous=false, so its
  # frames and speech sample for t01 were actually dvdvideo title 3's content. A subagent caught it
  # only by falling back to MakeMKV's per-title SIZE (2.13 / 1.88 / 2.06 GiB), which is not close.
  # Had it trusted the flag, two episodes would have shipped swapped - structurally perfect,
  # content wrong, which is this project's most expensive failure shape.
  #
  # So: for every pair, ask whether exchanging their assignments leaves the total error equal or
  # lower. If it does, duration cannot separate them and BOTH are positional - flag them, which
  # makes assert-accounted refuse card:/frame:/speech: citations against them and forces
  # corroboration from a rip, a size, or the disc's own menu.
  $assigned = @($result.Keys | Where-Object { $null -ne $result[$_].dvdvideoTitle } | Sort-Object)
  foreach ($i in $assigned) {
    foreach ($j in $assigned) {
      if ($j -le $i) { continue }
      $ti = $result[$i].dvdvideoTitle; $tj = $result[$j].dvdvideoTitle
      $cur = [math]::Abs($DvdSeconds[$ti] - $MkvSeconds[$i]) + [math]::Abs($DvdSeconds[$tj] - $MkvSeconds[$j])
      $swp = [math]::Abs($DvdSeconds[$tj] - $MkvSeconds[$i]) + [math]::Abs($DvdSeconds[$ti] - $MkvSeconds[$j])
      if ($swp -le $cur) {
        foreach ($k in @($i, $j)) {
          $result[$k].mappingAmbiguous = $true
          if ($result[$k].mappingTieSize -lt 2) { $result[$k].mappingTieSize = 2 }
        }
        $why = if ($swp -lt $cur) { "STRICTLY BETTER ($swp vs $cur)" } else { "equal ($swp)" }
        # Write-HOST, never Write-Output. This function RETURNS a value, and Write-Output inside it
        # appends to that return - the caller then receives an array of [log strings + hashtable]
        # and indexes strings by integer, getting silent blanks for every field. Caught immediately
        # here only because the control case (well-separated durations) never reached this line and
        # so still worked, which is exactly how a bug like this survives a smoke test.
        Write-Host ("    t{0:00}/t{1:00} -> dvdvideo {2}/{3}: swapping them is {4} - duration cannot separate these two, marking BOTH ambiguous" -f `
                    $i, $j, $ti, $tj, $why)
      }
    }
  }
  return $result
}

# ---- 1b. MAP MakeMKV titles ONTO dvdvideo titles BY DURATION, never by index ------------------
#
# The offset is NOT a constant. On Witness the two enumerators listed the same 16 titles with a
# clean +1 offset, so `dvdvideoTitle = id + 1` looked like a rule. On The Malta Story MakeMKV's
# t00 is dvdvideo title 2 - the demuxer does not expose a title 1 at all - and the assumed +1
# probed the wrong title and produced frames=0, head=False, speech='' with NO error. A silent
# nothing is the worst possible failure here, because an empty catalogue still looks like a swept
# disc.
#
# So: ask the demuxer what it actually has, and match on runtime. Durations from the two tools
# agree to within a second or two on every disc tested.
Write-Output "mapping MakeMKV titles onto dvdvideo titles by duration ..."
$dvdDur = @{}
for ($cand = 1; $cand -le ($byId.Count + 6); $cand++) {
  $d = & $ff -hide_banner -f dvdvideo -title $cand -i $Disc -t 0.1 -f null - 2>&1
  $line = ($d | Select-String 'Duration:\s+(\d+):(\d\d):(\d\d)' | Select-Object -First 1)
  if ($line -and $line.Matches.Count -gt 0) {
    $m = $line.Matches[0]
    $dvdDur[$cand] = [int]$m.Groups[1].Value*3600 + [int]$m.Groups[2].Value*60 + [int]$m.Groups[3].Value
  }
}
$mkvSeconds = @{}
foreach ($id in $byId.Keys) { $mkvSeconds[$id] = Get-Seconds $byId[$id].duration }
$mapping = Resolve-DvdTitleMapping -MkvSeconds $mkvSeconds -DvdSeconds $dvdDur -ToleranceSec 5
foreach ($id in ($byId.Keys | Sort-Object)) {
  $m0 = $mapping[$id]
  $byId[$id].dvdvideoTitle    = $m0.dvdvideoTitle
  $byId[$id].mappingAmbiguous = $m0.mappingAmbiguous
  $byId[$id].mappingTieSize   = $m0.mappingTieSize
  $byId[$id].mappingDeltaSec  = $m0.mappingDeltaSec
  if ($null -eq $m0.dvdvideoTitle) {
    Write-Warning ("t{0:D2} ({1}): no dvdvideo title within 5s - NO evidence can be captured for it" -f $id, $byId[$id].duration)
  } elseif ($m0.mappingAmbiguous) {
    Write-Warning ("t{0:D2} ({1}): {2} equal-duration titles - mapped to dvdvideo {3} BY ORDER, not proven. Evidence below is positional; corroborate before citing card:/frame:/speech: against it." -f `
                   $id, $byId[$id].duration, $m0.mappingTieSize, $m0.dvdvideoTitle)
  }
}
$byId.Keys | Sort-Object | ForEach-Object {
  "  t{0:D2} {1,9} -> dvdvideo title {2}{3}" -f $_, $byId[$_].duration, $byId[$_].dvdvideoTitle,
    $(if ($byId[$_].mappingAmbiguous) { "  (AMBIGUOUS: tie of $($byId[$_].mappingTieSize), matched by order)" } else { '' })
}



# ---- 2. EVIDENCE per title --------------------------------------------------------------------
foreach ($id in ($byId.Keys | Sort-Object)) {
  $rec = $byId[$id]
  $dv  = $rec.dvdvideoTitle
  if ($null -eq $dv) {
    # Record WHY there is no evidence - an unmapped title and a failed probe are different
    # faults, and they used to look identical (empty fields, ordinary row, exit 0).
    $rec.evidenceNote = 'no dvdvideo title matched its duration - nothing was probed'
    Write-Output ("  t{0:D2} {1,9}  SKIPPED - no dvdvideo title matched its duration" -f $id, $rec.duration)
    continue
  }
  $dur = Get-Seconds $rec.duration
  $src = @('-f', 'dvdvideo', '-title', "$dv", '-i', $Disc)

  # sample frames, clamped so a short title never yields a black frame read as "nothing here"
  $points = @($FrameAt | Where-Object { $dur -eq 0 -or $_ -lt $dur * 0.95 })
  if (-not $points -and $dur -gt 0) { $points = @([math]::Max(1, [int]($dur * 0.25))) }
  foreach ($sec in $points) {
    $png = Join-Path $frameDir ("t{0:D3}-{1:D4}.png" -f $id, $sec)
    $vf = "yadif,scale=480:270:force_original_aspect_ratio=decrease,pad=480:270:(ow-iw)/2:(oh-ih)/2:black," +
          "drawtext=text='t$id @ ${sec}s':x=8:y=8:fontsize=22:fontcolor=yellow:box=1:boxcolor=black@0.7"
    & $ff -v error @src -ss $sec -frames:v 1 -vf $vf -y $png 2>$null
    if (Test-Path -LiteralPath $png) { $rec.frames += $png }
  }

  # head strip - title cards live in the first seconds and are gone by 30 s
  $headLen = if ($dur -gt 0 -and $dur -lt $HeadSeconds) { $dur } else { $HeadSeconds }
  $head = Join-Path $frameDir ("t{0:D3}-head.png" -f $id)
  $hvf = "fps=1,scale=300:169:force_original_aspect_ratio=decrease," +
         "pad=300:169:(ow-iw)/2:(oh-ih)/2:black,tile=8x5"
  & $ff -v error @src -t $headLen -vf $hvf -frames:v 1 -y $head 2>$null
  if (Test-Path -LiteralPath $head) { $rec.headStrip = $head }

  # speech - a card is optional, speech is not
  if ($whisperPy -and $dur -ge 30) {
    # INSIDE $runScratch, never a bare TEMP name: a title-number-only path is how three
    # concurrent catalogues transcribed each other's audio (see the lock block at the top).
    $wav = Join-Path $runScratch ("t{0:D3}.wav" -f $id)
    # STAY INSIDE THE FIRST CELL. dvdvideo reads only a title's first cell, so a sample point
    # chosen as a FRACTION of the runtime lands past the end on a long title and yields nothing:
    # on Witness the 1:47 feature returned speech=False at 15% (~16 min in) while every short title
    # succeeded. Sample early - dialogue starts early, and a fixed offset is inside cell one for
    # any title long enough to be worth transcribing.
    $at  = [int]([math]::Min(90, [math]::Max(5, $dur * 0.15)))
    # Provenance, recorded whether or not the transcription succeeds: WHICH disc, WHICH dvdvideo
    # title, WHERE in it, and the exact wav path used. After-the-fact audit of a suspect
    # speechSample starts here - the contamination above was only provable by cross-reading two
    # catalogues' texts, because nothing recorded where a sample had come from.
    $rec.speechFrom = ("disc={0}|dvdvideoTitle={1}|offset={2}s|wav={3}" -f $Disc, $dv, $at, $wav)
    & $ff -v error @src -ss $at -t $SpeechSeconds -map '0:a:0?' -ac 1 -ar 16000 -y $wav 2>$null
    if (Test-Path -LiteralPath $wav) {
      # stdout carries the transcriber's positive markers, stderr carries launcher failures as
      # ErrorRecords. `if ($txt)` used to record a FAILURE identically to "no speech" - see
      # Resolve-TranscribeOutput in lib-subtitles.ps1 and the transcribe-wav.py docstring.
      $raw  = & python $whisperPy $wav 2>&1
      $sOut = @($raw | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
      $sErr = @($raw | Where-Object { $_ -is  [System.Management.Automation.ErrorRecord] })
      $sp   = Resolve-TranscribeOutput -OutputLines $sOut
      $rec.speechStatus = $sp.Status
      if ($sp.Status -eq 'ok') { $rec.speechSample = $sp.Text }
      elseif ($sp.Status -eq 'failed') {
        $why = if ($sErr) { "$($sErr[0])" } else { $sp.Detail }
        Write-Warning ("t{0:D2}: speech sample FAILED - this is NOT 'no speech'; do not treat the gap as evidence. {1}" -f $id, $why)
      }
      Remove-Item -LiteralPath $wav -Force -ErrorAction SilentlyContinue
    } else {
      $rec.speechStatus = 'no-wav'
      Write-Warning ("t{0:D2}: no wav extracted (title has no audio stream, or extraction failed) - speech evidence is MISSING, not empty" -f $id)
    }
  }

  # ZERO EVIDENCE MUST NOT LOOK LIKE A SWEPT TITLE. On WITNESS_SCE_EN t07 came back frames=0,
  # head=False, speech=null and was logged as an ordinary row beside fifteen successes - the
  # catalogue.json recorded empty fields, the summary said "16 title(s)", and nothing anywhere
  # said one title was never actually seen. A title with no captured evidence is NOT catalogued;
  # it has merely been enumerated. Same defect class as an OCR failure recorded as "no text".
  if ($rec.frames.Count -eq 0 -and -not $rec.headStrip -and -not $rec.speechSample) {
    # Re-probe once WITHOUT discarding stderr, so the note can say what ffmpeg actually said -
    # the evidence captures above all run 2>$null and so cannot distinguish their failures.
    $probeSaid = (@(& $ff -v error @src -frames:v 1 -f null - 2>&1 | ForEach-Object { "$_" } |
                    Where-Object { $_ -match '\S' }) | Select-Object -First 2) -join ' '
    $rec.evidenceNote = ("probed dvdvideo title {0} and captured NOTHING - {1}" -f $dv,
                         $(if ($probeSaid) { "ffmpeg: $probeSaid" } else { 'ffmpeg reported no error, yet frames, head strip and speech are all empty' }))
    Write-Warning ("t{0:D2} ({1}): NO EVIDENCE CAPTURED - this title has been enumerated, not catalogued. {2}" -f $id, $rec.duration, $rec.evidenceNote)
  }
  Write-Output ("  t{0:D2} {1,9}  frames={2} head={3} speech={4}{5}" -f $id, $rec.duration,
                $rec.frames.Count, [bool]$rec.headStrip, $(if ($rec.speechStatus) { $rec.speechStatus } else { 'skipped' }),
                $(if ($rec.evidenceNote) { '  <<< NO EVIDENCE' } else { '' }))
}

# ---- 3. CONTACT SHEETS ------------------------------------------------------------------------
$all = @($byId.Keys | Sort-Object | ForEach-Object { $byId[$_].frames } | Where-Object { $_ })
if ($all.Count -gt 0) {
  # Inside $runScratch: the old per-DISC name ("dvdcat-$discName") was safe across discs but not
  # across two runs of the same disc - and per-run uniqueness costs nothing now the lock exists.
  $seqDir = Join-Path $runScratch 'sheet-seq'
  New-Item -ItemType Directory -Force $seqDir | Out-Null
  $i = 0
  foreach ($f in $all) { Copy-Item -LiteralPath $f -Destination (Join-Path $seqDir ("f{0:D3}.png" -f $i)); $i++ }
  $per = 16; $sheet = 1
  for ($start = 0; $start -lt $all.Count; $start += $per) {
    $outPng = Join-Path $OutDir "$discName-sheet$sheet.png"
    & $ff -v error -framerate 1 -start_number $start -i (Join-Path $seqDir 'f%03d.png') `
          -frames:v 1 -vf "tile=4x4" -y $outPng 2>$null
    $sheet++
  }
}
# Whole per-run scratch goes at once (speech wavs are already deleted per-title; this catches
# anything a failure left behind). The mutex releases itself when the process exits.
Remove-Item -LiteralPath $runScratch -Recurse -Force -ErrorAction SilentlyContinue

# ---- 4. CATALOGUE ------------------------------------------------------------------------------
# WAS THE COPY VERIFIED WHEN THIS RAN?
#
# catalogue-disc.ps1 stamps `sourceVerified` for Blu-rays, and assert-accounted.ps1 refuses a
# catalogue swept from an unverified copy - because a short enumeration shifts TITLE NUMBERING and
# makes every disposition point at the wrong title. That is not a theoretical risk: it produced a
# 26-title catalogue of a 51-title disc on 2026-08-23.
#
# This script never stamped it. The gate tolerates an ABSENT field as "an older catalogue", so the
# guard was silently INERT FOR EVERY DVD - and this library's remaining batch is mostly DVDs (the
# BBC Shakespeare set, The Bill, The Saint). A guard that covers half the discs and says nothing
# about the other half is worse than one that is known to be missing.
#
# _fetch-one.ps1 appends a unit to _fetch-done.txt only after matching file COUNT and BYTES against
# the source, so presence there is the verification.
$dvdSourceVerified = $false
$fdList = @(Get-Content 'D:/video/_fetch-done.txt' -ErrorAction SilentlyContinue |
            Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
$dvdSourceVerified = ($fdList -contains $discName)
if (-not $dvdSourceVerified) {
  Write-Warning "$discName is NOT in _fetch-done.txt - the copy is unverified and may still be"
  Write-Warning "copying. Title numbering from a short enumeration makes every disposition wrong."
}

$cat = [pscustomobject]@{
  disc = $discName; discPath = $Disc; discType = 'DVD'; minLength = $MinLength
  sourceVerified = $dvdSourceVerified
  # NOT "+1": the offset is not a constant (Witness was +1, The Malta Story was +2 with no
  # dvdvideo title 1 at all). Each title's dvdvideoTitle field records its own duration-matched
  # mapping; a null there means no dvdvideo title matched and no evidence could be captured.
  titleNumbering = 'MakeMKV (0-based). Per-title dvdvideoTitle is matched by DURATION, not by a fixed offset.'
  titleCount = $byId.Count
  titles = @($byId.Keys | Sort-Object | ForEach-Object { $byId[$_] })
}
$catPath = Join-Path $OutDir "$discName.catalogue.json"
$cat | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $catPath -Encoding UTF8
Write-Output ""
Write-Output "catalogue: $catPath"
Write-Output "$($byId.Count) title(s) - every one needs a disposition before the raw disc is released (assert-accounted.ps1)"
Write-Output "Rip with the MAKEMKV numbers shown above."

# ---- 5. EVIDENCE SUMMARY - a sweep that captured nothing for a title must SAY so, once more,
# at the very end where the eye lands, and in the exit code where a caller can see it.
$noEvidence = @($byId.Keys | Sort-Object | Where-Object {
  $r = $byId[$_]; $r.frames.Count -eq 0 -and -not $r.headStrip -and -not $r.speechSample
})
if ($noEvidence.Count -gt 0) {
  Write-Output ""
  Write-Output ("*** {0} TITLE(S) CAPTURED NO EVIDENCE - enumerated, NOT catalogued ***" -f $noEvidence.Count)
  foreach ($id in $noEvidence) {
    Write-Output ("  t{0:D2}  {1,9}  {2}" -f $id, $byId[$id].duration, $byId[$id].evidenceNote)
  }
  Write-Output "Identify these from another source (rip and probe, menu render) before writing their dispositions."
  # Exit non-zero only when a SUBSTANTIAL title is evidence-free. A 10-20 s menu stub or logo
  # sting legitimately yields nothing and a blanket failure would cry wolf; a 28-minute title
  # with nothing captured is the Witness t07 case and the caller must be able to tell.
  $substantial = @($noEvidence | Where-Object { (Get-Seconds $byId[$_].duration) -ge 60 })
  if ($substantial.Count -gt 0) {
    Write-Output ("EXIT 3: {0} of them run 60s or longer - the sweep is INCOMPLETE for this disc." -f $substantial.Count)
    exit 3
  }
}
