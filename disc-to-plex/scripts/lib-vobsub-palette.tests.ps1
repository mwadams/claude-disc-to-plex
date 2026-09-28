<#
  Tests for lib-vobsub-palette.ps1, its wiring in transcode.ps1, and the palette sidecar written by
  dvd-angle-cells.py and carried by retime-vob-cells.py.
  Run: pwsh -NoProfile -File lib-vobsub-palette.tests.ps1   (exit 0 = all passed)

  WHAT THESE HAVE TO PROVE (The Invisible Enemy S00E346-349, 2026-09-28 - see the lib's header):
    1. The palette read from the IFO is BYTE-IDENTICAL to what ffmpeg's dvdvideo demuxer writes.
       REAL CASE: the 64 CLUT bytes of that disc's VTS_02 PGC 5 must give the line whose extradata
       MD5 is e663151d5cf21c11ac3963598dcd04dc - measured on the published S15E08.
    2. retime-vob-cells.py carries the sidecar to the retimed file (and invents none).
    3. The guard: a palette-less dvd_subtitle is refused, so is a wrong palette; a right one passes.
    4. The repair is lossless - subtitle packets (pts, duration, size, flags, MD5), every stream's
       tags and dispositions, and the other streams, all unchanged - and it refuses a malformed
       palette and a network path.
    5. END TO END through transcode.ps1 on a synthetic carve .vob whose subtitle stream has NO
       palette (the defect, reproduced and asserted):
         a. with its .palette.txt  -> OK, the output carries exactly that palette, packets intact;
         b. without one            -> REFUSED before encoding, nothing written;
         c. known-negative: an MKV source that carries its own palette -> passes through untouched.
  All media is synthetic (generated DVD subpictures, testsrc video, sine audio) - no disc content.
#>
param([string]$Transcode = (Join-Path $PSScriptRoot 'transcode.ps1'), [switch]$UnitOnly)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib-vobsub-palette.ps1"
$script:fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}
function Md5([byte[]]$b) { [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash($b)).Replace('-', '').ToLower() }

$tp = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
$ff = $tp.ffmpeg; $fp = Join-Path (Split-Path $ff) 'ffprobe.exe'; $mkx = $tp.mkvextract
$angle = Join-Path $PSScriptRoot 'dvd-angle-cells.py'
$retime = Join-Path $PSScriptRoot 'retime-vob-cells.py'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('vobsubpal-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$IE = 'palette: 0000fd, fd0000, 000000, fdfdfd, 00fe00, fc00fd, fefe00, 007c7b, 7c7c7c, e0e0e0, 7a0000, 007d00, f9fcd9, 923a38, 006300, 7c007b'

try {
  Write-Output '1. IFO CLUT -> palette line, byte-identical to ffmpeg''s dvdvideo demuxer'
  # A minimal VTS IFO: the magic, VTS_PGCIT at sector 1, one PGC, its CLUT at PGC+0xA4.
  function New-Ifo([string]$path, [string]$clutHex) {
    $b = New-Object byte[] (2048 + 16 + 0xA4 + 64)
    [Text.Encoding]::ASCII.GetBytes('DVDVIDEO-VTS').CopyTo($b, 0)
    $b[0xCF] = 1                                   # VTS_PGCIT start sector (big-endian 0x00000001)
    $b[2048 + 1] = 1                               # nr of PGCs = 1
    $b[2048 + 8 + 4 + 3] = 16                      # PGC 1 offset from the PGCIT = 16
    for ($k = 0; $k -lt 64; $k++) { $b[2048 + 16 + 0xA4 + $k] = [Convert]::ToByte($clutHex.Substring(2 * $k, 2), 16) }
    [IO.File]::WriteAllBytes($path, $b)
  }
  $vts = Join-Path $tmp 'VIDEO_TS'; New-Item -ItemType Directory -Path $vts -Force | Out-Null
  # REAL: The Invisible Enemy VTS_02 PGC 5 CLUT (0,Y,Cr,Cb x16), read off the disc 2026-09-28.
  New-Ifo (Join-Path $vts 'VTS_02_0.IFO') '00286df00051f05a0010808000ea808000902235006addca00d29210005b4992007b808000d180800030b66d004f515b00e581710059a77200425b62003caea4'
  $line = "$(& python $angle $vts 2 1 --palette)".Trim()
  Check 'REAL: Invisible Enemy PGC 5 line' $line $IE
  Check 'REAL: extradata MD5 = the published S15E08''s' (Md5 ([Text.Encoding]::ASCII.GetBytes($line + "`n"))) 'e663151d5cf21c11ac3963598dcd04dc'
  Check 'line is 135 chars (+\n = 136 bytes, as measured)' $line.Length 135
  # Known-negative: a different CLUT gives a different line (the value is read, not constant).
  New-Ifo (Join-Path $vts 'VTS_03_0.IFO') ('00108080' + '00eb8080' * 15)
  $neg = "$(& python $angle $vts 3 1 --palette)".Trim()
  Check 'other CLUT: black then white' ((($neg -split ', ')[0..1]) -join ',') 'palette: 000000,fefefe'
  & python $angle $vts 2 7 --palette 2>$null | Out-Null
  Check 'absent PGC refused (exit 2)' $LASTEXITCODE 2

  if (-not $UnitOnly) {
    Write-Output '   (fixture) synthetic DVD subpictures, and a carve .vob that loses their palette'
    # Four 160x40 subpictures (2-bit RLE, both fields, SET_COLOR/CONTR/DAREA/DSPXA, stop after
    # 1.5 s), each in its own 2048-byte private-stream-1 pack - i.e. a VobSub .sub - with an .idx
    # that carries the Invisible Enemy palette. ffmpeg's vobsub demuxer turns that into a
    # dvd_subtitle stream WITH extradata, exactly as the dvdvideo demuxer does.
    $gen = Join-Path $tmp 'mkspu.py'
    @'
import struct, sys
base, pal = sys.argv[1], sys.argv[2]
W, H = 160, 40
def code(n, c):   # 16-bit RLE form, valid for 64 <= n <= 255
    return struct.pack('>H', (n << 2) | c)
def line(k, y):
    return code(64 + (k * 7 + y) % 32, 1) + code(64, 2) + struct.pack('>H', 3)   # 3 = fill line
def spu(k, dur):
    top = b''.join(line(k, y) for y in range(0, H, 2))
    bot = b''.join(line(k, y) for y in range(1, H, 2))
    d1 = 4 + len(top) + len(bot)
    x1, x2, y1, y2 = 280, 280 + W - 1, 480, 480 + H - 1
    area = bytes([x1 >> 4, ((x1 & 15) << 4) | (x2 >> 8), x2 & 255, y1 >> 4, ((y1 & 15) << 4) | (y2 >> 8), y2 & 255])
    c1 = bytes([3, 0x32, 0x10, 4, 0xFF, 0xF0, 5]) + area + bytes([6]) + struct.pack('>HH', 4, 4 + len(top)) + bytes([1, 0xFF])
    d2 = d1 + 4 + len(c1)
    body = top + bot + struct.pack('>HH', 0, d2) + c1 + struct.pack('>HH', dur, d2) + bytes([2, 0xFF])
    return struct.pack('>HH', 4 + len(body), d1) + body
def pts5(p):
    return bytes([0x21 | (((p >> 30) & 7) << 1), (p >> 22) & 255, 1 | (((p >> 15) & 127) << 1), (p >> 7) & 255, 1 | ((p & 127) << 1)])
PACK = b'\x00\x00\x01\xba' + bytes([0x44, 0, 4, 0, 4, 1, 1, 0x89, 0xc3, 0xf8])
subs, idx = b'', []
for k, sec in enumerate([1, 3, 5, 7]):
    pes = bytes([0x81, 0x80, 5]) + pts5(sec * 90000) + b'\x20' + spu(k, 132)
    p = PACK + b'\x00\x00\x01\xbd' + struct.pack('>H', len(pes)) + pes
    pad = 2048 - len(p)
    p += b'\x00\x00\x01\xbe' + struct.pack('>H', pad - 6) + b'\xff' * (pad - 6)
    idx.append('timestamp: 00:00:%02d:000, filepos: %09x' % (sec, len(subs)))
    subs += p
open(base + '.sub', 'wb').write(subs)
open(base + '.idx', 'w', newline='\n').write('# VobSub index file, v7 (do not modify this line!)\n' + pal + '\nid: en, index: 0\n' + '\n'.join(idx) + '\n')
'@ | Set-Content -LiteralPath $gen -Encoding utf8
    $fx = Join-Path $tmp 'fx'
    & python $gen $fx $IE
    $mpg = Join-Path $tmp 'v.mpg'; $mka = Join-Path $tmp 'a.mka'; $vob = Join-Path $tmp 'carve.vob'; $ref = Join-Path $tmp 'ref.mkv'
    & $ff -y -hide_banner -v error -f lavfi -i 'testsrc2=size=720x576:rate=25:duration=10' -c:v mpeg2video -b:v 5M -g 12 -bf 2 -sc_threshold 1000000000 -flags +cgop -aspect 4:3 -f vob $mpg
    & $ff -y -hide_banner -v error -f lavfi -i 'sine=frequency=440:sample_rate=48000:duration=10' -c:a ac3 -b:a 192k -f matroska $mka
    & $ff -y -hide_banner -v error -i $mpg -i $mka -i "$fx.idx" -map 0:v -map 1:a -map 2:s -c copy -f dvd $vob
    & $ff -y -hide_banner -v error -i $mpg -i $mka -i "$fx.idx" -map 0:v -map 1:a -map 2:s -c copy $ref
    Check 'fixture: reference MKV carries the palette' (Get-DvdSubPaletteLine -Ffprobe $fp -InSpec @('-i', $ref)) $IE
    Check 'fixture: reference has 4 subpictures' (Get-SubPacketList $fp $ref 0).Count 4
    Check 'fixture: the CARVE''s dvd_subtitle has NO palette (the defect)' ("$(& $fp -v error -select_streams s:0 -show_entries stream=codec_name -of csv=p=0 $vob)".Trim(',') + '/' + [string](Get-DvdSubPaletteLine -Ffprobe $fp -InSpec @('-i', $vob))) 'dvd_subtitle/'

    Write-Output '2. retime-vob-cells.py carries the sidecar'
    [IO.File]::WriteAllText("$vob.palette.txt", "$IE`n")
    & python $retime $vob (Join-Path $tmp 'carve.retimed.vob') | Out-Null
    Check 'retime exit' $LASTEXITCODE 0
    Check 'sidecar carried byte-for-byte' ((Test-Path -LiteralPath (Join-Path $tmp 'carve.retimed.vob.palette.txt')) -and ((Get-Content -Raw (Join-Path $tmp 'carve.retimed.vob.palette.txt')) -eq "$IE`n")) 'True'
    Remove-Item -LiteralPath "$vob.palette.txt"
    & python $retime $vob (Join-Path $tmp 'carve.retimed2.vob') | Out-Null
    Check 'no sidecar in -> none invented' (Test-Path -LiteralPath (Join-Path $tmp 'carve.retimed2.vob.palette.txt')) 'False'

    Write-Output '3. The guard'
    $bare = Join-Path $tmp 'bare.mkv'
    & $ff -y -hide_banner -v error -i $vob -map 0:v -map 0:a -map 0:s -c copy -metadata:s:a:0 title=Stereo -metadata:s:s:0 language=eng -metadata:s:s:0 title=English -disposition:s:0 default $bare
    $g = Test-DvdSubPalette -Ffprobe $fp -Path $bare -Want $IE
    Check 'palette-less stream refused' "$($g.Ok)/$($g.Missing)" 'False/1'
    $g = Test-DvdSubPalette -Ffprobe $fp -Path $ref -Want ($IE -replace '^palette: 0000fd', 'palette: 000000')
    Check 'wrong palette refused' "$($g.Ok)/$($g.Wrong)" 'False/1'
    Check 'right palette passes' (Test-DvdSubPalette -Ffprobe $fp -Path $ref -Want $IE).Ok 'True'
    Check 'no dvd_subtitle at all passes' (Test-DvdSubPalette -Ffprobe $fp -Path $mka).Ok 'True'

    Write-Output '4. The repair is lossless, and refuses what it cannot do safely'
    $snap0 = Get-StreamSnapshot $fp $bare; $pk0 = Get-SubPacketList $fp $bare 0
    $r = Add-DvdSubPalette -Ffmpeg $ff -Ffprobe $fp -Mkvextract $mkx -Path $bare -Palette $IE -WorkDir $tmp
    Check 'repair Ok' "$($r.Ok)/$($r.Repaired)" 'True/1'
    Check 'palette now present and right' (Get-DvdSubPaletteLine -Ffprobe $fp -InSpec @('-i', $bare)) $IE
    Check 'extradata is exactly the 136 bytes' ((& $fp -v error -select_streams s:0 -show_entries stream=extradata_size -of csv=p=0 $bare) -join '').Trim(',') 136
    Check 'subtitle packets identical (pts,dur,size,flags,md5)' ((Get-SubPacketList $fp $bare 0) -join '|') ($pk0 -join '|')
    $snap1 = Get-StreamSnapshot $fp $bare
    Check 'every stream''s tags/dispositions/packet count unchanged' ($snap1.Streams -join ' ; ') ($snap0.Streams -join ' ; ')
    Check 'sub keeps language, title and default' (($snap1.Streams[2] -split '\|')[3..5] -join '|') 'eng|English|d1f0h0v0c0'
    Check 'no temp left beside the file' @(Get-ChildItem -LiteralPath $tmp -Filter '*.palette-*.tmp.mkv').Count 0
    Check 'second run is a no-op' (Add-DvdSubPalette -Ffmpeg $ff -Ffprobe $fp -Mkvextract $mkx -Path $bare -Palette $IE -WorkDir $tmp).Repaired 0
    Check 'malformed palette refused' (Add-DvdSubPalette -Ffmpeg $ff -Ffprobe $fp -Mkvextract $mkx -Path $bare -Palette 'palette: 000000' -WorkDir $tmp).Ok 'False'
    Check 'network path refused' (Add-DvdSubPalette -Ffmpeg $ff -Ffprobe $fp -Mkvextract $mkx -Path '\\NASTEAMV\x\y.mkv' -Palette $IE -WorkDir $tmp).Ok 'False'

    Write-Output '5. End to end through transcode.ps1'
    function Run-Item([string]$name, [string]$src, [string]$kind) {
      $out = Join-Path $tmp "out/$name.mkv"
      New-Item -ItemType Directory -Path (Split-Path $out) -Force | Out-Null
      $man = Join-Path $tmp "$name.json"
      ConvertTo-Json -Depth 5 -InputObject @([ordered]@{
          out = $out.Replace('\', '/'); kind = $kind; src = $src.Replace('\', '/'); dar = '4:3'; subTrack = 0
          audioTracks = @(0); audioLangs = @('eng'); expectSeconds = 10.0; expectFrames = 250 }) |
        Set-Content -LiteralPath $man -Encoding utf8
      $log = & pwsh -NoProfile -File $Transcode -Manifest $man -LogDir $tmp 2>&1
      $x = $LASTEXITCODE
      # Write-Host, not Write-Output: this function's output IS its return value.
      $log | Where-Object { "$_" -match 'palette|PALETTE|FAILED|   OK ' } | ForEach-Object { Write-Host "       | $_" }
      [pscustomobject]@{ Exit = $x; Out = $out; Log = ($log -join "`n") }
    }
    [IO.File]::WriteAllText("$vob.palette.txt", "$IE`n")
    $a = Run-Item 'carve' $vob 'MKV'
    Check 'a. carve + sidecar: exit' $a.Exit 0
    Check 'a. output exists' (Test-Path -LiteralPath $a.Out) 'True'
    if (Test-Path -LiteralPath $a.Out) {
      Check 'a. output carries the sidecar palette' (Get-DvdSubPaletteLine -Ffprobe $fp -InSpec @('-i', $a.Out)) $IE
      $sz = { param($p) (Get-SubPacketList $fp $p 0 | ForEach-Object { ($_ -split ',')[2, 4] -join ',' }) -join '|' }
      Check 'a. subpictures byte-identical to the palette-bearing reference' (& $sz $a.Out) (& $sz $ref)
    }
    Check 'a. no .no-palette' (Test-Path -LiteralPath "$($a.Out).no-palette") 'False'

    Remove-Item -LiteralPath "$vob.palette.txt"
    $b = Run-Item 'carve-nopal' $vob 'MKV'
    Check 'b. carve without sidecar: refused (exit 1)' $b.Exit 1
    Check 'b. says why' ($b.Log -match 'PALETTE is unknown') 'True'
    Check 'b. nothing written' ((Test-Path -LiteralPath $b.Out) -or (Test-Path -LiteralPath "$($b.Out).no-palette")) 'False'

    $c = Run-Item 'mkvsrc' $ref 'MKV'
    Check 'c. MKV source with its own palette: exit' $c.Exit 0
    Check 'c. palette from the source stream' ($c.Log -match 'subtitle palette from the source stream') 'True'
    Check 'c. no repair needed' ($c.Log -match 'palette written to') 'False'
    if (Test-Path -LiteralPath $c.Out) { Check 'c. output palette = source' (Get-DvdSubPaletteLine -Ffprobe $fp -InSpec @('-i', $c.Out)) $IE }
  }
} finally {
  if ($tmp.StartsWith([IO.Path]::GetTempPath())) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($script:fails) { Write-Output "FAILED: $script:fails check(s)"; exit 1 }
Write-Output 'ALL PASSED'; exit 0
