<#
  transcode.ps1 — encode a manifest of disc titles to Plex-ready MKVs (H.264 NVENC, CQ20).
  Manifest-driven so it covers episodes, movies, and extras with one code path.

  Usage:
    pwsh -File transcode.ps1 -Manifest items.json [-ToolsDir "D:\video\.transcode-tools"] [-LogDir .]

  Manifest = JSON array. Each item:
    out    (string, required)  full output .mkv path (already Plex-named)
    kind   ("BD"|"DVD"|"MKV")  BD = H.264 m2ts (1080p); DVD = MPEG-2 via dvdvideo demuxer (SD PAL);
                               MKV = a MakeMKV-ripped SD .mkv (same SD treatment as DVD — deinterlace
                               + preserve DAR — but read as a plain file). Use MKV when the dvdvideo
                               demuxer mis-reads a disc (e.g. multi-cell titles it truncates — see
                               gotchas.md); rip the titles with MakeMKV first, then point src at them.
    src    (string, required)  BD: path to .m2ts.  DVD: the DVD ROOT (a decrypted VIDEO_TS
                               parent folder, an ISO, or an optical drive like "F:" — libdvdcss
                               decrypts a live CSS disc automatically).  MKV: path to the .mkv.
    crop   ("auto"|"none"|"W:H:X:Y")
                               BD only. auto = cropdetect voted across 6 sample points (handles
                               pillarboxed 4:3 -> 1440:1080:240:0 AND letterboxed widescreen ->
                               e.g. 1920:816:0:132). Stills/split-screen/full-frame -> "none".
                               Pass an explicit "W:H:X:Y" to override auto. DVD ignores (no crop).
    deinterlace (str, opt.)    DVD/MKV only. Omit to deinterlace (bwdif), which is right for every
                               DVD and every MakeMKV SD rip. "none" for a source that is already
                               progressive — typically a VHS-to-DivX capture deinterlaced at capture
                               time. "mixed" for a capture carrying BOTH field orders and no flags:
                               idet marks each frame and bwdif repairs only the combed ones.
                               State it from a MEASUREMENT, the same way `dar` is stated:
                               `ffmpeg -i SRC -vf idet -frames:v 400 -f null -` AT SEVERAL OFFSETS —
                               one sample over titles or a static scene reads progressive and is how
                               a plainly interlaced episode was nearly shipped un-deinterlaced.
    title  (int)               DVD only, required. DVD title (PGC) number (see identification.md).
    chapterStart / chapterEnd  DVD only, optional. Extract a chapter RANGE = one episode when a
                               title holds several episodes as chapter ranges.
    vts / vobSectors           DVD only, optional, TOGETHER. Read a raw CELL-SECTOR RANGE of a
                               title set instead of going through the dvdvideo demuxer:
                               vts = the title-set number, vobSectors = [first,last] INCLUSIVE
                               2048-byte sectors into the concatenation of VTS_<vts>_1..9.VOB
                               (VTS_<vts>_0.VOB is the MENU domain and is not part of that sector
                               space - see dvd-still-cells.py). For content NAVIGATION HIDES: The
                               Champions D1's alternate ending is cells 14-15 of a 15-cell PGC,
                               the demuxer stops emitting after cell 13 (a cell command ends
                               playback there), and no chapter covers those cells - so no demuxer
                               option can reach them. The range is carved to a temp .vob (per-PID
                               work dir), byte-verified, then RETIMED by retime-vob-cells.py:
                               multi-cell titles restart SCR/PTS/DTS near zero at every cell, and
                               encoding such a carve raw loses frames at every seam (592 frames /
                               23.68 s on The Champions D9 VTS_03, ffmpeg exit 0 - the retimer's
                               per-cell table in the encode log is the audit trail). A carve with
                               no resets passes through byte-identical. `title` is still REQUIRED:
                               audioTracks ordinals on such an item are declared in the DVDVIDEO
                               TITLE'S stream order (= the order the .tracks.json evidence uses)
                               and are translated to the cut's own order via MPEG stream ids -
                               discovery order inside a mid-PGC cut is arbitrary (measured: the
                               tail cut of The Champions D1 finds 0x81 BEFORE 0x80).
    expectSeconds (num, opt.)  Post-encode guard, any kind: the OUTPUT's container duration must
                               be within 2 s of this or the item FAILS and the file is moved
                               aside as *.wrong-length. For titles where a default read path
                               yields the WRONG length (the dvdvideo demuxer DECLARES The
                               Champions D1 t2 as 3049.2s but EMITS 3179.6s; MakeMKV's title is
                               2494s) - a wrong cut otherwise ships looking perfectly normal.
    expectFrames (int, opt.)   Same guard on the OUTPUT's video packet count (tolerance 25 - a
                               cell-seam discontinuity legitimately drops a frame or two).
    subTrack (int|str, opt.)   Which source subtitle to keep. Either a 0-based ordinal, or a
                               LANGUAGE TAG such as "eng" — prefer the tag. Disc subtitle order is
                               arbitrary and often merely alphabetical (dan,eng,fin,nor,swe puts
                               English at 1), so a fixed ordinal silently ships the wrong language
                               on the next disc. Defaults to 0 (fine for a single-PGS Blu-ray).
    commentary (int, optional) 0-based SOURCE audio index to tag as "Audio Commentary".
                               Accepts a list, or [idx,"Title"] pairs to name them.
    audioDescription (int, optional) 0-based SOURCE audio index of a narrated-visuals track for
                               blind viewers. Same shapes as commentary. Tagged "Audio Description"
                               with the `visual_impaired` disposition (VERIFIED - Matroska silently
                               ignores `descriptions`). Without this there is no way to LABEL such a
                               track, and an unlabelled one is a hazard a viewer can select by
                               accident - so they were being dropped.
    audioLangs (array, opt)    ISO-639 codes matching `audioTracks` one-for-one, e.g. ["deu","eng"].
                               Blu-ray m2ts are frequently UNTAGGED, and an untagged stream falls
                               back to 'eng' - so on a foreign-language disc every kept track ends
                               up labelled English unless you say otherwise here (or via origLang,
                               which names the first kept track only).
    origLang (str, optional)   ISO-639 code of the title's ORIGINAL language. Omit or 'eng' for
                               English content -> keep English audio only (drop foreign dubs). For a
                               foreign original (e.g. 'deu' Run Lola Run, 'jpn'): keep the original-
                               language audio as the DEFAULT track, add the English dub as an
                               alternative, and default the English subtitles ON.

  Behaviour baked in (see references/gotchas.md for the why):
    - Audio count de-duped to distinct numeric indices (m2ts double-lists streams).
    - No-audio sources encode video-only (never map a missing 0:a:0).
    - Audio matrix: AAC stereo@160 (default) [+ AAC 5.1@160 if source a:0 is 6ch] + passthru
      of every original track. AAC forced to -ar 48000 (some DVD AC3 don't propagate rate).
    - BD: per-item cropdetect; if PGS subs present AND cropped, reposition with SupMover.
    - DVD: read via `-f dvdvideo -title N [-chapter_start/-chapter_end]`; bwdif deinterlace +
      setsar 16/15 + -aspect 4:3 (anamorphic), stays SD. Reads decrypted folders OR live CSS
      discs (libdvdcss). Native title/chapter selection handles all DVD episode layouts.
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [string]$ToolsDir = "D:\video\.transcode-tools",
  [string]$LogDir = "."
)
$ErrorActionPreference = 'Continue'
$tp = Get-Content (Join-Path $ToolsDir "tool-paths.json") | ConvertFrom-Json
$ff = $tp.ffmpeg; $sm = $tp.supmover
$fp = Join-Path (Split-Path $ff) 'ffprobe.exe'    # our ffprobe (has dvdvideo demuxer + libdvdcss)
# Per-process work dir. Two lanes encoding Blu-rays concurrently both extract PGS subs as
# s<index>.sup / s<index>_fixed.sup; with a SHARED work dir the second lane's extraction deletes
# the first lane's .sup mid-run and ffmpeg dies with "Error opening input file ... _fixed.sup"
# about a second in. Keyed by PID so lanes cannot collide.
$work = Join-Path $ToolsDir ("work\pid$PID"); New-Item -ItemType Directory -Force $work | Out-Null
# A MISSING OR EMPTY MANIFEST MUST NOT REPORT SUCCESS.
#
# This was `$items = Get-Content $Manifest -Raw | ConvertFrom-Json` with nothing checking it. Given
# a path that does not exist, Get-Content raised a NON-TERMINATING error, $items came back empty,
# the encode loop ran zero times, and the script printed "MANIFEST DONE" and exited 0. lane-runner
# treats that as a completed encode and moves the manifest to _queue/done - so a typo in a path
# would silently mark work finished that was never attempted.
#
# Observed 2026-08-23 while testing something else, which is the only reason it was noticed at all.
# Same family as the gate that errored and let a manifest through: a step that cannot fail loudly
# will eventually fail silently.
if(-not (Test-Path -LiteralPath $Manifest)){
  Write-Output "*** MANIFEST NOT FOUND: $Manifest ***"
  exit 2
}
$items = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
if($null -eq $items -or @($items).Count -eq 0){
  Write-Output "*** MANIFEST IS EMPTY OR NOT VALID JSON: $Manifest ***"
  Write-Output "    A manifest with no items is never intentional - refusing rather than reporting DONE."
  exit 2
}

# ---------------------------------------------------------------------------------------------
# PREFLIGHT: a BD item reading a RAW .m2ts is only safe if no playlist extends that stream.
#
# WHY THIS IS ENFORCED IN CODE RATHER THAN WRITTEN DOWN. "Enumerate Blu-rays with MakeMKV, not by
# picking a .m2ts" is in gotchas.md in capitals, and it was still violated hours after being
# written: the Zulu extras were enumerated correctly WITH MakeMKV and then encoded from raw
# streams anyway. Trailer 2 shipped at 1:23 against a true 3:38 because title 1 is a PLAYLIST
# spanning several streams and only the first was read. The same class of error shipped the
# 95-minute cut of The Italian Job when the disc holds 99.5.
#
# A truncated extra looks completely normal - it plays, it has audio, it just stops early - so
# nothing downstream catches it. This check costs one MakeMKV info call per disc and makes the
# rule mechanical instead of remembered.
#
# It ABORTS rather than warns: shipping the wrong length is the expensive outcome, and the fix
# (rip the title with MakeMKV, point src at the .mkv) takes a minute.
# ---------------------------------------------------------------------------------------------
function Preflight-BDStreams($items){
  $makemkv = 'C:\Program Files (x86)\MakeMKV\makemkvcon64.exe'
  if(-not (Test-Path -LiteralPath $makemkv)){ Write-Warning 'MakeMKV not found - skipping raw-m2ts playlist check'; return }

  $raw = @($items | Where-Object { $_.kind -eq 'BD' -and "$($_.src)" -match '\.m2ts$' })
  if(-not $raw){ return }

  # group by disc root (…\<disc>\BDMV\STREAM\x.m2ts -> …\<disc>) so we call MakeMKV once per disc
  $byDisc = $raw | Group-Object { (Split-Path (Split-Path (Split-Path $_.src -Parent) -Parent) -Parent) }
  $problems = @()

  foreach($g in $byDisc){
    $disc = $g.Name
    if(-not (Test-Path -LiteralPath $disc)){ continue }
    $info = & $makemkv -r --cache=1 --minlength=10 info "file:$disc" 2>&1

    # TINFO:<id>,9,0,"H:MM:SS" = runtime, TINFO:<id>,16,0,"<source>" = playlist or stream it came from
    $len = @{}; $srcOf = @{}
    foreach($line in $info){
      if($line -match '^TINFO:(\d+),9,0,"(\d+):(\d\d):(\d\d)"'){
        $len[[int]$Matches[1]] = [int]$Matches[2]*3600 + [int]$Matches[3]*60 + [int]$Matches[4]
      } elseif($line -match '^TINFO:(\d+),16,0,"([^"]+)"'){
        $srcOf[[int]$Matches[1]] = $Matches[2]
      }
    }
    if(-not $len.Count){ Write-Warning "preflight: MakeMKV reported no titles for $disc"; continue }

    foreach($it in $g.Group){
      $stream = Split-Path $it.src -Leaf                     # e.g. 00020.m2ts
      $stem   = [IO.Path]::GetFileNameWithoutExtension($stream)
      $actual = [double](& $fp -v error -show_entries format=duration -of csv=p=0 $it.src 2>$null)
      if(-not $actual){ continue }

      # Titles whose source IS this stream are fine. The danger is a PLAYLIST title that is
      # materially longer than the stream AND actually contains it - that playlist spans clips
      # this item will never read.
      #
      # Containment matters, or the check is useless noise: every extra on a disc is shorter than
      # the FEATURE playlist, so a length-only test flags all of them and gets ignored. A .mpls
      # lists its clips as plain ASCII 5-digit names before "M2TS", so membership reads directly.
      $cands = $len.Keys | Where-Object {
        $s = $srcOf[$_]
        if(-not $s -or $len[$_] -le $actual + 20){ return $false }
        if($s -eq $stream){ return $false }
        if($s -notmatch '\.mpls$'){ return $false }
        $mpls = Join-Path $disc "BDMV\PLAYLIST\$s"
        if(-not (Test-Path -LiteralPath $mpls)){ return $true }   # can't prove it - report it
        $txt = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($mpls))
        $clips = [regex]::Matches($txt,'(\d{5})(?=M2TS)') | ForEach-Object { $_.Groups[1].Value }
        return ($clips -contains $stem)
      }
      foreach($c in $cands){
        $problems += [pscustomobject]@{
          Out = Split-Path $it.out -Leaf; Stream = $stream
          StreamMin = [math]::Round($actual/60,2); TitleId = $c
          TitleMin = [math]::Round($len[$c]/60,2); TitleSrc = $srcOf[$c]
        }
      }
    }
  }

  if($problems){
    Write-Output ''
    Write-Output '*** PREFLIGHT ABORT: raw .m2ts shorter than a playlist title on the same disc ***'
    $problems | Format-Table -AutoSize | Out-String | Write-Output
    Write-Output 'A playlist spans multiple streams; encoding the raw .m2ts ships a TRUNCATED file.'
    Write-Output 'Fix: rip the title with MakeMKV, then point src at the resulting .mkv (kind stays "BD"):'
    Write-Output '  makemkvcon64.exe -r --cache=1 --minlength=10 --noscan mkv "file:<disc>" <titleId> <outdir>'
    Write-Output 'If the longer playlist is genuinely unrelated, set "allowRawStream": true on that item.'
    exit 2
  }
}
if(-not ($items | Where-Object { $_.allowRawStream -eq $true })){ Preflight-BDStreams $items }

# ---------------------------------------------------------------------------------------------
# PREFLIGHT: enough free space to hold what this manifest will WRITE.
#
# The rip track has been space-gated since it filled the disk once; the ENCODE track never was.
# So a manifest could be claimed with 18 GB free, write a 14 GB feature, and run the volume to
# zero mid-encode. ffmpeg does not fail cleanly out of space - it leaves a SHORT, UNFINALISED
# mkv, and this pipeline's whole failure signature is a plausible-looking file that passes
# structural checks. A truncated feature with a correct name is the most expensive thing we ship.
#
# Estimate from the SOURCE size rather than a fixed floor: a 200 MB gallery extra must not be
# blocked by a floor sized for a feature. NVENC at CQ20 has never exceeded ~0.75x its source on
# this library (Metropolis: 34.4 GB source -> 17.7 GB output, 0.51x), so 0.75x plus a 6 GB working
# margin is comfortably conservative without being superstitious.
#
# Skipped items cost nothing - `out` already exists is how this batch resumes - so only count
# what will actually be written.
$pending = @($items | Where-Object { -not (Test-Path -LiteralPath $_.out) -or
                                     (Get-Item -LiteralPath $_.out -EA SilentlyContinue).Length -lt 5MB })
if($pending.Count){
  # COUNT EACH DISTINCT SOURCE ONCE, NOT ONCE PER ITEM.
  #
  # The estimate asks "how many bytes will this manifest WRITE" and derives it from source size,
  # because an output has never exceeded ~0.75x its source. That reasoning holds PER SOURCE - but
  # several items routinely share one `src`: every title of a DVD names the same VIDEO_TS folder,
  # and a BD chapter-range split names the same .m2ts. Summing per ITEM counts the same bytes once
  # per item, and the outputs of N titles of one disc still only add up to that one disc.
  #
  # Mugaritz Experiences, 2026-08-31: 61 titles of one 6.19 GB DVD, encoded as 61 parts to be
  # appended into a single 61-chapter film. The guard demanded 289.4 GB (61 x 6.19 x 0.75 + 6)
  # against 115 GB free and sent the manifest to _queue\failed before writing any per-item log -
  # which reads like a broken manifest, not a mis-scaled check. Counting each distinct src once
  # asks for 10.6 GB, which is the honest figure.
  #
  # This can only LOWER the estimate where sources repeat; where every src is distinct - the common
  # case, and every manifest shipped so far - the figure is unchanged.
  $needBytes = 0
  foreach($sp in (@($pending | ForEach-Object { "$($_.src)" }) | Sort-Object -Unique)){
    if(Test-Path -LiteralPath $sp -PathType Leaf){ $needBytes += (Get-Item -LiteralPath $sp).Length }
    elseif(Test-Path -LiteralPath $sp){
      $needBytes += (Get-ChildItem -LiteralPath $sp -Recurse -File -EA SilentlyContinue |
                     Measure-Object -Property Length -Sum).Sum
    }
  }
  $needGB = [math]::Round(($needBytes * 0.75) / 1GB, 1) + 6
  $outDrive = ([IO.Path]::GetPathRoot($pending[0].out)).Substring(0,1)
  $freeGB = [math]::Round([IO.DriveInfo]::new($outDrive).AvailableFreeSpace / 1GB, 1)
  if($freeGB -lt $needGB){
    Write-Output '*** PREFLIGHT ABORT: not enough free space for this manifest ***'
    Write-Output ("  {0}: {1} GB free, need ~{2} GB for {3} pending item(s)" -f $outDrive, $freeGB, $needGB, $pending.Count)
    Write-Output '  Release staging for a unit whose outputs are byte-verified on the NAS, or'
    Write-Output '  wait for a publish to complete. Do NOT encode into the last few GB - ffmpeg'
    Write-Output '  leaves a truncated, unfinalised mkv that looks finished.'
    exit 2
  }
  Write-Output ("space preflight OK - {0} GB free, ~{1} GB needed for {2} pending item(s)" -f $freeGB, $needGB, $pending.Count)
}

# PREFLIGHT: kind "BD" on a STANDARD-DEFINITION source.
#
# "BD" means HD: no deinterlace, and the crop filter is configured for an HD frame. Point it at a
# 720x480 / 720x576 source and cropdetect returns a crop the BD path cannot configure -
# "Failed to configure input pad on Parsed_crop_0" - and the item fails after ~2 seconds having
# written a ZERO-BYTE output. The failure names the crop filter, so it reads like a crop bug; the
# actual fault is one word in the manifest.
#
# This is easy to get wrong because a disc mixes resolutions freely: Goldfinger's extras are seven
# HD titles and three NTSC SD ones, and To Kill a Mockingbird's are six SD and one HD. On
# 2026-08-21 the same mistake was made twice within an hour - once per disc - because the ONLY
# signal was a crop error two stages downstream.
#
# SD sources want kind "MKV", which applies the SD deinterlace path and preserves the source DAR.
$sdKind = @()
foreach($it in $items){
  if("$($it.kind)" -ne 'BD'){ continue }
  $sp = "$($it.src)"
  if(-not (Test-Path -LiteralPath $sp)){ continue }
  $wh = (& $fp -v error -select_streams v:0 -show_entries stream=width,height -of csv=p=0 $sp) -split ','
  if($wh.Count -lt 2){ continue }
  $w = [int]$wh[0]; $h = [int]$wh[1]
  if($w -le 720 -and $h -le 576){
    $sdKind += [pscustomobject]@{ Out = Split-Path $it.out -Leaf; Src = Split-Path $sp -Leaf; Res = "${w}x${h}" }
  }
}
if($sdKind){
  Write-Output ''
  Write-Output '*** PREFLIGHT ABORT: kind "BD" on a standard-definition source ***'
  $sdKind | Format-Table -AutoSize | Out-String | Write-Output
  Write-Output 'The BD path applies no deinterlace and configures crop for an HD frame; on an SD source'
  Write-Output 'it fails with "Failed to configure input pad on Parsed_crop_0" and writes a 0-byte file.'
  Write-Output 'Fix: set "kind": "MKV" for these items (SD deinterlace + source DAR preserved).'
  exit 2
}

# ---------------------------------------------------------------------------------------------
# PREFLIGHT: an SD source whose DECLARED aspect is neither 4:3 nor 16:9.
#
# Get-DAR preserves whatever the source declares, which is correct - until the source declares
# nothing. A MakeMKV rip of an SD extra often carries sample_aspect_ratio 1:1, so the computed
# display aspect is simply width/height: 720x480 -> 3:2. Encoding that faithfully ships a
# horizontally STRETCHED picture, and nothing downstream notices, because the file is valid,
# the duration is right and the checksum matches. The user spotted it by eye on 2026-08-24.
#
# 4:3 IS NOT ASSUMED. On the very disc that exposed this, SIX of the seven SD extras declared a
# proper NTSC anamorphic 109:90 (DAR ~1.82, i.e. 16:9) and only ONE was broken - so silently
# forcing 4:3 would have squashed six correct files. This project has hard-coded 4:3 before and
# paid for it.
#
# So: refuse, name the items, and require the author to LOOK at a frame and state `dar`.
# Real SD material is 4:3 (1.333) or 16:9 (1.778); anything else is a missing flag, not a format.
$badDar = @()
foreach($it in $items){
  if("$($it.kind)" -notin @('DVD','MKV')){ continue }
  # NOT `Has $it 'dar'` - this preflight runs at line ~284 and Has is not defined until ~316.
  # PowerShell resolves functions at CALL time, so the call threw and every item fell through the
  # `continue`, making the guard fire even on items that DID declare an aspect. The other
  # preflights use direct property access for the same reason.
  if($it.PSObject.Properties.Name -contains 'dar' -and "$($it.dar)" -ne ''){ continue }
  $sp = "$($it.src)"
  if(-not (Test-Path -LiteralPath $sp -PathType Leaf)){ continue }   # DVD folders: read via the demuxer elsewhere
  $g = (& $fp -v error -select_streams v:0 -show_entries stream=width,height,display_aspect_ratio -of csv=p=0 $sp 2>$null) -split ','
  if($g.Count -lt 3){ continue }
  $w=[int]$g[0]; $h=[int]$g[1]; $darTxt="$($g[2])".Trim()
  if($h -gt 576){ continue }                        # HD: the BD path handles it
  $parts = $darTxt -split ':'
  if($parts.Count -ne 2 -or [double]$parts[1] -eq 0){ continue }
  $ratio = [double]$parts[0] / [double]$parts[1]
  $is43  = [Math]::Abs($ratio - (4.0/3.0)) -le 0.05
  $is169 = [Math]::Abs($ratio - (16.0/9.0)) -le 0.06
  if(-not ($is43 -or $is169)){
    $badDar += [pscustomobject]@{ Out=Split-Path $it.out -Leaf; Res="${w}x${h}"; Declared=$darTxt; Ratio=[Math]::Round($ratio,3) }
  }
}
if($badDar){
  Write-Output ''
  Write-Output '*** PREFLIGHT ABORT: SD source declares an aspect that is neither 4:3 nor 16:9 ***'
  $badDar | Format-Table -AutoSize | Out-String | Write-Output
  Write-Output 'That is a MISSING aspect flag, not a real format - the rip carries sample_aspect_ratio 1:1'
  Write-Output 'so the DAR is just width/height. Encoding it ships a stretched picture that passes every'
  Write-Output 'other check: valid file, correct duration, matching bytes.'
  Write-Output ''
  Write-Output 'LOOK AT A FRAME, then state the aspect explicitly on those items, e.g. "dar": "4:3":'
  Write-Output '  ffmpeg -ss 380 -i "<src>" -vf "yadif,scale=640:480" -frames:v 1 f43.png   # 4:3'
  Write-Output '  ffmpeg -ss 380 -i "<src>" -vf "yadif,scale=854:480" -frames:v 1 f169.png  # 16:9'
  Write-Output 'Faces are the giveaway. Do NOT assume 4:3 - on Back to the Future six of seven SD extras'
  Write-Output 'were genuinely 16:9 and only one was broken.'
  exit 2
}

function Has($o,$n){ $o.PSObject.Properties.Name -contains $n -and $null -ne $o.$n -and "$($o.$n)" -ne '' }
function Finalised-Output($path){
  # Is this output a FINALISED container? A finished Matroska reports a duration; one whose encode
  # died mid-write reports N/A. SIZE IS NOT A PROXY FOR SUCCESS IN EITHER DIRECTION, and the old
  # "-gt 1MB" success floor was wrong both ways at once: a 37 s video-only stills extra encodes to
  # 959 KB, so a PERFECT four-item manifest was filed under _queue\failed (danger-man-s1d6,
  # 2026-09-02) - while a LARGE unfinalised file from a killed encode would have passed the same
  # floor and been reported OK, which is the dangerous direction. Judge by what the container says
  # about itself, plus ffmpeg's own exit code at the call site.
  if(-not (Test-Path -LiteralPath $path)){ return $false }
  if((Get-Item -LiteralPath $path).Length -le 0){ return $false }
  $d = "$(& $fp -v error -show_entries format=duration -of csv=p=0 $path 2>$null)".Trim()
  $dv = 0.0; [void][double]::TryParse($d, [ref]$dv)
  return ($dv -gt 0)
}
function Extract-VobSectors($it,[string]$dest){
  # Carve an INCLUSIVE 2048-byte-sector range out of a VTS's TITLE-domain VOB set.
  # Sector 0 is the first sector of VTS_<vts>_1.VOB; the numbered VOBs concatenate into one
  # sector space. VTS_<vts>_0.VOB is the MENU domain and is deliberately NOT included - counting
  # it shifts every offset by the whole menu VOB and yields plausible garbage (dvd-still-cells.py
  # documents the same trap). Returns $true only when the byte count written equals the byte
  # count the range demands - a short carve decodes to a plausible-looking truncated clip, which
  # is this pipeline's characteristic failure, so it is never returned as success.
  $vts   = [int]$it.vts
  $first = [long](@($it.vobSectors)[0]); $last = [long](@($it.vobSectors)[1])
  if($last -lt $first -or $first -lt 0){ throw "vobSectors [$first,$last] is not a valid range" }
  $vtDir = Join-Path "$($it.src)" 'VIDEO_TS'
  if(-not (Test-Path -LiteralPath $vtDir)){ throw "no VIDEO_TS under $($it.src)" }
  $parts = @()
  foreach($n in 1..9){
    $p = Join-Path $vtDir ('VTS_{0:D2}_{1}.VOB' -f $vts, $n)
    if(Test-Path -LiteralPath $p){ $parts += Get-Item -LiteralPath $p }
  }
  if(-not $parts.Count){ throw ('no VTS_{0:D2}_n.VOB under {1}' -f $vts, $vtDir) }
  $want = ($last - $first + 1) * 2048
  $startByte = $first * 2048
  $outFs = [IO.File]::Create($dest)
  try {
    $buf = New-Object byte[] 4194304
    $pos = [long]0; $remaining = [long]$want
    foreach($f in $parts){
      $fileStart = $pos; $pos = $pos + $f.Length
      if($pos -le $startByte -or $remaining -le 0){ continue }
      $fs = [IO.File]::OpenRead($f.FullName)
      try {
        $fs.Position = [Math]::Max([long]0, $startByte - $fileStart)
        while($remaining -gt 0){
          $got = $fs.Read($buf, 0, [int][Math]::Min([long]$buf.Length, $remaining))
          if($got -le 0){ break }
          $outFs.Write($buf, 0, $got); $remaining -= $got
        }
      } finally { $fs.Close() }
    }
  } finally { $outFs.Close() }
  return ((Get-Item -LiteralPath $dest).Length -eq $want)
}
function InSpec($it,[switch]$Hwaccel){   # ffmpeg/ffprobe input args (demuxer + -i) for this item
  # -hwaccel cuda decodes on the GPU and hands frames back in system memory, so the crop/bwdif
  # filters and PGS handling are unaffected. NOT applied to ffprobe calls (probing is cheap) and
  # NOT to DVD (SD MPEG-2 decodes fast; the win is on HD sources, above all VC-1, whose ffmpeg
  # decoder has no frame-level threading and pegs a single core).
  $hw = if($Hwaccel -and $it.kind -ne 'DVD'){ @('-hwaccel','cuda') } else { @() }
  if($it.kind -eq 'DVD'){
    # A raw cell-range cut (vobSectors) was already carved to a plain MPEG-PS file in the work
    # dir - read that. The mpeg demuxer flags TS_DISCONT, so ffmpeg rebases the timestamp reset
    # at a cell seam instead of mangling it (measured: cells 14-15 of The Champions D1 encode to
    # a continuous 147.92 s).
    if(Has $it '_cutFile'){ return @('-i',$it._cutFile) }
    $s = @('-f','dvdvideo','-title',[string]$it.title)
    # A DVD still-set (gallery, biography, infopod page) is a chain of ~0.40 s padding cells, and
    # the demuxer REFUSES such a title outright without this - "looks empty (may consist of padding
    # cells)... disable the -trim option". So `-trim false` is required to open one at all.
    #
    # IT IS NOT SUFFICIENT, and do not assume it is. MEASURED on Farscape's Peacekeeper Wars extras
    # disc (2026-08-30): with the flag, titles 10, 12 and 13 each yield exactly ONE frame, 0.04 s -
    # the first-cell truncation this project already documents for this demuxer. MakeMKV is no help
    # either; it skips them as sub-floor (MSG:3025). Getting the whole chain needs the cell range
    # decoded out of the menu-domain VOBs. See follow-up.md.
    #
    # Scoped to `stillsHold` on purpose: `-trim false` on an ordinary title would admit padding the
    # demuxer is right to drop. If a previously-shipped gallery is ever re-encoded, compare its
    # still count against the original before replacing it.
    if($it.stillsHold){ $s += @('-trim','false') }
    if(Has $it 'chapterStart'){ $s += @('-chapter_start',[string]$it.chapterStart) }
    if(Has $it 'chapterEnd'){   $s += @('-chapter_end',  [string]$it.chapterEnd) }
    return ($s + @('-i',$it.src))
  }
  # Seamless-branching Blu-rays hold no single feature stream: the film is 20+ short m2ts clips
  # assembled by a .mpls playlist (the biggest STREAM file may be only ~15 min of a 2 hr film).
  # Point src at a concat-demuxer list (a .txt of "file '...'" lines, in playlist order) and the
  # whole feature is read as one input WITHOUT building a 25 GB+ intermediate copy on disk.
  if($it.src -match '\.txt$'){ return ($hw + @('-f','concat','-safe','0','-i',$it.src)) }
  return ($hw + @('-i',$it.src))
}
function Audio-Count($inspec){ ((& $fp -v error @inspec -select_streams a -show_entries stream=index -of csv=p=0 2>$null) | Where-Object { $_ -match '^\d+$' } | Sort-Object -Unique | Measure-Object).Count }
function Audio-Ch0($inspec,$idx){ $c=(& $fp -v error @inspec -select_streams "a:$idx" -show_entries stream=channels -of csv=p=0 2>$null | Select-Object -First 1); if($c){[int]$c}else{0} }
function Audio-Codec($inspec,$idx){ "$(& $fp -v error @inspec -select_streams "a:$idx" -show_entries stream=codec_name -of csv=p=0 2>$null | Select-Object -First 1)" }
function Audio-Lang($inspec,$idx){
  # Source language tag of one audio ordinal. Untagged/unknown -> 'eng' (English-original discs often
  # leave the tag empty). NEVER hard-code eng here: on a foreign original (dan/deu/jpn) that would
  # mislabel the original-language track as English in Plex.
  $l = "$(& $fp -v error @inspec -select_streams "a:$idx" -show_entries stream_tags=language -of csv=p=0 2>$null | Select-Object -First 1)".Trim()
  if(-not $l -or $l -in @('und','')){ 'eng' } else { $l }
}
function Keep-AudioIdx($inspec,$na,$origLang){
  # Which audio ordinals to keep, and in what order (first = default track).
  #  - English-original content (origLang eng/unset): keep English (+ commentary/untagged) only; drop foreign DUBS.
  #  - Foreign-original content (origLang e.g. deu/jpn): keep the ORIGINAL-language audio FIRST (becomes default)
  #    then the English dub as an alternative. English subtitles are defaulted on by the caller.
  if($na -le 0){ return @() }        # no audio (e.g. a stills gallery) -> map none (0..-1 would wrongly yield 0,-1)
  if($na -eq 1){ return @(0) }
  $langs = @(& $fp -v error @inspec -select_streams a -show_entries stream_tags=language -of csv=p=0 2>$null)
  if($langs.Count -gt $na){ $langs = $langs[0..($na-1)] }   # m2ts double-lists; first $na are the streams in order
  $eng = @('eng','en','und','')
  if($origLang -and $origLang -notin @('eng','en')){
    $fore=@(); $en=@()
    for($i=0;$i -lt $na;$i++){ if($langs[$i] -eq $origLang){ $fore+=$i } elseif($langs[$i] -in $eng){ $en+=$i } }
    $keep = @($fore + $en)
  } else {
    $keep=@(); for($i=0;$i -lt $na;$i++){ if($langs[$i] -in $eng){ $keep+=$i } }
  }
  if($keep.Count -eq 0){ return @(0..($na-1)) }   # nothing matched -> keep all rather than drop everything
  return $keep
}
function Sub-Count($inspec){ ((& $fp -v error @inspec -select_streams s -show_entries stream=index -of csv=p=0 2>$null) | Where-Object { $_ -match '^\d+$' } | Sort-Object -Unique | Measure-Object).Count }
function Sub-IdxByLang($inspec,$lang){
  # Resolve a subtitle ORDINAL from its language tag. Subtitle order on a disc means nothing —
  # it is often just alphabetical (dan,eng,fin,nor,swe puts English at 1, not 0), so a
  # hard-coded index silently ships the wrong language. Returns $null if the tag isn't present.
  # The @() must wrap the WHOLE pipeline, not just the ffprobe call. A pipeline emitting ONE item
  # collapses to a bare string, and indexing a string returns a CHARACTER: with a single subtitle
  # stream, $langs became "eng" and $langs[0] was 'e', which never equals 'eng'. So this returned
  # $null for every source carrying exactly one subtitle track - Peaky Blinders, Coco Chanel - and
  # nobody noticed, because the old behaviour then fell back to s:0, which in that exact case is
  # the right stream anyway. It only surfaced once the fallback became an abort.
  $langs = @(@(& $fp -v error @inspec -select_streams s -show_entries stream_tags=language -of csv=p=0 2>$null) |
             ForEach-Object { "$_".Trim() })
  for($i=0; $i -lt $langs.Count; $i++){ if($langs[$i] -eq $lang){ return $i } }
  return $null
}
function Get-DAR($inspec){   # source display aspect ("16:9"/"4:3"); preserve it, never force
  $d="$(& $fp -v error @inspec -select_streams v:0 -show_entries stream=display_aspect_ratio -of csv=p=0 2>$null | Select-Object -First 1)"
  if($d -match '(\d+):(\d+)' -and "$($Matches[1]):$($Matches[2])" -ne '0:1'){ "$($Matches[1]):$($Matches[2])" } else { '4:3' }
}
function Get-Crop($src){
  $dur=[double](& $fp -v error -show_entries format=duration -of csv=p=0 $src 2>$null)
  if(-not $dur -or $dur -lt 1){ return '1440:1080:240:0' }
  # Vote across several sample points and take the MODE, not the largest area.
  # A single dark/close-up scene yields a bogus tight crop; only the true frame
  # recurs across the whole film, so frequency is far more robust than area.
  $crops=@{}
  foreach($fr in 0.15,0.3,0.45,0.6,0.75,0.9){
    $o=& $ff -hide_banner -ss ([int]($dur*$fr)) -i $src -vf "cropdetect=limit=24:round=2" -frames:v 150 -an -f null NUL 2>&1 |
       Select-String -Pattern 'crop=(\d+):(\d+):(\d+):(\d+)' -AllMatches
    foreach($m in $o.Matches){ $crops[$m.Value] = 1 + $(if($crops.ContainsKey($m.Value)){$crops[$m.Value]}else{0}) }
  }
  $best=$null;$bn=0
  foreach($k in $crops.Keys){ if($crops[$k] -gt $bn){ $bn=$crops[$k]; $best=$k } }
  if(-not $best){ return '1440:1080:240:0' }
  $best -match 'crop=(\d+):(\d+):(\d+):(\d+)'|Out-Null
  $w=[int]$Matches[1];$h=[int]$Matches[2];$x=[int]$Matches[3];$y=[int]$Matches[4]
  # Accept EITHER a pillarboxed 4:3 (full height, bars at the sides) OR a
  # letterboxed widescreen frame (full width, bars top/bottom). Anything that is
  # inset on both axes is a scene artefact, not the frame — fall back to 4:3.
  $fullW = ($w -ge 1900); $fullH = ($h -ge 1060)
  if(-not ($fullW -or $fullH)){ return '1440:1080:240:0' }
  if($w -lt 1280 -or $w -gt 1920 -or $h -lt 600 -or $h -gt 1080){ return '1440:1080:240:0' }
  if($x%2){$x--}; if($y%2){$y--}
  "$w`:$h`:$x`:$y"
}

$i=0
$failCount=0
foreach($it in $items){
  $i++
  Write-Output ("[{0}/{1}] {2}  ({3})" -f $i,$items.Count,(Split-Path $it.out -Leaf),$it.kind)
  New-Item -ItemType Directory -Force (Split-Path $it.out) | Out-Null
  # RESUME ONLY ON A FINALISED FILE. "exists and over 5 MB" is not "finished".
  #
  # An encode that dies part-way - a killed process, a crash, a reboot, a full volume - leaves a
  # large mkv with NO duration in its header. Skipping on size alone then treats that truncated
  # file as complete: it is never re-encoded, and publish-work.ps1 is the only thing standing
  # between it and the NAS. On 2026-08-24 a 158 MB unfinalised "Michael J. Fox Interview.mkv"
  # was produced exactly this way and would have been skipped as done on the next pass.
  #
  # A finalised Matroska reports a duration; a truncated one reports N/A. That is the check.
  # (Same defect, same fix, as _rip-loop.ps1's "a file existing is not a completed rip".)
  #
  # ANY non-empty existing output gets the duration probe - there is no size floor here. The old
  # "-gt 5MB" pre-filter meant a small-but-finalised output (a sub-minute video-only extra can be
  # under 1 MB) fell through to a pointless re-encode on every requeue. The probe is the check;
  # size is not evidence in either direction (danger-man-s1d6, 2026-09-02).
  if((Test-Path $it.out) -and ((Get-Item $it.out).Length -gt 0)){
    $od = "$(& $fp -v error -show_entries format=duration -of csv=p=0 $it.out 2>$null)".Trim()
    $odv = 0.0; [void][double]::TryParse($od, [ref]$odv)
    if($odv -gt 0){ Write-Output "   skip (exists)"; continue }
    Write-Output "   existing output is UNFINALISED (no duration) - re-encoding it"
    Remove-Item -LiteralPath $it.out -Force -ErrorAction SilentlyContinue
  }

  # --- DVD raw cell-range cut (vts + vobSectors) ----------------------------------------------
  # Carve the stated sector range to a temp .vob, then TRANSLATE the manifest's audio ordinals.
  # The manifest (and the .tracks.json evidence it was gated against) speaks in the DVDVIDEO
  # TITLE'S stream order; a mid-PGC cut discovers streams in an arbitrary order (the tail cut of
  # The Champions D1 finds 0x81 before 0x80), so ordinals are resolved via MPEG stream ids -
  # measured on both ends, never assumed. Any id the cut does not carry is a hard per-item FAIL:
  # falling back to "whatever a:N is" ships the wrong audio with a correct label.
  if($it.kind -eq 'DVD' -and (Has $it 'vobSectors')){
    if(-not (Has $it 'vts') -or -not (Has $it 'title') -or @($it.vobSectors).Count -ne 2){
      Write-Output '   !! FAILED - vobSectors requires vts, title and a [firstSector,lastSector] pair'
      $failCount++; continue
    }
    $cut = Join-Path $work ("cut$i.vob")
    $cutOk = $false
    try { $cutOk = Extract-VobSectors $it $cut }
    catch { Write-Output "   !! FAILED - vobSectors carve: $_" }
    if(-not $cutOk){
      if(Test-Path -LiteralPath $cut){ Write-Output '   !! FAILED - carve wrote a SHORT range (would encode a plausible truncated clip)' }
      $failCount++; continue
    }
    Write-Output ('   vobSectors {0}..{1} of VTS_{2:D2} -> {3:N0} bytes carved and byte-verified' -f `
      [long](@($it.vobSectors)[0]), [long](@($it.vobSectors)[1]), [int]$it.vts, (Get-Item -LiteralPath $cut).Length)
    # RETIME THE CARVE - per-cell timestamp resets are rewritten into one continuous timeline
    # BEFORE anything reads the cut. A multi-cell VOB restarts SCR/PTS/DTS near zero at every
    # cell, and ffmpeg's TS_DISCONT rebase (one shared offset per input) loses a frame or two at
    # every seam - and fails CATASTROPHICALLY when a stream is absent from one cell: The Champions
    # D9 VTS_03 has no 0x80 audio in cell 17, the offset flapped between the audio and video
    # resets, and 592 frames (23.68 s) were dropped with ffmpeg exit 0 - only the expectFrames
    # guard caught it. retime-vob-cells.py fixes this deterministically from the video DTS chain
    # (within-cell A/V timing untouched; a stream missing from a cell becomes a true gap, not a
    # desync) and is a byte-identical no-op on a carve with no resets. Its per-cell table is the
    # audit trail, so it is logged in full.
    $retimed = Join-Path $work ("cut$i-retimed.vob")
    $rtOut = & python (Join-Path $PSScriptRoot 'retime-vob-cells.py') $cut $retimed 2>&1
    $rtExit = $LASTEXITCODE        # captured BEFORE any pipeline can dilute it - never read an exit code through a pipe
    $rtOut | ForEach-Object { Write-Output "   $_" }
    if($rtExit -ne 0 -or -not (Test-Path -LiteralPath $retimed) -or `
       (Get-Item -LiteralPath $retimed).Length -ne (Get-Item -LiteralPath $cut).Length){
      Write-Output '   !! FAILED - retime-vob-cells refused the carve (see its report above); never encoding an unretimed multi-cell cut'
      $failCount++; continue
    }
    $cut = $retimed
    if((Has $it 'audioTracks') -and @($it.audioTracks).Count -gt 0){
      $titleIds = @(& $fp -v error -f dvdvideo -title ([string]$it.title) -select_streams a -show_entries stream=id -of csv=p=0 "$($it.src)" 2>$null | ForEach-Object { "$_".Trim().TrimEnd(',') } | Where-Object { $_ -match '^0x' })
      $cutIds   = @(& $fp -v error -select_streams a -show_entries stream=id -of csv=p=0 $cut 2>$null | ForEach-Object { "$_".Trim().TrimEnd(',') } | Where-Object { $_ -match '^0x' })
      $mapTC = @{}; $mapBad = $null
      foreach($t in @($it.audioTracks | ForEach-Object { [int]$_ })){
        if($t -ge $titleIds.Count){ $mapBad = "a:$t is not a stream of dvdvideo title $($it.title) (it has $($titleIds.Count) audio streams)"; break }
        $id = $titleIds[$t]; $c = [array]::IndexOf($cutIds, $id)
        if($c -lt 0){ $mapBad = "stream $id (title a:$t) is not present in the carved range - the cut cannot ship it"; break }
        $mapTC[$t] = $c
        Write-Output ("   audio title a:{0} ({1}) -> cut a:{2}" -f $t, $id, $c)
      }
      if(-not $mapBad){
        foreach($fld in 'commentary','audioDescription'){
          if(-not (Has $it $fld)){ continue }
          $new = @()
          foreach($e in @($it.$fld)){
            if($e -is [array]){ $e2 = @($e); $ix = [int]$e2[0] } else { $ix = [int]$e }
            if(-not $mapTC.ContainsKey($ix)){ $mapBad = "$fld a:$ix is not among the kept audioTracks, so it cannot be translated"; break }
            if($e -is [array]){ $e2[0] = $mapTC[$ix]; $new += ,$e2 } else { $new += $mapTC[$ix] }
          }
          if($mapBad){ break }
          $it.$fld = $new
        }
      }
      if($mapBad){
        Write-Output "   !! FAILED - vobSectors audio translation: $mapBad"
        $failCount++; continue
      }
      $it.audioTracks = @($it.audioTracks | ForEach-Object { $mapTC[[int]$_] })
    }
    $it | Add-Member -NotePropertyName '_cutFile' -NotePropertyValue $cut -Force
  }

  $inspec = InSpec $it                       # probes: software decode, they only read headers
  $encspec = InSpec $it -Hwaccel             # the encode: GPU decode where the source allows it
  $usedHwaccel = ($encspec -contains '-hwaccel')
  $na = Audio-Count $inspec
  $origLang = if(Has $it 'origLang'){ "$($it.origLang)" } else { 'eng' }   # ISO-639 of the ORIGINAL language; eng/unset = English content
  # audioTracks overrides the automatic pick: an explicit list of audio ordinals to keep, in order
  # (first = default). Needed on Blu-ray m2ts, which frequently carry NO language tags at all — the
  # automatic pick treats untagged as English, so every French/Spanish dub would be kept, and a
  # 5.1 LPCM dub gets FLAC-encoded into the output. Read the real languages from the PLAYLIST
  # .mpls (the m2ts has none) and list only the ones you want.
  # `audioTracks: []` means KEEP NO AUDIO, and it has to be tested BEFORE Has(): Has stringifies
  # the value and rejects '', so an empty array reads as "field absent" and silently falls through
  # to the automatic pick - the opposite of what it says.
  #
  # That is not a theoretical difference. The Saint D8's dvdvideo title 7 (7:22 of mute newsreel
  # rushes) DECLARES one AC-3 stream and ships ZERO packets in it. Written as `audioTracks: []`
  # and run through the old path, the auto-picker kept that stream anyway and the extra shipped
  # with two audio tracks - an AAC downmix and the AC-3 passthru - each containing no packets at
  # all. Every structural check passes: the file plays, the duration is exact to the frame, the
  # size is plausible. A viewer just finds two audio tracks that are silent.
  $audioNone = ($it.PSObject.Properties.Name -contains 'audioTracks') -and
               ($null -ne $it.audioTracks) -and (@($it.audioTracks).Count -eq 0)
  if($audioNone){
    $keep = @()
    Write-Output "   audioTracks [] -> keeping NO audio (explicit)"
  } elseif(Has $it 'audioTracks'){
    $keep = @($it.audioTracks | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 0 -and $_ -lt $na })
    Write-Output "   audioTracks explicit -> a:$($keep -join ' a:')"
  } else {
    $keep = @(Keep-AudioIdx $inspec $na $origLang)   # audio ordinals to keep (foreign original first, then English)
  }
  $nk = $keep.Count
  $ch0 = if($nk -gt 0){ Audio-Ch0 $inspec $keep[0] } else { 0 }
  $ns = Sub-Count $inspec
  # subTrack accepts an ordinal (0-based), a language tag ("eng"), or "none". The tag is safer than
  # an ordinal: disc subtitle order is arbitrary, so an ordinal right on one disc is wrong on the
  # next.
  #
  # "none" exists because a tag is NOT proof either. Blu-ray extras are frequently authored with
  # subtitles for the FOREIGN releases only - an English-language featurette needs none - and the
  # streams on a raw .m2ts are usually UNTAGGED, so every one of them answers to "eng". Fantasia's
  # extras carry exactly five, matching the disc's five non-English languages; "eng" selected the
  # Spanish one, and the tagging below then relabelled it English. The result plays as an English
  # subtitle track that is not English, and nothing downstream can tell.
  #
  # So when the source has no English subtitle, say so explicitly rather than accepting whatever
  # s:0 happens to be.
  # OMITTING subTrack IS NOT A SAFE DEFAULT - it used to mean "keep s:0", which is the SAME hazard
  # the abort below exists to prevent, reached by the one route that did not check. The tagging
  # step near the end of this file stamps `language=eng` on whichever stream is kept, unconditionally.
  #
  # Band of Brothers disc 6 (2026-08-19): fourteen SD extras whose sources carry spa+por subtitles
  # and NO English. The manifest simply left subTrack out, so s:0 - Spanish - was kept and relabelled
  # English on all fourteen. Nothing in the encode log said so; it was caught only because
  # publish-work.ps1 refuses a bitmap track with no sidecar, i.e. by luck of a different guard.
  #
  # So an absent subTrack now means exactly `subTrack: 'eng'`: resolve by TAG, and abort rather than
  # guess. A source with no subtitle streams at all still passes straight through.
  $subIdx  = 0
  $subSpec = if(Has $it 'subTrack'){ "$($it.subTrack)" } else { 'eng' }
  $subDflt = if(Has $it 'subTrack'){ '' } else { " (defaulted - manifest omits subTrack)" }
  if($subSpec -eq 'none'){
      $ns = 0
      Write-Output "   subTrack 'none' -> no subtitle track kept (source carries no English subs)"
    }
    elseif($subSpec -match '^\d+$'){ $subIdx = [int]$subSpec }
    elseif($ns -gt 0){
      $byLang = Sub-IdxByLang $inspec $subSpec
      if($null -ne $byLang){ $subIdx = $byLang; Write-Output "   subTrack '$subSpec'$subDflt -> s:$subIdx" }
      else {
        # ABORT, do not fall back to s:0.
        #
        # Falling back is how a disc that tags NOTHING gets whatever stream happens to be first.
        # Cloud Atlas's featurettes carry seven untagged PGS streams - ja, en, fr, es, fr, es, ja -
        # so "eng" resolved to nothing, s:0 was Japanese, and the tagging below stamped
        # language=eng on it. It reached the NAS. The old behaviour DID say so, on a WARNING line,
        # which lane-runner.ps1's output filter drops - so in practice the fallback was silent.
        #
        # There is no safe default here. Either the caller knows which stream is English (pass the
        # ORDINAL, established by rendering the streams and reading them) or the source has no
        # English subtitles (pass "none"). Guessing is what this whole file exists to prevent.
        Write-Output "   ABORT: no '$subSpec' subtitle on this source and $ns subtitle stream(s) present.$subDflt"
        Write-Output "          Refusing to fall back to s:0 - that ships an unknown language tagged as 'eng'."
        Write-Output "          Fix the manifest: use an explicit 0-based ordinal, or subTrack:'none' if the source has no English subs."
        # COUNT THE SKIP AS A FAILURE. Without this the manifest exits 0 and lane-runner files it
        # under done\ with an item never encoded - "MANIFEST DONE with failed items" through the one
        # path the exit-code fix at the bottom of this file did not cover. The ABORT line above is
        # only as durable as whatever captures stdout; the exit code is what actually routes.
        $failCount++
        continue
      }
    }

  $a = @('-y','-hide_banner','-v','error','-stats')
  # A RETIMED CARVE'S TIMESTAMPS ARE TRUSTWORTHY - TELL FFMPEG SO. mpegps is a TS_DISCONT format,
  # so ffmpeg's input handler rebases the whole input's shared ts_offset whenever ANY stream's DTS
  # jumps more than dts_delta_threshold (default 10 s) - in EITHER direction. After retiming, the
  # only jumps left are REAL: a stream absent from a cell resumes with a forward gap (The Champions
  # D9 VTS_03: audio 0x80 has no cell-17 packets, so it re-enters at +59.44 s). Default handling
  # read that as a discontinuity, rebased the input by -59.4 s, then the OTHER audio stream's next
  # packet read as a -59.4 s jump and rebased it back - the offset flapped on alternating packets
  # and vsync dropped 565 video frames (22.6 s) with exit 0. Measured 2026-09-03 via -v info:
  # "timestamp discontinuity ... new offset" pairs alternating for the whole tail. With the
  # threshold at 3600 s the same command emits all 26,215 frames, zero drops, zero rebase messages.
  # Scoped to the retimed cut ONLY: every other input keeps the default heuristic, which is right
  # for sources whose timestamps genuinely do reset (that is what the retimer exists to remove).
  if($it.kind -eq 'DVD' -and (Has $it '_cutFile')){ $a += @('-dts_delta_threshold','3600') }
  $a += $encspec

  # --- timestamp origin ---------------------------------------------------------------------
  # A Blu-ray .m2ts does not have to start at PTS 0. The Ipcress File begins at 11.650667, and
  # its first subtitle packet sits at 41.03 absolute - i.e. 29.4 s into the picture.
  #
  # Left alone, ffmpeg rebases the VIDEO by the container start time (-11.65) but the SUBTITLE
  # stream by its own first packet (-41.03). The two shifts differ, so the subtitles land ~29 s
  # EARLY. Nothing in the log hints at it, durations are exact, and the OCR pass then inherits
  # the same error - both the PGS and the SRT are wrong by an identical amount, which makes it
  # look like a disc-authoring quirk rather than something we did.
  #
  # There are two routes a subtitle can take out of here and they need DIFFERENT fixes:
  #
  #   direct   (no crop)  the PGS is mapped straight from input 0  -> -copyts -start_at_zero
  #   via .sup (cropped)  it is extracted, repositioned, remuxed   -> -itsoffset on input 1
  #
  # -start_at_zero cannot serve both: applied globally it also rebases the .sup input back to
  # zero, silently undoing itself. That is what made a first attempt at this fix appear to work
  # on an uncropped test and fail on every real (cropped) Blu-ray.
  #
  # $subRel is where the first cue genuinely belongs, measured once from the source: the first
  # subtitle packet's PTS minus the container start. For Run Lola Run that is
  # 31.754078 - 11.650667 = 20.103 s.
  $subRel = 0.0
  if($it.kind -eq 'BD' -and $ns -gt 0){
    $st0 = [double]("$(& $fp -v error @inspec -show_entries format=start_time -of csv=p=0 2>$null)".Trim() -replace '^$','0')
    $fp0 = "$(& $fp -v error @inspec -select_streams "s:$subIdx" -show_entries packet=pts_time -of csv=p=0 -read_intervals '%+180' 2>$null | Select-Object -First 1)".Trim().TrimEnd(',')
    if($fp0 -and $fp0 -ne 'N/A'){ $subRel = [math]::Round([double]$fp0 - $st0, 3) }
    if($subRel -lt 0){ $subRel = 0.0 }
    if($st0 -gt 0.5){ Write-Output ("   source starts at {0}s; first subtitle belongs at {1}s" -f [math]::Round($st0,3), $subRel) }
  }

  # --- video filter + optional PGS subtitle repositioning (BD crop) ---
  $subInput = $null; $crop = $null

  # STILLS GALLERY: re-time, do not copy.
  #
  # A Blu-ray gallery is a handful of full-resolution frames that the PLAYER holds on screen for
  # several seconds each. The video stream is therefore a fraction of the playlist's duration -
  # Back to the Future t13 is 26 frames spanning 1.08 seconds against a declared 125s. Encoded
  # as-is it ships an "extra" that flashes past in a second and looks broken.
  #
  # `declared duration / frame count` recovers the author's display time exactly. Measured across
  # that disc's five galleries: 4.8, 4.9, 4.9, 4.9, 4.9 seconds per still. Set `stillsHold` to it;
  # _rip-loop.ps1 prints the value when it identifies a gallery.
  #
  #   setpts=N*HOLD/TB   spaces every frame HOLD seconds apart
  #   fps=<rate>         fills the gaps so the result is a normal CFR video Plex can seek
  #
  # Applied INSTEAD of crop/deinterlace: a gallery is progressive full-frame artwork, and
  # cropdetect on a black-bordered still would eat the picture.
  #
  # ALSO COVERS A SINGLE STILL HELD UNDER AUDIO, not just an N-frame gallery. Middlemarch Disk 1
  # dvdvideo title 5 ("The Music of Middlemarch") is ONE video packet against 1759.01 s of 5.1
  # audio - a still card under a 29:20 score suite. `stillsHold` handles it: with one input frame
  # the setpts gives that frame a HOLD-second duration and `fps` fills the whole span, so
  # stillsHold = the AUDIO length yields a full-length video. The default read path yields 0.04 s,
  # a file that passes every size check and looks merely small.
  #
  # THE RATE WAS HARD-CODED 24 AND THAT IS WRONG FOR PAL. Every DVD in this library is 25 fps;
  # a 24 fps still item would be the only file in the show at another rate, and with audio present
  # the nominal rate is no longer cosmetic. So derive it from the SOURCE - which is a measurement,
  # not a guess - and let `stillsFps` state it explicitly when the source cannot say.
  #
  # The derived value is CLAMPED to 10-60 fps and falls back to 24. A degenerate still stream can
  # report a nonsense r_frame_rate (a handful of frames 0.04 s apart inside a 125 s playlist can
  # probe as 90000/1); accepting that unchecked would emit millions of frames and fill the disk,
  # which is a far worse failure than the wrong nominal rate it is trying to fix.
  if($it.stillsHold){
    $hold = [double]$it.stillsHold
    if($hold -le 0){ throw "stillsHold must be > 0 on $($it.out)" }
    $sfps = $null
    if(Has $it 'stillsFps'){
      $sfps = "$($it.stillsFps)"
      Write-Output "   stills frame rate $sfps (explicit)"
    } else {
      $rfr = "$(& $fp -v error @inspec -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 2>$null | Select-Object -First 1)".Trim().TrimEnd(',')
      if($rfr -match '^(\d+)/(\d+)$' -and [int]$Matches[2] -gt 0){
        $rv = [double]$Matches[1] / [double]$Matches[2]
        if($rv -ge 10 -and $rv -le 60){ $sfps = $rfr }
      }
      if($sfps){ Write-Output "   stills frame rate $sfps (from source)" }
      else { $sfps = '24'; Write-Output "   stills frame rate 24 (source reported '$rfr', outside 10-60fps - falling back)" }
    }
    $vf = "setpts=N*$hold/TB,fps=$sfps"
    Write-Output ("   STILLS GALLERY - holding each frame {0:N1}s (setpts+fps)" -f $hold)
  }
  if(-not $it.stillsHold){
  if($it.kind -in @('DVD','MKV')){
    # SD source (DVD demuxer OR an already-demuxed SD file): deinterlace only; aspect set via
    # -aspect below (preserve source DAR).
    #
    # `deinterlace: "none"` EXISTS FOR SOURCES THAT ARE ALREADY PROGRESSIVE. A DVD is interlaced
    # PAL and always wants bwdif, which is why this was unconditional - but `kind: "MKV"` also
    # takes VHS-to-DivX captures and other demuxed files, and those are routinely deinterlaced
    # ALREADY, by the capture card, years ago. Running bwdif over progressive frames interpolates
    # fields that are not there and softens real detail, silently: the encode succeeds and looks
    # plausible, which is this pipeline's characteristic failure.
    #
    # Same precedent as `dar` directly below - the author states it per item from a MEASUREMENT
    # (`ffmpeg -vf idet`), not from taste. Omitted means deinterlace, so every existing manifest
    # behaves exactly as before.
    # `deinterlace: "mixed"` IS FOR A CAPTURE THAT CARRIES BOTH FIELD ORDERS AND NO FLAGS.
    #
    # Some VHS-to-DivX captures contain combed frames in BOTH parities in one file, with
    # `field_order=unknown` and every frame flagged progressive - the encoder recorded nothing, so
    # the combing is simply baked into the pixels. Measured on IMITATION_GAME.avi: 80 BFF at one
    # offset, 77 TFF at another, progressive dominant throughout.
    #
    # Neither plain answer is right there. Unconditional bwdif assumes TFF, so it repairs the TFF
    # frames and MANGLES the BFF ones; skipping it leaves visible combing on a quarter of the
    # frames. `idet` analyses each frame and sets the interlaced/parity flags the file lacks, and
    # `bwdif=deint=interlaced` then touches ONLY the frames idet marked, at the parity it found -
    # so genuinely progressive frames pass through untouched.
    $di = if(Has $it 'deinterlace'){ "$($it.deinterlace)".Trim().ToLower() } else { 'yes' }
    if($di -notin @('yes','none','mixed')){
      throw "deinterlace must be 'none', 'mixed' or omitted, got '$di'"
    }
    # NOTE the shape: an `if` block ASSIGNED to a variable emits everything the block writes, so a
    # Write-Output inside it lands in $vf as an array element and would be passed to ffmpeg as a
    # filter. Log outside the assignment.
    if($di -eq 'none'){
      $vf = $null
      Write-Output '   deinterlace=none (source stated progressive in the manifest)'
    } elseif($di -eq 'mixed'){
      $vf = 'idet,bwdif=mode=send_frame:deint=interlaced'
      Write-Output '   deinterlace=mixed (idet flags each frame; bwdif touches only the combed ones)'
    } else {
      $vf = 'bwdif=mode=send_frame'
    }
    # SAY SO WHEN A CROP IS SET AND IGNORED.
    #
    # `crop` is documented "BD only" and this branch never reads it - so an author who sets it on a
    # DVD item gets no filter, no error and no line in the log saying why. Documented-but-silent is
    # how a field becomes believed: on As You Like It (2006), a 16:9 picture letterboxed inside a
    # 4:3 PAL frame, cropdetect was effectively unanimous and an explicit crop would simply have
    # vanished. Better to name it than to leave the author checking the output and guessing.
    if($it.crop -and "$($it.crop)" -ne 'none'){
      Write-Output ("   NOTE: crop='{0}' IGNORED - kind '{1}' takes the deinterlace-only path (crop is BD only)" -f $it.crop, $it.kind)
    }
  }
  else {
    if($it.crop -eq 'auto'){ $crop = Get-Crop $it.src; $vf = "crop=$crop"; Write-Output "   crop=$crop (auto)" }
    elseif("$($it.crop)" -match '^\d+:\d+:\d+:\d+$'){ $crop = "$($it.crop)"; $vf = "crop=$crop"; Write-Output "   crop=$crop (explicit)" }
    else { $vf = $null; Write-Output "   crop=none" }
    # "BD" used to mean "HD, therefore progressive, therefore no deinterlace". That holds for
    # features and not for BONUS material: Bond disc extras are routinely authored 1080i29.97 from
    # interlaced video masters, and they shipped combed because nothing looked. Decide from the
    # SOURCE's field order rather than from `kind`, which is a naming convention, not a measurement.
    # Set "deinterlace": false on an item to override (e.g. a source mistagged interlaced).
    $wantDi = $true
    if($null -ne $it.deinterlace){ $wantDi = [bool]$it.deinterlace }
    if($wantDi){
      $fo = "$(& $fp -v error @inspec -select_streams v:0 -show_entries stream=field_order -of csv=p=0 2>$null | Select-Object -First 1)".Trim()
      if($fo -and $fo -notin @('progressive','unknown','')){
        $vf = if($vf){ "bwdif=mode=send_frame,$vf" } else { 'bwdif=mode=send_frame' }
        Write-Output "   source is INTERLACED (field_order=$fo) -> bwdif"
      }
    }
    # The -color_* options further down are OUTPUT options: when the source declares different (or
    # UNKNOWN) colour properties, ffmpeg silently inserts a full software colour conversion and every
    # 1080p frame goes through swscale on the CPU. Measured on a VC-1 Blu-ray whose tags are all
    # "unknown": 49s -> 397s for the same 3-minute clip, an 8x penalty that dwarfs anything decode
    # or the encoder cost. VC-1 discs (Sherlock Holmes, Superman Returns) are routinely untagged,
    # which is why they crawled while properly-tagged H.264 discs did not.
    # setparams TAGS the frames instead of converting them, so the output options then match and no
    # scaler is inserted. HD Blu-ray is bt709 by definition, so tagging is correct, not a guess.
    $srcCol = "$(& $fp -v error @inspec -select_streams v:0 -show_entries stream=color_space -of csv=p=0 2>$null | Select-Object -First 1)".Trim()
    if($srcCol -in @('','unknown','reserved')){
      $sp = 'setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709:range=tv'
      $vf = if($vf){ "$sp,$vf" } else { $sp }
      Write-Output "   source colour tags missing -> setparams (avoids an 8x swscale conversion)"
    }
    if($ns -gt 0 -and $crop){
      $crop -match '(\d+):(\d+):(\d+):(\d+)'|Out-Null
      $L=[int]$Matches[3]; $T=[int]$Matches[4]; $R=(1920-[int]$Matches[1]-[int]$Matches[3]); $B=(1080-[int]$Matches[2]-[int]$Matches[4])
      # A full-frame crop (1920:1080:0:0 — cropdetect found nothing to remove) moves no subtitle:
      # SupMover writes NO output file for an all-zero crop, and passing the missing path to ffmpeg
      # kills the encode instantly with "Error opening input file ..._fixed.sup". Skip the whole
      # repositioning step in that case and let the PGS stream copy through untouched.
      if($L -eq 0 -and $T -eq 0 -and $R -eq 0 -and $B -eq 0){
        Write-Output "   crop is full-frame; PGS repositioning not needed"
      } else {
        $sup="$work\s$i.sup"; $supf="$work\s${i}_fixed.sup"
        # Extract zero-based deliberately: a .sup carries no absolute origin, so whatever base it
        # has is discarded when ffmpeg reads it back. $subRel below is the single source of truth
        # for where these cues belong.
        & $ff -y -hide_banner -v error @inspec -map "0:s:$subIdx" -c copy $sup 2>&1 | Out-Null
        if((Test-Path $sup) -and ((Get-Item $sup).Length -gt 1KB)){
          & $sm $sup $supf --crop $L $T $R $B 2>&1 | Out-Null
          # Never hand ffmpeg a path SupMover did not actually write.
          if((Test-Path $supf) -and ((Get-Item $supf).Length -gt 1KB)){ $subInput = $supf }
          else { Write-Output "   !! SupMover produced no output; keeping original PGS" }
        }
      }
    }
  }
  if($subInput){
    # ffmpeg discards the .sup's own base on read, so put the cues back where they belong.
    if($subRel -gt 0){ $a += @('-itsoffset',[string]$subRel) }
    $a += @('-i',$subInput)
  } elseif($ns -gt 0 -and $subRel -gt 0) {
    # direct-map path: rebase every stream from the container origin instead of per-stream
    $a += @('-copyts','-start_at_zero')
  }

  }   # end: not a stills gallery - the ffmpeg ARG ASSEMBLY below runs for both paths

  # --- stream maps ---
  $a += @('-map','0:v:0')
  $aacIdx = 0
  if($nk -gt 0){
    if($ch0 -ge 6){ $a += @('-map',"0:a:$($keep[0])") }
    $a += @('-map',"0:a:$($keep[0])")
    foreach($k in $keep){ $a += @('-map',"0:a:$k") }
  }
  if($ns -gt 0){ if($subInput){ $a += @('-map','1:0') } else { $a += @('-map',"0:s:$subIdx") } }

  # --- video codec ---
  if($vf){ $a += @('-vf',$vf) }
  $a += @('-c:v','h264_nvenc','-preset','medium','-rc','vbr','-cq','20','-b:v','0','-pix_fmt','yuv420p')
  # `dar` OVERRIDES THE SOURCE'S DECLARED ASPECT - because the source can be wrong.
  #
  # Get-DAR preserves what the source declares, which is right when the source declares anything
  # meaningful. A MakeMKV rip of an SD extra often does NOT: Back to the Future's 720x480 extras
  # come back sample_aspect_ratio 1:1, so the computed DAR is 720/480 = 3:2, and encoding that
  # faithfully ships a horizontally STRETCHED picture. Verified by eye against a talking-head
  # frame - at 4:3 the face is correctly proportioned, at 3:2 it is visibly wide.
  #
  # 4:3 is NOT assumed here: this project has SD extras that are genuinely 16:9, and hard-coding
  # 4:3 has caused its own damage. The manifest author states `dar` per item, from LOOKING at a
  # frame. Absent the field, behaviour is unchanged.
  if($it.kind -in @('DVD','MKV')){
    $dar = if(Has $it 'dar'){ "$($it.dar)" } else { Get-DAR $inspec }
    if(Has $it 'dar'){ Write-Output "   DAR $dar (explicit; source declares $(Get-DAR $inspec))" }
    $a += @('-aspect',$dar)
  } else { $a += @('-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-color_range','tv') }

  # --- audio codecs ---
  # Audio-Lang reads the SOURCE tag and falls back to 'eng' when a stream is untagged. Blu-ray
  # m2ts are routinely untagged, so on a FOREIGN-language disc every kept track came out labelled
  # English - Run Lola Run shipped with the German audio as the default track marked "English",
  # which is exactly as wrong as picking the wrong track, just harder to spot.
  #
  # `audioTracks` already says WHICH streams to keep and in what order; `audioLangs` (optional,
  # same length) says what they ARE. Failing that, `origLang` names the first kept track, which is
  # the documented meaning of putting it first. Anything still unknown keeps the source tag.
  $langOf = {
    param($j)
    if((Has $it 'audioLangs') -and $j -lt @($it.audioLangs).Count){ "$(@($it.audioLangs)[$j])" }
    elseif($j -eq 0 -and $origLang -and $origLang -notin @('eng','en')){ $origLang }
    else { Audio-Lang $inspec $keep[$j] }
  }
  # language of the FIRST kept track = what the AAC downmix is made from. Not evaluated when no
  # track is kept: $langOf would index an empty $keep to read a tag that is about to go unused.
  $lang0 = if($nk -gt 0){ & $langOf 0 } else { 'eng' }
  if($nk -gt 0){
    if($ch0 -ge 6){
      $a += @("-c:a:$aacIdx",'aac',"-b:a:$aacIdx",'160k',"-ac:a:$aacIdx",'6',"-ar:a:$aacIdx",'48000',"-metadata:s:a:$aacIdx",'title=Surround 5.1 (AAC)',"-metadata:s:a:$aacIdx","language=$lang0","-disposition:a:$aacIdx",'default'); $aacIdx++
      # `-disposition 0` IS REQUIRED, NOT REDUNDANT. ffmpeg carries the INPUT stream's disposition
      # onto its output even when re-encoding, so this stereo downmix silently inherits `default`
      # whenever the source track had it - which every MakeMKV rip does. See the block comment on
      # the passthru loop below; this is the same defect on the encoded track.
      $a += @("-c:a:$aacIdx",'aac',"-b:a:$aacIdx",'160k',"-ac:a:$aacIdx",'2',"-ar:a:$aacIdx",'48000',"-metadata:s:a:$aacIdx",'title=Stereo (AAC)',"-metadata:s:a:$aacIdx","language=$lang0","-disposition:a:$aacIdx",'0'); $aacIdx++
    } else {
      $a += @("-c:a:$aacIdx",'aac',"-b:a:$aacIdx",'160k',"-ac:a:$aacIdx",'2',"-ar:a:$aacIdx",'48000',"-metadata:s:a:$aacIdx",'title=Stereo (AAC)',"-metadata:s:a:$aacIdx","language=$lang0","-disposition:a:$aacIdx",'default'); $aacIdx++
    }
    for($j=0;$j -lt $nk;$j++){
      $oi = $aacIdx + $j
      # passthru the original track bit-for-bit — EXCEPT Blu-ray/DVD LPCM, which Matroska can't store via -c copy
      # ("No wav codec tag for pcm_bluray"); re-encode those to FLAC (lossless, MKV-native) instead.
      if((Audio-Codec $inspec $keep[$j]) -match '^pcm'){ $a += @("-c:a:$oi",'flac') } else { $a += @("-c:a:$oi",'copy') }
      $a += @("-metadata:s:a:$oi","language=$(& $langOf $j)")
      # CLEAR THE INHERITED `default` FLAG. ffmpeg copies the INPUT stream's disposition to the
      # output, and MakeMKV flags EVERY audio track it writes as `default` - so every kind:"MKV"
      # encode shipped with all of its audio streams flagged default, while kind:"DVD" encodes came
      # out correct because the dvdvideo demuxer sets no disposition at all. Verified 2026-09-01 by
      # probing both source types side by side, not inferred from the outputs.
      #
      # What it cost: 658 published files of 5161 scanned - all of them TV, none of the films -
      # including whole runs of The Newsroom, Spartacus, Thriller, Band of Brothers and Rome. With
      # every stream flagged default, which track a client selects is UNDEFINED: it may land on the
      # AC3 passthru instead of the AAC compatibility track, or on a commentary. Nothing errors,
      # nothing looks wrong in a file listing, and any player that happens to pick first-match
      # behaves perfectly - which is why it survived so long. Found by an independent validation
      # pass over one disc, never by a gate.
      #
      # Emitted BEFORE the commentary / audio-description blocks below on purpose: ffmpeg takes the
      # LAST -disposition for a stream, so those correctly override this to `comment` /
      # `visual_impaired`. The AAC track built above carries the only `default`.
      $a += @("-disposition:a:$oi",'0')
      # commentary accepts a single ordinal OR a list - discs often carry two or three separate
      # commentaries (Life of Brian has two), and tagging only the first leaves the rest looking
      # like alternate language mixes in Plex. A list may also be [idx,"Title"] pairs to name them.
      if(Has $it 'commentary'){
        $cm = @($it.commentary)
        for($ci=0; $ci -lt $cm.Count; $ci++){
          $entry = $cm[$ci]
          $cidx = $null; $ctitle = 'Audio Commentary'
          if($entry -is [array]){ $cidx = [int]$entry[0]; if($entry.Count -gt 1){ $ctitle = "$($entry[1])" } }
          else { $cidx = [int]$entry; if($cm.Count -gt 1){ $ctitle = "Audio Commentary $($ci+1)" } }
          if($cidx -eq $keep[$j]){ $a += @("-disposition:a:$oi",'comment',"-metadata:s:a:$oi","title=$ctitle") }
        }
      }
      # AUDIO DESCRIPTION - narrated visuals for blind viewers. Accepts the same shapes as
      # `commentary`: an ordinal, a list of ordinals, or [idx,"Title"] pairs.
      #
      # It needs its own field because it is neither a commentary nor an alternate mix, and until
      # this existed there was NO way to label one. Skyfall's Blu-ray carries an English AC3 5.1 AD
      # track alongside the feature mix, identified by transcription ("Q reaches into his pocket and
      # takes out an envelope. He hands it to Bond."). With no label it would have reached Plex as a
      # second unnamed "Surround 5.1" that a viewer could select by accident - the same hazard as an
      # unlabelled commentary - so it was being DROPPED instead. Now it can be kept and named.
      #
      # The disposition is `visual_impaired`, and that was VERIFIED, not assumed. The obvious
      # candidate, `descriptions`, is an MP4/QuickTime flag: the Matroska muxer accepts the option,
      # writes NOTHING, and reports no error - ffprobe comes back `descriptions=0` on the output.
      # A silently-ignored flag is exactly the kind of thing that ships looking correct, so the
      # three candidates were muxed into test files and read back:
      #   visual_impaired -> DISPOSITION:visual_impaired=1   <- persists, and is the Matroska flag
      #   descriptions    -> all flags 0                     <- silently dropped
      #   comment         -> DISPOSITION:comment=1           <- wrong meaning; that is a commentary
      if(Has $it 'audioDescription'){
        $ad = @($it.audioDescription)
        for($di=0; $di -lt $ad.Count; $di++){
          $entry = $ad[$di]
          $didx = $null; $dtitle = 'Audio Description'
          if($entry -is [array]){ $didx = [int]$entry[0]; if($entry.Count -gt 1){ $dtitle = "$($entry[1])" } }
          else { $didx = [int]$entry; if($ad.Count -gt 1){ $dtitle = "Audio Description $($di+1)" } }
          if($didx -eq $keep[$j]){ $a += @("-disposition:a:$oi",'visual_impaired',"-metadata:s:a:$oi","title=$dtitle") }
        }
      }
    }
  }
  if($ns -gt 0){ $a += @('-c:s','copy','-metadata:s:s:0','language=eng'); if($origLang -and $origLang -notin @('eng','en')){ $a += @('-disposition:s:0','default') } }  # default English subs ON for foreign originals
  # FORCE THE MUXER TO INTERLEAVE ON A LONG `stillsHold` - the output is otherwise unseekable.
  #
  # With ONE input frame the setpts+fps chain emits NOTHING until the demuxer hits EOF, then floods
  # out every generated frame at once. The audio, meanwhile, decodes and encodes in seconds. The
  # muxer takes what it has: MEASURED on Middlemarch S00E03 (2026-09-03, 29:20 still + 5.1 suite),
  # all 43,975 video packets landed in the LAST 20 MB of a 189 MB file, behind every audio packet -
  # video t=0 at byte 169,727,762, audio t=0 at byte 71,394,398.
  #
  # That file plays from the start and probes perfectly: right duration, right packet counts, right
  # geometry, ffmpeg exit 0. It only fails when you SEEK - `ffmpeg -ss 880` returned an EMPTY wav,
  # zero samples, because the seek lands on a video keyframe past all the audio. Every gate in this
  # pipeline passes it; a viewer scrubbing 30 seconds in gets silence. Characteristic failure shape.
  #
  # `-max_interleave_delta 0` makes the muxer buffer until every stream has data instead of flushing
  # audio ahead of absent video. Cost is memory (~550 MB peak here, holding the encoded audio) and
  # nothing is written until the video starts, so the output stays 0 bytes for the first minute -
  # that is expected on this path, not a stall. After the fix, byte position tracks time on both
  # streams and the same seeks return full audio.
  #
  # Scoped to stillsHold: an ordinary encode produces video and audio in step and needs no buffering.
  if($it.stillsHold){ $a += @('-max_interleave_delta','0') }
  $a += @('-max_muxing_queue_size','1024',$it.out)

  if($env:TRANSCODE_DEBUG){ Write-Output ("   CMD: " + ($a -join ' ')) }
  $t0=Get-Date; & $ff @a; $ffExit=$LASTEXITCODE; $secs=[int]((Get-Date)-$t0).TotalSeconds
  # NVENC does the encoding, so a slow item is almost always DECODE-bound (measured on a VC-1
  # Blu-ray: software decode 1.62x realtime, adding the encode cost only 8% more -- the encoder
  # idles waiting for frames). $hwaccel puts the decode on the GPU too. It can fail on odd
  # profiles/codecs, so on failure retry once with software decode before reporting a problem.
  if(($ffExit -ne 0) -or -not (Finalised-Output $it.out)){
    if($usedHwaccel){
      Write-Output "   hwaccel decode failed; retrying with software decode"
      Remove-Item $it.out -Force -ErrorAction SilentlyContinue
      $a = @($a | Where-Object { $_ -ne '-hwaccel' -and $_ -ne 'cuda' })
      $t0=Get-Date; & $ff @a; $ffExit=$LASTEXITCODE; $secs=[int]((Get-Date)-$t0).TotalSeconds
    }
  }
  # Success = ffmpeg said it succeeded AND the container is finalised. See Finalised-Output for why
  # a byte-size floor is wrong in both directions (danger-man-s1d6, 2026-09-02).
  $itemOk = ($ffExit -eq 0) -and (Finalised-Output $it.out)
  # expectSeconds / expectFrames: length verification for items where a DEFAULT read path yields
  # the WRONG length while everything else looks normal - exit 0, finalised container, plausible
  # size. The Champions D1 t2 is the founding case: the dvdvideo demuxer declares 3049.2 s, MakeMKV
  # enumerates 2494 s, and the true published cut is 3179.6 s; a wrong cut here differs by MINUTES,
  # so the 2 s / 25-frame tolerances are generous to seam effects and hostile to every known
  # failure mode. The wrong-length file is MOVED ASIDE, not left in place - a finalised output at
  # `out` is what the resume check trusts, so leaving it would make the failure permanent.
  if($itemOk -and (Has $it 'expectSeconds')){
    $gd = 0.0; [void][double]::TryParse("$(& $fp -v error -show_entries format=duration -of csv=p=0 $it.out 2>$null)".Trim().TrimEnd(','), [ref]$gd)
    if([Math]::Abs($gd - [double]$it.expectSeconds) -gt 2.0){
      Write-Output ("   !! WRONG LENGTH - output is {0:N2}s, manifest expects {1:N2}s; moved aside as .wrong-length" -f $gd, [double]$it.expectSeconds)
      Move-Item -LiteralPath $it.out -Destination "$($it.out).wrong-length" -Force
      $itemOk = $false
    }
  }
  if($itemOk -and (Has $it 'expectFrames')){
    $gfTxt = "$(& $fp -v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets -of csv=p=0 $it.out 2>$null)".Trim().TrimEnd(',')
    $gf = 0; [void][int]::TryParse($gfTxt, [ref]$gf)
    if([Math]::Abs($gf - [int]$it.expectFrames) -gt 25){
      Write-Output ("   !! WRONG LENGTH - output has {0:N0} video frames, manifest expects {1:N0}; moved aside as .wrong-length" -f $gf, [int]$it.expectFrames)
      Move-Item -LiteralPath $it.out -Destination "$($it.out).wrong-length" -Force
      $itemOk = $false
    }
  }
  if($itemOk){ Write-Output ("   OK {0:N2}GB in {1}s" -f ((Get-Item -LiteralPath $it.out).Length/1GB),$secs) }
  else { Write-Output "   !! FAILED ($secs s, ffmpeg exit $ffExit)"; $failCount++ }
  Remove-Item "$work\s$i.sup","$work\s${i}_fixed.sup","$work\cut$i.vob" -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------------------------
# POSTFLIGHT: report untitled and DUPLICATE audio tracks.
#
# WHY. Zulu shipped three audio tracks where the disc has two: a:0 and a:1 were the same dialogue
# mix twice over, and a:2 - the commentary - carried no title at all. Nothing in the container
# revealed it; it surfaced only by transcribing the audio. A sweep then found untitled tracks on
# NINE of eleven films in the batch (King Lear had four tracks all carrying the same dialogue).
#
# The cause is structural, not careless: discs ship one mix in several formats (5.1 / stereo /
# TrueHD), we transcode them all to AAC - which makes them genuinely redundant - and the one
# track that IS different, the commentary, ends up unlabelled among them. In Plex that means a
# viewer picking "English" at random may land on a commentary.
#
# This only REPORTS. Which duplicate to keep, and what a commentary should be called, needs a
# human or a transcript (scripts/identify-audio.py); silently dropping tracks is how content gets
# lost. Fixing is a lossless remux - no re-encode - so acting on this is cheap.
# ---------------------------------------------------------------------------------------------
$audioFlags = @()
foreach($it in $items){
  if(-not (Test-Path -LiteralPath $it.out)){ continue }
  $rows = @(& $fp -v error -select_streams a -show_entries 'stream=index:stream_tags=title' -of csv=p=0 $it.out 2>$null)
  if($rows.Count -lt 2){ continue }

  $untitled = @()
  for($k=0; $k -lt $rows.Count; $k++){
    $title = ($rows[$k] -split ',',2)[1]
    if(-not $title){ $untitled += "a:$k" }
  }

  # Cheap duplicate detection: mean volume + peak over the same 30 s window. Two encodes of the
  # SAME mix agree to ~0.1 dB; a commentary or a dub does not. This is a prompt to check, never
  # proof - identical figures on genuinely different tracks are possible, so verify before acting.
  $sigs = @()
  for($k=0; $k -lt $rows.Count; $k++){
    # A track shorter than the sample window, or one volumedetect can't read, yields no match -
    # index into a null Matches and the whole postflight dies AFTER a successful encode, which
    # reads as a failed manifest. Never let a report break the run that produced it.
    #
    # `-v info` is REQUIRED, not incidental: volumedetect prints its summary at info level, so the
    # habitual `-v error` silently yields NOTHING and every track reads as unmeasurable. The first
    # version of this guard had exactly that bug - it ran clean, reported no duplicates, and could
    # never have reported any. `-nostats` keeps the per-second progress spam out of the capture.
    $vol  = & $ff -hide_banner -nostats -v info -ss 600 -t 30 -i $it.out -map "0:a:$k" -af volumedetect -f null - 2>&1
    $mm   = $vol | Select-String 'mean_volume: (-?[\d.]+)' | Select-Object -First 1
    $pm   = $vol | Select-String 'max_volume: (-?[\d.]+)'  | Select-Object -First 1
    if(-not $mm -or -not $pm){ $sigs += "unknown-$k"; continue }   # unique: never counts as a dupe
    $sigs += "$($mm.Matches[0].Groups[1].Value)/$($pm.Matches[0].Groups[1].Value)"
  }
  $dupes = @($sigs | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Group[0] })

  if($untitled -or $dupes){
    $audioFlags += [pscustomobject]@{
      File = Split-Path $it.out -Leaf; Tracks = $rows.Count
      Untitled = ($untitled -join ' '); DuplicateSig = ($dupes -join ' ')
    }
  }
}
if($audioFlags){
  Write-Output ''
  Write-Output '*** AUDIO REVIEW NEEDED (untitled and/or duplicate tracks) ***'
  $audioFlags | Format-Table -AutoSize | Out-String | Write-Output
  Write-Output 'Identify each track from its CONTENT before labelling or dropping anything:'
  Write-Output '  python scripts/identify-audio.py "<file>" --tracks 0 1 2 --start 3000'
  Write-Output 'Then fix by REMUX (stream copy, no re-encode) - see gotchas.md "duplicate audio".'
}

# "MANIFEST DONE with failed items" is a real, documented failure mode: this line used to print
# unconditionally AND the script always exited 0, so lane-runner filed a partly-failed manifest
# under done\ and the only evidence was a FAILED line deep in the lane log. The literal string
# "MANIFEST DONE" is preserved in both branches because waiters grep for it; the exit code now
# tells the truth, which is what lane-runner actually routes on (failed manifests go to
# _queue\failed, where they are visible and safely re-queueable - resume skips finished outputs).
if($failCount -gt 0){
  Write-Output ("MANIFEST DONE - {0} of {1} item(s) FAILED (see the !! FAILED lines above)" -f $failCount, $items.Count)
  exit 1
}
Write-Output "MANIFEST DONE"
