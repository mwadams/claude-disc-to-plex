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
    title  (int)               DVD only, required. DVD title (PGC) number (see identification.md).
    chapterStart / chapterEnd  DVD only, optional. Extract a chapter RANGE = one episode when a
                               title holds several episodes as chapter ranges.
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
  $needBytes = 0
  foreach($it in $pending){
    $sp = "$($it.src)"
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
function InSpec($it,[switch]$Hwaccel){   # ffmpeg/ffprobe input args (demuxer + -i) for this item
  # -hwaccel cuda decodes on the GPU and hands frames back in system memory, so the crop/bwdif
  # filters and PGS handling are unaffected. NOT applied to ffprobe calls (probing is cheap) and
  # NOT to DVD (SD MPEG-2 decodes fast; the win is on HD sources, above all VC-1, whose ffmpeg
  # decoder has no frame-level threading and pegs a single core).
  $hw = if($Hwaccel -and $it.kind -ne 'DVD'){ @('-hwaccel','cuda') } else { @() }
  if($it.kind -eq 'DVD'){
    $s = @('-f','dvdvideo','-title',[string]$it.title)
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
  if((Test-Path $it.out) -and ((Get-Item $it.out).Length -gt 5MB)){
    $od = "$(& $fp -v error -show_entries format=duration -of csv=p=0 $it.out 2>$null)".Trim()
    $odv = 0.0; [void][double]::TryParse($od, [ref]$odv)
    if($odv -gt 0){ Write-Output "   skip (exists)"; continue }
    Write-Output "   existing output is UNFINALISED (no duration) - re-encoding it"
    Remove-Item -LiteralPath $it.out -Force -ErrorAction SilentlyContinue
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
        continue
      }
    }

  $a = @('-y','-hide_banner','-v','error','-stats') + $encspec

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
  #   fps=24             fills the gaps so the result is a normal CFR video Plex can seek
  #
  # Applied INSTEAD of crop/deinterlace: a gallery is progressive full-frame artwork, and
  # cropdetect on a black-bordered still would eat the picture.
  if($it.stillsHold){
    $hold = [double]$it.stillsHold
    if($hold -le 0){ throw "stillsHold must be > 0 on $($it.out)" }
    $vf = "setpts=N*$hold/TB,fps=24"
    Write-Output ("   STILLS GALLERY - holding each frame {0:N1}s (setpts+fps)" -f $hold)
  }
  if(-not $it.stillsHold){
  if($it.kind -in @('DVD','MKV')){ $vf = 'bwdif=mode=send_frame' }   # SD interlaced source (DVD demuxer OR a MakeMKV-ripped .mkv): deinterlace only; aspect set via -aspect below (preserve source DAR)
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
      $a += @("-c:a:$aacIdx",'aac',"-b:a:$aacIdx",'160k',"-ac:a:$aacIdx",'2',"-ar:a:$aacIdx",'48000',"-metadata:s:a:$aacIdx",'title=Stereo (AAC)',"-metadata:s:a:$aacIdx","language=$lang0"); $aacIdx++
    } else {
      $a += @("-c:a:$aacIdx",'aac',"-b:a:$aacIdx",'160k',"-ac:a:$aacIdx",'2',"-ar:a:$aacIdx",'48000',"-metadata:s:a:$aacIdx",'title=Stereo (AAC)',"-metadata:s:a:$aacIdx","language=$lang0","-disposition:a:$aacIdx",'default'); $aacIdx++
    }
    for($j=0;$j -lt $nk;$j++){
      $oi = $aacIdx + $j
      # passthru the original track bit-for-bit — EXCEPT Blu-ray/DVD LPCM, which Matroska can't store via -c copy
      # ("No wav codec tag for pcm_bluray"); re-encode those to FLAC (lossless, MKV-native) instead.
      if((Audio-Codec $inspec $keep[$j]) -match '^pcm'){ $a += @("-c:a:$oi",'flac') } else { $a += @("-c:a:$oi",'copy') }
      $a += @("-metadata:s:a:$oi","language=$(& $langOf $j)")
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
  $a += @('-max_muxing_queue_size','1024',$it.out)

  if($env:TRANSCODE_DEBUG){ Write-Output ("   CMD: " + ($a -join ' ')) }
  $t0=Get-Date; & $ff @a; $secs=[int]((Get-Date)-$t0).TotalSeconds
  # NVENC does the encoding, so a slow item is almost always DECODE-bound (measured on a VC-1
  # Blu-ray: software decode 1.62x realtime, adding the encode cost only 8% more -- the encoder
  # idles waiting for frames). $hwaccel puts the decode on the GPU too. It can fail on odd
  # profiles/codecs, so on failure retry once with software decode before reporting a problem.
  if((-not (Test-Path $it.out)) -or ((Get-Item $it.out).Length -le 1MB)){
    if($usedHwaccel){
      Write-Output "   hwaccel decode failed; retrying with software decode"
      Remove-Item $it.out -Force -ErrorAction SilentlyContinue
      $a = @($a | Where-Object { $_ -ne '-hwaccel' -and $_ -ne 'cuda' })
      $t0=Get-Date; & $ff @a; $secs=[int]((Get-Date)-$t0).TotalSeconds
    }
  }
  if((Test-Path $it.out) -and ((Get-Item $it.out).Length -gt 1MB)){ Write-Output ("   OK {0:N2}GB in {1}s" -f ((Get-Item $it.out).Length/1GB),$secs) }
  else { Write-Output "   !! FAILED ($secs s)"; $failCount++ }
  Remove-Item "$work\s$i.sup","$work\s${i}_fixed.sup" -ErrorAction SilentlyContinue
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
