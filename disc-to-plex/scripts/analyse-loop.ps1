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
  [string]$Analyzer  = 'D:/video/.claude/skills/disc-to-plex/scripts/analyze-tracks.py',
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

$toolCfg = Get-Content $ToolPaths -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $toolCfg.ffmpeg) 'ffprobe.exe'
if (-not (Test-Path -LiteralPath $ffprobe)) { throw "ffprobe not found at $ffprobe - refusing to run without the still-being-written check" }

function Say($msg) { Write-Output ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $msg) }

Say "analyse loop: watching $Stage rip folders (*-x, *-main, *-mkv)"

while ($true) {
  $did = $false
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

  if ($Once) { break }
  if (-not $did) { Start-Sleep -Seconds 120 }
}
