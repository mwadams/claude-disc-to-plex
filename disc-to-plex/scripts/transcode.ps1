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
    subTrack (int, optional)   0-based source subtitle index to keep (English). BD defaults to the
                               single PGS track; on multi-language DVDs set this to the English one.
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
$work = Join-Path $ToolsDir "work"; New-Item -ItemType Directory -Force $work | Out-Null
$items = Get-Content $Manifest -Raw | ConvertFrom-Json

function Has($o,$n){ $o.PSObject.Properties.Name -contains $n -and $null -ne $o.$n -and "$($o.$n)" -ne '' }
function InSpec($it){   # ffmpeg/ffprobe input args (demuxer + -i) for this item
  if($it.kind -eq 'DVD'){
    $s = @('-f','dvdvideo','-title',[string]$it.title)
    if(Has $it 'chapterStart'){ $s += @('-chapter_start',[string]$it.chapterStart) }
    if(Has $it 'chapterEnd'){   $s += @('-chapter_end',  [string]$it.chapterEnd) }
    return ($s + @('-i',$it.src))
  }
  return @('-i',$it.src)
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

  $inspec = InSpec $it
  $na = Audio-Count $inspec
  $origLang = if(Has $it 'origLang'){ "$($it.origLang)" } else { 'eng' }   # ISO-639 of the ORIGINAL language; eng/unset = English content
  $keep = @(Keep-AudioIdx $inspec $na $origLang)   # audio ordinals to keep (foreign original first, then English)
  $nk = $keep.Count
  $ch0 = if($nk -gt 0){ Audio-Ch0 $inspec $keep[0] } else { 0 }
  $ns = Sub-Count $inspec
  $subIdx = if(Has $it 'subTrack'){ [int]$it.subTrack } else { 0 }

  $a = @('-y','-hide_banner','-v','error','-stats') + $inspec

  # --- video filter + optional PGS subtitle repositioning (BD crop) ---
  $subInput = $null; $crop = $null
  if($it.kind -in @('DVD','MKV')){ $vf = 'bwdif=mode=send_frame' }   # SD interlaced source (DVD demuxer OR a MakeMKV-ripped .mkv): deinterlace only; aspect set via -aspect below (preserve source DAR)
  else {
    if($it.crop -eq 'auto'){ $crop = Get-Crop $it.src; $vf = "crop=$crop"; Write-Output "   crop=$crop (auto)" }
    elseif("$($it.crop)" -match '^\d+:\d+:\d+:\d+$'){ $crop = "$($it.crop)"; $vf = "crop=$crop"; Write-Output "   crop=$crop (explicit)" }
    else { $vf = $null; Write-Output "   crop=none" }
    if($ns -gt 0 -and $crop){
      $crop -match '(\d+):(\d+):(\d+):(\d+)'|Out-Null
      $L=[int]$Matches[3]; $T=[int]$Matches[4]; $R=(1920-[int]$Matches[1]-[int]$Matches[3]); $B=(1080-[int]$Matches[2]-[int]$Matches[4])
      $sup="$work\s$i.sup"; $supf="$work\s${i}_fixed.sup"
      & $ff -y -hide_banner -v error @inspec -map "0:s:$subIdx" -c copy $sup 2>&1 | Out-Null
      if((Test-Path $sup) -and ((Get-Item $sup).Length -gt 1KB)){ & $sm $sup $supf --crop $L $T $R $B 2>&1 | Out-Null; $subInput = $supf }
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
      if((Has $it 'commentary') -and ([int]$it.commentary -eq $keep[$j])){ $a += @("-disposition:a:$oi",'comment',"-metadata:s:a:$oi",'title=Audio Commentary') }
    }
  }
  if($ns -gt 0){ $a += @('-c:s','copy','-metadata:s:s:0','language=eng'); if($origLang -and $origLang -notin @('eng','en')){ $a += @('-disposition:s:0','default') } }  # default English subs ON for foreign originals
  $a += @('-max_muxing_queue_size','1024',$it.out)

  $t0=Get-Date; & $ff @a; $secs=[int]((Get-Date)-$t0).TotalSeconds
  if((Test-Path $it.out) -and ((Get-Item $it.out).Length -gt 1MB)){ Write-Output ("   OK {0:N2}GB in {1}s" -f ((Get-Item $it.out).Length/1GB),$secs) }
  else { Write-Output "   !! FAILED ($secs s)" }
  Remove-Item "$work\s$i.sup","$work\s${i}_fixed.sup" -ErrorAction SilentlyContinue
}
Write-Output "MANIFEST DONE"
