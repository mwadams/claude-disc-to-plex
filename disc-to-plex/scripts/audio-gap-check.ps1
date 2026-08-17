<#
  audio-gap-check.ps1 — detect audio streams that are MISSING FRAMES at a regular cadence.

  WHY. Das Boot (1981) shipped with a ~32 ms hole in every audio track every 0.672 s: one frame
  in every 21 was simply absent, about 4.8% of the audio. Nothing upstream noticed, because every
  structural check passes — the file plays, ffprobe reports no errors, volumedetect sees a normal
  level, the duration is right, and both the encode and the publish verified. Only a listener
  hears it, and only as a periodic tick.

  The defect is invisible to duration checks precisely because the TIMESTAMPS still span the full
  runtime; it is the packets between them that are missing. So this looks at packet CADENCE:
  decode nothing, just read the packet timestamps for a window and compare the number of frames
  present against the number the frame duration says there should be.

  A clean stream has one modal delta (an AC3 frame is 32 ms, AAC 21.3 ms) and essentially no
  outliers. A frame-dropping stream shows a second delta at a multiple of the first, repeating on
  a fixed period.

  Read-only. Reports; changes nothing.

  Usage:
    pwsh -File audio-gap-check.ps1 -Path '\\NASTEAMV\Multimedia\Movies'          # scan a library
    pwsh -File audio-gap-check.ps1 -Path 'D:\video\Movies\X (1999)\X (1999).mkv' # one file
#>
param(
  [Parameter(Mandatory)][string]$Path,
  [int]$Start = 1800,          # sample well inside the film; a title shorter than this is sampled at 25%
  [int]$Dur   = 60,
  [double]$FailPct = 1.0,      # flag a stream missing more than this % of its frames
  [switch]$AllStreams          # by default report only flagged streams
)

$paths   = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'

$files = if (Test-Path -LiteralPath $Path -PathType Leaf) { @(Get-Item -LiteralPath $Path) }
         else { @(Get-ChildItem -LiteralPath $Path -Recurse -File -Filter *.mkv -ErrorAction SilentlyContinue) }

$flagged = @()
foreach ($f in $files) {
  $dur = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null)".Trim()
  if (-not ($dur -as [double])) { continue }
  $ss = if ([double]$dur -lt ($Start + $Dur)) { [int]([double]$dur * 0.25) } else { $Start }

  $na = @(& $ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 $f.FullName 2>$null).Count
  for ($a = 0; $a -lt $na; $a++) {
    $rows = & $ffprobe -v error -read_intervals "$ss%+$Dur" -select_streams "a:$a" `
              -show_entries packet=pts_time -of csv=p=0 $f.FullName 2>$null
    $pts = @(); foreach ($r in $rows) { $v = ($r -split ',')[0]; if ($v -match '^[\d.]+$') { $pts += [double]$v } }
    # Enforce the window ourselves. -read_intervals is a SEEK HINT, not a hard limit: ffprobe can
    # keep emitting past it, which silently turns a 60-second probe into a full-file scan - slow,
    # and it quietly changes what the percentages below are measured over.
    $pts = @($pts | Where-Object { $_ -ge $ss -and $_ -le ($ss + $Dur) })
    if ($pts.Count -lt 50) { continue }

    $deltas = for ($i = 1; $i -lt $pts.Count; $i++) { $pts[$i] - $pts[$i-1] }
    # Frame duration = MEDIAN delta, not the modal one. Packet timestamps are reported to limited
    # precision, so an AAC frame of 21.333 ms arrives as an alternating run of 0.021 and 0.022; the
    # modal value picks 0.021, and dividing the span by a frame duration ~1.6% too short invents a
    # ~1.6-point shortfall in every stream - enough to flag clean files. The median is unaffected
    # by the dropouts themselves as long as they are a minority of the deltas, which they are.
    # The median is a robust starting point but is itself quantised (it lands on 0.021 or 0.022,
    # never 0.021333), so use it only to separate normal deltas from gaps, then take the MEAN of
    # the normal ones - averaging the alternating run recovers the true frame duration.
    $sorted = @($deltas | Sort-Object)
    $approx = [double]$sorted[[int]($sorted.Count / 2)]
    if ($approx -le 0) { continue }
    $normal = @($deltas | Where-Object { $_ -lt $approx * 1.5 })
    if ($normal.Count -lt 10) { continue }
    $modal  = [double](($normal | Measure-Object -Average).Average)
    if ($modal -le 0) { continue }

    # Frames PRESENT vs frames the cadence says the window should hold. A missing frame shows up
    # as a delta of 2x (or more) the modal frame duration, so counting the shortfall directly is
    # more honest than counting outliers: it survives several consecutive drops.
    $span    = $pts[-1] - $pts[0]
    $expect  = [math]::Round($span / $modal)
    $present = $pts.Count - 1
    $missPct = if ($expect -gt 0) { 100.0 * ($expect - $present) / $expect } else { 0 }

    $gapAt = @(); for ($i = 1; $i -lt $pts.Count; $i++) { if (($pts[$i] - $pts[$i-1]) -gt $modal * 1.5) { $gapAt += $pts[$i-1] } }
    $period = if ($gapAt.Count -gt 1) { [math]::Round(($gapAt[-1] - $gapAt[0]) / ($gapAt.Count - 1), 4) } else { 0 }

    $bad = $missPct -ge $FailPct
    if ($bad -or $AllStreams) {
      $line = "{0,-52} a:{1}  frame={2}ms  missing={3}%  gaps={4}  period={5}s" -f `
              $f.Name, $a, [math]::Round($modal * 1000, 2), [math]::Round($missPct,2), $gapAt.Count, $period
      if ($bad) { $flagged += $line; Write-Output "FLAG $line" } else { Write-Output "     $line" }
    }
  }
}

Write-Output ""
Write-Output "scanned $($files.Count) file(s); $($flagged.Count) stream(s) flagged at >= $FailPct% missing frames"
