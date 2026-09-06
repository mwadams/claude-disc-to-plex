<#
.SYNOPSIS
  Build ONE chaptered .mkv from several DVD titles, so a pile of short extras becomes a title Plex
  will actually show.

.WHY
  Plex indexes a movie folder's local extras only when that folder holds exactly ONE movie file.
  `Movies/Led Zeppelin/` held eight concert films in its root beside a `Featurettes/` folder of
  fifteen extras, and Plex showed NONE of the extras (see assert-edition-layout.ps1, which now
  refuses that shape at the gate). Rehousing the eight films fixes the films - but it leaves the
  extras with no parent movie at all, and an extras folder with no main title is still invisible.

  The user's direction, 2026-09-06:

    "If you put the extras under 'Featurettes' but have no main title, then they will not appear in
     Plex. It would be better to concatenate them into a single MKV with named chapters for each of
     the sub elements and put that into a Led Zeppelin DVD (2003) folder and ensure it appears as
     title in Plex."

  So: one film, one folder, one library item, and every extra reachable as a named chapter.

.WHY NOT STREAM-COPY
  The obvious build is `mkvmerge --append` over the already-published extras: no re-encode, minutes
  not hours. It cannot work. The published extras carry TWELVE different rasters (694x572, 708x572,
  480x560, 696x576, 700x572, 698x576, 702x570, 718x576, 720x576, 702x554, 692x574, 480x554) and one
  of them (`Extras 03`) has NO AUDIO STREAM at all, while another has five including DTS. mkvmerge
  refuses to append tracks whose parameters differ, and it is right to.

  That variation is not an artefact of the first encode - the DISC holds mixed rasters, because some
  menu clips are authored half-D1 (480-wide) and the rest full-D1 (720-wide). So NO route to a single
  file avoids a re-encode. Once re-encoding is unavoidable, reading the DVD titles directly is
  strictly better than re-encoding the published files: one generation from the MPEG-2 rather than
  two. That is why this script takes a disc and a spec, not a list of .mkv files.

.HOW
  Per item: decode the DVD title, deinterlace, square the sample aspect, letterbox-fit to a common
  raster, and force a single stereo 48 kHz AAC track - synthesising SILENCE for a title that has no
  audio, because a missing track is exactly what blocks the append. Every intermediate then has
  identical parameters, so the join really is a stream copy and the video is encoded ONCE.

  Chapter times come from PROBING the intermediates, never from the spec's declared seconds. The
  declared value is the guard (a title that decodes to the wrong length FAILS here rather than
  shipping a wrong cut); the measured value is the timeline. Conflating the two is how a compilation
  ends up with chapter marks that drift further from the content with every segment.

.EXAMPLE
  pwsh -File build-chaptered-compilation.ps1 -Spec D:/video/_pending/led-zeppelin-compilation.spec.json `
       -Out 'D:/video/Movies/Led Zeppelin DVD (2003)/Led Zeppelin DVD (2003).mkv'
#>
param(
  [Parameter(Mandatory)][string]$Spec,
  [Parameter(Mandatory)][string]$Out,
  [string]$WorkDir,
  [int]$Width  = 768,
  [int]$Height = 576,
  [int]$Crf    = 18,
  [double]$ToleranceSeconds = 2.0,
  [switch]$KeepIntermediates,
  [switch]$WhatIf,
  [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------------------------
# Pure helpers - unit-testable, no I/O.
# ---------------------------------------------------------------------------------------------

function ConvertTo-Timestamp {
  <# Matroska chapter timestamps are HH:MM:SS.nnnnnnnnn. Anything less precise makes the last
     chapters of a long compilation land visibly early. #>
  param([Parameter(Mandatory)][double]$Seconds)
  if ($Seconds -lt 0) { throw "negative timestamp: $Seconds" }
  $ts = [TimeSpan]::FromSeconds($Seconds)
  # FLOOR, NOT [int]. PowerShell's [int] cast ROUNDS - so 1863 s (0.5175 hours) became hour 1 and a
  # 32-minute compilation got a chapter stamped 01:31:03, past the end of the file. Every timestamp
  # more than half an hour into its hour was wrong. Measured on the Led Zeppelin build, 2026-09-06;
  # the two hour cases in the self-test (1.03 h, 25.0 h) both happened to round the right way, which
  # is why it shipped. TotalHours (not Hours) so a compilation past 24 h still reads 25:00:00.
  $h = [int][math]::Floor($ts.TotalHours)
  # Nanoseconds are computed from the ORIGINAL double, so guard the carry: a value like 12.9999999996
  # rounds to 1e9 ns, which would render as ":12.1000000000" - eleven digits, and unparseable.
  $ns = [long][math]::Round(($Seconds - [math]::Floor($Seconds)) * 1e9)
  $s  = $ts.Seconds
  if ($ns -ge 1000000000) { $ns = 0; return (ConvertTo-Timestamp ([math]::Floor($Seconds) + 1)) }
  '{0:00}:{1:00}:{2:00}.{3:000000000}' -f $h, $ts.Minutes, $s, $ns
}

function Get-ChapterEdges {
  <# Cumulative start times from measured segment durations. Returns one edge per segment; the
     first is always 0. Kept separate from the XML writer so the arithmetic can be tested. #>
  param([Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Durations)
  $edges = @(); $t = 0.0
  foreach ($d in $Durations) { $edges += $t; $t += $d }
  return ,$edges
}

function New-ChapterXml {
  param(
    [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Names,
    [Parameter(Mandatory)][AllowEmptyCollection()][double[]]$Starts
  )
  if ($Names.Count -ne $Starts.Count) { throw "chapter names ($($Names.Count)) and starts ($($Starts.Count)) differ" }
  $sb = [Text.StringBuilder]::new()
  [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
  [void]$sb.AppendLine('<!DOCTYPE Chapters SYSTEM "matroskachapters.dtd">')
  [void]$sb.AppendLine('<Chapters>')
  [void]$sb.AppendLine('  <EditionEntry>')
  [void]$sb.AppendLine('    <EditionFlagDefault>1</EditionFlagDefault>')
  for ($i = 0; $i -lt $Names.Count; $i++) {
    # Chapter names are free text from the spec and routinely carry & and quotes ("Bonham & Jones").
    # Escaping is not optional: an unescaped & makes the XML unparseable and mkvpropedit rejects the
    # whole file, which reads as "the build failed" rather than "one name had an ampersand".
    $safe = [Security.SecurityElement]::Escape($Names[$i])
    [void]$sb.AppendLine('    <ChapterAtom>')
    [void]$sb.AppendLine("      <ChapterTimeStart>$(ConvertTo-Timestamp $Starts[$i])</ChapterTimeStart>")
    [void]$sb.AppendLine('      <ChapterDisplay>')
    [void]$sb.AppendLine("        <ChapterString>$safe</ChapterString>")
    [void]$sb.AppendLine('        <ChapterLanguage>eng</ChapterLanguage>')
    [void]$sb.AppendLine('      </ChapterDisplay>')
    [void]$sb.AppendLine('    </ChapterAtom>')
  }
  [void]$sb.AppendLine('  </EditionEntry>')
  [void]$sb.AppendLine('</Chapters>')
  return $sb.ToString()
}

function Test-SpecItem {
  <# Returns $null when the item is usable, or a string saying what is wrong. A spec is written by
     an agent from disc evidence; the failure that matters is a MISSING or ZERO dvdTitle, because
     ffmpeg would then read title 0 and build a confident, wrong film. #>
  param([Parameter(Mandatory)]$Item, [int]$Index)
  if ($null -eq $Item.dvdTitle)                     { return "item[$Index] has no dvdTitle" }
  $t = 0
  if (-not [int]::TryParse("$($Item.dvdTitle)", [ref]$t)) { return "item[$Index] dvdTitle '$($Item.dvdTitle)' is not an integer" }
  if ($t -lt 1)                                     { return "item[$Index] dvdTitle $t is not >= 1 (dvdvideo titles are 1-based; 0 would silently read the wrong title)" }
  if (-not "$($Item.chapter)".Trim())               { return "item[$Index] (dvdTitle $t) has no chapter name" }
  $s = 0.0
  if (-not [double]::TryParse("$($Item.seconds)", [ref]$s) -or $s -le 0) { return "item[$Index] (dvdTitle $t) has no positive 'seconds' - there would be nothing to verify the decode against" }
  return $null
}

function Test-LocalOutputPath {
  <# The working set NEVER lives on the NAS, and a compilation writes several GB of intermediates.
     Refuse a UNC or E: destination outright rather than trusting the caller. #>
  param([Parameter(Mandatory)][string]$Path)
  $p = "$Path" -replace '/', '\'
  if ($p.StartsWith('\\'))            { return "output is a UNC path - the working set never lives on the NAS: $Path" }
  if ($p -match '^[Ee]:\\')           { return "output is on E: - that drive holds source rips and is read-only to this pipeline: $Path" }
  return $null
}

if ($SelfTest) {
  $fail = 0
  function T($name, $cond) { if ($cond) { "  ok   $name" } else { $script:fail++; "  FAIL $name" } }

  T 'timestamp zero'            ((ConvertTo-Timestamp 0) -eq '00:00:00.000000000')
  T 'timestamp seconds'         ((ConvertTo-Timestamp 65.5) -eq '00:01:05.500000000')
  T 'timestamp hours'           ((ConvertTo-Timestamp 3725.25) -eq '01:02:05.250000000')
  T 'timestamp past 24h'        ((ConvertTo-Timestamp 90000) -eq '25:00:00.000000000')
  # REGRESSION, 2026-09-06: [int] rounds, so anything past the half-hour gained an hour. 1863.3 s is
  # the exact value that stamped a chapter at 01:31:03 inside a 32-minute file.
  T 'timestamp half-hour+ stays in hour 0' ((ConvertTo-Timestamp 1863.3).StartsWith('00:31:03'))
  T 'timestamp 59m59s stays in hour 0'     ((ConvertTo-Timestamp 3599) -eq '00:59:59.000000000')
  T 'timestamp 1h30m is hour 1'            ((ConvertTo-Timestamp 5400) -eq '01:30:00.000000000')
  T 'timestamp ns carry'                   ((ConvertTo-Timestamp 12.9999999996) -eq '00:00:13.000000000')
  T 'timestamp negative throws' $(try { [void](ConvertTo-Timestamp -1); $false } catch { $true })

  $e = Get-ChapterEdges -Durations @(10.0, 20.0, 5.5)
  T 'edges start at zero'       ($e[0] -eq 0.0)
  T 'edges cumulative'          ($e[1] -eq 10.0 -and $e[2] -eq 30.0)
  T 'edges count matches'       ($e.Count -eq 3)
  T 'edges empty ok'            ((Get-ChapterEdges -Durations @()).Count -eq 0)

  $xml = New-ChapterXml -Names @('One','Bonham & Jones') -Starts @(0.0, 12.0)
  T 'xml has both atoms'        (([regex]::Matches($xml, '<ChapterAtom>')).Count -eq 2)
  T 'xml escapes ampersand'     ($xml -match 'Bonham &amp; Jones' -and $xml -notmatch 'Bonham & Jones')
  T 'xml second start'          ($xml -match '00:00:12\.000000000')
  T 'xml parses'                $(try { [void][xml]$xml; $true } catch { $false })
  T 'xml mismatch throws'       $(try { [void](New-ChapterXml -Names @('a') -Starts @(0.0,1.0)); $false } catch { $true })

  T 'item ok'                   ($null -eq (Test-SpecItem ([pscustomobject]@{dvdTitle=5;chapter='x';seconds=10}) 0))
  T 'item no dvdTitle'          ((Test-SpecItem ([pscustomobject]@{chapter='x';seconds=10}) 0) -match 'no dvdTitle')
  T 'item dvdTitle zero'        ((Test-SpecItem ([pscustomobject]@{dvdTitle=0;chapter='x';seconds=10}) 0) -match 'not >= 1')
  T 'item dvdTitle nonint'      ((Test-SpecItem ([pscustomobject]@{dvdTitle='five';chapter='x';seconds=10}) 0) -match 'not an integer')
  T 'item no chapter'           ((Test-SpecItem ([pscustomobject]@{dvdTitle=5;chapter=' ';seconds=10}) 0) -match 'no chapter name')
  T 'item no seconds'           ((Test-SpecItem ([pscustomobject]@{dvdTitle=5;chapter='x'}) 0) -match 'positive')
  T 'item zero seconds'         ((Test-SpecItem ([pscustomobject]@{dvdTitle=5;chapter='x';seconds=0}) 0) -match 'positive')

  T 'out refuses UNC'           ((Test-LocalOutputPath '\\NASTEAMV\Multimedia\x.mkv') -match 'UNC')
  T 'out refuses E:'            ((Test-LocalOutputPath 'E:/Movies/x.mkv') -match 'E:')
  T 'out allows D: fwd slash'   ($null -eq (Test-LocalOutputPath 'D:/video/Movies/x/x.mkv'))
  T 'out allows D: backslash'   ($null -eq (Test-LocalOutputPath 'D:\video\Movies\x\x.mkv'))

  if ($fail) { "SELFTEST FAILED - $fail case(s)"; exit 1 }
  'SELFTEST OK'; exit 0
}

# ---------------------------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------------------------

$badOut = Test-LocalOutputPath $Out
if ($badOut) { Write-Output "REFUSE - $badOut"; exit 2 }

$toolsCfg = 'D:/video/.transcode-tools/tool-paths.json'
if (-not (Test-Path -LiteralPath $toolsCfg)) { Write-Output "REFUSE - no tool-paths.json at $toolsCfg"; exit 2 }
$tools    = Get-Content -LiteralPath $toolsCfg -Raw | ConvertFrom-Json
$ff       = $tools.ffmpeg
$fp       = Join-Path (Split-Path $ff) 'ffprobe.exe'
$mkvdir   = Split-Path $tools.mkvextract
$mkvmerge = Join-Path $mkvdir 'mkvmerge.exe'
$mkvprop  = Join-Path $mkvdir 'mkvpropedit.exe'
foreach ($t in @($ff, $fp, $mkvmerge, $mkvprop)) {
  if (-not (Test-Path -LiteralPath $t)) { Write-Output "REFUSE - missing tool: $t"; exit 2 }
}

if (-not (Test-Path -LiteralPath $Spec)) { Write-Output "REFUSE - no spec at $Spec"; exit 2 }
$s = Get-Content -LiteralPath $Spec -Raw -Encoding UTF8 | ConvertFrom-Json

$disc = "$($s.disc)"
if (-not $disc -or -not (Test-Path -LiteralPath $disc)) { Write-Output "REFUSE - spec 'disc' missing or not present: $disc"; exit 2 }
$discNorm = $disc -replace '/', '\'
if ($discNorm.StartsWith('\\')) { Write-Output "REFUSE - spec 'disc' is on the NAS; stage it locally first: $disc"; exit 2 }

$items = @($s.items)
if ($items.Count -lt 2) { Write-Output "REFUSE - spec has $($items.Count) item(s); a compilation needs at least 2"; exit 2 }

$problems = @()
for ($i = 0; $i -lt $items.Count; $i++) {
  $p = Test-SpecItem $items[$i] $i
  if ($p) { $problems += $p }
}
if ($problems.Count) {
  Write-Output "REFUSE - $($problems.Count) problem(s) in the spec:"
  $problems | ForEach-Object { Write-Output "    $_" }
  exit 2
}

# dvdTitle appearing twice means two chapters would hold identical content - always a spec error,
# and one that a duration check cannot catch because both copies decode to the right length.
$dupes = @($items | Group-Object { "$($_.dvdTitle)" } | Where-Object { $_.Count -gt 1 })
if ($dupes.Count) {
  Write-Output "REFUSE - dvdTitle repeated in the spec (the same content would appear twice):"
  $dupes | ForEach-Object { Write-Output "    dvdTitle $($_.Name) x$($_.Count): $((($_.Group | ForEach-Object { $_.chapter }) -join ' | '))" }
  exit 2
}

Write-Output "compilation: $($s.work)"
Write-Output "  disc  : $disc"
Write-Output "  items : $($items.Count)"
Write-Output "  out   : $Out"
Write-Output "  raster: ${Width}x${Height} square pixels, 25 fps, one stereo AAC track"

if ($WhatIf) {
  $n = 1
  foreach ($it in $items) {
    Write-Output ("  {0,2}. dvdTitle {1,-3} {2,7:N1}s  {3}" -f $n, $it.dvdTitle, [double]$it.seconds, $it.chapter)
    $n++
  }
  $tot = ($items | Measure-Object -Property seconds -Sum).Sum
  Write-Output ("  declared total {0:N0} s ({1:hh\:mm\:ss})" -f $tot, [TimeSpan]::FromSeconds($tot))
  exit 0
}

if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ("compilation-" + [guid]::NewGuid().ToString('N').Substring(0,8)) }
New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
Write-Output "  work  : $WorkDir"

$outDir = Split-Path -Parent $Out
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

# --- Stage A: normalise each title to identical parameters -----------------------------------
# Every knob here exists to make the intermediates byte-compatible for the append:
#   bwdif        DVD is interlaced; deinterlace before any scaling or the field comb is baked in.
#   scale iw*sar squares the sample aspect FIRST, so a 16:9 anamorphic clip and a 4:3 one both
#                arrive at their true shape before being fitted (skip this and the anamorphic ones
#                come out horizontally squashed - and it looks plausible, which is worse).
#   fit + pad    letterbox rather than stretch: half-D1 menu clips keep their geometry.
#   setsar=1     square pixels, so no downstream player re-applies a DAR.
#   fps=25       PAL; a fixed rate keeps the appended timeline linear.
$vf = "bwdif=mode=send_frame,scale=trunc(iw*sar/2)*2:ih,scale=${Width}:${Height}:force_original_aspect_ratio=decrease,pad=${Width}:${Height}:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=25"

$parts = @(); $measured = @(); $names = @()
$n = 0
foreach ($it in $items) {
  $n++
  $part = Join-Path $WorkDir ("{0:00}.mkv" -f $n)
  $log  = Join-Path $WorkDir ("{0:00}.log" -f $n)
  $inspec = @('-f','dvdvideo','-title',[string]$it.dvdTitle,'-i',$disc)

  # A title with no audio stream is not an error - it is a silent menu clip. Give it silence, so
  # every intermediate carries exactly one audio track and the append stays a stream copy.
  $nAud = @(& $fp -v error @inspec -select_streams a -show_entries stream=index -of csv=p=0 2>$null |
            Where-Object { $_ -match '^\d+$' } | Sort-Object -Unique).Count
  $silent = ($nAud -eq 0)

  $args = @('-hide_banner','-nostdin','-y') + $inspec
  if ($silent) { $args += @('-f','lavfi','-i','anullsrc=channel_layout=stereo:sample_rate=48000') }
  $args += @('-map','0:v:0')
  $args += @(if ($silent) { '-map','1:a:0','-shortest' } else { '-map','0:a:0' })
  $args += @('-vf',$vf,'-c:v','libx264','-preset','slow','-crf',[string]$Crf,'-pix_fmt','yuv420p',
             '-c:a','aac','-ac','2','-ar','48000','-b:a','192k','-sn','-dn','-map_chapters','-1',$part)

  # RESUMABLE. An intermediate that already exists and probes to the right length is reused, so a
  # killed build - or a re-run to fix the JOIN or the CHAPTERS, which cost seconds while the encodes
  # cost half an hour - does not re-encode what is already correct. The reuse is gated on the same
  # duration guard the fresh encode faces, so a truncated leftover is re-encoded rather than trusted.
  $reuse = $false
  if (Test-Path -LiteralPath $part) {
    $have = 0.0
    if ([double]::TryParse("$(& $fp -v error -show_entries format=duration -of csv=p=0 $part 2>$null)".Trim(), [ref]$have)) {
      if ([math]::Abs($have - [double]$it.seconds) -le $ToleranceSeconds) { $reuse = $true }
    }
    if (-not $reuse) { Remove-Item -LiteralPath $part -Force -ErrorAction SilentlyContinue }
  }

  Write-Output ("  [{0}/{1}] dvdTitle {2} -> {3}{4}{5}" -f $n, $items.Count, $it.dvdTitle, (Split-Path -Leaf $part), $(if ($silent) { '  (no audio on disc; silence synthesised)' } else { '' }), $(if ($reuse) { '  (reusing existing intermediate)' } else { '' }))
  if (-not $reuse) { & $ff @args *> $log }
  if ((-not $reuse -and $LASTEXITCODE -ne 0) -or -not (Test-Path -LiteralPath $part)) {
    Write-Output "  FAILED - ffmpeg exit $LASTEXITCODE on dvdTitle $($it.dvdTitle). Log tail:"
    Get-Content -LiteralPath $log -Tail 20 | ForEach-Object { Write-Output "      $_" }
    exit 1
  }

  $dur = [double]("$(& $fp -v error -show_entries format=duration -of csv=p=0 $part)".Trim())
  $want = [double]$it.seconds
  $delta = [math]::Abs($dur - $want)
  Write-Output ("        decoded {0,8:N2}s  expected {1,8:N2}s  delta {2,6:N2}s" -f $dur, $want, ($dur - $want))
  if ($delta -gt $ToleranceSeconds) {
    # The whole point of the guard: a title that decodes to the wrong length is a WRONG CUT, and a
    # wrong cut inside a compilation is invisible once joined.
    Write-Output "  FAILED - dvdTitle $($it.dvdTitle) decoded $([math]::Round($dur,2))s but the spec says $want s (tolerance ${ToleranceSeconds}s)."
    Write-Output "           Either the spec's dvdTitle is wrong, or this demuxer truncates the title (multi-cell)."
    Write-Output "           Intermediates kept for inspection: $WorkDir"
    exit 1
  }

  $parts    += $part
  $measured += $dur
  $names    += "$($it.chapter)".Trim()
}

# --- Stage B: append (stream copy) ------------------------------------------------------------
Write-Output "  joining $($parts.Count) segment(s) - stream copy, no second encode"
$mergeArgs = @('-o', $Out, '--no-chapters', $parts[0])
foreach ($p in $parts[1..($parts.Count-1)]) { $mergeArgs += @('+', '--no-chapters', $p) }
$mergeLog = Join-Path $WorkDir 'merge.log'
& $mkvmerge @mergeArgs *> $mergeLog
# mkvmerge: 0 = ok, 1 = warnings but the file IS written, 2 = error.
if ($LASTEXITCODE -ge 2 -or -not (Test-Path -LiteralPath $Out)) {
  Write-Output "  FAILED - mkvmerge exit $LASTEXITCODE. Log tail:"
  Get-Content -LiteralPath $mergeLog -Tail 25 | ForEach-Object { Write-Output "      $_" }
  exit 1
}
if ($LASTEXITCODE -eq 1) { Write-Output "  (mkvmerge reported warnings - see $mergeLog)" }

# --- Stage C: chapters from MEASURED durations -------------------------------------------------
$starts   = Get-ChapterEdges -Durations $measured
$xmlPath  = Join-Path $WorkDir 'chapters.xml'
New-ChapterXml -Names $names -Starts $starts | Set-Content -LiteralPath $xmlPath -Encoding UTF8
& $mkvprop $Out --chapters $xmlPath *> (Join-Path $WorkDir 'propedit.log')
if ($LASTEXITCODE -ne 0) {
  Write-Output "  FAILED - mkvpropedit exit $LASTEXITCODE applying chapters. Log:"
  Get-Content -LiteralPath (Join-Path $WorkDir 'propedit.log') -Tail 20 | ForEach-Object { Write-Output "      $_" }
  exit 1
}

# --- Stage D: verify the artefact, not the exit codes ------------------------------------------
$total    = [double]("$(& $fp -v error -show_entries format=duration -of csv=p=0 $Out)".Trim())
$expected = ($measured | Measure-Object -Sum).Sum
$chapters = @(& $mkvmerge --identify --identification-format json $Out 2>$null | ConvertFrom-Json).chapters
$chapCount = 0
if ($chapters) { $chapCount = ($chapters | Measure-Object -Property num_entries -Sum).Sum }

Write-Output ""
Write-Output ("  total    {0:N1}s ({1:hh\:mm\:ss})  expected {2:N1}s  delta {3:N2}s" -f $total, [TimeSpan]::FromSeconds($total), $expected, ($total - $expected))
Write-Output ("  chapters {0} (spec declared {1})" -f $chapCount, $items.Count)
Write-Output ("  size     {0:N0} MB" -f ((Get-Item -LiteralPath $Out).Length / 1MB))

$bad = @()
if ([math]::Abs($total - $expected) -gt ($ToleranceSeconds * $items.Count)) { $bad += "joined duration is $([math]::Round($total-$expected,2))s off the sum of its segments" }
if ($chapCount -ne $items.Count) { $bad += "wrote $chapCount chapter(s) for $($items.Count) item(s)" }
# COUNT IS NOT PLACEMENT. The first build wrote all 11 chapters - the count check passed - and
# stamped the last one at 01:31:03 inside a 32-minute file, because [int] rounded 0.5175 hours up to
# 1. A chapter past the end of the file is unreachable and the count says nothing about it. So
# assert the timeline itself: strictly increasing, starting at zero, every mark inside the file.
if ($starts.Count -gt 0 -and $starts[0] -ne 0.0) { $bad += "first chapter starts at $($starts[0])s, not 0" }
for ($i = 1; $i -lt $starts.Count; $i++) {
  if ($starts[$i] -le $starts[$i-1]) { $bad += "chapter $($i+1) starts at $([math]::Round($starts[$i],2))s, not after chapter $i at $([math]::Round($starts[$i-1],2))s" }
}
$outside = @(0..($starts.Count-1) | Where-Object { $starts[$_] -ge $total })
foreach ($i in $outside) { $bad += "chapter $($i+1) ('$($names[$i])') starts at $([math]::Round($starts[$i],2))s, past the file's $([math]::Round($total,2))s" }
if ($bad.Count) {
  Write-Output "  FAILED verification:"
  $bad | ForEach-Object { Write-Output "      $_" }
  Write-Output "  Intermediates kept: $WorkDir"
  exit 1
}

Write-Output ""
Write-Output "  chapter map:"
for ($i = 0; $i -lt $names.Count; $i++) {
  Write-Output ("    {0,2}. {1}  {2}" -f ($i+1), (ConvertTo-Timestamp $starts[$i]).Substring(0,8), $names[$i])
}

if (-not $KeepIntermediates) {
  # Local scratch only - $WorkDir came from GetTempPath() or the caller, and the output-path guard
  # above has already refused any UNC destination.
  Remove-Item -LiteralPath $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
  Write-Output "  intermediates kept: $WorkDir"
}

Write-Output ""
Write-Output "BUILT  $Out"
exit 0
