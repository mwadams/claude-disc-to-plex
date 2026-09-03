<#
.SYNOPSIS
  Compare a file's CFR-DECODE frame count against its VIDEO PACKET count. The discriminator for
  a SEAM OVERSHOOT - a gap in the timeline that no packet-counting guard can see.

.DESCRIPTION
  WHY THIS EXISTS (2026-09-03). `retime-vob-cells.py` shipped deriving its frame duration from
  the MODAL DTS INTERVAL, which is the VOBU/DTS-SIGNALLING PERIOD, not a frame duration, and is
  per-disc (5 frames on The Champions D9, 12 on a League of Gentlemen angle carve). Where a cell
  ends on a PARTIAL signalling group the seam overshoots by the remainder, leaving a GAP in the
  output's timeline.

  Both existing guards pass a file with that defect, and it is worth being precise about why:

    * `expectFrames` counts PACKETS (`ffprobe -count_packets`). A seam gap does not add or remove
      a single coded picture - the payload is byte-identical - so the packet count is EXACTLY the
      quantity the defect leaves untouched. That is why it passed.
    * `expectSeconds` compares container duration, but only against a number a human wrote in the
      manifest, which is usually derived from the same wrong arithmetic; and its 2 s tolerance is
      wider than most seam gaps (the measured League case was 0.28 s).

  What DOES see it: decode the file with `-fps_mode cfr`. CFR re-times the output onto a constant
  grid at the stream's own frame rate, so it must DUPLICATE a frame for every frame-slot the
  timeline leaves empty. Equal counts = every packet occupies exactly one slot = clean. A CFR
  count HIGHER than the packet count is the gap, in frames.

  Measured on the real League of Gentlemen angle-1 carve (2,982 coded pictures either way):
    old retimer output   packets 2982   CFR 2989   -> +7 frames, container 119.56 s
    fixed retimer output packets 2982   CFR 2982   -> clean,     container 119.28 s (= PGC)

  A CFR count LOWER than the packet count is the opposite fault - frames sharing a timestamp, or
  timestamps that step backwards, so CFR drops them. Both are reported.

  Read-only. Never writes, moves or deletes anything.

.PARAMETER Path
  A media file, or a folder to sweep (recursively) for .mkv/.mp4/.m2ts/.vob.

.PARAMETER Tolerance
  Frames of slack before a difference is called a fault. Default 2 - a container's final frame
  duration is sometimes rounded, which can move the count by one.

.PARAMETER Quiet
  Print only faults and the summary.

.OUTPUTS
  Exit 0 = every file clean. Exit 2 = at least one file flagged or unmeasurable.
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Path,
  [int]$Tolerance = 2,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

$tp = Get-Content (Join-Path $PSScriptRoot '..\..\..\.transcode-tools\tool-paths.json') -Raw -ErrorAction SilentlyContinue
if (-not $tp) { $tp = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw }
$tools = $tp | ConvertFrom-Json
$ff = $tools.ffmpeg
$fp = Join-Path (Split-Path $ff) 'ffprobe.exe'
if (-not (Test-Path -LiteralPath $ff) -or -not (Test-Path -LiteralPath $fp)) {
  Write-Output "ERROR: ffmpeg/ffprobe not found (install-tools.ps1)"; exit 2
}

$files = @()
if (Test-Path -LiteralPath $Path -PathType Container) {
  $files = @(Get-ChildItem -LiteralPath $Path -Recurse -File |
             Where-Object { $_.Extension -in '.mkv', '.mp4', '.m2ts', '.vob' } |
             Sort-Object FullName)
} elseif (Test-Path -LiteralPath $Path) {
  $files = @(Get-Item -LiteralPath $Path)
} else {
  Write-Output "ERROR: $Path not found"; exit 2
}
if (-not $files.Count) { Write-Output "ERROR: no media files under $Path"; exit 2 }

$bad = 0
foreach ($f in $files) {
  # GUARD EVERY COMPARISON WITH A BYTE COUNT. Two unmeasurable files agree perfectly, and an
  # equality between two zeroes reads exactly like a clean result.
  if ($f.Length -le 0) {
    Write-Output ("  UNMEASURABLE  {0} - zero bytes" -f $f.Name); $bad++; continue
  }

  $pktTxt = "$(& $fp -v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets -of csv=p=0 $f.FullName 2>$null)".Trim().TrimEnd(',')
  $pkt = 0; [void][int]::TryParse($pktTxt, [ref]$pkt)

  # -stats writes the running counter to stderr; the LAST `frame=` is the final total. Captured
  # into a variable so $LASTEXITCODE is the ffmpeg exit code, never a pipeline's.
  $out = & $ff -nostdin -v error -stats -i $f.FullName -map 0:v:0 -an -sn -dn -fps_mode cfr -f null - 2>&1
  $ffExit = $LASTEXITCODE
  $m = [regex]::Matches(($out -join "`n"), 'frame=\s*(\d+)')
  $cfr = if ($m.Count) { [int]$m[$m.Count - 1].Groups[1].Value } else { -1 }

  if ($pkt -le 0 -or $cfr -le 0) {
    Write-Output ("  UNMEASURABLE  {0} - packets={1} cfrFrames={2} (ffmpeg exit {3}); {4:N0} bytes on disc, so this is a MEASUREMENT failure, not an empty file" -f `
                  $f.Name, $pkt, $cfr, $ffExit, $f.Length)
    $bad++; continue
  }

  # A TRUNCATED file agrees with itself. Testing this script, a failed matroska stream-copy left
  # a 74,380-byte stub carrying ONE packet; packets 1 = CFR 1 read as a clean pass. Two counts
  # agreeing is only evidence when there is something there to count, so cross-check the packet
  # count against the container's OWN duration and frame rate before believing the comparison.
  $durTxt = "$(& $fp -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null)".Trim().TrimEnd(',')
  $dur = 0.0; [void][double]::TryParse($durTxt, [ref]$dur)
  $rfr = "$(& $fp -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 $f.FullName 2>$null)".Trim().TrimEnd(',')
  $fps = 0.0
  if ($rfr -match '^(\d+)/(\d+)$' -and [int]$Matches[2] -gt 0) { $fps = [double]$Matches[1] / [double]$Matches[2] }
  # Below about a second of video there is no seam to find and no useful comparison to make. Say
  # "could not judge" rather than "OK": the stub above was INTERNALLY CONSISTENT (1 packet, 0.04 s,
  # 25 fps) so no cross-check can call it broken - but a bare OK on it is a lie by omission.
  if ($pkt -lt 25) {
    Write-Output ("  TOO SHORT     {0} - {1:N0} packet(s) in {2:N0} bytes; nothing to judge, not a clean result" -f $f.Name, $pkt, $f.Length)
    $bad++; continue
  }
  if ($dur -gt 1.0 -and $fps -gt 0 -and $pkt -lt ($dur * $fps / 2)) {
    Write-Output ("  TRUNCATED     {0} - only {1:N0} packet(s) for a declared {2:N2}s at {3:N3} fps (~{4:N0} expected); the file is short, so the CFR comparison would be meaningless" -f `
                  $f.Name, $pkt, $dur, $fps, ($dur * $fps))
    $bad++; continue
  }

  $d = $cfr - $pkt
  if ($d -gt $Tolerance) {
    Write-Output ("  SEAM GAP      {0} - packets {1:N0}, CFR decode {2:N0} (+{3:N0} frame(s) of empty timeline)" -f $f.Name, $pkt, $cfr, $d)
    $bad++
  } elseif ($d -lt -$Tolerance) {
    Write-Output ("  CFR DROPPED   {0} - packets {1:N0}, CFR decode {2:N0} ({3:N0} frame(s) lost: duplicate or backward timestamps)" -f $f.Name, $pkt, $cfr, $d)
    $bad++
  } elseif (-not $Quiet) {
    Write-Output ("  OK            {0} - packets {1:N0}, CFR decode {2:N0}" -f $f.Name, $pkt, $cfr)
  }
}

Write-Output ("check-cfr-frame-count: {0} file(s), {1} flagged" -f $files.Count, $bad)
if ($bad) { exit 2 }
exit 0
