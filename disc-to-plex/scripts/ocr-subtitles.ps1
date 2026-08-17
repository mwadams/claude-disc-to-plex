<#
.SYNOPSIS
  Convert an MKV's BITMAP subtitle tracks (PGS / VOBSUB) to text SRT.

.DESCRIPTION
  Bitmap subtitles are pictures of text baked at a fixed size by the disc author. Plex's
  subtitle size / font / colour / position settings apply ONLY to text subtitles, so for
  bitmaps the player can do nothing but scale the image - which is why DVD subs in particular
  look oversized and blocky (720x576, 4 colours, upscaled 3-5x on a 1080p/4K screen).

  This converts them to SRT so the viewer controls the rendering. The original bitmap track is
  always KEPT: OCR is never perfect, and the bitmap costs little.

  Two output modes:
    -Mode Sidecar  (DEFAULT) write <basename>.<lang>.srt next to the media file. Plex picks these
                   up automatically. Use this for everything: new transfers AND retro-fits. It
                   CREATES a file and never rewrites the media, so it does not run into the NAS
                   delete/move guard - and, more importantly, a bad OCR can be corrected or
                   deleted later without touching the video at all.
    -Mode Mux      remux the SRT into the MKV as a default-flagged track. Available, but prefer
                   Sidecar: OCR errors surface only when someone watches the film, and by then
                   repairing a muxed track means rewriting the whole file.

  REMEMBER when publishing: a sidecar is a SEPARATE FILE. Copy the .srt to the NAS alongside the
  .mkv, or the subtitles simply will not be there.

.PARAMETER Path
  An .mkv file, or a folder to process recursively.

.PARAMETER Lang
  ISO-639-2 language to OCR. Default 'eng'. Only tracks tagged with this (or untagged) are done.

.PARAMETER Mode
  Mux (default) or Sidecar.

.PARAMETER WhatIf
  Report what would happen without writing anything.

.NOTES
  Requires mkvextract + seconv + Tesseract - see install-tools.ps1. ffmpeg has NO vobsub muxer,
  so mkvextract is not optional; and seconv cannot read VOBSUB out of a Matroska container
  itself, hence extract-then-convert.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [Parameter(Mandatory)][string]$Path,
  [string]$Lang = 'eng',
  # Sidecar is the DEFAULT and should stay that way. OCR is imperfect and its failures are only
  # visible once someone watches the film, so the recovery cost matters more than the tidiness of
  # a single file. Fixing a sidecar is a text edit; fixing a muxed track means rewriting a
  # multi-gigabyte mkv - which is what stripping three bad Shakespeare tracks actually cost, and
  # why ~4,900 pipe-for-I artefacts already muxed into earlier transfers are not worth repairing.
  # Plex reads sidecars automatically, so nothing is lost by keeping the text outside the media.
  [ValidateSet('Mux','Sidecar')][string]$Mode = 'Sidecar',
  # Shift every cue by this many milliseconds. NEGATIVE = show earlier, POSITIVE = show later.
  #
  # LEAVE THIS AT 0 unless you have a specific reason. The OCR introduces no drift - verified by
  # comparing an output SRT against the source PGS packet timestamps, which matched to the
  # millisecond - so any desync you see is the DISC's own authoring, and the bitmap track is out by
  # exactly the same amount. Reproducing source timing faithfully is therefore the correct default:
  # it is never worse than what the library already plays.
  #
  # It is also rarely needed, because Plex offers a per-playback subtitle offset control - and that
  # control works ONLY on text subtitles. Converting the bitmap to SRT is precisely what lets the
  # viewer fix timing themselves, non-destructively. Baking an offset in takes that choice away.
  [int]$OffsetMs = 0,
  [string]$ToolsDir = 'D:\video\.transcode-tools'
)

$ErrorActionPreference = 'Stop'
$paths = Get-Content (Join-Path $ToolsDir 'tool-paths.json') -Raw | ConvertFrom-Json
$ffprobe = (Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe')
$ffmpeg  = $paths.ffmpeg
$mkvx    = $paths.mkvextract
$seconv  = $paths.seconv

if (-not $mkvx -or -not (Test-Path $mkvx)) { throw "mkvextract missing - re-run install-tools.ps1" }
if (-not $seconv -or -not (Test-Path $seconv)) { throw "seconv missing - re-run install-tools.ps1" }
# seconv shells out to tesseract and resolves it from PATH *as its child process sees it*. A
# tesseract that this script can find via Get-Command is NOT necessarily visible to seconv - the
# installer updates the machine PATH, but an already-running shell keeps its inherited copy, so
# seconv reports "Tesseract not found on PATH" while `tesseract --version` works right here.
# Prepend the real directory so the child inherits it.
$tessExe = (Get-Command tesseract -ErrorAction SilentlyContinue).Source
if (-not $tessExe) { $tessExe = $paths.tesseract }
if ($tessExe -and (Test-Path $tessExe)) {
  $tessDir = Split-Path $tessExe
  if ($env:PATH -notlike "*$tessDir*") { $env:PATH = "$tessDir;$env:PATH" }
}

if (-not $tessExe) {
  throw @"
Tesseract is not installed. Install it (elevated) and re-run:
  winget install --id UB-Mannheim.TesseractOCR --accept-package-agreements --accept-source-agreements

Do NOT substitute seconv's built-in nOCR engine: on real DVD material it returns "*" for every
cue while still reporting success.
"@
}

# Codecs that are bitmaps and therefore need OCR. Anything else is already text.
$bitmapCodecs = @('hdmv_pgs_subtitle','dvd_subtitle','dvb_subtitle','xsub')

# ---------------------------------------------------------------------------------------------
# VOBSUB PALETTE REPAIR - the fix for systematically split letters (d->cl, b->lo, m->rn, th->tt)
#
# A DVD subpicture is 2 bits per pixel: FOUR indices into a 16-entry palette, each with its own
# alpha. The near-universal authoring convention is
#     index 0 = transparent background      index 1 = glyph FILL (white/yellow)
#     index 2 = ANTI-ALIAS ring (mid grey)  index 3 = OUTLINE (black)
# Subtitle Edit's VobSub OCR does "colour isolation": it binarises to black-on-white by keeping
# ONE colour - the fill - and discarding everything else. That is correct only when the fill
# carries the stroke. Measured on the actual bitmaps:
#     Queen Christina (1933), OCRs fine : fill 2623 px, anti-alias   70 px  -> aa/fill = 0.03
#     Blithe Spirit  (1945), garbled    : fill 5745 px, anti-alias 6889 px  -> aa/fill = 1.20
# On Blithe Spirit MORE THAN HALF the ink is in the anti-alias index, so isolating the fill erodes
# every stroke to a 1px hairline and the thin joins break: the bowl of a 'd' separates from its
# ascender and reads as "cl", 'b' as "lo", 'm' as "rn", 'th' as "tt". That is the whole defect. It
# is per-DISC (a light-weight face with heavy anti-aliasing), NOT per-era - which is why two 1930s
# discs are clean and three of the same vintage are not.
#
# The fix is one line of palette: repaint every ink index with the FILL's colour, so isolation
# keeps fill+anti-alias as a single solid glyph. Nothing else changes - the .sub bitmap, the
# timings and the OCR engine are all untouched, and on a disc that never needed it (Queen
# Christina) the output is byte-for-byte identical.
#
# Rejected alternative: seconv's --no-vobsub-isolate-colors. It makes things WORSE, not better -
# without isolation Tesseract latches onto the black outline and reads the inter-word gaps as
# letters: "Oncelupontaltime! therelwaslalcharminglcounthy house". Dictionary hit rate 56%, vs 87%
# for the broken default and 99% with the palette repaired.
function Repair-VobSubPalette {
  param([string]$IdxPath)

  $subPath = [IO.Path]::ChangeExtension($IdxPath, '.sub')
  if (-not (Test-Path $subPath)) { return $null }

  $lines = Get-Content -LiteralPath $IdxPath
  $palLine = $lines | Where-Object { $_ -match '^palette:' } | Select-Object -First 1
  if (-not $palLine) { return $null }
  $pal = @(($palLine -replace '^palette:\s*','') -split ',' | ForEach-Object { [Convert]::ToInt32($_.Trim(), 16) })
  if ($pal.Count -lt 16) { return $null }

  # Only the first few cues are needed - the four index roles are set per display command and are
  # constant across a disc in practice. Reading a 1 MB window covers them without slurping a
  # multi-megabyte .sub.
  $fs = [IO.File]::OpenRead($subPath)
  try {
    $buf = New-Object byte[] ([math]::Min(1MB, $fs.Length))
    [void]$fs.Read($buf, 0, $buf.Length)
  } finally { $fs.Dispose() }

  $starts = @($lines | ForEach-Object { if ($_ -match 'filepos:\s*([0-9a-fA-F]+)') { [Convert]::ToInt32($Matches[1], 16) } }) |
              Select-Object -First 8

  $palIdx = $null; $alpha = $null; $hist = @(0,0,0,0); $decoded = 0
  foreach ($start in $starts) {
    if ($start -ge $buf.Length) { continue }
    $cw = 0; $ch = 0; $off0 = -1; $off1 = -1

    # Reassemble the SPU packet: it is spread over consecutive 2 KB MPEG program-stream sectors,
    # each carrying a pack header (0x000001BA) then a private_stream_1 PES (0x000001BD) whose
    # payload begins with a one-byte substream id. Concatenate payloads until we have the length
    # declared in the SPU's own first two bytes.
    # EVERY 16-bit field below casts to [int] before shifting. PowerShell's -shl keeps the WIDTH of
    # its left operand, so `[byte]0x11 -shl 8` is 0, not 0x1100: without the cast every length and
    # offset silently loses its high byte, the packet reassembles short, and the whole repair
    # returns $null - i.e. it fails by doing nothing at all, which looks exactly like "this disc
    # needed no repair". Do not remove the casts.
    $p = $start; $want = -1
    $spu = New-Object 'System.Collections.Generic.List[byte]'
    while ($p -lt $buf.Length - 6) {
      if ($buf[$p] -ne 0 -or $buf[$p+1] -ne 0 -or $buf[$p+2] -ne 1) { $p++; continue }
      $sc = $buf[$p+3]
      if ($sc -eq 0xBA) { $p += 14 + ($buf[$p+13] -band 7); continue }
      $plen = ([int]$buf[$p+4] -shl 8) -bor $buf[$p+5]
      if ($sc -eq 0xBD) {
        $from = $p + 9 + $buf[$p+8] + 1      # +1 skips the substream id byte
        $to   = [math]::Min($p + 6 + $plen, $buf.Length)
        for ($i = $from; $i -lt $to; $i++) { $spu.Add($buf[$i]) }
        if ($want -lt 0 -and $spu.Count -ge 2) { $want = ([int]$spu[0] -shl 8) -bor $spu[1] }
        if ($want -ge 0 -and $spu.Count -ge $want) { break }
      }
      $p += 6 + $plen
    }
    if ($spu.Count -lt 8) { continue }
    $s = $spu.ToArray()

    # Walk the display control sequences for SET_COLOR (0x03) and SET_CONTRAST (0x04). Both pack
    # the four entries HIGHEST INDEX FIRST across two bytes, so index 0 is the LOW nibble of the
    # SECOND byte - getting that backwards silently swaps background for outline.
    $dcsq = ([int]$s[2] -shl 8) -bor $s[3]; $seen = @{}
    while ($dcsq -gt 0 -and $dcsq -lt $s.Length - 4 -and -not $seen.ContainsKey($dcsq)) {
      $seen[$dcsq] = $true
      $next = ([int]$s[$dcsq+2] -shl 8) -bor $s[$dcsq+3]
      $i = $dcsq + 4
      while ($i -lt $s.Length) {
        $c = $s[$i]
        if ($c -eq 0xFF) { break }
        elseif ($c -le 0x02) { $i++ }
        elseif ($c -eq 0x03) {
          if (-not $palIdx) { $palIdx = @(($s[$i+2] -band 15), ($s[$i+2] -shr 4), ($s[$i+1] -band 15), ($s[$i+1] -shr 4)) }
          $i += 3
        }
        elseif ($c -eq 0x04) {
          # A fade-in authors an all-zero contrast in the FIRST sequence and the real one later, so
          # take the first command that actually makes something visible.
          $a = @(($s[$i+2] -band 15), ($s[$i+2] -shr 4), ($s[$i+1] -band 15), ($s[$i+1] -shr 4))
          if (-not $alpha -and (@($a | Where-Object { $_ -gt 0 }).Count -gt 0)) { $alpha = $a }
          $i += 3
        }
        elseif ($c -eq 0x05) {
          # SET_DISPLAY_AREA: two 12-bit pairs packed into six bytes.
          $x1 = ([int]$s[$i+1] -shl 4) -bor ($s[$i+2] -shr 4)
          $x2 = (([int]$s[$i+2] -band 15) -shl 8) -bor $s[$i+3]
          $y1 = ([int]$s[$i+4] -shl 4) -bor ($s[$i+5] -shr 4)
          $y2 = (([int]$s[$i+5] -band 15) -shl 8) -bor $s[$i+6]
          $cw = $x2 - $x1 + 1; $ch = $y2 - $y1 + 1
          $i += 7
        }
        elseif ($c -eq 0x06) {
          # SET_PIXEL_DATA_ADDRESS: byte offsets of the even and odd row fields.
          $off0 = ([int]$s[$i+1] -shl 8) -bor $s[$i+2]
          $off1 = ([int]$s[$i+3] -shl 8) -bor $s[$i+4]
          $i += 5
        }
        elseif ($c -eq 0x07) { $i += 1 + (([int]$s[$i+1] -shl 8) -bor $s[$i+2]) }
        else { $i++ }
      }
      if ($next -eq $dcsq) { break }
      $dcsq = $next
    }

    # Decode the 2-bit RLE and COUNT pixels per index. This is what makes the repair targeted
    # rather than blanket: see the ink-weight test further down. Runs are nibble-coded - 1 to 4
    # nibbles, value = (count << 2) | colour - each row padded to a byte boundary, with even rows
    # at $off0 and odd rows at $off1.
    if ($cw -gt 0 -and $ch -gt 0 -and $off0 -ge 0) {
      foreach ($field in 0,1) {
        $ni = 2 * $(if ($field -eq 0) { $off0 } else { $off1 })
        for ($y = $field; $y -lt $ch; $y += 2) {
          $x = 0
          while ($x -lt $cw) {
            $n = 0; $ran = $false
            for ($k = 0; $k -lt 4; $k++) {
              # $ni -shr 1, NOT [int]($ni / 2): PowerShell's [int] cast rounds to even rather than
              # truncating, so [int](7/2) is 4 and every odd nibble index reads the WRONG byte.
              $bi = $ni -shr 1
              if ($bi -ge $s.Length) { $ran = $true; break }
              $v = if ($ni % 2 -eq 0) { $s[$bi] -shr 4 } else { $s[$bi] -band 15 }
              $ni++
              $n = ($n -shl 4) -bor $v
              if ($n -ge (4 -shl (2 * $k))) { break }
            }
            if ($ran) { break }
            $cnt = $n -shr 2; $col = $n -band 3
            if ($cnt -eq 0 -or $cnt -gt ($cw - $x)) { $cnt = $cw - $x }
            $hist[$col] += $cnt
            $x += $cnt
          }
          if ($ni % 2) { $ni++ }        # each row restarts on a byte boundary
        }
      }
      $decoded++
    }
    if ($palIdx -and $alpha -and $decoded -ge 3) { break }
  }
  if (-not $palIdx -or -not $alpha) { return $null }

  # Classify by luminance. DVD subtitles are light text with a dark outline essentially without
  # exception, so the DARKEST visible index is the outline and everything else visible is ink.
  # Deliberately not using a midpoint threshold: Blithe Spirit's anti-alias sits at luma 124
  # against fill 253 and outline 0, i.e. BELOW the midpoint, so a midpoint rule would discard the
  # very pixels this repair exists to keep.
  $vis = @(0..3 | Where-Object { $alpha[$_] -gt 0 })
  if ($vis.Count -lt 2) { return $null }
  $lum = @{}
  foreach ($i in $vis) {
    $c = $pal[$palIdx[$i]]
    $lum[$i] = 0.299 * (($c -shr 16) -band 255) + 0.587 * (($c -shr 8) -band 255) + 0.114 * ($c -band 255)
  }
  $outline = ($vis | Sort-Object { $lum[$_] })[0]
  # "Everything except the darkest index is ink" is NOT safe: some discs author a hard drop-shadow
  # as a SECOND near-black index. Kiki's Delivery Service is exactly that - visible indices are
  # yellow(225), black(0), black(0) - and it OCRs perfectly today because isolating the fill loses
  # nothing. Merging its second black into the fill would flood every glyph solid yellow and break
  # a title that works. So ink must be CLEARLY brighter than the darkest index; a real anti-alias
  # sits midway between fill and outline (Blithe 124, Ponyo 113, Queen 129 against a 0 outline),
  # while a shadow sits on top of it.
  $lumMin = ($vis | ForEach-Object { $lum[$_] } | Measure-Object -Minimum).Minimum
  $ink    = @($vis | Where-Object { ($lum[$_] - $lumMin) -gt 32 })
  if ($ink.Count -lt 2) { return $null }           # no anti-alias index -> nothing to merge
  $fill    = ($ink | Sort-Object { -$lum[$_] })[0]
  $fillCol = $pal[$palIdx[$fill]]

  # INK-WEIGHT TEST - only repair a disc that actually needs it.
  #
  # Merging the anti-alias into the fill is not free: it fattens every glyph by up to a pixel. On a
  # disc whose anti-alias is a token 3% of the fill that is pure downside, and measurably so -
  # repairing Queen Christina regardless changed 18 lines out of 5028, turning 'we'/'victorious'
  # into 'We'/'Victorious' as thickened lowercase letters started reading as capitals. It gained
  # nothing (dictionary score identical at 99.1%) and cost about nine lines.
  #
  # So gate on how much ink the anti-alias actually carries, measured from the decoded bitmaps:
  #     Kiki's Delivery Service  0.00  no anti-alias index at all      -> skip
  #     Queen Christina          0.03  70 px against a 2623 px fill    -> skip
  #     Ponyo                    0.76  942 px against 1244 px          -> REPAIR
  #     Blithe Spirit            1.20  6889 px against 5745 px         -> REPAIR
  # 0.15 sits in the wide empty gap between the two groups. Below it the fill alone still carries
  # a legible glyph, which is precisely the condition under which colour isolation is safe.
  $aaPx   = ($ink | Where-Object { $_ -ne $fill } | ForEach-Object { $hist[$_] } | Measure-Object -Sum).Sum
  $fillPx = $hist[$fill]
  if ($fillPx -le 0) { return $null }
  $ratio = $aaPx / $fillPx
  if ($ratio -lt 0.15) { return $null }

  # Never repaint a palette ENTRY that the outline or the transparent background also points at -
  # entries are shared, and recolouring one would repaint the outline white and destroy the image.
  $protected = @($palIdx[$outline]) + @(0..3 | Where-Object { $alpha[$_] -eq 0 } | ForEach-Object { $palIdx[$_] })
  $changed = 0
  foreach ($j in $ink) {
    $e = $palIdx[$j]
    if ($e -eq $palIdx[$fill] -or $protected -contains $e) { continue }
    if ($pal[$e] -ne $fillCol) { $pal[$e] = $fillCol; $changed++ }
  }
  if ($changed -eq 0) { return $null }

  $newPal = 'palette: ' + (($pal | ForEach-Object { '{0:x6}' -f $_ }) -join ', ')
  # WriteAllLines, not Set-Content -Encoding UTF8: under Windows PowerShell 5.1 that spelling emits
  # a BOM, and a BOM ahead of the "# VobSub index file, v7" line stops the parser recognising the
  # file at all. WriteAllLines is BOM-free on every runtime.
  [IO.File]::WriteAllLines($IdxPath, [string[]]($lines | ForEach-Object { if ($_ -match '^palette:') { $newPal } else { $_ } }))
  return ('anti-alias {0:P0} of fill ink -> merged into #{1:x6}' -f $ratio, $fillCol)
}

# ---------------------------------------------------------------------------------------------
# English word list, used by the dictionary gate below. Tesseract ships its own 338k-word English
# dawg inside eng.traineddata, and the two tools that unpack it (combine_tessdata, dawg2wordlist)
# sit next to tesseract.exe - so this needs NO new dependency and no download. Built once and
# cached in the tools dir; a few seconds the first time, nothing thereafter.
function Get-EnglishWordSet {
  param([string]$ToolsDir, [string]$TessExe)
  # Held for the life of the run: a batch is often 100+ files and re-reading 3 MB into a fresh
  # HashSet for each one costs about a second apiece for no benefit.
  if ($script:EngWords) { return ,$script:EngWords }
  $cache = Join-Path $ToolsDir 'eng-words.txt'
  if (-not (Test-Path $cache)) {
    $tdir = Join-Path (Split-Path $TessExe) 'tessdata'
    $comb = Join-Path (Split-Path $TessExe) 'combine_tessdata.exe'
    $d2w  = Join-Path (Split-Path $TessExe) 'dawg2wordlist.exe'
    $td   = Join-Path $tdir 'eng.traineddata'
    if (-not (Test-Path $comb) -or -not (Test-Path $d2w) -or -not (Test-Path $td)) { return $null }
    $tmp = Join-Path $ToolsDir ("work\dict$PID\")
    New-Item -ItemType Directory -Force (Split-Path $tmp -Parent) | Out-Null
    New-Item -ItemType Directory -Force $tmp.TrimEnd('\') | Out-Null
    & $comb -u $td (Join-Path $tmp 'eng.') 2>&1 | Out-Null
    & $d2w (Join-Path $tmp 'eng.lstm-unicharset') (Join-Path $tmp 'eng.lstm-word-dawg') $cache 2>&1 | Out-Null
    Remove-Item $tmp.TrimEnd('\') -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $cache)) { return $null }
  }
  $set = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
  foreach ($w in [IO.File]::ReadLines($cache)) { [void]$set.Add($w) }
  # `return ,$set` - the leading comma is load-bearing. A bare `return $set` lets PowerShell UNROLL
  # the HashSet into 338,000 loose strings, so the caller gets an Object[]; .Contains() then binds
  # to IList.Contains, which is ordinal, CASE-SENSITIVE and O(n). The gate still "works", it just
  # scores every real conversion at ~13% and takes minutes doing it. Wrapping in a one-element
  # array keeps the HashSet whole.
  $script:EngWords = $set
  return ,$set
}

$targets = if ((Get-Item $Path).PSIsContainer) {
  Get-ChildItem -LiteralPath $Path -Recurse -File -Filter *.mkv
} else { @(Get-Item -LiteralPath $Path) }

Write-Host "files to consider: $($targets.Count)"
$work = Join-Path $ToolsDir ("work\ocr$PID")
New-Item -ItemType Directory -Force $work | Out-Null

$done = 0; $skipped = 0; $failed = 0

foreach ($f in $targets) {
  # ---- pick the track: bitmap, in the wanted language (untagged counts - discs often omit it)
  $info = & $ffprobe -v error -select_streams s `
            -show_entries stream=index,codec_name:stream_tags=language -of csv=p=0 $f.FullName 2>$null
  if (-not $info) { $skipped++; continue }

  $cand = @()
  foreach ($line in $info) {
    $p = $line -split ','
    if ($p.Count -lt 2) { continue }
    $idx = [int]$p[0]; $codec = $p[1]; $lang = if ($p.Count -ge 3) { $p[2] } else { '' }
    if ($bitmapCodecs -notcontains $codec) { continue }
    if ($lang -and $lang -ne $Lang -and $lang -ne 'und') { continue }
    $cand += [pscustomobject]@{ Index = $idx; Codec = $codec }
  }
  if (-not $cand) { $skipped++; continue }

  # already has a text track in this language? then there is nothing to gain
  $hasText = $info | Where-Object { $bitmapCodecs -notcontains ($_ -split ',')[1] }
  if ($hasText) { Write-Host "  skip (already has text subs): $($f.Name)"; $skipped++; continue }

  $track = $cand[0]
  $ext   = if ($track.Codec -eq 'hdmv_pgs_subtitle') { 'sup' } else { 'idx' }
  $stem  = Join-Path $work ([IO.Path]::GetRandomFileName())
  $bmp   = "$stem.$ext"

  if (-not $PSCmdlet.ShouldProcess($f.Name, "OCR subtitle track $($track.Index) ($($track.Codec))")) { continue }

  try {
    # mkvextract reads MATROSKA ONLY. A library also contains .mp4 rips that legitimately carry
    # dvd_subtitle tracks, and on those mkvextract exits quietly having written nothing - which
    # reads as an OCR failure when it is really a container mismatch. Remux just the wanted
    # subtitle stream into a temporary single-track mkv first (stream copy, no re-encode); inside
    # that file the track is always id 0.
    $extractFrom = $f.FullName
    $extractId   = $track.Index
    $shim        = $null
    if ($f.Extension -ne '.mkv') {
      $shim = "$stem.shim.mkv"
      & $ffmpeg -v error -i $f.FullName -map 0:$($track.Index) -c copy -y $shim 2>&1 | Out-Null
      if (-not (Test-Path $shim)) { throw "could not remux $($f.Extension) subtitle track into mkv for extraction" }
      $extractFrom = $shim
      $extractId   = 0
    }

    & $mkvx tracks $extractFrom "${extractId}:$bmp" 2>&1 | Out-Null
    if (-not (Test-Path $bmp)) { throw "mkvextract produced nothing" }

    # A track can be DECLARED in the header and hold no packets at all - the stream shows up in
    # ffprobe, so the survey flags the file, but there is nothing in it. (Two Sherlock Holmes
    # discs: `nb_read_packets` = N/A, and burning s:0 onto frames at three points rendered no
    # text.) Extraction "succeeds" and yields an index with no images, which then surfaces as
    # "seconv produced no SRT" - a failure report for a file that is simply empty. Detect it and
    # skip cleanly, so real failures stay visible in a long campaign.
    $payload = if ($ext -eq 'idx') { [IO.Path]::ChangeExtension($bmp, '.sub') } else { $bmp }
    $payloadSize = if (Test-Path $payload) { (Get-Item $payload).Length } else { 0 }
    if ($payloadSize -lt 10KB) {
      Write-Host ("  skip (subtitle track is empty - {0} bytes extracted): {1}" -f $payloadSize, $f.Name)
      $skipped++
      continue
    }

    # Repair the palette BEFORE OCR (VOBSUB only - PGS has 256 colours and a different isolation
    # path in Subtitle Edit, and no disc here has shown the defect on PGS). This edits the scratch
    # .idx that mkvextract just wrote; the media file is never touched.
    if ($ext -eq 'idx') {
      $repair = Repair-VobSubPalette -IdxPath $bmp
      if ($repair) { Write-Host "  vobsub palette: $repair" }
    }

    & $seconv $bmp subrip --ocr-engine:tesseract --ocr-language:$Lang `
        --output-folder:$work --overwrite 2>&1 | Out-Null
    $srt = [IO.Path]::ChangeExtension($bmp, '.srt')
    if (-not (Test-Path $srt)) { throw "seconv produced no SRT" }

    # Shift cues if asked. Done here rather than via seconv's --offset because that takes an
    # hh:mm:ss:ms string and cannot express a NEGATIVE shift, which is the direction usually needed.
    if ($OffsetMs -ne 0) {
      $shifted = [regex]::Replace((Get-Content $srt -Raw), '(\d{2}):(\d{2}):(\d{2}),(\d{3})', {
        param($m)
        $ms = ([int]$m.Groups[1].Value * 3600000) + ([int]$m.Groups[2].Value * 60000) +
              ([int]$m.Groups[3].Value * 1000) + [int]$m.Groups[4].Value + $OffsetMs
        if ($ms -lt 0) { $ms = 0 }   # cues cannot start before the file does
        '{0:D2}:{1:D2}:{2:D2},{3:D3}' -f [int]($ms/3600000), [int](($ms%3600000)/60000), [int](($ms%60000)/1000), [int]($ms%1000)
      })
      Set-Content -LiteralPath $srt -Value $shifted -Encoding UTF8 -NoNewline
    }

    # ---- SYSTEMATIC OCR REPAIR (before the gates, so they judge the shipped text)
    #
    # The single commonest error on these discs is a capital I read as a pipe: "Ol! | was here
    # before you!". The substitution is safe in one direction only - a pipe is essentially never
    # legitimate in dialogue, whereas I is one of the commonest characters in English - so this is
    # a rare case where a blanket replacement is right.
    #
    # Deliberately NOT doing the same for l/I or ./, : those are genuinely ambiguous and a wrong
    # "fix" would corrupt correct text, which is worse than leaving a visible artefact.
    $text = Get-Content $srt -Raw
    $pipes = ([regex]::Matches($text, '\|')).Count
    if ($pipes -gt 0) {
      # only inside cue text - never touch the index or the --> timing lines
      $fixed = ($text -split "`r?`n" | ForEach-Object {
        if ($_ -match '^\d+$' -or $_ -match '-->') { $_ } else { $_ -replace '\|', 'I' }
      }) -join "`r`n"
      Set-Content -LiteralPath $srt -Value $fixed -Encoding UTF8
      Write-Host ("  repaired {0} pipe->I substitution(s)" -f $pipes)
    }

    # ---- QUALITY GATES. A bad OCR is worse than blocky subtitles, and seconv reports success
    #      even when recognition has completely failed, so the output must be inspected.
    $text  = Get-Content $srt -Raw
    $cues  = [regex]::Matches($text, '(?m)^\d+\s*$').Count
    $lines = @($text -split "`r?`n" | Where-Object { $_ -and $_ -notmatch '^\d+$' -and $_ -notmatch '-->' })

    # Junk = a line that is too short to be dialogue, OR that is mostly not letters. The
    # length-only test misses the worst real-world failure: a track whose images the engine
    # cannot read at all still emits long lines, they are just gibberish -
    #   "= | dea oe ae esa ll"   "2 RES SI ASS SS)"
    # which are 20 characters of nothing. Measure the alphabetic fraction instead.
    $junk = @($lines | Where-Object {
      $t = $_.Trim()
      if ($t.Length -le 2) { return $true }
      $alpha = ($t.ToCharArray() | Where-Object { [char]::IsLetter($_) -or $_ -eq ' ' }).Count
      ($alpha / $t.Length) -lt 0.65
    }).Count
    $junkPct = if ($lines.Count) { [math]::Round(100 * $junk / $lines.Count) } else { 100 }

    # The cue floor has to scale with runtime. A flat "at least 5" is right for a feature but
    # wrong for the short items this pipeline also handles: a 22-second deleted scene genuinely
    # holds one or two lines of dialogue, and failing it means the extra ships with only the
    # blocky bitmap for no reason. Allow roughly one cue per 15 s of runtime, capped at 5, so a
    # feature still has to clear the real bar.
    # A flat floor of 5 is far too lax at the long end: a 51-minute drama came back with EIGHT
    # unreadable cues and passed. Scale both ways - about one cue per 15 s for short clips (so a
    # 22-second deleted scene needs only one), and for anything over 5 minutes require a rate a
    # real dialogue track easily clears (a feature runs 600-1500 cues, so duration/4 is generous).
    $durSec = [double]("$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null)".Trim() -replace '^$','0')
    $durMin = $durSec / 60
    $minCues = if ($durMin -gt 5) { [int][math]::Floor($durMin / 4) }
               else { [math]::Max(1, [math]::Min(5, [int][math]::Floor($durSec / 15))) }

    if ($cues -lt $minCues) { throw "only $cues cues for $([math]::Round($durMin,1)) min (need $minCues) - recognition failed" }
    if ($junkPct -gt 30)    { throw "$junkPct% of cues are 1-2 chars - recognition failed (this is the nOCR signature)" }

    # THE decisive check: does the output contain actual English?
    #
    # Some discs defeat Tesseract while producing output that passes every structural test - the
    # right number of cues, sensible timings, plenty of letters:
    #   "AMIN ~ FED" PGNGR ED PED wD II"        (Legally Blonde, 1103 cues, 5% "junk")
    #   "Wy Wavalhlialaatlatiavattacmetit"      (BBC Shakespeare, 2360 cues, 3% "junk")
    # Counting characters cannot tell that from prose, because it IS mostly letters. Counting
    # WORDS can: real dialogue is saturated with a handful of function words. Measured across 31
    # genuine conversions the rate never fell below 43%; the two failures scored 1% and 0%.
    #
    # Only meaningful for English, so it is skipped for any other -Lang.
    if ($Lang -eq 'eng') {
      $common = '(?i)\b(the|and|you|that|this|with|have|not|for|but|what|are|was|his|her|him|she|they|there|would|your|from|all|been|will|has|had|who|when|were)\b'
      $withWord = @($lines | Where-Object { $_ -match $common }).Count
      $wordPct  = if ($lines.Count) { [math]::Round(100 * $withWord / $lines.Count) } else { 0 }
      if ($wordPct -lt 15) {
        throw "only $wordPct% of lines contain a common English word - output is not English text (genuine conversions score 43-77%)"
      }

      # DICTIONARY GATE. Every gate above this line PASSED the split-letter failure described at
      # Repair-VobSubPalette: Blithe Spirit came back with 1434 cues, 2% "junk" and 60% of lines
      # holding a common English word, because the damage is INSIDE words -
      #   "it's unnecessary to co everything at tite cloulsle."
      #   "try to rememioer to clo it calmly ancl methocically."
      # The function words survive (they are short) and every character is a letter, so counting
      # characters or function words cannot see it. Counting words AGAINST A DICTIONARY can.
      #
      # Only tokens STARTING WITH A LOWERCASE LETTER are scored. Proper nouns are the one large
      # legitimate gap in any word list, and how many a film has is an accident of its script, not
      # a measure of OCR quality: scoring every token rates a correctly converted Ponyo at 92.8%,
      # because it is wall-to-wall Sosuke/Fujimoto/Ohashi, and that is close enough to the failures
      # to be unusable as a bar. Restricting to lowercase-initial words drops proper nouns and
      # all-caps hearing-impaired cues ("PATTERING") and separates the two populations cleanly:
      #   bad   Ponyo 80.1%  Blithe Spirit 87.6%  Hobson's Choice 88.4%
      #         The Sound Barrier 88.9%  Great Expectations 90.1%
      #   good  everything else in a 46-film library >= 96.7% (lowest: King Lear)
      #   after the palette repair: Blithe 98.9%  Great Expectations 99.1%  Ponyo 99.7%
      # 95 sits in the 6.6-point gap. Sentence-initial ordinary words are discarded too, but they
      # are in the dictionary anyway, so nothing is lost but volume.
      #
      # Note this flagged The Sound Barrier, which had not been reported as faulty but carries the
      # same signature ("loucler", "Dackly") - the gate is more sensitive than a viewer skimming
      # Plex.
      #
      # Soft-fails to a warning if the word list cannot be built, since a missing dictionary is a
      # tooling problem and should not throw away an otherwise good conversion.
      $words = Get-EnglishWordSet -ToolsDir $ToolsDir -TessExe $tessExe
      if (-not $words) {
        Write-Warning "  dictionary gate skipped - could not build the word list from eng.traineddata"
      } else {
        $tot = 0; $inDict = 0
        foreach ($l in $lines) {
          foreach ($m in [regex]::Matches($l, "[A-Za-z][A-Za-z']{2,}")) {
            $w = $m.Value.Trim("'")
            if ($w.Length -lt 3) { continue }
            if ($w -cnotmatch '^[a-z]') { continue }   # -cnotmatch: must be CASE-SENSITIVE here
            $tot++
            # "doesn't" is stored as "doesn" in the dawg, so retry on the pre-apostrophe stem.
            $bare = ($w -replace "'.*$", '')
            if ($words.Contains($w) -or $words.Contains($bare)) { $inDict++ }
          }
        }
        $dictPct = if ($tot) { [math]::Round(100 * $inDict / $tot, 1) } else { 0 }
        if ($tot -ge 200 -and $dictPct -lt 95) {
          throw "only $dictPct% of lowercase words are in the English dictionary ($tot words) - letters are being split (good conversions score 97-99%)"
        }
        Write-Host ("  dictionary: {0}% of {1} lowercase words" -f $dictPct, $tot)
      }
    }

    # Matroska is the only container here that takes an SRT track cleanly - mp4 would need
    # mov_text, and rewriting someone's existing mp4 to gain a subtitle is a worse trade than
    # writing a sidecar Plex reads just as happily.
    $effMode = if ($Mode -eq 'Mux' -and $f.Extension -ne '.mkv') {
      Write-Host ("  {0} is {1}, not mkv -> writing a sidecar instead of remuxing" -f $f.Name, $f.Extension)
      'Sidecar'
    } else { $Mode }

    if ($effMode -eq 'Sidecar') {
      $dest = Join-Path $f.DirectoryName ($f.BaseName + ".$Lang.srt")
      Copy-Item $srt $dest -Force
      Write-Host ("  OK {0}  {1} cues, {2}% junk -> sidecar" -f $f.Name, $cues, $junkPct) -ForegroundColor Green
    } else {
      # remux: the SRT default-flagged, bitmap kept as the fallback.
      #
      # `-map 0 -map 1` APPENDS the SRT after every original stream, so in the OUTPUT the new
      # subtitle is the LAST subtitle, not s:0. Addressing it as `-disposition:s:0` therefore
      # tags the original BITMAP track instead - the file mixes fine, ffprobe reports no error,
      # and the only symptom is that Plex still defaults to the blocky bitmap, i.e. exactly the
      # problem this script exists to fix. Count the source's subtitle streams and index off that.
      $nSubs = @($info).Count
      $disp  = @()
      for ($i = 0; $i -lt $nSubs; $i++) { $disp += @("-disposition:s:$i", '0') }   # clear the originals
      $disp += @("-disposition:s:$nSubs", 'default')                                # flag the SRT

      $tmp = Join-Path $work ("mux_" + $f.Name)
      & $ffmpeg -v error -i $f.FullName -i $srt -map 0 -map 1 -c copy `
          -metadata:s:s:$nSubs "language=$Lang" @disp `
          -y $tmp 2>&1 | Out-Null
      if (-not (Test-Path $tmp) -or (Get-Item $tmp).Length -lt (0.9 * $f.Length)) { throw "remux output too small" }

      # Prove the flag landed on the TEXT track. A size check cannot see this, and a mis-flagged
      # file looks completely healthy - it just plays the bitmap.
      $chk = & $ffprobe -v error -select_streams s `
               -show_entries stream=codec_name:stream_disposition=default -of csv=p=0 $tmp 2>$null
      $defText = @($chk | Where-Object { $_ -match '^subrip,1' }).Count
      $defBmp  = @($chk | Where-Object { $p = $_ -split ','; $bitmapCodecs -contains $p[0] -and $p[1] -eq '1' }).Count
      if ($defText -ne 1 -or $defBmp -ne 0) { throw "remux left the wrong subtitle default-flagged ($($chk -join '; '))" }

      Move-Item $tmp $f.FullName -Force
      Write-Host ("  OK {0}  {1} cues, {2}% junk -> muxed" -f $f.Name, $cues, $junkPct) -ForegroundColor Green
    }
    $done++
  }
  catch {
    Write-Warning ("  FAILED {0}: {1}" -f $f.Name, $_.Exception.Message)
    $failed++
  }
  finally {
    Get-ChildItem $work -File -Filter ([IO.Path]::GetFileNameWithoutExtension($stem) + '*') -EA SilentlyContinue |
      Remove-Item -Force -EA SilentlyContinue
  }
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "ocr: $done converted, $skipped skipped, $failed failed"
if ($failed) { exit 1 }
