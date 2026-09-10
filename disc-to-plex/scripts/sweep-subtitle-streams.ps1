<#
.SYNOPSIS
  WHICH of a file's bitmap subtitle streams is the English one? Answers it by OCR'ing a short
  sample of EVERY stream and scoring the text, then optionally running the real conversion.

.WHY THIS EXISTS
  ocr-subtitles.ps1 takes the FIRST bitmap stream whose language tag does not contradict -Lang.
  When a disc carries one subtitle track that is the whole story. When it carries twenty-one, all
  UNTAGGED, "the first" is a coin toss - and losing it produced a terminal verdict blaming the
  disc.

  Monty Python's Flying Circus, measured 2026-09-10. Seven episodes, each with twenty-one
  `dvd_subtitle` streams, every one of them carrying real packets (151-175 in the first ten
  minutes) and not one of them tagged. Rendering a cue from each showed French, German,
  Portuguese, Arabic, Croatian, Czech, Danish, Dutch, Finnish, Greek, Hindi, Icelandic, Norwegian,
  Romanian, Slovene, Swedish, Turkish, Italian, Spanish - and ENGLISH at s:17 ("I'm terribly sorry
  to interrupt, but my tooth's hurting") and again at s:18. Selection took s:0, French. The
  language gate was right, the verdict that followed said the disc mislabelled its track and
  publishing stopped - for seven episodes whose English subtitles were inside the file all along.

  Spider-Man (2002) is the same shape with a different cause: four streams all tagged `eng`,
  33 / 1,191 / 1,543 / 11,230 packets, and the 33-packet FORCED signs track is first.

  So this is the missing step, and it is a SCRIPT rather than a note because doing it by eye - the
  way it was done the first time, by rendering 21 PNGs and reading them - is exactly the kind of
  per-disc manual intervention this pipeline exists to remove.

.HOW IT DECIDES
  Per stream: remux just that stream (stream copy, no re-encode) into a short single-track mkv,
  extract, repair the VobSub palette, OCR the sample, then score the text two ways -

    english%   lines carrying a common ENGLISH function word (the/and/you/that/with/...)
    foreign%   lines carrying a high-frequency function word that is NOT an English word
               (de/la/het/und/ist/pour/que/...). English homographs are deliberately absent.

  A stream wins on the highest english% provided it also clears the foreign% bar. The two lists
  are the SAME ONES ocr-subtitles.ps1's gates use, on purpose: a stream this script nominates has
  to survive those gates afterwards, and a nomination the gate then rejects is a wasted hour.

  THIS SCRIPT ONLY RANKS. It never writes a sidecar and never lowers a bar. The winner is handed
  to ocr-subtitles.ps1 -StreamIndex, which applies the full quality gates to the whole track. If the
  winner fails them there, that is the correct outcome and this script was still right to nominate
  it - ranking a sample and judging a conversion are different questions.

.SAMPLING
  -SampleSeconds bounds the cost. A full OCR of 21 streams is 21 full conversions; a 12-minute
  sample of each is roughly one. The sample is taken from the START, which is where a disc's
  subtitle streams all begin, and the cue floor is deliberately low (a stream with 8 readable
  sample lines is still rankable) because this is a comparison between streams of the same file,
  not an absolute quality judgement.

.NOTES
  Reads the NAS through the governor and stages locally first, like ocr-subtitles.ps1: without
  that, twenty-one remuxes each drag the whole file across SMB.

  REPORT-ONLY BY DEFAULT. -Apply is what runs the real conversion.

    pwsh -NoProfile -File sweep-subtitle-streams.ps1 -Path '\\NAS\...\S02E06.mkv'
    pwsh -NoProfile -File sweep-subtitle-streams.ps1 -List files.txt -Apply
#>
param(
  [string]$Path = '',
  # A file of paths, one per line - the same shape the OCR queue's own lists take.
  [string]$List = '',
  [string]$Lang = 'eng',
  [int]$SampleSeconds = 720,
  [string]$ToolsDir = 'D:/video/.transcode-tools',
  # Run ocr-subtitles.ps1 -StreamIndex <winner> on each file once the winner is known.
  [switch]$Apply,
  # A stream must clear this to be nominated. 15 is the same floor ocr-subtitles.ps1's function-word
  # gate uses for a full track; on a sample it is if anything generous, which is the right direction
  # for a RANKING step whose nominee is judged properly afterwards.
  [int]$MinEnglishPct = 15,
  # ...and must not look foreign. 25 is the bar the short-track gate uses.
  [int]$MaxForeignPct = 25,
  [switch]$NoStage
)

$ErrorActionPreference = 'Stop'

# lib-subtitles.ps1 carries Repair-OcrGlyphs. Verify the load rather than dot-sourcing and hoping:
# a dot-source of a bad path raises a NON-TERMINATING error, so the function would simply be
# undefined and every stream would score badly for the wrong reason.
#
# Repair-VobSubPalette is deliberately NOT used here. It lives inside ocr-subtitles.ps1, which
# cannot be dot-sourced (it runs on load), and copying it would give this project two versions of
# the one thing it has already been bitten by drifting - the anti-alias sampling window was widened
# on 2026-09-07 and a stale second copy would silently keep the old threshold. Skipping it is safe
# for a RANKING step: palette damage is a property of the DISC's subpicture palette, so it lands on
# every stream of a file alike and does not move one stream above another. The winner then goes
# through ocr-subtitles.ps1, which does repair the palette before the conversion that ships.
$subsLib = "$PSScriptRoot/lib-subtitles.ps1"
if (-not (Test-Path -LiteralPath $subsLib)) { throw "subtitle library missing: $subsLib" }
. $subsLib
if (-not (Get-Command Repair-OcrGlyphs -ErrorAction SilentlyContinue)) {
  throw 'lib-subtitles.ps1 failed to load - Repair-OcrGlyphs is undefined'
}
$govLib = "$PSScriptRoot/lib-nas-governor.ps1"
if (-not (Test-Path -LiteralPath $govLib)) { throw "nas governor missing: $govLib" }
. $govLib
if (-not (Get-Command Invoke-NasRead -ErrorAction SilentlyContinue)) {
  throw 'lib-nas-governor.ps1 failed to load - refusing to read the NAS ungoverned'
}

$paths   = Get-Content (Join-Path $ToolsDir 'tool-paths.json') -Raw | ConvertFrom-Json
$ffprobe = (Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe')
$ffmpeg  = $paths.ffmpeg
$mkvx    = $paths.mkvextract
$seconv  = $paths.seconv
$bitmapCodecs = @('dvd_subtitle', 'hdmv_pgs_subtitle', 'dvb_subtitle', 'xsub')

# TESSERACT MUST BE ON THE PATH *SECONV'S CHILD PROCESS* SEES, and this script found out the hard
# way: the first run scored all 21 Monty Python streams at 0% and concluded "NO ENGLISH STREAM
# FOUND - needs the source disc", when the truth was that seconv had said "Tesseract not found on
# PATH" twenty-one times into Out-Null. Get-Command finding tesseract here is NOT the same as the
# child seeing it - the installer updates the machine PATH but a running shell keeps its inherited
# copy. Prepend the real directory, and refuse to start if it is not there: a ranking run that
# cannot OCR must not produce a ranking.
$tessExe = (Get-Command tesseract -ErrorAction SilentlyContinue).Source
if (-not $tessExe) { $tessExe = $paths.tesseract }
if ($tessExe -and (Test-Path $tessExe)) {
  $tessDir = Split-Path $tessExe
  if ($env:PATH -notlike "*$tessDir*") { $env:PATH = "$tessDir;$env:PATH" }
} else {
  throw 'Tesseract is not installed or not in tool-paths.json - refusing to rank streams we cannot read'
}

# The SAME two lists ocr-subtitles.ps1 judges with. Kept identical on purpose - see .HOW IT DECIDES.
$commonEnglish = '(?i)\b(the|and|you|that|this|with|have|not|for|but|what|are|was|his|her|him|she|they|there|would|your|from|all|been|will|has|had|who|when|were)\b'
$foreignWords  = '(?i)\b(de|la|el|los|las|una|que|por|para|del|esta|pero|todo|lo|les|des|du|une|pour|avec|dans|qui|mais|cette|vous|nous|der|das|und|ist|nicht|f[uü]r|mit|ein|eine|sich|von|dem|den|het|een|niet|voor|zijn)\b'

$targets = @()
if ($Path) { $targets += $Path }
if ($List) { $targets += @(Get-Content -LiteralPath $List | Where-Object { $_.Trim() }) }
if (-not $targets) { throw 'nothing to do - pass -Path or -List' }

$work = Join-Path (Join-Path $ToolsDir 'work') "substreams$PID"
New-Item -ItemType Directory -Force $work | Out-Null

$govSay = { param($m) Write-Host "  [governor] $m" }
$results = @()

try {
foreach ($file in $targets) {
  Write-Host ''
  Write-Host ("=== {0}" -f (Split-Path $file -Leaf))
  if (-not (Test-Path -LiteralPath $file)) { Write-Warning '  missing'; continue }

  $info = & $ffprobe -v error -select_streams s -show_entries stream=index,codec_name:stream_tags=language `
            -of csv=p=0 $file 2>$null
  $streams = @()
  foreach ($line in $info) {
    $p = $line -split ','
    if ($p.Count -lt 2) { continue }
    if ($bitmapCodecs -notcontains $p[1]) { continue }
    $streams += [pscustomobject]@{ Index = [int]$p[0]; Codec = $p[1]; Lang = $(if ($p.Count -ge 3) { $p[2] } else { '' }) }
  }
  if ($streams.Count -lt 2) {
    Write-Host ("  {0} bitmap stream(s) - nothing to choose between; this file's remedy is not stream selection" -f $streams.Count)
    $results += [pscustomobject]@{ File = $file; Winner = $null; Note = 'single bitmap stream' }
    continue
  }
  Write-Host ("  {0} bitmap stream(s): {1}" -f $streams.Count, (($streams | ForEach-Object { $_.Index }) -join ', '))

  # ONE local copy for all N streams. Twenty-one remuxes straight off the NAS is twenty-one full
  # container reads; staged, it is one.
  $readFrom = $file
  $staged   = $null
  if (-not $NoStage -and ([IO.Path]::IsPathRooted($file)) -and $file.StartsWith('\\')) {
    $dest = Join-Path $work ('src' + [IO.Path]::GetExtension($file))
    # Copy-NasFileThrottled, not Copy-Item: the copy IS the ceiling, and it honours the kill switch
    # between 4 MB chunks. Invoke-NasRead around it takes the machine-wide read slot.
    [void](Invoke-NasRead -Path $file -Label ("substreams stage " + (Split-Path $file -Leaf)) -Say $govSay -Do {
      Copy-NasFileThrottled -Source $file -Destination $dest
    })
    if (Test-Path -LiteralPath $dest) { $staged = $dest; $readFrom = $dest; Write-Host '  staged locally' }
    else { Write-Host '  NOT staged - reading the remote file directly' }
  }

  $scores = @()
  foreach ($s in $streams) {
    $stem = Join-Path $work ("s{0:d3}" -f $s.Index)
    $shim = "$stem.mkv"
    # -t bounds the SAMPLE. -map on the single subtitle stream, stream copy: no decode, no re-encode.
    & $ffmpeg -v error -y -i $readFrom -map "0:$($s.Index)" -c copy -t $SampleSeconds $shim 2>&1 | Out-Null
    if (-not (Test-Path $shim)) {
      $scores += [pscustomobject]@{ Index = $s.Index; Lines = 0; EngPct = 0; ForPct = 0; Note = 'remux produced nothing' }
      continue
    }
    $ext = if ($s.Codec -eq 'hdmv_pgs_subtitle') { 'sup' } else { 'idx' }
    $bmp = "$stem.$ext"
    & $mkvx tracks $shim "0:$bmp" 2>&1 | Out-Null
    $payload = if ($ext -eq 'idx') { [IO.Path]::ChangeExtension($bmp, '.sub') } else { $bmp }
    $bytes = if (Test-Path $payload) { (Get-Item $payload).Length } else { 0 }
    if ($bytes -lt 4KB) {
      # A stream can be DECLARED and hold nothing. That is a finding about the stream, not a failure.
      $scores += [pscustomobject]@{ Index = $s.Index; Lines = 0; EngPct = 0; ForPct = 0; Note = ("empty ({0:N0} B)" -f $bytes) }
      continue
    }
    $seconvOut = & $seconv $bmp subrip --ocr-engine:tesseract --ocr-language:$Lang --output-folder:$work --overwrite 2>&1
    $srt = [IO.Path]::ChangeExtension($bmp, '.srt')
    if (-not (Test-Path $srt)) {
      # Fold seconv's own words in. Discarding them is how the first run of this script turned
      # "Tesseract not found on PATH" into a silent 0% and then into a verdict about the disc.
      $why = (@($seconvOut | ForEach-Object { "$_" } |
                Where-Object { $_ -match 'not found|produced no OCR text|No subtitles recognised|error' }) -join ' ').Trim()
      $scores += [pscustomobject]@{ Index = $s.Index; Lines = -1; EngPct = 0; ForPct = 0
                                    Note = $(if ($why) { "OCR FAILED - $why" } else { 'OCR FAILED - seconv produced no SRT' }) }
      continue
    }
    $text  = Repair-OcrGlyphs -Text (Get-Content $srt -Raw)
    $lines = @($text.Text -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\d+$' -and $_ -notmatch '-->' })
    $eng   = if ($lines.Count) { [math]::Round(100 * @($lines | Where-Object { $_ -match $commonEnglish }).Count / $lines.Count) } else { 0 }
    $for   = if ($lines.Count) { [math]::Round(100 * @($lines | Where-Object { $_ -match $foreignWords  }).Count / $lines.Count) } else { 0 }
    $sample = ($lines | Where-Object { $_.Trim().Length -gt 12 } | Select-Object -First 1)
    $scores += [pscustomobject]@{ Index = $s.Index; Lines = $lines.Count; EngPct = $eng; ForPct = $for; Note = "$sample" }
  }

  Write-Host ''
  Write-Host '  stream  lines  english%  foreign%  first readable line'
  foreach ($sc in $scores) {
    Write-Host ('  {0,6}  {1,5}  {2,7}%  {3,7}%  {4}' -f $sc.Index, $sc.Lines, $sc.EngPct, $sc.ForPct,
                "$($sc.Note)".Substring(0, [Math]::Min(52, "$($sc.Note)".Length)))
  }

  # A SWEEP THAT READ NOTHING HAS NOT FOUND ANYTHING. The first run of this script scored every
  # stream 0% because Tesseract was not on the child's PATH, and then printed "NO ENGLISH STREAM
  # FOUND - this file needs the source disc" - a confident, actionable, entirely false conclusion
  # drawn from its own tooling failure. That is the same defect class as confirming a rip from a
  # grep of anticipated outcomes: an answer shaped like a finding, produced by a check that never
  # ran. So separate "we looked and none was English" from "we could not look", and refuse to
  # conclude in the second case.
  $read    = @($scores | Where-Object { $_.Lines -gt 0 })
  $ocrDead = @($scores | Where-Object { $_.Lines -lt 0 })
  $winner  = @($read | Where-Object { $_.EngPct -ge $MinEnglishPct -and $_.ForPct -le $MaxForeignPct } |
               Sort-Object EngPct -Descending) | Select-Object -First 1
  if (-not $winner -and $read.Count -eq 0) {
    Write-Host ''
    Write-Warning ("  SWEEP FAILED - not one of {0} stream(s) produced OCR text, so NOTHING was ranked." -f $streams.Count)
    Write-Warning  '  This is a TOOLING result, not a finding about the file. Fix the OCR path and re-run;'
    Write-Warning  '  do not read it as "no English stream".'
    if ($ocrDead.Count) { Write-Warning ("  first reason given: {0}" -f $ocrDead[0].Note) }
    $results += [pscustomobject]@{ File = $file; Winner = $null; Note = 'SWEEP FAILED - nothing ranked' }
  }
  elseif (-not $winner) {
    Write-Host ''
    Write-Host ("  NO ENGLISH STREAM FOUND among {0} bitmap stream(s) ({1} ranked, {2} unreadable). This file's" -f `
                $streams.Count, $read.Count, $ocrDead.Count)
    Write-Host  '  remedy is NOT stream selection - it needs the source disc, or transcription.'
    if ($ocrDead.Count) {
      Write-Host ('  CAVEAT: {0} stream(s) could not be OCR''d at all and were never judged.' -f $ocrDead.Count)
    }
    $results += [pscustomobject]@{ File = $file; Winner = $null; Note = "no english stream ($($read.Count) ranked)" }
  } else {
    Write-Host ''
    Write-Host ("  ENGLISH IS STREAM {0}  ({1}% english, {2}% foreign, {3} sample lines)" -f `
                $winner.Index, $winner.EngPct, $winner.ForPct, $winner.Lines) -ForegroundColor Green
    Write-Host ("     pwsh -NoProfile -File $PSScriptRoot/ocr-subtitles.ps1 -Path '{0}' -StreamIndex {1}" -f $file, $winner.Index)
    $results += [pscustomobject]@{ File = $file; Winner = $winner.Index; Note = "$($winner.EngPct)% english" }
    if ($Apply) {
      Write-Host '  -Apply: running the real conversion on that stream'
      & pwsh -NoProfile -File "$PSScriptRoot/ocr-subtitles.ps1" -Path $file -StreamIndex $winner.Index -Lang $Lang -Manual
    }
  }

  if ($staged) { Remove-Item -LiteralPath $staged -Force -EA SilentlyContinue }
  Get-ChildItem $work -File -EA SilentlyContinue | Remove-Item -Force -EA SilentlyContinue
}
}
finally {
  Remove-Item -LiteralPath $work -Recurse -Force -EA SilentlyContinue
}

Write-Host ''
Write-Host '==== summary ===='
foreach ($r in $results) {
  Write-Host ('  {0,-58} {1}' -f (Split-Path $r.File -Leaf), $(if ($null -ne $r.Winner) { "stream $($r.Winner)  ($($r.Note))" } else { $r.Note }))
}
if (-not $Apply -and @($results | Where-Object { $null -ne $_.Winner }).Count) {
  Write-Host ''
  Write-Host '  REPORT ONLY. Re-run with -Apply to convert using the winning stream.'
}
