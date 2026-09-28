<#
.SYNOPSIS
  Measure a carved DVD VOB's AUDIO PRE-ROLL - sound that sits ahead of the first picture, which a
  DVD player never presents - and return the output-side trim that removes it. Dot-source this;
  it defines functions and does nothing on its own.

.REACH FOR THIS WHEN
  A carved .vob item (dvd-angle-cells.py angle carve, or a vobSectors cut) fails transcode.ps1's
  CFR check as "SEAM GAP" although retime-vob-cells.py reports ONE continuous video timeline -
  look at the FIRST packet of each stream before looking at any seam.

.WHY THIS EXISTS (2026-09-28, The Invisible Enemy, CGI Effects angle of Parts Two and Three)
  Both items failed as SEAM GAP, +6 frames (packets 37,901 / CFR 37,907 and 34,976 / 34,982). There
  was no seam gap. The retimer's 24 cells joined exactly (37,901 pictures, DTS span = 37,900 x 3,600
  ticks), and the failed output's 37,901 video PTS stepped by exactly 40 ms from end to end. The
  empty timeline was all AT THE START: the output's video began at 0.200 s and its audio at 0.

  Measured on the carves themselves (ffprobe first packets; first NAV pack's PCI VOBU_S_PTM):

      carve          VOBU_S_PTM   first video PTS   first audio PTS   audio lead
      PGC 2 (Pt 1)   0.287267     0.287267          0.287267          0          -> passed
      PGC 3 (Pt 2)   0.348689     0.348689          0.156689          0.192 s    -> SEAM GAP
      PGC 4 (Pt 3)   0.284711     0.284711          0.092711          0.192 s    -> SEAM GAP
      PGC 5 (Pt 4)   0.287267     0.287267          0.287267          0          -> passed

  The disc authors audio packets up to a VOBU ahead of the title's presentation start (the first
  VOBU's VOBU_S_PTM, which is the first picture's PTS). A player starts its clock at VOBU_S_PTM and
  never plays them, and ffmpeg's dvdvideo demuxer discards them for the same reason - which is why
  the SAME disc's angle-1 titles (S15E06/E07, read through dvdvideo) start video and audio together
  at 0. A carve is read by the plain mpegps demuxer, which keeps them, so the MKV opened with 0.192 s
  (4.8 frames) of sound over no picture. Nothing about the carve or the retimer was wrong; the
  carved route simply lacked the demuxer's presentation-start rule.

  The only prior fix for this shape was a hand-set `startSeconds` (The Silurians D2 S00E241). That
  is a per-disc manual step for a MEASURABLE quantity, so it is derived here instead.

.THE RULE
  lead = firstVideoPts - min(first PTS of every KEPT audio stream). Trim only when:
    * lead >= one frame     - below that there is no empty frame slot to fill
    * lead <= MaxLeadSeconds (1.0 s) - a pre-roll is at most a VOBU; anything longer is not
      pre-roll and is left for the CFR gate to fail loudly, never trimmed silently
  The trim is expressed in the OUTPUT timeline ffmpeg builds, whose zero is the INPUT's start_time
  (the minimum over ALL its streams, mapped or not), so:
      trim = (firstVideoPts - inputStart) - MarginSeconds
  The 1 ms margin keeps the first picture on the kept side of an output-side -ss whose comparison
  is >=, so the video payload is never touched - expectFrames stays an exact count.

  The trim cuts ONLY sound the player would not have played, so the manifest's expectSeconds /
  expectFrames (which describe the video) need no adjustment - unlike `startSeconds`, which also
  cuts pictures and is subtracted by the length guards.
#>

function Get-CarvePrerollTrim {
  param(
    [Parameter(Mandatory)][double]$VideoStart,
    [double[]]$AudioStarts = @(),
    [double]$InputStart = [double]::NaN,
    [double]$FrameSeconds = 0.04,
    [double]$MaxLeadSeconds = 1.0,
    [double]$MarginSeconds = 0.001
  )
  $aud = @($AudioStarts | Where-Object { -not [double]::IsNaN($_) })
  if (-not $aud.Count) {
    return [pscustomobject]@{ Trim = 0.0; Lead = 0.0; Reason = 'no-audio' }
  }
  $earliest = ($aud | Measure-Object -Minimum).Minimum
  $lead = [Math]::Round($VideoStart - $earliest, 6)
  if ($lead -lt $FrameSeconds) {
    return [pscustomobject]@{ Trim = 0.0; Lead = $lead; Reason = 'none' }
  }
  if ($lead -gt $MaxLeadSeconds) {
    return [pscustomobject]@{ Trim = 0.0; Lead = $lead; Reason = 'too-large' }
  }
  $origin = if ([double]::IsNaN($InputStart)) { $earliest } else { [Math]::Min($InputStart, $earliest) }
  # Rounded to the microsecond (ffmpeg's -ss resolution); the 1 ms margin dwarfs the rounding.
  $trim = [Math]::Round((($VideoStart - $origin) - $MarginSeconds), 6)
  return [pscustomobject]@{ Trim = $trim; Lead = $lead; Reason = 'preroll' }
}

function Measure-CarvePreroll {
  # Probe a source's start times and return Get-CarvePrerollTrim's verdict, plus the raw figures.
  # $InSpec is the ffprobe input spec (e.g. @('-i', 'x.vob')); $AudioOrdinals are the KEPT a:N.
  param(
    [Parameter(Mandatory)][string]$Ffprobe,
    [Parameter(Mandatory)][string[]]$InSpec,
    [int[]]$AudioOrdinals = @()
  )
  function StartOf([string[]]$sel, [string]$entry) {
    $t = "$(& $Ffprobe -v error @InSpec @sel -show_entries $entry -of csv=p=0 2>$null | Select-Object -First 1)".Trim().TrimEnd(',')
    $v = 0.0
    if ([double]::TryParse($t, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $v }
    return [double]::NaN
  }
  # THE FIRST PICTURE, NOT the stream's start_time. start_time is the lowest PTS ffprobe SAW, and it
  # skips packets that carry none - a first I-frame without a PTS (measured on an elementary-stream
  # mux: I and P unstamped, the first stamped packet a B-frame 40 ms AFTER the I) reads as a later
  # start, and trimming to it cut the opening picture (249 of 250). A DVD VOBU opens on an I-frame
  # that carries VOBU_S_PTM as its PTS, so: the first video packet must be a KEYFRAME WITH a PTS, and
  # the start is the lowest PTS among the opening packets (never later than that keyframe). Anything
  # else is unmeasurable - no trim, and the CFR gate judges the file as before.
  $v0 = [double]::NaN
  $vp = @(& $Ffprobe -v error @InSpec -select_streams v:0 -show_entries packet=pts_time,flags -read_intervals '%+#30' -of csv=p=0 2>$null |
          ForEach-Object { "$_".Trim() } | Where-Object { $_ })
  if ($vp.Count -and $vp[0] -match '^([0-9.]+),K') {
    $ci = [Globalization.CultureInfo]::InvariantCulture
    $v0 = ($vp | Where-Object { $_ -match '^([0-9.]+),' } | ForEach-Object { [double]::Parse(($_ -split ',')[0], $ci) } |
           Measure-Object -Minimum).Minimum
  }
  $in0 = StartOf @() 'format=start_time'
  $aud = @($AudioOrdinals | ForEach-Object { StartOf @('-select_streams', "a:$_") 'stream=start_time' })
  if ([double]::IsNaN($v0)) {
    return [pscustomobject]@{ Trim = 0.0; Lead = 0.0; Reason = 'unmeasurable'; VideoStart = $v0; InputStart = $in0; AudioStarts = $aud }
  }
  $r = Get-CarvePrerollTrim -VideoStart $v0 -AudioStarts $aud -InputStart $in0
  $r | Add-Member -NotePropertyName VideoStart -NotePropertyValue $v0
  $r | Add-Member -NotePropertyName InputStart -NotePropertyValue $in0
  $r | Add-Member -NotePropertyName AudioStarts -NotePropertyValue $aud
  return $r
}
