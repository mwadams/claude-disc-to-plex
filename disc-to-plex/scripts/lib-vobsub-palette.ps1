<#
  Carry a DVD subtitle's PALETTE into an encode, and refuse an encode that lost it.

  WHY. A DVD subpicture is 2-bit pixel indices into a 16-colour CLUT that lives in the PGC (the
  IFO), not in the VOB. ffmpeg's dvdvideo demuxer reads the CLUT and exposes it as the stream's
  extradata - `palette: rrggbb, ... (x16)\n`, 136 bytes - and a stream copy carries that into the
  MKV's CodecPrivate. A CARVED .vob (dvd-angle-cells.py angle carve, or a vobSectors cut) is read
  by the plain mpegps demuxer instead, which has no IFO: the dvd_subtitle stream is copied with NO
  extradata, every structural check passes, and OCR renders the bitmaps against a DEFAULT palette.

  The Invisible Enemy S00E346-349 (CGI Effects angle carves), measured 2026-09-28: subtitle packets
  byte-identical to the primary-angle S15E08 (256/256 - pts, size, MD5), the ONLY difference the
  missing palette. S00E349 failed the OCR dictionary gate 49 times at 94.7% ("letters are being
  split"); S00E346-348 passed by luck. Every published carve with a kept subtitle had the same
  defect: S00E241, S00E269-272, S00E346-349, S07E11 (Doctor Who).

  THE FIX IS A LOSSLESS REMUX, NOT A RE-ENCODE. Matroska stores the palette only as CodecPrivate,
  and ffmpeg has no option to set extradata on a stream copy. Its VOBSUB demuxer, though, reads the
  palette from an .idx and emits it as extradata. So: mkvextract the track to .idx/.sub, write the
  palette line into the .idx, and remux with -copyts so every timestamp is carried as written. The
  result is VERIFIED against the original, packet for packet (pts, duration, size, flags, MD5), with
  every other stream's packet count, tags, dispositions and chapters unchanged - and the original
  is replaced only if all of that holds.

  Functions:
    Get-DvdSubPaletteLine  -Ffprobe -InSpec -Stream     palette line from a stream's extradata, or $null
    Get-DvdSubStreams      -Ffprobe -Path               dvd_subtitle streams with their palette (or $null)
    Test-DvdSubPalette     -Ffprobe -Path -Want         the GUARD: Ok only if every dvd_subtitle carries Want
    Add-DvdSubPalette      -Ffmpeg -Ffprobe -Mkvextract -Path -Palette -WorkDir   the repair
#>

$script:VobSubPaletteRx = '^palette: ([0-9a-f]{6}, ){15}[0-9a-f]{6}$'

function ConvertFrom-FfprobeHexdump([string[]]$Lines) {
  # ffprobe -show_data prints `00000010: 2066 6430 ...  <ascii>`: fixed-width hex columns 10..48.
  $hex = ($Lines | Where-Object { $_ -match '^[0-9a-f]{8}: ' } | ForEach-Object {
      $row = $_.PadRight(49); $row.Substring(10, 39) -replace '\s', '' }) -join ''
  if (-not $hex -or ($hex.Length % 2)) { return [byte[]]@() }
  [byte[]]$out = for ($k = 0; $k -lt $hex.Length; $k += 2) { [Convert]::ToByte($hex.Substring($k, 2), 16) }
  return $out
}

function Get-DvdSubPaletteLine {
  # The `palette: ...` line of one subtitle stream's extradata, or $null when it carries none.
  param([string]$Ffprobe, [string[]]$InSpec, [string]$Stream = 's:0')
  $txt = & $Ffprobe -v error @InSpec -select_streams $Stream -show_streams -show_data 2>$null
  # Only the FIRST stream section: a -select_streams spec that matches several would concatenate.
  $sect = @(); $in = $false
  foreach ($l in $txt) {
    if ($l -eq '[STREAM]') { if ($in) { break }; $in = $true; continue }
    if ($l -eq '[/STREAM]') { break }
    if ($in) { $sect += $l }
  }
  $at = [array]::IndexOf($sect, ($sect | Where-Object { $_ -like 'extradata=*' } | Select-Object -First 1))
  if ($at -lt 0) { return $null }
  $dump = @(); for ($k = $at + 1; $k -lt $sect.Count -and $sect[$k] -match '^[0-9a-f]{8}: '; $k++) { $dump += $sect[$k] }
  $bytes = ConvertFrom-FfprobeHexdump $dump
  if (-not $bytes.Count) { return $null }
  $line = ([Text.Encoding]::ASCII.GetString($bytes) -split "`r?`n") | Where-Object { $_ -match '^palette:' } | Select-Object -First 1
  if (-not $line) { return $null }
  return $line.Trim()
}

function Get-DvdSubStreams {
  # One row per dvd_subtitle stream in a file: absolute Index, subtitle ordinal SubOrd, Palette (or $null).
  param([string]$Ffprobe, [string]$Path)
  $rows = @(& $Ffprobe -v error -select_streams s -show_entries stream=index,codec_name -of csv=p=0 $Path 2>$null)
  $ord = 0
  foreach ($r in $rows) {
    $f = "$r".Trim().TrimEnd(',') -split ','
    if ($f.Count -ge 2 -and $f[1] -eq 'dvd_subtitle') {
      [pscustomobject]@{ Index = [int]$f[0]; SubOrd = $ord
        Palette = Get-DvdSubPaletteLine -Ffprobe $Ffprobe -InSpec @('-i', $Path) -Stream "s:$ord" }
    }
    $ord++
  }
}

function Test-DvdSubPalette {
  # THE GUARD. Ok = every dvd_subtitle stream carries a palette, equal to -Want when one is given.
  # A file with no dvd_subtitle stream is Ok (nothing to carry).
  param([string]$Ffprobe, [string]$Path, [string]$Want)
  $s = @(Get-DvdSubStreams -Ffprobe $Ffprobe -Path $Path)
  $missing = @($s | Where-Object { -not $_.Palette })
  $wrong = if ($Want) { @($s | Where-Object { $_.Palette -and $_.Palette -ne $Want }) } else { @() }
  $why = @()
  if ($missing) { $why += "dvd_subtitle stream(s) $(($missing | ForEach-Object { "#$($_.Index)" }) -join ',') carry NO palette" }
  if ($wrong) { $why += "dvd_subtitle stream(s) $(($wrong | ForEach-Object { "#$($_.Index)" }) -join ',') carry a palette that is not the source's" }
  [pscustomobject]@{ Ok = -not ($missing -or $wrong); Streams = $s.Count; Missing = $missing.Count; Wrong = $wrong.Count; Reason = ($why -join '; ') }
}

function Get-StreamSnapshot([string]$Ffprobe, [string]$Path) {
  # Everything a lossless remux must leave unchanged, per stream, plus chapters and duration.
  $j = & $Ffprobe -v error -count_packets -show_entries 'stream=index,codec_name,nb_read_packets:stream_tags=language,title:stream_disposition=default,forced,hearing_impaired,visual_impaired,comment:format=duration' -show_chapters -of json $Path 2>$null | ConvertFrom-Json
  [pscustomobject]@{
    Streams  = @($j.streams | ForEach-Object {
        '{0}|{1}|{2}|{3}|{4}|d{5}f{6}h{7}v{8}c{9}' -f $_.index, $_.codec_name, $_.nb_read_packets, $_.tags.language, $_.tags.title,
          $_.disposition.default, $_.disposition.forced, $_.disposition.hearing_impaired, $_.disposition.visual_impaired, $_.disposition.comment })
    Chapters = @($j.chapters).Count
    Duration = [double]$j.format.duration
  }
}

function Get-SubPacketList([string]$Ffprobe, [string]$Path, [int]$SubOrd) {
  @(& $Ffprobe -v error -select_streams "s:$SubOrd" -show_entries packet=pts,duration,size,flags,data_hash -show_data_hash MD5 -of csv=p=0 $Path 2>$null)
}

function Add-DvdSubPalette {
  # Give every palette-less dvd_subtitle stream in -Path the palette -Palette, losslessly, in place.
  # Returns Ok/Repaired/Reason. On any doubt the ORIGINAL IS LEFT UNTOUCHED and Ok is $false.
  param([string]$Ffmpeg, [string]$Ffprobe, [string]$Mkvextract, [string]$Path, [string]$Palette, [string]$WorkDir)
  $fail = { param($why) [pscustomobject]@{ Ok = $false; Repaired = 0; Reason = $why } }
  if ($Palette -notmatch $script:VobSubPaletteRx) { return (& $fail "not a 16-entry palette line: '$Palette'") }
  # The remux writes its temp file beside -Path. Local D: only - never a working file on the NAS.
  if ($Path.StartsWith('\\') -or $Path.StartsWith('//')) { return (& $fail "refusing a network path ($Path): repair a LOCAL copy") }
  if (-not (Test-Path -LiteralPath $Mkvextract)) { return (& $fail "mkvextract not found at $Mkvextract") }
  $todo = @(Get-DvdSubStreams -Ffprobe $Ffprobe -Path $Path | Where-Object { -not $_.Palette })
  if (-not $todo) { return [pscustomobject]@{ Ok = $true; Repaired = 0; Reason = 'every dvd_subtitle stream already carries a palette' } }

  $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $dir = Join-Path $WorkDir "vobsubpal-$tag"
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $tmp = Join-Path (Split-Path -Parent $Path) ("{0}.palette-{1}.tmp.mkv" -f [IO.Path]::GetFileNameWithoutExtension($Path), $tag)
  try {
    $before = Get-StreamSnapshot $Ffprobe $Path
    $nStreams = $before.Streams.Count
    $idxFor = @{}
    foreach ($s in $todo) {
      # mkvextract numbers tracks from 0 in file order - for an ffmpeg-written MKV, the stream index.
      $idx = Join-Path $dir ("t{0}.idx" -f $s.Index)
      $xo = & $Mkvextract $Path tracks ("{0}:{1}" -f $s.Index, $idx) 2>&1
      if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $idx) -or -not (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($idx, '.sub')))) {
        return (& $fail "mkvextract did not write track $($s.Index) as .idx/.sub: $($xo | Select-Object -Last 2)")
      }
      # Palette and size lines go in the header; nothing else of ours. Only `palette:` is written so
      # the extradata is the SAME 136 bytes the dvdvideo route produces.
      $lines = @(Get-Content -LiteralPath $idx)
      $body = @($lines | Select-Object -Skip 1 | Where-Object { $_ -notmatch '^(palette|size):' })
      [IO.File]::WriteAllLines($idx, [string[]](@($lines[0], $Palette) + $body))
      $idxFor[$s.Index] = $idx
    }
    # Inputs: 0 = the file, then one .idx per repaired stream. Maps in the ORIGINAL stream order.
    $a = @('-y', '-hide_banner', '-v', 'error', '-copyts', '-i', $Path)
    $inputOf = @{}; $n = 1
    foreach ($k in ($idxFor.Keys | Sort-Object)) { $a += @('-i', $idxFor[$k]); $inputOf[$k] = $n; $n++ }
    for ($k = 0; $k -lt $nStreams; $k++) {
      if ($inputOf.ContainsKey($k)) { $a += @('-map', "$($inputOf[$k]):0") } else { $a += @('-map', "0:$k") }
    }
    $a += @('-c', 'copy', '-map_metadata', '0', '-map_chapters', '0')
    # Tags for EVERY stream from the original: any per-stream -map_metadata switches ffmpeg's default
    # per-stream copying off for all streams, so mapping only the replaced ones would strip the rest.
    for ($k = 0; $k -lt $nStreams; $k++) { $a += @("-map_metadata:s:$k", "0:s:$k") }
    foreach ($k in $inputOf.Keys) {
      # Dispositions for a replaced stream come from the ORIGINAL stream, not the .idx.
      $f = ($before.Streams[$k] -split '\|')[5]
      $disp = @(); if ($f -match 'd1') { $disp += 'default' }; if ($f -match 'f1') { $disp += 'forced' }
      if ($f -match 'h1') { $disp += 'hearing_impaired' }; if ($f -match 'v1') { $disp += 'visual_impaired' }; if ($f -match 'c1') { $disp += 'comment' }
      $a += @("-disposition:$k", $(if ($disp) { $disp -join '+' } else { '0' }))
    }
    $a += $tmp
    $fo = & $Ffmpeg @a 2>&1
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $tmp)) { return (& $fail "remux failed: $($fo | Select-Object -Last 2)") }

    # VERIFY before anything is replaced.
    $after = Get-StreamSnapshot $Ffprobe $tmp
    $diff = @()
    if ($after.Streams.Count -ne $nStreams) { $diff += "stream count $nStreams -> $($after.Streams.Count)" }
    else { for ($k = 0; $k -lt $nStreams; $k++) { if ($after.Streams[$k] -ne $before.Streams[$k]) { $diff += "stream $k '$($before.Streams[$k])' -> '$($after.Streams[$k])'" } } }
    if ($after.Chapters -ne $before.Chapters) { $diff += "chapters $($before.Chapters) -> $($after.Chapters)" }
    if ([Math]::Abs($after.Duration - $before.Duration) -gt 0.05) { $diff += "duration $($before.Duration) -> $($after.Duration)" }
    foreach ($s in $todo) {
      $p0 = Get-SubPacketList $Ffprobe $Path $s.SubOrd; $p1 = Get-SubPacketList $Ffprobe $tmp $s.SubOrd
      if (($p0 -join "`n") -ne ($p1 -join "`n")) { $diff += "stream $($s.Index): subtitle packets differ ($($p0.Count) -> $($p1.Count))" }
    }
    $g = Test-DvdSubPalette -Ffprobe $Ffprobe -Path $tmp -Want $Palette
    if (-not $g.Ok) { $diff += $g.Reason }
    if ($diff) { return (& $fail ("remux not lossless - original kept: " + ($diff -join '; '))) }

    Move-Item -LiteralPath $tmp -Destination $Path -Force
    return [pscustomobject]@{ Ok = $true; Repaired = $todo.Count; Reason = "palette written to $($todo.Count) dvd_subtitle stream(s); packets, tags, dispositions and chapters verified unchanged" }
  }
  finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
}
