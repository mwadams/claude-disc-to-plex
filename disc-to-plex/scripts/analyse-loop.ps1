# ANALYSE track: run analyze-tracks.py over any ripped .mkv that lacks its .tracks.json evidence.
#
# WHY THIS EXISTS. Manifest audio fields must be DERIVED from measurement, not asserted -
# assert-tracks-analysed.ps1 refuses to queue a manifest whose audio claims lack (or disagree
# with) <file>.tracks.json evidence, so a rip with no analysis BLOCKS its manifest at the queue.
# On 2026-08-23 this step was hand-driven all day; the same day, two concurrent hand-runs of
# analyze-tracks.py were observed RACING on the same file. A loop with a per-file lock replaces
# both problems.
#
# ONE ANALYSIS AT A TIME: whisper is expensive and already saturates what it is given, exactly as
# _ocr-loop runs one Tesseract at a time. Concurrency would only fight the encode lanes.
#
# SINGLE INSTANCE ONLY. This loop is stateless - it re-derives its work list from the filesystem
# on every pass - so a second copy does not share out the work, it DUPLICATES it: both scan the
# same tree, both pick the same first file, and both run the analyzer on it at once, racing to
# write one evidence file. Nothing here ever exits, so every relaunch leaves the previous copy
# running - by 2026-08-21 the OCR loop had accumulated THIRTY-SIX live instances since 17 August,
# and the visible symptom was not "output is wrong" but "everything is slow": encodes, whisper
# transcriptions and OCR all crawling against a disk being swept by three dozen scanners. A leak
# that only ever costs throughput is one nobody goes looking for, which is why this guard exists
# rather than a note telling the next person to check.

param(
  [string]$Stage     = 'D:/video/_stage',
  [string]$Catalogue = 'D:/video/_catalogue',
  [string]$Queue     = 'D:/video/_queue',
  [string]$Analyzer  = 'D:/video/.claude/skills/disc-to-plex/scripts/analyze-tracks.py',
  [string]$Lib       = 'D:/video/.claude/skills/disc-to-plex/scripts/lib-audio-evidence.ps1',
  [string]$ToolPaths = 'D:/video/.transcode-tools/tool-paths.json',
  [switch]$Once      # one pass then exit - for tests; production runs without it
)

$loopMutex = New-Object System.Threading.Mutex($false, 'Global\video-analyse-loop')
$loopOwned = $false
try { $loopOwned = $loopMutex.WaitOne(0) }
catch [System.Threading.AbandonedMutexException] { $loopOwned = $true }  # holder died; the lock is ours
if (-not $loopOwned) {
  Write-Output "another _analyse-loop.ps1 already holds the lock - exiting (this is the guard working, not an error)"
  exit 0
}

# Observable, for the reason _fetch-loop.ps1 spells out: this loop wrote to stdout only, and
# _bounce-track.ps1 starts tracks with `Start-Process pwsh -WindowStyle Hidden` and no redirection,
# so everything it said was discarded and _logs/analyse-loop.log went stale on 2026-09-04 04:04 -
# which reads like a stopped loop rather than an unobservable one. Added 2026-09-05. Transcript
# rather than a launcher redirect, so it holds however the loop is started, and AFTER the mutex
# guard above so a losing second instance writes nothing.
$logDir = 'D:/video/_logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
# NOTE THE NAME: 'analyse-loop.log', with NO leading underscore. _tail.ps1 documents that spelling
# for this one track ("analyse-loop.log  live (NO underscore)"). Writing _analyse-loop.log instead
# would leave the real log stale beside a new one and create exactly the decoy this fixes.
try { Start-Transcript -Path (Join-Path $logDir 'analyse-loop.log') -Append | Out-Null } catch { }

$toolCfg = Get-Content $ToolPaths -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $toolCfg.ffmpeg) 'ffprobe.exe'
if (-not (Test-Path -LiteralPath $ffprobe)) { throw "ffprobe not found at $ffprobe - refusing to run without the still-being-written check" }

# The evidence-path rule and the "could this source ever be measured?" rule, shared with
# assert-tracks-analysed.ps1. Two copies of these would drift, and the gate would then wait for a
# file this loop had decided to write somewhere else.
. $Lib
if (-not (Get-Command Get-ManifestAudioWork -ErrorAction SilentlyContinue)) {
  throw "$Lib did not load - refusing to run without the queued-manifest arm"   # dot-source failures do not throw
}

function Say($msg) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) }

# A `.HOLD` on a staged unit parks it deliberately. Arms 1 and 2 test the folder they iterate;
# the queued-manifest arm starts from a FILE deep inside one, so walk up to the direct child of
# $Stage and test that. (Fight Club Disk 2 carried a load-bearing .HOLD on 2026-09-04 while
# another agent worked in it.)
function Test-StageHold([string]$Path, [string]$StageRoot) {
  try {
    $full  = [IO.Path]::GetFullPath($Path)
    $root  = [IO.Path]::GetFullPath($StageRoot).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $rest  = $full.Substring($root.Length)
    $first = $rest.Split([char[]]@('\', '/'), 2)[0]
    if (-not $first) { return $false }
    return (Test-Path -LiteralPath (Join-Path (Join-Path $StageRoot $first) '.HOLD'))
  } catch { return $false }
}

# Reported ONCE per source, not once per pass: an unanalysable source is a standing condition and
# a 120 s heartbeat of the same line is how a log stops being read.
$saidUnanalysable = New-Object System.Collections.Generic.HashSet[string]

Say "analyse loop: watching $Stage rip folders (*-x, *-main, *-mkv, *-rip), staged DVDs, and $Queue manifests"

while ($true) {
  $did = $false

  # ---- SOURCES A QUEUED MANIFEST NAMES. First, because these are BLOCKING A GPU LANE. ---------
  #
  # The two arms below find work by CONVENTION: a folder whose name ends -x/-main/-mkv/-rip, or a
  # folder containing VIDEO_TS. Both miss whole classes of source, and the misses are silent.
  #
  #   * A RAW BLU-RAY STREAM is never in a rip folder. `bladerunner-d1.json` reads
  #     `_stage/Bladerunner Disk 1/BDMV/STREAM/00047.m2ts` directly - deliberately, because ripping
  #     that feature costs 23 GB on a volume already near its floor - so nothing here would ever
  #     have written its evidence. It deferred at the queue from 02:41 on 2026-09-04 and would have
  #     expired into failed\ four hours later having burned no CPU and learned nothing.
  #   * The suffix list is described in the note below as "A LIABILITY, NOT A CONVENTION", and it
  #     is: 70 already-shipped manifest items read `.mkv` files out of `dh2-extras`, `fyeo-extras`,
  #     `goldfinger-rest`, `ser-feat` and friends, none of which it matches. Every one needed a
  #     hand-run of analyze-tracks.py.
  #
  # A QUEUED MANIFEST NEEDS NO CONVENTION - it states exactly which sources are about to be
  # encoded, and assert-tracks-analysed.ps1 is about to demand evidence for precisely those. So
  # take the work list from the manifest itself (Get-ManifestAudioWork, shared with the gate so the
  # two cannot disagree about where the evidence goes). Bounded by construction: only manifests in
  # the queue, only items making an audio claim, only evidence that is missing or stale.
  #
  # `_gate-queue.ps1` is the only sanctioned route into `_queue` and it admits a manifest only once
  # its staging is byte-verified, so a queued source is a COMPLETE source. The still-being-written
  # triad is kept anyway - it costs 1.5 s on work we are about to spend whisper-minutes on.
  foreach ($mf in @(
      @(Get-ChildItem -LiteralPath $Queue -File -Filter '*.json' -ErrorAction SilentlyContinue) +
      @(Get-ChildItem -LiteralPath (Join-Path $Queue 'pending') -File -Filter '*.json' -ErrorAction SilentlyContinue)
    )) {
    foreach ($w in @(Get-ManifestAudioWork -Manifest $mf.FullName)) {
      if (-not $w.Analysable) {
        # NOT this loop's problem to solve, but it IS its problem to say out loud. The gate now
        # refuses these by name rather than deferring for ever, so this is corroboration.
        $key = "$($mf.Name)|$($w.Src)"
        if ($saidUnanalysable.Add($key)) {
          Say "$($mf.Name): CANNOT ANALYSE '$($w.Src)' - $($w.Reason). No evidence will appear; assert-tracks-analysed.ps1 refuses this rather than waiting."
        }
        continue
      }
      if (Test-StageHold -Path $w.Src -StageRoot $Stage) { continue }

      # A LONE `audioTracks: [0]` ON A ONE-STREAM SOURCE NEEDS NO EVIDENCE, and the gate exempts
      # it. Blade Runner's Ridley Scott introduction is that shape; a disc of 37 short extras is
      # 37 of them, and each would cost two whisper minutes to produce a file nothing reads.
      if (Test-AudioClaimTrivial -Ffprobe $ffprobe -Row $w) {
        $key = "trivial|$($w.Src)"
        if ($saidUnanalysable.Add($key)) {
          Say "$(Split-Path $w.Src -Leaf): single audio stream claimed as [0] - the gate exempts this, not analysing it"
        }
        continue
      }

      $isFile = Test-Path -LiteralPath $w.Src -PathType Leaf
      if ($isFile) {
        $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $w.Src 2>$null)".Trim()
        if (-not $d -or $d -eq 'N/A') { continue }
        $len1 = (Get-Item -LiteralPath $w.Src).Length
        Start-Sleep -Milliseconds 1500
        $len2 = (Get-Item -LiteralPath $w.Src -ErrorAction SilentlyContinue).Length
        if ($null -eq $len2 -or $len1 -ne $len2) { continue }
        $leaf = Split-Path $w.Src -Leaf
        $writer = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe' OR Name='makemkvcon64.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($leaf) })
        if ($writer.Count -gt 0) { continue }
      }

      # THE SAME LOCK NAMES THE OTHER TWO ARMS USE, so a source reachable both ways (a rip .mkv
      # that a manifest also names) can never be analysed twice at once. A losing writer's json is
      # silent corruption of the evidence a gate trusts.
      $lockKey = if ($isFile) { $w.Src } else { "$(Split-Path $w.Src -Leaf)-title$($w.Title)" }
      $handRun = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
                   Where-Object { $_.CommandLine -and $_.CommandLine -match 'analyze-tracks' -and
                                  $_.CommandLine.Contains((Split-Path $w.Src -Leaf)) })
      if ($handRun.Count -gt 0) {
        Say "$(Split-Path $w.Src -Leaf): already being analysed by pid $($handRun[0].ProcessId) - leaving it alone"
        continue
      }
      $qMutex = New-Object System.Threading.Mutex($false, ('Global\analyse-' + ($lockKey -replace '[^\w\-\.]', '_')))
      $qOwned = $false
      try { $qOwned = $qMutex.WaitOne(0) }
      catch [System.Threading.AbandonedMutexException] { $qOwned = $true }
      if (-not $qOwned) { $qMutex.Dispose(); continue }

      try {
        Say "ANALYSE (queued by $($mf.Name)): $($w.AnalyzerArgs -join ' ')"
        $out = & python $Analyzer @($w.AnalyzerArgs) 2>&1
        $code = $LASTEXITCODE
        # THE ARTIFACT IS THE VERDICT, not the exit code alone - the analyzer writes its json as
        # its final act, so a failed run leaves nothing and can never read as done.
        if ($code -eq 0 -and (Test-Path -LiteralPath $w.Evidence)) {
          Say ("  evidence written -> {0}" -f $w.Evidence)
          @($out | Where-Object { "$_" -match '^\s*!!' }) | Select-Object -First 6 | ForEach-Object { Say ("    " + $_) }
        } else {
          Say ("  ANALYSIS FAILED for {0} (exit {1}) - NO evidence recorded; will retry next pass. Output tail:" -f (Split-Path $w.Src -Leaf), $code)
          @($out | Where-Object { "$_" -match '\S' }) | Select-Object -Last 4 | ForEach-Object { Say ("    " + $_) }
        }
      } finally {
        $qMutex.ReleaseMutex()
        $qMutex.Dispose()
      }
      $did = $true
    }
  }

  # Rip folders ONLY - they hold MakeMKV output awaiting analysis. Disc folders (BDMV/VIDEO_TS)
  # are upstream of ripping and carry nothing to analyse.
  #
  # THE SUFFIX LIST IS A LIABILITY, NOT A CONVENTION. These names are ad-hoc and always have been:
  # `metro-x`, `mumins1-mkv`, `-main`, and now `bttf1-rip` from _rip-loop.ps1. A folder whose
  # suffix is missing here is not analysed, its manifest can never be authored, and NOTHING
  # REPORTS IT - the loop simply never sees the work. That is precisely how `bttf1-rip` would have
  # stalled on 2026-08-23, silently, after a 50-minute re-rip.
  # Add every form that exists; when adding a new one, add it to _stallwatch.ps1's $isRip too.
  foreach ($ripDir in @(Get-ChildItem $Stage -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '-(x|main|mkv|rip)$' })) {
    # A held unit is deliberately parked (e.g. mumins1-mkv, awaiting a missing disc) - burning
    # hours of whisper on rips nobody can manifest yet steals CPU from live units.
    if (Test-Path -LiteralPath (Join-Path $ripDir.FullName '.HOLD')) { continue }

    # BIGGEST FIRST - the feature, not the extras.
    #
    # Filename order analyses t11, t12, t14 ... and reaches the FEATURE last. On Back to the
    # Future that put ~85 minutes of extras analysis in front of the one file that unblocks
    # everything: no feature evidence means no manifest, which means no encode, which means no
    # publish, which means no reclaim - and the volume was at 28 GB with the fetch track already
    # holding at its floor. The GPU would have sat idle the whole time waiting on galleries.
    #
    # The feature is reliably the largest title on a disc, so size is a good enough proxy and
    # needs no disposition parsing here. Extras still get analysed - just after the thing that
    # releases the pipeline.
    foreach ($f in @(Get-ChildItem -LiteralPath $ripDir.FullName -File -Filter *.mkv -ErrorAction SilentlyContinue |
                     Sort-Object Length -Descending)) {
      $evidence = "$($f.FullName).tracks.json"

      # CHEAP CHECK FIRST. The still-being-written probe below costs 1.5 s plus a process query
      # per file; charging that to every already-analysed file on every pass is the exact
      # throughput bug _ocr-loop documents. Evidence NEWER than the mkv = done. Evidence OLDER
      # = the mkv was re-ripped after analysis, so the evidence describes a different file - redo.
      if (Test-Path -LiteralPath $evidence) {
        if ((Get-Item -LiteralPath $evidence).LastWriteTime -gt $f.LastWriteTime) { continue }
        Say "$($f.Name): evidence exists but is OLDER than the mkv - re-analysing"
      }

      # STILL BEING WRITTEN? Three independent tells, all required to pass, because each alone
      # has a hole. A duration is NOT proof a rip/encode finished - a growing Matroska reports
      # one long before it is finalised (that gap let 11 partial files acquire PERMANENT wrong
      # verdicts in the OCR loop on 2026-08-23). So: header duration present, AND size stable
      # across 1.5 s, AND no ffmpeg/makemkvcon64 with this file (or this rip folder - makemkvcon
      # names only the output DIRECTORY on its command line) in its command line.
      $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null)".Trim()
      if (-not $d -or $d -eq 'N/A') { continue }
      $len1 = $f.Length
      Start-Sleep -Milliseconds 1500
      $len2 = (Get-Item -LiteralPath $f.FullName -ErrorAction SilentlyContinue).Length
      if ($null -eq $len2 -or $len1 -ne $len2) { continue }
      $writer = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe' OR Name='makemkvcon64.exe'" -ErrorAction SilentlyContinue |
                  Where-Object { $_.CommandLine -and ($_.CommandLine.Contains($f.Name) -or $_.CommandLine.Contains($ripDir.FullName)) })
      if ($writer.Count -gt 0) { continue }

      # PER-FILE LOCK - two concurrent analyze-tracks.py runs on the same file raced on
      # 2026-08-23, and the loser's write is silent corruption of the evidence a gate trusts.
      # Two layers, because they catch different intruders:
      #   1. a process check catches a HAND-RUN python already analysing this file
      #   2. a named per-file mutex makes anything else honouring the convention mutually exclusive
      $handRun = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
                   Where-Object { $_.CommandLine -and $_.CommandLine -match 'analyze-tracks' -and $_.CommandLine.Contains($f.Name) })
      if ($handRun.Count -gt 0) {
        Say "$($f.Name): already being analysed by pid $($handRun[0].ProcessId) - leaving it alone"
        continue
      }
      $fileMutex = New-Object System.Threading.Mutex($false, ('Global\analyse-' + ($f.FullName -replace '[^\w\-\.]', '_')))
      $fileOwned = $false
      try { $fileOwned = $fileMutex.WaitOne(0) }
      catch [System.Threading.AbandonedMutexException] { $fileOwned = $true }
      if (-not $fileOwned) {
        $fileMutex.Dispose()
        Say "$($f.Name): another holder has the per-file lock - skipping this pass"
        continue
      }

      try {
        Say "ANALYSE: $($f.FullName)"
        # Capture the child's output IN FULL before filtering (piping straight into a head-style
        # cmdlet can close the pipeline and kill the child mid-run - see _ocr-loop.ps1).
        $out = & python $Analyzer $f.FullName 2>&1
        $code = $LASTEXITCODE

        # THE VERDICT IS THE ARTIFACT, NOT THE EXIT CODE ALONE: success means the evidence file
        # now exists and postdates the mkv. A failed run writes nothing (the analyzer writes its
        # json as its final act), so a failure can never look done - report it loudly, record
        # nothing, retry next pass. Never a success message next to an operation that can fail.
        $ok = ($code -eq 0 -and (Test-Path -LiteralPath $evidence) -and
               (Get-Item -LiteralPath $evidence).LastWriteTime -gt $f.LastWriteTime)
        if ($ok) {
          Say ("  evidence written -> {0}" -f $evidence)
          # The analyzer's own warnings are the part a human must see (each starts '!!').
          @($out | Where-Object { "$_" -match '^\s*!!' }) | Select-Object -First 6 | ForEach-Object { Say ("    " + $_) }
        } else {
          Say ("  ANALYSIS FAILED for {0} (exit {1}) - NO evidence recorded; will retry next pass. Output tail:" -f $f.Name, $code)
          @($out | Where-Object { "$_" -match '\S' }) | Select-Object -Last 4 | ForEach-Object { Say ("    " + $_) }
        }
      } finally {
        $fileMutex.ReleaseMutex()
        $fileMutex.Dispose()
      }
      $did = $true
    }
  }

  # ---- DVD TITLES. The rip folders above cannot cover these, BY DESIGN. ----------------------
  #
  # A DVD dispositioned `episode` is deliberately never ripped: the manifest reads the disc FOLDER
  # through `-f dvdvideo -title N`, so a MakeMKV rip would be pure waste. The consequence was that
  # NO loop produced audio evidence for those titles - and assert-tracks-analysed.ps1 REQUIRES it,
  # keyed `<disc>.title<N>.tracks.json`, whenever several gated items share one disc folder.
  #
  # So every DVD TV disc reached the queue needing an analysis nothing ran. On 2026-09-01 that was
  # hand-driven again (Babylon 5 Disk 6, titles 1 and 37) - and WORKING-AGREEMENT.md's answer to
  # "no script does it" is to write the script, not to run it by hand once. This is that script.
  #
  # KEYED BY DVDVIDEO NUMBER, WHICH IS WHY IT IS SAFE TO DRIVE FROM THE CATALOGUE.
  # The catalogue's `dvdvideoTitle` column is matched by duration and is sometimes ROTATED against
  # the MakeMKV numbering (flagged `mappingAmbiguous`; observed on Disks 1, 4 and 5 of this very
  # set). That does not endanger the evidence: the file is named for the dvdvideo title actually
  # analysed, and the manifest cites the same dvdvideo number. A mapping error can therefore only
  # make us analyse a title nobody wanted - wasted minutes - never file one title's audio under
  # another's name. It FAILS CLOSED: the missing evidence stops the manifest at the gate, loudly.
  foreach ($discDir in @(Get-ChildItem $Stage -Directory -ErrorAction SilentlyContinue |
                         Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'VIDEO_TS') })) {
    if (Test-Path -LiteralPath (Join-Path $discDir.FullName '.HOLD')) { continue }
    $disc = $discDir.Name
    $dispPath = Join-Path $Catalogue "$disc.dispositions.txt"
    $catPath  = Join-Path $Catalogue "$disc.catalogue.json"
    if (-not (Test-Path -LiteralPath $dispPath) -or -not (Test-Path -LiteralPath $catPath)) { continue }

    # Which MakeMKV titles are KEPT? Unfinished dispositions ('?') mean the answer is not settled.
    $lines = @(Get-Content -LiteralPath $dispPath -ErrorAction SilentlyContinue)
    if ($lines | Where-Object { $_ -match '^t\d+\|\?\|' }) { continue }
    $keep = @()
    foreach ($l in $lines) { if ($l -match '^t(\d+)\|(feature|extra|episode)\|') { $keep += [int]$Matches[1] } }
    if ($keep.Count -eq 0) { continue }

    $cj = Get-Content -LiteralPath $catPath -Raw | ConvertFrom-Json
    $dvdTitles = @()
    foreach ($t in $cj.titles) {
      if (($keep -contains [int]$t.title) -and $t.dvdvideoTitle) { $dvdTitles += [int]$t.dvdvideoTitle }
    }
    foreach ($n in ($dvdTitles | Sort-Object -Unique)) {
      $evidence = Join-Path $Stage "$disc.title$n.tracks.json"
      if (Test-Path -LiteralPath $evidence) { continue }

      # ONE audio stream needs no evidence - assert-tracks-analysed exempts a lone `audioTracks:[0]`
      # because there is nothing to choose between. Skip those rather than burn whisper on them.
      $na = @(& $ffprobe -v error -f dvdvideo -title $n -i $discDir.FullName -select_streams a `
                 -show_entries stream=index -of csv=p=0 2>$null | Where-Object { $_ -match '^\d+$' }).Count
      if ($na -le 1) { continue }

      $handRun = @(Get-CimInstance Win32_Process -Filter "Name='python.exe'" -ErrorAction SilentlyContinue |
                   Where-Object { $_.CommandLine -and $_.CommandLine -match 'analyze-tracks' -and
                                  $_.CommandLine.Contains($disc) -and $_.CommandLine -match "--dvd-title\s+$n\b" })
      if ($handRun.Count -gt 0) {
        Say "$disc title ${n}: already being analysed by pid $($handRun[0].ProcessId) - leaving it alone"
        continue
      }
      $tMutex = New-Object System.Threading.Mutex($false, ('Global\analyse-' + ("$disc-title$n" -replace '[^\w\-\.]', '_')))
      $tOwned = $false
      try { $tOwned = $tMutex.WaitOne(0) }
      catch [System.Threading.AbandonedMutexException] { $tOwned = $true }
      if (-not $tOwned) { $tMutex.Dispose(); continue }

      try {
        Say "ANALYSE: $disc dvdvideo title $n ($na audio streams)"
        $out = & python $Analyzer $discDir.FullName --dvd-title $n 2>&1
        $code = $LASTEXITCODE
        # Same rule as above: the ARTIFACT is the verdict. The analyzer writes its json last, so a
        # failed run leaves nothing and can never read as done.
        if ($code -eq 0 -and (Test-Path -LiteralPath $evidence)) {
          Say ("  evidence written -> {0}" -f $evidence)
          @($out | Where-Object { "$_" -match '^\s*!!' }) | Select-Object -First 6 | ForEach-Object { Say ("    " + $_) }
        } else {
          Say ("  ANALYSIS FAILED for $disc title $n (exit {0}) - NO evidence recorded; will retry next pass. Output tail:" -f $code)
          @($out | Where-Object { "$_" -match '\S' }) | Select-Object -Last 4 | ForEach-Object { Say ("    " + $_) }
        }
      } finally {
        $tMutex.ReleaseMutex()
        $tMutex.Dispose()
      }
      $did = $true
    }
  }

  if ($Once) { break }
  if (-not $did) { Start-Sleep -Seconds 120 }
}
