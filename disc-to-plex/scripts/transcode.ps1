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
$items = Get-Content $Manifest -Raw | ConvertFrom-Json

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
  $langs = @(& $fp -v error @inspec -select_streams s -show_entries stream_tags=language -of csv=p=0 2>$null) |
           ForEach-Object { "$_".Trim() }
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
foreach($it in $items){
  $i++
  Write-Output ("[{0}/{1}] {2}  ({3})" -f $i,$items.Count,(Split-Path $it.out -Leaf),$it.kind)
  New-Item -ItemType Directory -Force (Split-Path $it.out) | Out-Null
  if((Test-Path $it.out) -and ((Get-Item $it.out).Length -gt 5MB)){ Write-Output "   skip (exists)"; continue }

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
  if(Has $it 'audioTracks'){
    $keep = @($it.audioTracks | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 0 -and $_ -lt $na })
    Write-Output "   audioTracks explicit -> a:$($keep -join ' a:')"
  } else {
    $keep = @(Keep-AudioIdx $inspec $na $origLang)   # audio ordinals to keep (foreign original first, then English)
  }
  $nk = $keep.Count
  $ch0 = if($nk -gt 0){ Audio-Ch0 $inspec $keep[0] } else { 0 }
  $ns = Sub-Count $inspec
  # subTrack accepts an ordinal (0-based) OR a language tag ("eng"). The tag is safer: disc
  # subtitle order is arbitrary, so an ordinal that was right on one disc is wrong on the next.
  $subIdx = 0
  if(Has $it 'subTrack'){
    if("$($it.subTrack)" -match '^\d+$'){ $subIdx = [int]$it.subTrack }
    else {
      $byLang = Sub-IdxByLang $inspec "$($it.subTrack)"
      if($null -ne $byLang){ $subIdx = $byLang; Write-Output "   subTrack '$($it.subTrack)' -> s:$subIdx" }
      else { Write-Output "   WARNING: no '$($it.subTrack)' subtitle on this source - falling back to s:0"; }
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
  # -copyts keeps input timestamps; -start_at_zero then rebases EVERY stream by the same origin.
  # Harmless when the source already starts at 0 (the DVD path always does).
  $a += @('-copyts','-start_at_zero')

  # --- video filter + optional PGS subtitle repositioning (BD crop) ---
  $subInput = $null; $crop = $null
  if($it.kind -in @('DVD','MKV')){ $vf = 'bwdif=mode=send_frame' }   # SD interlaced source (DVD demuxer OR a MakeMKV-ripped .mkv): deinterlace only; aspect set via -aspect below (preserve source DAR)
  else {
    if($it.crop -eq 'auto'){ $crop = Get-Crop $it.src; $vf = "crop=$crop"; Write-Output "   crop=$crop (auto)" }
    elseif("$($it.crop)" -match '^\d+:\d+:\d+:\d+$'){ $crop = "$($it.crop)"; $vf = "crop=$crop"; Write-Output "   crop=$crop (explicit)" }
    else { $vf = $null; Write-Output "   crop=none" }
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
  if($subInput){ $a += @('-i',$subInput) }

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
  if($it.kind -in @('DVD','MKV')){ $a += @('-aspect',(Get-DAR $inspec)) } else { $a += @('-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-color_range','tv') }

  # --- audio codecs ---
  $lang0 = Audio-Lang $inspec $keep[0]      # language of the FIRST kept track = what the AAC downmix is made from
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
      $a += @("-metadata:s:a:$oi","language=$(Audio-Lang $inspec $keep[$j])")
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
  else { Write-Output "   !! FAILED ($secs s)" }
  Remove-Item "$work\s$i.sup","$work\s${i}_fixed.sup" -ErrorAction SilentlyContinue
}
Write-Output "MANIFEST DONE"
