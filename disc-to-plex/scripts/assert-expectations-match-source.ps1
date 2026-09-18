<#
.SYNOPSIS
  REFUSE a manifest whose `expectSeconds` does not match the SOURCE FILE it claims to describe.

.WHY THIS EXISTS - AND WHY assert-expectations-consistent.ps1 CANNOT DO IT
  That guard compares `expectSeconds` against `expectFrames` and asks whether the ratio is a real
  frame rate. Its header is explicit that this is deliberate: "checkable against each other with no
  disc access at all - the cheapest possible guard". It catches one figure being copied from another
  title. It CANNOT catch both figures being wrong by the same factor, because then they agree
  perfectly with each other and imply a perfectly ordinary 29.97 fps.

  That is exactly what happened. The Rubber-Keyed Wonder Disc 2, 2026-09-11: all EIGHTEEN rows
  carried an `expectSeconds` precisely 1.000 s too high, and `expectFrames` precisely 30 too high.
  Internally consistent, so this chain passed them; every encode then came out 30 frames "short",
  was quarantined as `.wrong-length`, and the whole manifest failed - 35 GB of correct encodes
  rejected, the unit escalated, and ~146 GB of staging held for hours on a disk that was already
  below its fetch floor.

  THE SOURCE OF THE ERROR, since a guard should say what it is guarding against. The catalogue
  records MakeMKV's own duration string, which is ROUNDED UP to the whole second:

      catalogue duration   0:17:46      (= 1066 s)
      true source          1065.130 s
      manifest wrote       1066.13 s    = ceil(1065.130) + 0.130

  The integer part was taken from the rounded-up string and the fraction re-attached from the true
  measurement. `_briefs/manifest.md` already says to take these figures from the EMITTED PACKET
  COUNTS; that instruction was there and was not followed, which is the usual reason a rule needs to
  become a check.

.WHAT IT CHECKS
  Only rows whose `src` is a FILE this machine can probe - a rip's .mkv, a BD .m2ts. For those the
  source's own container duration is the authority, and `expectSeconds` must match it.

.WHAT IT DELIBERATELY SKIPS, silently (exit 0)
  * `src` that is a DIRECTORY - a DVD's VIDEO_TS. ffprobe cannot open a folder, and the row's
    `title` selects one title from many, so the folder has no single duration to compare.
  * rows carrying a non-empty `title` - the source holds several titles and `expectSeconds`
    describes ONE of them, not the file.
  * `kind` STILLS - assembled from carved PGC pages, not transcoded from a runtime.
  * rows with no `expectSeconds`, a missing source, or an unprobeable one.
  A guard that cannot measure has not found a fault: it must not refuse.

.NOTES
  ONE header probe per row - no decode, no packet count. `format=duration` is a few KB even on a
  31 GB mkv, so this is cheap enough to sit in the gate chain.

  Exit 0 = nothing to refuse.  Exit 2 = REFUSED.
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  # The real error was 1.000 s. Container/encoder rounding is far smaller - a correct encode of a
  # 1065.130 s source measured 1065.151 s, 0.021 s out - so 0.50 s sits an order of magnitude above
  # the noise and an order of magnitude below the fault it exists to catch.
  [double]$ToleranceSeconds = 0.50,
  [string]$ToolsDir = 'D:/video/.transcode-tools',
  [switch]$Quiet
)

function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path -LiteralPath $Manifest)) { Say "assert-expectations-match-source: no manifest at $Manifest - nothing to check."; exit 0 }
try { $mj = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json }
catch { Say "assert-expectations-match-source: $Manifest is not readable JSON - leaving it to the gate's own parser."; exit 0 }

# ConvertFrom-Json UNWRAPS a single-element array, so a one-row manifest is not an array and an
# `-is [System.Array]` test would read zero rows and exit 0 having checked nothing.
$rows = @()
if ($null -ne $mj) {
  if ($mj -isnot [System.Array] -and $mj.PSObject.Properties.Name -contains 'outputs') { $rows = @($mj.outputs) }
  else { $rows = @($mj) }
}
if (-not $rows.Count) { Say 'assert-expectations-match-source: no rows in this manifest.'; exit 0 }

$ffprobe = $null
try {
  $paths = Get-Content (Join-Path $ToolsDir 'tool-paths.json') -Raw | ConvertFrom-Json
  $ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'
} catch { }
if (-not $ffprobe -or -not (Test-Path -LiteralPath $ffprobe)) {
  Say 'assert-expectations-match-source: ffprobe not found - CANNOT MEASURE, so nothing is refused.'
  exit 0
}

function Get-Text($row, [string]$name) {
  if ($null -eq $row -or $row.PSObject.Properties.Name -notcontains $name) { return '' }
  return "$($row.$name)".Trim()
}

$faults = @(); $fieldFaults = @(); $containerOverruns = @(); $checked = 0; $skipped = 0
foreach ($r in $rows) {
  $exp = Get-Text $r 'expectSeconds'
  if (-not $exp) { $skipped++; continue }
  $expSec = 0.0
  if (-not [double]::TryParse($exp, [ref]$expSec) -or $expSec -le 0) { $skipped++; continue }
  if ((Get-Text $r 'kind') -eq 'STILLS') { $skipped++; continue }
  # A non-empty `title` means the source holds several titles and this row is ONE of them.
  if ((Get-Text $r 'title') -ne '') { $skipped++; continue }

  $src = (Get-Text $r 'src') -replace '/', '\'
  if (-not $src) { $skipped++; continue }
  if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { $skipped++; continue }   # folder, or gone

  $raw = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $src 2>$null)".Trim()
  $act = 0.0
  # ffprobe returns the STRING 'N/A' when the header carries no duration, and [double]'N/A' throws.
  if (-not [double]::TryParse($raw, [ref]$act) -or $act -le 0) { $skipped++; continue }

  $checked++

  # FIELD-CODED INTERLACED H.264 PUTS EACH FIELD IN ITS OWN PACKET. 2026-09-17: every Firefly Blu-ray
  # SD extra (720x480, field_order tt, 30000/1001) was manifested with expectFrames = the source's
  # PACKET count - 103,036 for a 1719 s title, i.e. 59.94 per second - and the encoder rightly wrote
  # 51,518 frames at 29.97, so all eleven correct encodes were quarantined as .wrong-length. The ratio
  # passes assert-expectations-consistent (59.94 is a real rate); only the source's own frame rate and
  # field order show the packets are FIELDS.
  $expF = Get-Text $r 'expectFrames'
  $expFrames = 0
  if ($expF -and [int]::TryParse(($expF -replace '\.0+$', ''), [ref]$expFrames) -and $expFrames -gt 0) {
    # avg_frame_rate, NOT r_frame_rate: Friends S5 D2's Season 5 Overview (bb, 2026-09-17) reports
    # r_frame_rate 60000/1001 - the FIELD rate - and avg 30000/1001, so a test on r_frame_rate missed it.
    # ONE LINE: a BD .m2ts lists each stream once per PROGRAM, so ffprobe prints the answer twice.
    $fo = "$(& $ffprobe -v error -select_streams v:0 -show_entries stream=field_order -of csv=p=0 $src 2>$null | Select-Object -First 1)".Trim().TrimEnd(',')
    if ($fo -notmatch '^(tt|bb|tb|bt)$') { $fo = '' }
    $rfr = 0.0
    foreach ($key in 'avg_frame_rate', 'r_frame_rate') {
      $v = "$(& $ffprobe -v error -select_streams v:0 -show_entries stream=$key -of csv=p=0 $src 2>$null | Select-Object -First 1)".Trim().TrimEnd(',')
      if ($v -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -ne 0 -and [double]$Matches[1] -gt 0) { $rfr = [double]$Matches[1] / [double]$Matches[2]; break }
    }
    $rate = $expFrames / $act
    if ($fo -and $rfr -gt 0 -and [math]::Abs($rate - 2 * $rfr) -le 0.01 * 2 * $rfr) {
      $fieldFaults += [pscustomobject]@{
        Out = (Split-Path (Get-Text $r 'out') -Leaf); Src = (Split-Path $src -Leaf)
        Expect = $expFrames; Should = [int][math]::Floor($expFrames / 2); FieldOrder = $fo; Rate = $rfr
      }
    }
  }

  $delta = $expSec - $act
  if ([math]::Abs($delta) -gt $ToleranceSeconds) {
    # A CONTAINER CAN BE LONGER THAN THE PROGRAMME, and then the container is NOT the authority.
    #
    # Friends S7 D2 t06 (S07E16), 2026-09-18: container 1376.320 s, last video packet 1315.356 s,
    # last audio packet 1316.320 s - and a PGS SUBTITLE stream declaring 1376.320 s, which is what
    # the container duration was reporting. Its siblings t05 and t07 have container == last audio
    # packet to the millisecond, so nothing was wrong with the manifest: 1316.352 s is the
    # programme, and the extra minute is a subtitle track hanging off the end.
    #
    # Refusing that row would have been actively harmful. "Correct it to the source" means writing
    # 1376.320, and transcode.ps1 would then quarantine the CORRECT ~1316 s encode as .wrong-length
    # - the exact failure this gate exists to prevent, caused by the gate.
    #
    # So before declaring a fault, MEASURE THE A/V EXTENT: the last video and audio packet. Only on
    # a row that would otherwise fail, and only over the tail of the file, so the fast path stays
    # one header probe per row as the header promises.
    # EACH STREAM'S OWN END, NOT JUST THE LATEST. Video and audio rarely end together, and a
    # manifest may legitimately describe either: Friends S7 D2 t06 took the AUDIO end (1316.352 vs
    # audio 1316.320), while Friends S8 D1 t12/t13 took the VIDEO end (1317.400 = 31,586 packets at
    # 23.976, vs video 1317.358, audio 1318.304). Comparing only against the LATER of the two
    # refused the second pair - a 0.9 s disagreement between the two streams of the same file, read
    # as a wrong expectation. transcode.ps1 tolerates 2 s under and re-measures the kept streams
    # before quarantining anything, so either end is a workable expectation; what must NOT pass is a
    # figure matching neither, which is what a real mistake looks like.
    $vExtent = 0.0; $aExtent = 0.0
    $tailFrom = [math]::Max(0, $act - 120)
    foreach ($sel in 'v:0', 'a:0') {
      $pts = @(& $ffprobe -v error -select_streams $sel -read_intervals ("{0}%+#100000" -f [int]$tailFrom) `
                 -show_entries packet=pts_time -of csv=p=0 $src 2>$null |
               Where-Object { $_ -match '^[0-9]+(\.[0-9]+)?$' })
      if ($pts.Count) { if ($sel -eq 'v:0') { $vExtent = [double]$pts[-1] } else { $aExtent = [double]$pts[-1] } }
    }
    $avExtent = [math]::Max($vExtent, $aExtent)
    # One frame of slack on top of the last packet's START time: at 23.976 fps that is 0.042 s.
    $matchesAnEnd = @($vExtent, $aExtent) | Where-Object { $_ -gt 0 -and [math]::Abs($expSec - $_) -le ($ToleranceSeconds + 0.05) }
    if ($matchesAnEnd.Count) {
      $containerOverruns += [pscustomobject]@{
        Out = (Split-Path (Get-Text $r 'out') -Leaf); Src = (Split-Path $src -Leaf)
        Expect = $expSec; Container = $act; AvExtent = $avExtent
        Which = $(if ([math]::Abs($expSec - $vExtent) -le ($ToleranceSeconds + 0.05)) { 'video' } else { 'audio' })
        VideoEnd = $vExtent; AudioEnd = $aExtent
      }
    } else {
      $faults += [pscustomobject]@{
        Out = (Split-Path (Get-Text $r 'out') -Leaf)
        Src = (Split-Path $src -Leaf)
        Expect = $expSec; Actual = $act; Delta = $delta
        AvExtent = $avExtent
      }
    }
  }
}

# SAID OUT LOUD EVEN THOUGH IT PASSES. A silent pass here would leave the next reader with a
# manifest whose expectSeconds visibly disagrees with `ffprobe -show_entries format=duration` and no
# record of why that is correct.
if ($containerOverruns.Count) {
  Say ''
  Say ("CONTAINER RUNS PAST THE PROGRAMME - {0} row(s) match the A/V content, not the container:" -f $containerOverruns.Count)
  foreach ($c in $containerOverruns) {
    Say ("   {0}" -f $c.Out)
    Say ("      manifest {0,12:N3}s  =  the {1} end ({2:N3}s)   BUT container says {3,12:N3}s   ({4})" -f `
         $c.Expect, $c.Which, $(if ($c.Which -eq 'video') { $c.VideoEnd } else { $c.AudioEnd }), $c.Container, $c.Src)
    if ([math]::Abs($c.VideoEnd - $c.AudioEnd) -gt 0.5) {
      Say ("      (video ends {0:N3}s, audio {1:N3}s - the streams do not end together on this source)" -f $c.VideoEnd, $c.AudioEnd)
    }
  }
  Say  '   A subtitle or data stream declaring a longer duration inflates the container. The encode'
  Say  '   will be the A/V length, so the manifest is RIGHT and is left alone.'
}

if ($faults.Count) {
  Say ''
  Say ("EXPECTATION DOES NOT MATCH THE SOURCE - {0} of {1} measurable row(s):" -f $faults.Count, $checked)
  Say ''
  foreach ($f in ($faults | Select-Object -First 25)) {
    Say ("   {0}" -f $f.Out)
    Say ("      source {0,12:N3}s   manifest {1,12:N3}s   {2:+0.000;-0.000}s   ({3})" -f $f.Actual, $f.Expect, $f.Delta, $f.Src)
    # Say what the tail probe found, so "the container is long" and "the manifest is wrong" are
    # distinguishable at a glance rather than by re-measuring.
    if ($f.AvExtent -gt 0) { Say ("      last A/V packet {0,12:N3}s - so the container is not merely overrunning" -f $f.AvExtent) }
  }
  if ($faults.Count -gt 25) { Say ("   ... and {0} more" -f ($faults.Count - 25)) }
  Say ''
  $deltas = @($faults | ForEach-Object { [math]::Round($_.Delta, 2) })
  $uniform = (@($deltas | Sort-Object -Unique).Count -le 2)
  if ($uniform -and $faults.Count -gt 2) {
    Say  'EVERY ROW IS OUT BY THE SAME AMOUNT. That is not a per-title mistake, it is one rule applied'
    Say  'wrongly to all of them - the commonest being MakeMKV''s duration string, which ROUNDS UP to'
    Say  'the whole second (0:17:46 for a 1065.130 s title). Take these figures from the EMITTED'
    Say  'PACKET COUNTS as _briefs/manifest.md rule 2 says, not from the catalogue''s duration text.'
  } else {
    Say  'Re-measure from the source and correct the row. The source is the authority: transcode.ps1'
    Say  'quarantines an output as .wrong-length by comparing against these figures, so a wrong'
    Say  'expectation rejects a CORRECT encode and fails the whole manifest.'
  }
  exit 2
}

if ($fieldFaults.Count) {
  Say ''
  Say ("expectFrames COUNTS FIELDS, NOT FRAMES - {0} row(s) from a field-coded interlaced source:" -f $fieldFaults.Count)
  Say ''
  foreach ($f in ($fieldFaults | Select-Object -First 25)) {
    Say ("   {0}" -f $f.Out)
    Say ("      expectFrames {0,9:N0} = 2x the source's {1:N3} fps (field_order {2}); the encode writes {3:N0} frames   ({4})" -f $f.Expect, $f.Rate, $f.FieldOrder, $f.Should, $f.Src)
  }
  Say ''
  Say 'Each field of a PAFF-coded H.264 stream is its own packet, so -count_packets on the SOURCE doubles the'
  Say 'frame count, while transcode.ps1 counts the OUTPUT''s whole frames. Set expectFrames to the value shown.'
  exit 2
}

Say ("assert-expectations-match-source: OK - {0} row(s) measured against their source, {1} not measurable (DVD folder, multi-title, STILLS or no figure)." -f $checked, $skipped)
exit 0
