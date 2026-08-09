<#
  transcode.ps1 — encode a manifest of disc titles to Plex-ready MKVs (H.264 NVENC, CQ20).
  Manifest-driven so it covers episodes, movies, and extras with one code path.

  Usage:
    pwsh -File transcode.ps1 -Manifest items.json [-ToolsDir "D:\video\.transcode-tools"] [-LogDir .]

  Manifest = JSON array. Each item:
    out    (string, required)  full output .mkv path (already Plex-named)
    kind   ("BD"|"DVD", req)   BD = H.264 m2ts (1080p); DVD = MPEG-2 VOB (SD PAL, interlaced)
    src    (string, required)  BD: path to .m2ts.  DVD: "concat:VTS_xx_1.VOB|VTS_xx_2.VOB|..."
    crop   ("auto"|"none")     BD only. auto = cropdetect (pillarboxed 4:3 -> ~1440). Stills/
                               split-screen/full-frame -> "none". DVD ignores (no crop).
    commentary (int, optional) 0-based SOURCE audio index to tag as "Audio Commentary".

  Behaviour baked in (see references/gotchas.md for the why):
    - Audio count de-duped to distinct numeric indices (m2ts double-lists streams).
    - No-audio sources encode video-only (never map a missing 0:a:0).
    - Audio matrix: AAC stereo@160 (default) [+ AAC 5.1@160 if source a:0 is 6ch] + passthru
      of every original track. AAC forced to -ar 48000 (some DVD AC3 don't propagate rate).
    - BD: per-item cropdetect; if PGS subs present AND cropped, reposition with SupMover so
      subtitles stay aligned to the cropped canvas. English subs only.
    - DVD: bwdif deinterlace + setsar 16/15 + -aspect 4:3 (anamorphic), stays SD, VOBSUB copy.
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [string]$ToolsDir = "D:\video\.transcode-tools",
  [string]$LogDir = "."
)
$ErrorActionPreference = 'Continue'
$tp = Get-Content (Join-Path $ToolsDir "tool-paths.json") | ConvertFrom-Json
$ff = $tp.ffmpeg; $sm = $tp.supmover
$work = Join-Path $ToolsDir "work"; New-Item -ItemType Directory -Force $work | Out-Null
$items = Get-Content $Manifest -Raw | ConvertFrom-Json

function Audio-Count($src){   # distinct numeric audio indices (m2ts double-lists; DVD has blanks)
  ((& ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 $src 2>$null) |
    Where-Object { $_ -match '^\d+$' } | Sort-Object -Unique | Measure-Object).Count
}
function Audio-Ch0($src){     # channel count of first audio stream (to decide AAC 5.1)
  $c = (& ffprobe -v error -select_streams a:0 -show_entries stream=channels -of csv=p=0 $src 2>$null | Select-Object -First 1)
  if($c){ [int]$c } else { 0 }
}
function Sub-Count($src){
  ((& ffprobe -v error -select_streams s -show_entries stream=index -of csv=p=0 $src 2>$null) |
    Where-Object { $_ -match '^\d+$' } | Sort-Object -Unique | Measure-Object).Count
}
function Get-Crop($src){      # sample by duration fraction; largest-area box; fallback 1440 pillarbox
  $dur=[double](& ffprobe -v error -show_entries format=duration -of csv=p=0 $src 2>$null)
  if(-not $dur -or $dur -lt 1){ return '1440:1080:240:0' }
  $crops=@{}
  foreach($fr in 0.2,0.4,0.6,0.8){
    $o=& $ff -hide_banner -ss ([int]($dur*$fr)) -i $src -vf "cropdetect=limit=24:round=2" -frames:v 150 -an -f null NUL 2>&1 |
       Select-String -Pattern 'crop=(\d+):(\d+):(\d+):(\d+)' -AllMatches
    foreach($m in $o.Matches){ $crops[$m.Value]=1 }
  }
  $best=$null;$ba=0
  foreach($k in $crops.Keys){ if($k -match 'crop=(\d+):(\d+):(\d+):(\d+)'){ $a=[int]$Matches[1]*[int]$Matches[2]; if($a -gt $ba){$ba=$a;$best=$k} } }
  if(-not $best){ return '1440:1080:240:0' }
  $best -match 'crop=(\d+):(\d+):(\d+):(\d+)'|Out-Null
  $w=[int]$Matches[1];$h=[int]$Matches[2];$x=[int]$Matches[3];$y=[int]$Matches[4]
  if($w -lt 1400 -or $w -gt 1920 -or $h -lt 1060){ return '1440:1080:240:0' }
  if($x%2){$x--}; if($y%2){$y--}
  "$w`:$h`:$x`:$y"
}

$i=0
foreach($it in $items){
  $i++
  Write-Output ("[{0}/{1}] {2}  ({3})" -f $i,$items.Count,(Split-Path $it.out -Leaf),$it.kind)
  New-Item -ItemType Directory -Force (Split-Path $it.out) | Out-Null
  if((Test-Path $it.out) -and ((Get-Item $it.out).Length -gt 5MB)){ Write-Output "   skip (exists)"; continue }

  $na = Audio-Count $it.src
  $ch0 = if($na -gt 0){ Audio-Ch0 $it.src } else { 0 }
  $ns = Sub-Count $it.src
  $a = @('-y','-hide_banner','-v','error','-stats','-i',$it.src)

  # --- video filter + optional PGS subtitle repositioning (BD crop) ---
  $subInput = $null; $crop = $null
  if($it.kind -eq 'DVD'){ $vf = 'bwdif=mode=send_frame,setsar=16/15' }
  else {
    if($it.crop -eq 'auto'){ $crop = Get-Crop $it.src; $vf = "crop=$crop"; Write-Output "   crop=$crop" }
    else { $vf = $null; Write-Output "   crop=none" }
    if($ns -gt 0 -and $crop){                       # PGS present + cropped -> reposition
      $crop -match '(\d+):(\d+):(\d+):(\d+)'|Out-Null
      $L=[int]$Matches[3]; $T=[int]$Matches[4]; $R=(1920-[int]$Matches[1]-[int]$Matches[3]); $B=(1080-[int]$Matches[2]-[int]$Matches[4])
      $sup="$work\s$i.sup"; $supf="$work\s${i}_fixed.sup"
      & $ff -y -hide_banner -v error -i $it.src -map 0:s:0 -c copy $sup 2>&1 | Out-Null
      if((Test-Path $sup) -and ((Get-Item $sup).Length -gt 1KB)){ & $sm $sup $supf --crop $L $T $R $B 2>&1 | Out-Null; $subInput = $supf }
    }
  }
  if($subInput){ $a += @('-i',$subInput) }

  # --- stream maps ---
  $a += @('-map','0:v:0')
  $aacIdx = 0                                        # output audio stream counter
  if($na -gt 0){
    if($ch0 -ge 6){ $a += @('-map','0:a:0') }        # AAC 5.1 (from a:0)
    $a += @('-map','0:a:0')                          # AAC stereo (from a:0)
    for($j=0;$j -lt $na;$j++){ $a += @('-map',"0:a:$j") }   # passthru every original
  }
  if($ns -gt 0){ if($subInput){ $a += @('-map','1:0') } elseif($it.kind -eq 'DVD'){ $a += @('-map','0:s:0') } else { $a += @('-map','0:s:0') } }

  # --- video codec ---
  if($vf){ $a += @('-vf',$vf) }
  $a += @('-c:v','h264_nvenc','-preset','medium','-rc','vbr','-cq','20','-b:v','0','-pix_fmt','yuv420p')
  if($it.kind -eq 'DVD'){ $a += @('-aspect','4:3') } else { $a += @('-color_primaries','bt709','-color_trc','bt709','-colorspace','bt709','-color_range','tv') }

  # --- audio codecs ---
  if($na -gt 0){
    if($ch0 -ge 6){
      $a += @("-c:a:$aacIdx",'aac',"-b:a:$aacIdx",'160k',"-ac:a:$aacIdx",'6',"-ar:a:$aacIdx",'48000',"-metadata:s:a:$aacIdx",'title=Surround 5.1 (AAC)',"-metadata:s:a:$aacIdx",'language=eng',"-disposition:a:$aacIdx",'default'); $aacIdx++
      $a += @("-c:a:$aacIdx",'aac',"-b:a:$aacIdx",'160k',"-ac:a:$aacIdx",'2',"-ar:a:$aacIdx",'48000',"-metadata:s:a:$aacIdx",'title=Stereo (AAC)',"-metadata:s:a:$aacIdx",'language=eng'); $aacIdx++
    } else {
      $a += @("-c:a:$aacIdx",'aac',"-b:a:$aacIdx",'160k',"-ac:a:$aacIdx",'2',"-ar:a:$aacIdx",'48000',"-metadata:s:a:$aacIdx",'title=Stereo (AAC)',"-metadata:s:a:$aacIdx",'language=eng',"-disposition:a:$aacIdx",'default'); $aacIdx++
    }
    for($j=0;$j -lt $na;$j++){
      $oi = $aacIdx + $j
      $a += @("-c:a:$oi",'copy',"-metadata:s:a:$oi",'language=eng')
      if($it.PSObject.Properties.Name -contains 'commentary' -and $it.commentary -eq $j){ $a += @("-disposition:a:$oi",'comment',"-metadata:s:a:$oi",'title=Audio Commentary') }
    }
  }
  if($ns -gt 0){ $a += @('-c:s','copy','-metadata:s:s:0','language=eng') }
  $a += @('-max_muxing_queue_size','1024',$it.out)

  $t0=Get-Date; & $ff @a; $secs=[int]((Get-Date)-$t0).TotalSeconds
  if((Test-Path $it.out) -and ((Get-Item $it.out).Length -gt 1MB)){ Write-Output ("   OK {0:N2}GB in {1}s" -f ((Get-Item $it.out).Length/1GB),$secs) }
  else { Write-Output "   !! FAILED ($secs s)" }
  Remove-Item "$work\s$i.sup","$work\s${i}_fixed.sup" -ErrorAction SilentlyContinue
}
Write-Output "MANIFEST DONE"
