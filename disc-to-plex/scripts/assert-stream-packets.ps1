# COUNT THE PACKETS. Durations, sizes and stream declarations can all be right while the media is
# wrong; a packet count is the thing that cannot be faked.
#
# WHY THIS IS A SCRIPT. Five defects found on 2026-08-28 alone were invisible to every structural
# check and every one of them was caught by counting packets:
#
#   1. `ffprobe -f dvdvideo -title 8` on The Saint Colour D13 reported format=duration 996.400000 -
#      the full 16:36 - while the title DECODED 1,480 packets (~59 s) against a flat read's 24,910.
#      The reported figure is the IFO's DECLARED PGC time, not a measurement.
#   2. A `-pg` program that DECLARED a second AC3 stream and shipped ZERO packets on it: an item
#      keeping that ordinal carries a silent minute no duration or size check can see.
#   3. An extra shipped with two zero-packet audio tracks because `audioTracks: []` read as absent.
#   4/5. The same shape again elsewhere.
#
# THE DISTINCTION THAT SAVES YOU:
#   * duration of an ENCODED OUTPUT is trustworthy - it comes from a real decode, so our
#     output-vs-MakeMKV comparisons stay valid;
#   * duration of a SOURCE TITLE read through `-f dvdvideo` is METADATA, and can be perfectly
#     correct while the title decodes to a fraction of it.
#   To measure a SOURCE you must COUNT PACKETS, never read format=duration.
#
# Checks, in order of how often they have caught something:
#   A. any declared stream carrying ZERO packets                       -> FAIL
#   B. video: declared duration vs packets/frame-rate                  -> FAIL on mismatch
#   C. audio: packet-derived duration vs the video's                   -> FAIL when materially short
#
# Read-only. Exits 2 on any failure so it can gate a publish or a source-deletion.

param(
  [Parameter(Mandatory, ParameterSetName = 'File')][string]$Path,
  [Parameter(Mandatory, ParameterSetName = 'Disc')][string]$Disc,
  [Parameter(Mandatory, ParameterSetName = 'Disc')][int]$Title,
  [double]$ToleranceSec = 2.0,     # allow trivial container/codec padding differences
  [double]$AudioTolerance = 5.0,   # audio may legitimately stop a little before picture
  [int]$ExpectVideoPackets = 0     # compare against a KNOWN source count (0 = skip)
)

# WHY -ExpectVideoPackets EXISTS. Checks A-C are all INTERNAL: they ask whether the file agrees with
# itself. A file can pass all three and still have lost content, because the loss is consistent -
# duration, frame count and declarations all shrink together and nothing inside the file disagrees.
#
# That happened here. Re-encoding the D13 reel from a `-fflags +genpts` remux of the VOB produced
# 24,885 frames against the source's 24,910: ffmpeg's CFR conversion DROPPED 25 frames at the 17
# cells' PTS discontinuities (visible only as `drop=25` in the progress line). The output declared
# 995.40 s and decoded 995.40 s - perfectly self-consistent, and 25 frames short of the disc.
# Fixed by muxing the elementary streams with clean 25 fps timestamps instead.
#
# So when a source count is known, PASS IT IN. Internal consistency is not completeness.

$paths   = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'

if ($PSCmdlet.ParameterSetName -eq 'Disc') {
  $inSpec = @('-f', 'dvdvideo', '-title', [string]$Title, '-i', $Disc)
  $label  = "$Disc  title $Title"
} else {
  if (-not (Test-Path -LiteralPath $Path)) { Write-Host "not found: $Path"; exit 1 }
  $inSpec = @('-i', $Path)
  $label  = Split-Path $Path -Leaf
}

Write-Host $label

# samples per compressed frame, for turning an audio packet count into seconds
$frameSize = @{ ac3 = 1536; eac3 = 1536; aac = 1024; mp2 = 1152; mp3 = 1152; dts = 512; vorbis = 1024; opus = 960 }

# DECLARED duration - metadata, and the thing under test
$declared = "$(& $ffprobe -v error @inSpec -show_entries format=duration -of csv=p=0 2>$null)".Trim()
$declaredSec = if ($declared -and $declared -ne 'N/A') { [double]$declared } else { -1 }

# One counting pass over every stream. JSON, NOT csv: with csv=p=0 a field that a stream does not
# carry is simply omitted, so the columns SHIFT per stream and positional parsing reads a frame rate
# as a packet count. (It did: "Cannot convert value 25/1 to type System.Int32".)
$json = & $ffprobe -v error @inSpec -count_packets `
        -show_entries stream=index,codec_type,codec_name,nb_read_packets,avg_frame_rate,sample_rate `
        -of json 2>$null
try { $streams = (($json -join "`n") | ConvertFrom-Json).streams } catch { $streams = @() }

$fail = @(); $videoSec = -1.0; $any = $false
foreach ($s in $streams) {
  $type = "$($s.codec_type)"
  if ($type -notin @('video', 'audio')) { continue }   # nav/data packets are not content
  $idx   = $s.index
  $codec = "$($s.codec_name)"
  $nb    = [int]("$($s.nb_read_packets)" -replace '[^\d]', '')
  $rate  = "$($s.avg_frame_rate)"
  $sr    = "$($s.sample_rate)"
  $any = $true

  # ---- A. zero packets on a declared stream ---------------------------------------------------
  if ($nb -eq 0) {
    Write-Host ("  [{0}] {1,-5} {2,-8} packets=0   *** DECLARED BUT EMPTY ***" -f $idx, $type, $codec)
    $fail += "stream $idx ($type/$codec) declares a stream and ships ZERO packets"
    continue
  }

  if ($type -eq 'video') {
    $fps = 0.0
    if ($rate -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -ne 0) { $fps = [double]$Matches[1] / [double]$Matches[2] }
    if ($fps -gt 0) { $videoSec = $nb / $fps }
    Write-Host ("  [{0}] {1,-5} {2,-8} packets={3,-8} decoded={4:F2}s  declared={5:F2}s" -f `
      $idx, $type, $codec, $nb, $videoSec, $declaredSec)
    # ---- B. declared vs decoded ---------------------------------------------------------------
    if ($declaredSec -gt 0 -and $videoSec -gt 0 -and [math]::Abs($declaredSec - $videoSec) -gt $ToleranceSec) {
      $fail += ("video declares {0:F2}s but decodes {1:F2}s ({2:F2}s difference) - the declared figure is METADATA" -f `
                $declaredSec, $videoSec, ($declaredSec - $videoSec))
    }
    # ---- D. against a KNOWN source count (external; the only check that sees consistent loss) ---
    if ($ExpectVideoPackets -gt 0) {
      if ($nb -ne $ExpectVideoPackets) {
        Write-Host ("      expected {0} packets from source, got {1} ({2:+#;-#;0})" -f $ExpectVideoPackets, $nb, ($nb - $ExpectVideoPackets))
        $fail += ("video has {0} packets against the source's {1} - {2} frame(s) LOST (check ffmpeg's drop= counter)" -f `
                  $nb, $ExpectVideoPackets, ($ExpectVideoPackets - $nb))
      } else {
        Write-Host ("      matches source count {0}" -f $ExpectVideoPackets)
      }
    }
  }
  elseif ($type -eq 'audio') {
    $aSec = -1.0
    if ($frameSize.ContainsKey($codec) -and $sr -match '^\d+$' -and [int]$sr -gt 0) {
      $aSec = $nb * $frameSize[$codec] / [double]$sr
    }
    Write-Host ("  [{0}] {1,-5} {2,-8} packets={3,-8} decoded={4}" -f `
      $idx, $type, $codec, $nb, $(if ($aSec -ge 0) { "{0:F2}s" -f $aSec } else { 'n/a' }))
    # ---- C. audio materially shorter than picture ---------------------------------------------
    if ($aSec -ge 0 -and $videoSec -gt 0 -and ($videoSec - $aSec) -gt $AudioTolerance) {
      $fail += ("audio stream {0} covers {1:F2}s against {2:F2}s of picture - {3:F2}s short" -f `
                $idx, $aSec, $videoSec, ($videoSec - $aSec))
    }
  }
}

if (-not $any) { Write-Host '  no streams reported'; exit 1 }

Write-Host ''
if ($fail) {
  Write-Host '*** PACKET COUNT DISAGREES WITH WHAT THE FILE DECLARES ***'
  $fail | ForEach-Object { Write-Host "  - $_" }
  Write-Host ''
  Write-Host 'A source title read through -f dvdvideo reports the IFO PGC time, not a decode. If the'
  Write-Host 'video line above is short, the title is TRUNCATED however right its duration looks -'
  Write-Host 'read it per-PROGRAM (-chapter_start N -chapter_end N) or read the VTS VOB directly.'
  exit 2
}
Write-Host 'packet counts agree with declarations'
exit 0
