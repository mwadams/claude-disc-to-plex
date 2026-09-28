<#
  Tests for lib-carve-preroll.ps1 and its wiring in transcode.ps1.
  Run: pwsh -NoProfile -File lib-carve-preroll.tests.ps1   (exit 0 = all passed)

  WHAT THESE HAVE TO PROVE (The Invisible Enemy, 2026-09-28 - see the lib's header):
    1. The rule, on the figures MEASURED from that disc's four angle-2 carves: Parts Two and Three
       (audio 17,280 ticks = 0.192 s ahead of VOBU_S_PTM) get a trim; Parts One and Four (audio and
       video start together) get none.
    2. The trim is in ffmpeg's OUTPUT timeline, whose zero is the input's start_time - which can be
       earlier than the kept audio (an unmapped stream) - and it never reaches the first picture.
    3. Bounds: less than a frame is not trimmed; more than a VOBU is refused, never cut silently.
    4. END TO END through transcode.ps1: a synthetic DVD-muxed VOB with the same 0.192 s audio lead.
       Before the fix it failed exactly as the disc did ("SEAM GAP", packets 250 / CFR 255); after
       it the item is OK, every video packet survives (250) and CFR == packets. Synthetic, so no
       disc content lives in the test - the lead is the measured one.
  -Transcode lets the end-to-end case be pointed at another copy of transcode.ps1 (it must sit in
  this scripts folder, since it dot-sources its libs from there) - that is how "fails before" was shown.
#>
param([string]$Transcode = (Join-Path $PSScriptRoot 'transcode.ps1'), [switch]$UnitOnly)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib-carve-preroll.ps1"
if (-not (Get-Command Get-CarvePrerollTrim -ErrorAction SilentlyContinue)) {
  Write-Output 'FAIL: lib-carve-preroll.ps1 did not load'; exit 1
}
$script:fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}

Write-Output '1. The Invisible Enemy angle-2 carves, as measured (first PTS per stream; format start)'
# PGC 3 (Part Two): VOBU_S_PTM 31382 = video 0.348689; audio 0x80/0x81 0.156689; format 0.156689
$r = Get-CarvePrerollTrim -VideoStart 0.348689 -AudioStarts @(0.156689, 0.156689) -InputStart 0.156689
Check 'Part Two reason' $r.Reason 'preroll'
Check 'Part Two lead'   $r.Lead   0.192
Check 'Part Two trim'   $r.Trim   0.191
# PGC 4 (Part Three): VOBU_S_PTM 25624 = video 0.284711; audio 0.092711
$r = Get-CarvePrerollTrim -VideoStart 0.284711 -AudioStarts @(0.092711, 0.092711) -InputStart 0.092711
Check 'Part Three reason' $r.Reason 'preroll'
Check 'Part Three trim'   $r.Trim   0.191
# PGC 2 / PGC 5 (Parts One / Four): everything at 0.287267 - these passed, and must stay untouched
$r = Get-CarvePrerollTrim -VideoStart 0.287267 -AudioStarts @(0.287267, 0.287267) -InputStart 0.287267
Check 'Part One/Four reason' $r.Reason 'none'
Check 'Part One/Four trim'   $r.Trim   0

Write-Output '2. Output-timeline origin and the first picture'
# An unmapped stream starts the input at 0.10; kept audio at 0.20; video at 0.40. ffmpeg's output
# zero is 0.10, so the picture sits at 0.30 there - the trim must be just short of 0.30, not 0.20.
$r = Get-CarvePrerollTrim -VideoStart 0.40 -AudioStarts @(0.20) -InputStart 0.10
Check 'origin is the input start' $r.Trim 0.299
Check 'lead is against kept audio' $r.Lead 0.2
# The earliest KEPT stream decides the lead, not the first one listed
$r = Get-CarvePrerollTrim -VideoStart 0.5 -AudioStarts @(0.45, 0.30)
Check 'earliest kept audio' $r.Lead 0.2
$r = Get-CarvePrerollTrim -VideoStart 0.348689 -AudioStarts @(0.156689) -InputStart 0.156689
Check 'trim stops short of the picture (0.192)' ($r.Trim -lt 0.192 -and $r.Trim -gt 0.19) 'True'

Write-Output '3. Bounds'
Check 'under a frame: none'   (Get-CarvePrerollTrim -VideoStart 1.02 -AudioStarts @(1.0)).Reason 'none'
Check 'video first: none'     (Get-CarvePrerollTrim -VideoStart 1.0 -AudioStarts @(1.3)).Reason 'none'
Check 'over a VOBU: refused'  (Get-CarvePrerollTrim -VideoStart 3.0 -AudioStarts @(1.5)).Reason 'too-large'
Check 'over a VOBU: no trim'  (Get-CarvePrerollTrim -VideoStart 3.0 -AudioStarts @(1.5)).Trim 0
Check 'no audio kept'         (Get-CarvePrerollTrim -VideoStart 0.3 -AudioStarts @()).Reason 'no-audio'
Check 'unreadable audio'      (Get-CarvePrerollTrim -VideoStart 0.3 -AudioStarts @([double]::NaN)).Reason 'no-audio'

if (-not $UnitOnly) {
  Write-Output '4. End to end through transcode.ps1 (synthetic VOB, audio 0.192 s ahead of the first picture)'
  $tp = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
  $ff = $tp.ffmpeg; $fp = Join-Path (Split-Path $ff) 'ffprobe.exe'
  $tmp = Join-Path ([IO.Path]::GetTempPath()) ('carvepreroll-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  try {
    $mpg = Join-Path $tmp 'v.mpg'; $mka = Join-Path $tmp 'a.mka'; $vob = Join-Path $tmp 'carve.vob'
    # Shaped like the real carve's opening: a closed GOP whose first packet is a timestamped
    # I-frame (PTS = VOBU_S_PTM, DTS 40 ms earlier), then B-frames. An ELEMENTARY .m2v mux does not
    # do that - its I and P carry no PTS - and trimming to the first STAMPED packet there cut the
    # opening picture, which is what check 'every picture kept' below exists to catch.
    & $ff -y -hide_banner -v error -f lavfi -i 'testsrc2=size=720x576:rate=25:duration=10' -c:v mpeg2video -b:v 5M -g 12 -bf 2 -sc_threshold 1000000000 -flags +cgop -aspect 4:3 -f vob $mpg
    & $ff -y -hide_banner -v error -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=10.2' -f lavfi -i 'sine=frequency=660:sample_rate=48000:duration=10.2' -map 0 -map 1 -c:a ac3 -b:a 192k -f matroska $mka
    # First picture 0.192 s after the audio - the measured Invisible Enemy lead. Asserted below.
    & $ff -y -hide_banner -v error -itsoffset 0.192 -i $mpg -i $mka -map 0:v -map 1:a -c copy -f dvd $vob
    $pr = Measure-CarvePreroll -Ffprobe $fp -InSpec @('-i', $vob) -AudioOrdinals @(0, 1)
    Check 'fixture lead is the measured 0.192 s' $pr.Lead 0.192
    Check 'fixture measured as pre-roll' $pr.Reason 'preroll'
    Check 'fixture trim' $pr.Trim 0.191

    # A first video packet that is NOT a timestamped keyframe must not be measured at all.
    $m2v = Join-Path $tmp 'v.m2v'; $bad = Join-Path $tmp 'unstamped.vob'
    & $ff -y -hide_banner -v error -f lavfi -i 'testsrc2=size=720x576:rate=25:duration=2' -c:v mpeg2video -g 12 -bf 2 -aspect 4:3 -f mpeg2video $m2v
    # -v fatal: the dvd muxer logs a buffer-underflow line per pack on an elementary input; harmless here.
    & $ff -y -hide_banner -v fatal -itsoffset 0.112 -i $m2v -i $mka -map 0:v -map 1:a -c copy -t 2 -f dvd $bad
    $pu = Measure-CarvePreroll -Ffprobe $fp -InSpec @('-i', $bad) -AudioOrdinals @(0)
    Check 'unstamped first keyframe: unmeasurable, no trim' "$($pu.Reason)/$($pu.Trim)" 'unmeasurable/0'

    $out = Join-Path $tmp 'out/carve.mkv'
    New-Item -ItemType Directory -Path (Split-Path $out) -Force | Out-Null
    $man = Join-Path $tmp 'manifest.json'
    ConvertTo-Json -Depth 5 -InputObject @([ordered]@{
        out = $out.Replace('\', '/'); kind = 'MKV'; src = $vob.Replace('\', '/'); dar = '4:3'; subTrack = 'none'
        audioTracks = @(0, 1); audioLangs = @('eng', 'eng'); expectSeconds = 10.0; expectFrames = 250 }) |
      Set-Content -LiteralPath $man -Encoding utf8
    $log = & pwsh -NoProfile -File $Transcode -Manifest $man -LogDir $tmp 2>&1
    $tx = $LASTEXITCODE
    $log | Where-Object { "$_" -match 'pre-roll|SEAM GAP|FAILED|CFR|   OK ' } | ForEach-Object { Write-Output "       | $_" }
    Check 'transcode exit' $tx 0
    Check 'output exists (not moved aside)' (Test-Path -LiteralPath $out) 'True'
    Check 'no .seam-gap' (Test-Path -LiteralPath "$out.seam-gap") 'False'
    if (Test-Path -LiteralPath $out) {
      $pk = "$(& $fp -v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets -of csv=p=0 $out)".Trim().TrimEnd(',')
      Check 'every picture kept (250)' $pk 250
      $cfr = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'check-cfr-frame-count.ps1') -Path $out
      $cx = $LASTEXITCODE
      Check 'CFR == packets' $cx 0
      $v0 = "$(& $fp -v error -select_streams v:0 -show_entries stream=start_time -of csv=p=0 $out)".Trim().TrimEnd(',')
      Check 'video starts at 0' ([Math]::Abs([double]$v0) -le 0.002) 'True'
    }
  } finally {
    if ($tmp.StartsWith([IO.Path]::GetTempPath())) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  }
}

if ($script:fails) { Write-Output "FAILED: $script:fails check(s)"; exit 1 }
Write-Output 'ALL PASSED'; exit 0
