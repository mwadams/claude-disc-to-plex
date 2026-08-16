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
