# CPU track: keep OCR running over every encoded file that still needs a sidecar.
#
# Runs as a loop rather than a one-shot list, because new encodes land continuously and a fixed
# list goes stale the moment the next manifest finishes. Publishing is BLOCKED on this (publish
# refuses bitmap subs with no sidecar), so an idle OCR track stalls the NAS track behind it.
#
# One file at a time: OCR is CPU-bound and Tesseract already uses the cores.

# SINGLE INSTANCE ONLY. This loop is stateless - it re-derives its work list from the filesystem on
# every pass - so a second copy does not share out the work, it DUPLICATES it: both scan the same
# tree, both pick the same first file, and both run OCR on it at once, racing to write one sidecar.
#
# Nothing here ever exits, so every relaunch left the previous copy running. By 2026-08-21 there
# were THIRTY-SIX live instances accumulated since 17 August, each ffprobing every mkv under Movies
# and Television Shows on a loop. The visible symptom was not "OCR is wrong" but "everything is
# slow" - encodes, whisper transcriptions and a single-file OCR all crawling against an NVMe being
# swept by three dozen scanners. A leak that only ever costs throughput is one nobody goes looking
# for, which is why this guard exists rather than a note telling the next person to check.
$mutex = New-Object System.Threading.Mutex($false, 'Global\video-ocr-loop')
if (-not $mutex.WaitOne(0)) {
  Write-Output "another _ocr-loop.ps1 already holds the lock - exiting (this is the guard working, not an error)"
  exit 0
}

$paths   = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'
# Load VERIFIED: a failed dot-source leaves the predicates undefined, each call errors without
# stopping the loop, and every skip-check silently stops skipping - the loop then re-OCRs files
# that are done, empty or blocked, forever.
. 'D:\video\.claude\skills\disc-to-plex\scripts\lib-subtitles.ps1'
if (-not (Get-Command Test-BitmapSubsAttemptable -ErrorAction SilentlyContinue) -or
    -not (Get-Command Resolve-OcrOutcome -ErrorAction SilentlyContinue)) {
  throw 'lib-subtitles.ps1 failed to load - refusing to run the OCR loop without its predicates'
}

while ($true) {
  $did = $false
  foreach ($f in Get-ChildItem 'D:\video\Movies','D:\video\Television Shows' -Recurse -File -Filter *.mkv -ErrorAction SilentlyContinue) {
    # skip anything still being written - no duration in the header yet
    $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null)".Trim()
    if (-not $d -or $d -eq 'N/A') { continue }



    $sidecar = [IO.Path]::ChangeExtension($f.FullName, $null) + 'eng.srt'
    if (Test-Path -LiteralPath $sidecar) { continue }

    # Not just "has a bitmap track" - has one with packets in it AND no settled verdict. Empty
    # shells (silent films), exhausted tracks (wordless shorts) and BLOCKED tracks (wrong-language
    # / quality defects that a retry cannot fix - see Resolve-OcrOutcome in lib-subtitles.ps1) are
    # all skipped here; blocked ones still hold publish, which is the point of the distinction.
    if (-not (Test-BitmapSubsAttemptable -Path $f.FullName -Ffprobe $ffprobe)) { continue }

    # STILL BEING WRITTEN?  (placed HERE, after the sidecar and populated checks, deliberately:
    #  when this sat earlier in the loop it charged EVERY file in the library 1.5 s plus a process
    #  query on EVERY pass - including the thousands that already have sidecars and were about to
    #  be skipped. A correctness fix that makes the loop crawl is a throughput bug.)
    # --- A duration is NOT proof an encode has finished - a growing Matroska
    # reports one long before it is finalised. OCR then fails on a partial file, and (before this
    # fix) the failure was recorded as the settled verdict "no usable text", which is PERMANENT and
    # silently unblocks publishing. On 2026-08-23 that marked 11 You Only Live Twice items during
    # their own encode, including the feature - which has 2002 subtitle packets.
    # Require the size to be STABLE, and never touch a file an ffmpeg is writing.
    $len1 = $f.Length
    Start-Sleep -Milliseconds 1500
    $len2 = (Get-Item -LiteralPath $f.FullName -ErrorAction SilentlyContinue).Length
    if ($null -eq $len2 -or $len1 -ne $len2) { continue }
    $writer = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and $_.CommandLine.Contains($f.Name) })
    if ($writer.Count -gt 0) { continue }

    Write-Output "OCR: $($f.Name)"
    # Capture the child's output IN FULL before filtering. Piping it straight into
    # `Select-Object -First N` lets the downstream cmdlet close the pipeline the moment it has
    # its N matches, which terminates the OCR child mid-run - so no sidecar is written, the next
    # pass finds the same file still needing one, and the loop spins on it forever.
    $out = & pwsh -File 'D:\video\.claude\skills\disc-to-plex\scripts\ocr-subtitles.ps1' -Path $f.FullName 2>&1

    # SHOW THE GATE LINE AND THE ERRORS SEPARATELY - they used to compete for the same two slots.
    # An ErrorRecord renders WITH its offending source line, and ocr-subtitles.ps1 is full of lines
    # mentioning "cues", so a thrown error matches this very filter. On Rome S00E07 two
    # `InvalidOperation` records did exactly that, took both `-First 2` slots, and hid the gate's
    # own "OK <file> N cues, N% junk -> sidecar" verdict. Nothing was corrupted (the sidecar had
    # 342 clean cues) - but a SUPPRESSED GATE VERDICT is precisely how 14 episodes once published
    # with no sidecar and nothing saying so. Never let diagnostics crowd out the quality report.
    $records = @($out)
    $errs = @($records | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] })
    $plain = @($records | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
    $plain | Select-String 'cues|refus|reject|SKIP|FAIL' | Select-Object -First 2 | ForEach-Object { "    $_" }
    $errs  | Select-Object -First 2 | ForEach-Object { "    !! $_" }

    # If OCR ran and still produced no sidecar, classify the outcome and record ONLY earned
    # verdicts. The classification used to live here as a five-branch elseif chain that grew one
    # branch per incident (wrong-language, dictionary near-miss, recognition failure, vanished
    # file, and a catch-all that recorded every surprise as the permanent verdict "no text here").
    # It is now Resolve-OcrOutcome in lib-subtitles.ps1, shared with every other consumer, and the
    # full incident history moved with it. Three shapes come back:
    #   exhausted  - positive finding of emptiness: stop retrying, stop blocking publish
    #   blocked    - a defect a retry cannot fix: stop retrying, KEEP publish blocked
    #   (nothing)  - unexplained failure or vanished file: record nothing, retry next pass
    if (-not (Test-Path -LiteralPath $sidecar)) {
      $outcome = Resolve-OcrOutcome -OutputText ($out | Out-String) `
                                    -SourceExists (Test-Path -LiteralPath $f.FullName)
      switch ($outcome.Verdict) {
        'exhausted' { Set-BitmapSubsExhausted -Path $f.FullName }
        'blocked'   { Set-BitmapSubsBlocked   -Path $f.FullName -Reason $outcome.BlockReason }
      }
      $outcome.Lines | ForEach-Object { "    $_" }
    }
    $did = $true
  }
  if (-not $did) { Start-Sleep -Seconds 120 }
}
