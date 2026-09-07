<#
.SYNOPSIS
  REFUSE a manifest whose `expectSeconds` and `expectFrames` cannot both describe the same title -
  two figures that imply no real frame rate, so one of them was copied from somewhere else.

.WHY THIS EXISTS
  2026-09-07, The Song Remains The Same. A playlist row read

      expectSeconds : 969.068
      expectFrames  : 27007

  which is 27.87 fps - not a frame rate any disc is authored at. The two numbers came from
  DIFFERENT titles: 969.068 s is the playlist this row encodes, while 27,007 frames is 901.1 s at
  29.97 - the truncated `Extras 08` the row SUPERSEDES. The seconds figure was updated when the
  row was re-pointed at the playlist and the frames figure was not.

  Everything downstream then behaved correctly and still produced a wrong answer. ffmpeg encoded
  the playlist exactly: 969.109 s, 29,043 frames, against a source measuring 969.068 s and 29,043
  packets - a perfect match. transcode.ps1's frame guard compared that to 27,007, called it 2,036
  frames long, quarantined a CORRECT output as `.wrong-length`, and failed the whole 10-item
  manifest. The encode cost 100 s and the diagnosis cost far more, because the evidence pointed at
  the encoder when the fault was in the paperwork.

  A manifest is a set of CLAIMS about a title. `expectSeconds` and `expectFrames` are two
  measurements of one quantity, so they are checkable against each other with no disc access at
  all - the ratio has to land on a real frame rate. That makes this the cheapest possible guard:
  pure arithmetic on the JSON, before a single frame is encoded.

  WHY NOT JUST DROP expectFrames. Because it catches things seconds cannot: a duration can match
  while frames are dropped (The Champions D1 t2 lost 592 frames inside a plausible runtime). Two
  independent measurements are worth keeping - they just have to agree.

.NOTES
  Silent (exit 0) when it cannot judge: rows carrying only one of the two figures are the normal
  case for many kinds, and a guard that refuses on missing evidence blocks the line for reasons
  that are not faults - see assert-edition-layout.ps1's header for the same stance.

.EXAMPLE
  pwsh -NoProfile -File assert-expectations-consistent.ps1 -Manifest D:/video/_queue/x.json
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  # How far the implied rate may sit from a real one before the row is refused, as a fraction.
  # 1.5% is far wider than any rounding in a manifest (the real error above was 7%) and far
  # narrower than the gap between adjacent broadcast rates (23.976 -> 24 is 0.1%, so the tolerance
  # deliberately does NOT try to tell those two apart - it only asks "is this a rate at all").
  [double]$Tolerance = 0.015,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Say "assert-expectations-consistent: no manifest at $Manifest"; exit 0 }
try { $rows = @(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json) }
catch { Say ("assert-expectations-consistent: unreadable manifest ({0}) - not this guard's call to refuse on" -f $_.Exception.Message); exit 0 }

# Every rate a disc in this library is authored at. PAL DVD is 25; NTSC DVD is 29.97 or its 23.976
# film original; Blu-ray adds 24, 50 and 59.94. A row landing on none of these is not "an unusual
# disc" - it is two numbers that were never measured from the same title.
$rates = @(23.976, 24.0, 25.0, 29.97, 30.0, 50.0, 59.94, 60.0)

$judged = 0; $bad = @(); $sparse = @()
foreach ($r in $rows) {
  $hasS = $null -ne $r.expectSeconds -and [double]$r.expectSeconds -gt 0
  $hasF = $null -ne $r.expectFrames  -and [int]$r.expectFrames  -gt 0
  if (-not ($hasS -and $hasF)) { continue }
  $judged++

  $secs = [double]$r.expectSeconds
  $frms = [int]$r.expectFrames
  $fps  = $frms / $secs

  # SPARSE VIDEO IS REAL, AND IT LOOKS EXACTLY LIKE A MISMATCH FROM HERE.
  #
  # The League of Gentlemen's "In Conversation with Paul Jackson" (S00E63) is a 63-MINUTE AUDIO
  # conversation over a NEAR-STATIC image: 3,820.04 s and 383 video packets in total, an implied
  # 0.10 fps. Its manifest row carries a note saying so, and both figures were verified against two
  # independent encodes. The first cut of this guard refused it - a published, correct item.
  #
  # Arithmetic cannot separate that from a genuinely mismatched pair, because both look like "these
  # two numbers imply no real rate". So the rule is asymmetric, on the side where the ambiguity is:
  #
  #   BELOW the lowest real rate -> WARN, do not refuse. A near-static title legitimately lives
  #   here, and transcode.ps1's own guards still measure the output against both figures anyway.
  #
  #   AT or ABOVE the rate band -> REFUSE. There is no such thing as a title carrying MORE frames
  #   per second than the format allows, so a figure landing in or above the band without matching
  #   a real rate was measured from a different title. That is the League of Gentlemen case's
  #   opposite, and it is the case this guard was written for (The Song Remains The Same, 27.87).
  $minRate = ($rates | Measure-Object -Minimum).Minimum
  if ($fps -lt ($minRate * (1 - $Tolerance))) {
    $sparse += [pscustomobject]@{ Out = (Split-Path "$($r.out)" -Leaf); Seconds = $secs; Frames = $frms; Fps = $fps }
    continue
  }

  $best = $null; $bestErr = [double]::MaxValue
  foreach ($cand in $rates) {
    $err = [math]::Abs($fps - $cand) / $cand
    if ($err -lt $bestErr) { $bestErr = $err; $best = $cand }
  }
  if ($bestErr -le $Tolerance) { continue }

  # Say what each figure would mean on its own, at the nearest real rate. That is the repair:
  # whichever of the two matches the source is right and the other is stale.
  $bad += [pscustomobject]@{
    Out       = (Split-Path "$($r.out)" -Leaf)
    Seconds   = $secs
    Frames    = $frms
    Fps       = $fps
    Nearest   = $best
    FramesAt  = [math]::Round($secs * $best)
    SecondsAt = [math]::Round($frms / $best, 2)
  }
}

if (-not $judged) { Say 'assert-expectations-consistent: no row carries BOTH expectSeconds and expectFrames - nothing to cross-check'; exit 0 }

foreach ($s in $sparse) {
  Say ("assert-expectations-consistent: SPARSE VIDEO (not refused) - {0}" -f $s.Out)
  Say ("      {0:N0} video frame(s) over {1:N2}s is {2:N3} fps, below any real rate - a near-static image" -f $s.Frames, $s.Seconds, $s.Fps)
  Say  '      carrying only a handful of packets. Legitimate (League of Gentlemen S00E63 is 383 frames'
  Say  '      over 63 minutes); flagged so it is a KNOWN shape rather than an unexamined one.'
}

if (-not $bad.Count) {
  Say ("assert-expectations-consistent: OK - all {0} row(s) with both figures are consistent" -f $judged)
  exit 0
}

Say ("assert-expectations-consistent: REFUSED - {0} of {1} row(s) carry two figures that cannot describe the same title:" -f $bad.Count, $judged)
foreach ($b in $bad) {
  Say ("   {0}" -f $b.Out)
  Say ("      expectSeconds {0:N3} and expectFrames {1:N0} imply {2:N2} fps - nearest real rate is {3:N3}" -f $b.Seconds, $b.Frames, $b.Fps, $b.Nearest)
  Say ("      at {0:N3} fps: {1:N3}s would be {2:N0} frames, or {3:N0} frames would be {4:N2}s" -f $b.Nearest, $b.Seconds, $b.FramesAt, $b.Frames, $b.SecondsAt)
}
Say ''
Say '   One of the two figures was measured from a DIFFERENT title - most often a row re-pointed at'
Say '   a new source with only one of them updated. Probe the source and correct the stale one:'
Say '      ffprobe -v error -show_entries format=duration -of csv=p=0 <src>'
Say '      ffprobe -v error -select_streams v:0 -count_packets -show_entries stream=nb_read_packets -of csv=p=0 <src>'
Say '   Refused HERE because both figures are gates in transcode.ps1: a stale one quarantines a'
Say '   CORRECT encode as .wrong-length and fails the whole manifest, which is what it did.'
exit 2
