<#
.SYNOPSIS
  Catalogue EVERY title on a staged disc, ONCE, into a durable artifact the manifest is written from.

.WHY THIS EXISTS
  Cataloguing kept happening as an ad-hoc investigation, re-opened whenever something looked odd.
  That meant the same disc was read three or four times and STILL shipped incomplete:

  1. **The enumeration floor truncated the list silently.** MakeMKV's default `minlength` is 120 s.
     The Man with the Golden Gun enumerated 14 titles at that default and 42 at `--minlength=10`.
     It was encoded, published and confirmed in Plex before the missing 29 were noticed, and the
     44 GB raw disc had to be kept back and re-ripped.
  2. **Identification ran AFTER publishing.** Diamonds Are Forever took three separate passes over
     material already on disk - audio-MD5 dedup, then dialogue matching, then contact sheets - and
     the first two produced a confident WRONG answer (seven titles excluded as in-film excerpts;
     they were alternate angles, and the user caught it).
  3. **Nothing recorded a disposition.** So "every title accounted for" got signed off against a
     list that had already been truncated, and afterwards there was no way to tell which titles had
     ever actually been looked at.

  One sweep, no ripping, durable output. Ripping is the expensive step and it is NOT needed to
  catalogue: MakeMKV's SINFO describes every stream, and a playlist's first clip can be probed and
  frame-grabbed straight out of BDMV\STREAM.

.OUTPUT
  <OutDir>\<disc>.catalogue.json   every title: duration, size, source, streams, video geometry,
                                   field order, 120 s decoded-audio MD5, frame paths, disposition
  <OutDir>\<disc>-sheet<N>.png     contact sheets, title id burned into each cell

.EXAMPLE
  pwsh -File catalogue-disc.ps1 -Disc "D:\video\_stage\ON HER MAJESTY_S SCRT SRVC"
  pwsh -File catalogue-disc.ps1 -Disc "D:\video\_stage\MOONRAKER_F1" -FrameAt 30,95,300
#>
param(
  [Parameter(Mandatory)][string]$Disc,
  [string]$OutDir = 'D:\video\_catalogue',
  [int]$MinLength = 10,
  # 95 s is deliberate: Inside The Man with the Golden Gun carries its title card at 95 s, well past
  # its siblings' ~30 s, and two sweeps of the first 80 s found nothing. Sample early AND late.
  [int[]]$FrameAt = @(30, 95),
  [string]$MakeMkv = 'C:\Program Files (x86)\MakeMKV\makemkvcon64.exe',
  [string]$ToolsDir = 'D:\video\.transcode-tools'
)
$ErrorActionPreference = 'Stop'
if(-not (Test-Path -LiteralPath $Disc)){ throw "disc folder not found: $Disc" }
$discName = Split-Path $Disc -Leaf
$tp = Get-Content (Join-Path $ToolsDir 'tool-paths.json') | ConvertFrom-Json
$ff = $tp.ffmpeg
$fp = Join-Path (Split-Path $ff) 'ffprobe.exe'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
# DISC TYPE IS DETECTED AND DISPATCHED, not left to the operator to notice.
#
# A DVD has no .m2ts to probe, so every piece of CONTENT evidence this sweep exists to collect -
# frames, head strip, speech sample, fingerprint - came back empty while the run still printed a
# title list and "N titles need a disposition". That reads exactly like a successful sweep, and on
# 2026-08-23 Witness produced 16 titles with probeFile=None and zero evidence.
#
# Telling the operator "use scan-disc.ps1 instead" is a PROSE rule in the middle of an automated
# pipeline, and prose rules get missed - which is the whole reason this file is full of guards.
# So: detect the type and run the right enumerator automatically.
if (Test-Path -LiteralPath (Join-Path $Disc 'VIDEO_TS')) {
  Write-Output "DVD detected (VIDEO_TS) - dispatching to scan-disc.ps1, which understands DVD titles."
  $scan = Join-Path $PSScriptRoot 'scan-disc.ps1'
  if (-not (Test-Path -LiteralPath $scan)) { throw "scan-disc.ps1 not found beside catalogue-disc.ps1" }
  & pwsh -NoProfile -File $scan -Root $Disc
  Write-Output ""
  Write-Output "NOTE: the DVD path enumerates and classifies titles, but does NOT yet capture frames,"
  Write-Output "head strips or speech samples the way the Blu-ray path does. Identification for this"
  Write-Output "disc still needs content evidence - see follow-up.md."
  exit $LASTEXITCODE
}

$frameDir = Join-Path $OutDir "$discName-frames"

# Speech capture is best-effort: if faster-whisper is not installed the sweep still runs, it just
# records no speechSample. Identification then falls back to frames, which is where it used to be.
$script:Whisper = Join-Path $PSScriptRoot 'transcribe-wav.py'
if(-not (Test-Path -LiteralPath $script:Whisper)){ $script:Whisper = $null }
New-Item -ItemType Directory -Force -Path $frameDir | Out-Null

# ---- 1. ENUMERATE AT THE LOW FLOOR --------------------------------------------------------
# NEVER MakeMKV's default. The floor defines what you are able to account for at all.
#
# SOME STAGED "DISCS" ARE AN .ISO, NOT A BDMV/VIDEO_TS TREE. MakeMKV's `file:` protocol finds
# nothing in a folder that merely CONTAINS an iso, so enumeration returns zero titles and the guard
# below fires - which is correct, but reads as "the disc is still copying" when the real answer is
# "wrong protocol". Sleep Dealer in batch 6 was exactly this. Use `iso:` for those.
$isIso = $false
$source = "file:$Disc"
if((Test-Path -LiteralPath $Disc -PathType Leaf) -and $Disc -match '\.iso$'){
  $isIso = $true; $source = "iso:$Disc"
} elseif(Test-Path -LiteralPath $Disc -PathType Container) {
  $hasDisc = (Test-Path -LiteralPath (Join-Path $Disc 'BDMV')) -or (Test-Path -LiteralPath (Join-Path $Disc 'VIDEO_TS'))
  if(-not $hasDisc){
    $isos = @(Get-ChildItem -LiteralPath $Disc -Filter *.iso -File -ErrorAction SilentlyContinue)
    if($isos.Count -eq 1){ $isIso = $true; $source = "iso:$($isos[0].FullName)" }
    elseif($isos.Count -gt 1){ throw "no BDMV/VIDEO_TS and $($isos.Count) iso files in $Disc - point -Disc at the one you want" }
  }
}
Write-Output ("cataloguing $discName (minlength=$MinLength){0} ..." -f $(if($isIso){' [ISO]'}else{''}))
$info = & $MakeMkv -r --cache=1 --minlength=$MinLength info $source 2>&1

$byId = @{}
# Every key is declared up front. An [ordered] record rejects assignment to a key that does not
# already exist ("The property 'x' cannot be found on this object"), and that failure lands
# mid-sweep, after the slow enumeration has already run.
function Ensure-Title($id){
  if(-not $byId.ContainsKey($id)){
    $byId[$id] = [ordered]@{
      title=$id; duration=$null; sizeText=$null; source=$null; outName=$null
      width=$null; height=$null; fieldOrder=$null; frameRate=$null
      probeFile=$null; probeScope=$null; audioMd5=$null; frames=@(); headStrip=$null; speechSample=$null; disposition=$null; streams=@()
    }
  }
}
function New-StreamRecord($n){ [ordered]@{ n=$n; type=$null; lang=$null; codec=$null; bitrate=$null; channels=$null; resolution=$null; label=$null } }
foreach($line in $info){
  if($line -match '^TINFO:(\d+),(\d+),\d+,"(.*)"$'){
    $id=[int]$Matches[1]; $code=[int]$Matches[2]; $val=$Matches[3]
    Ensure-Title $id
    switch($code){
      9  { $byId[$id].duration = $val }
      10 { $byId[$id].sizeText = $val }
      16 { $byId[$id].source   = $val }
      27 { $byId[$id].outName  = $val }
    }
  }
  elseif($line -match '^SINFO:(\d+),(\d+),(\d+),\d+,"(.*)"$'){
    $id=[int]$Matches[1]; $sn=[int]$Matches[2]; $code=[int]$Matches[3]; $val=$Matches[4]
    Ensure-Title $id
    while($byId[$id].streams.Count -le $sn){ $byId[$id].streams += ,(New-StreamRecord $byId[$id].streams.Count) }
    switch($code){
      1  { $byId[$id].streams[$sn].type       = $val }
      4  { $byId[$id].streams[$sn].lang       = $val }
      6  { $byId[$id].streams[$sn].codec      = $val }
      13 { $byId[$id].streams[$sn].bitrate    = $val }
      14 { $byId[$id].streams[$sn].channels   = $val }
      19 { $byId[$id].streams[$sn].resolution = $val }
      30 { $byId[$id].streams[$sn].label      = $val }
    }
  }
}
if($byId.Count -eq 0){ throw "enumeration returned NO titles - is the disc still copying? (assert-staged-complete.ps1)" }

# ---- 2. FIND A PROBE FILE PER TITLE, WITHOUT RIPPING --------------------------------------
# An m2ts-sourced title probes directly. A playlist title probes its FIRST clip: a .mpls lists its
# clips as plain ASCII 5-digit names immediately before "M2TS", so membership reads straight out.
$streamDir   = Join-Path $Disc 'BDMV\STREAM'
$playlistDir = Join-Path $Disc 'BDMV\PLAYLIST'
function Get-ProbeFile($src){
  # An ISO is a sealed container: its clips are not on the filesystem, so there is nothing to probe
  # or frame-grab without mounting it. Say so rather than silently producing a frameless catalogue.
  if($isIso){ return $null }
  if(-not $src){ return $null }
  if($src -match '\.m2ts$'){
    $p = Join-Path $streamDir $src
    if(Test-Path -LiteralPath $p){ return $p }
    return $null
  }
  if($src -match '\.mpls$'){
    $mp = Join-Path $playlistDir $src
    if(-not (Test-Path -LiteralPath $mp)){ return $null }
    $bytes = [IO.File]::ReadAllBytes($mp)
    $sb = New-Object System.Text.StringBuilder
    foreach($b in $bytes){ if($b -ge 32 -and $b -lt 127){ [void]$sb.Append([char]$b) } else { [void]$sb.Append(' ') } }
    if($sb.ToString() -match '(\d{5})\s*M2TS'){
      $p = Join-Path $streamDir ("{0}.m2ts" -f $Matches[1])
      if(Test-Path -LiteralPath $p){ return $p }
    }
  }
  return $null
}

# ---- 3. PROBE, FINGERPRINT, FRAME ---------------------------------------------------------
# The audio fingerprint PAIRS titles that share a soundtrack. It does not tell you what they are:
# identical audio with differing video is an alternate angle or a textless master at least as often
# as it is a duplicate. The frames are what separate those, which is why both are captured here, in
# the same pass, before any decision gets made.
#
# ⚠ The lookup table is `$byId`, NOT `$T`. PowerShell variable names are CASE-INSENSITIVE, so the
# natural pair `$T` (table) and `$t` (current record) are ONE variable: `$t = $T[$id]` silently
# replaces the table with the record. The first iteration then works, and every later `$T[$id]`
# indexes the RECORD by position, handing back a random field value. It surfaced here as
# "The property 'probeFile' cannot be found on this object" on the second title - a type error far
# from its cause, with no hint that a lookup table had been overwritten.
#
$ids = @($byId.Keys | Sort-Object)
foreach($id in $ids){
  $t = $byId[$id]
  $probe = Get-ProbeFile $t.source
  $t.probeFile = $probe
  # A playlist title is probed through its FIRST CLIP only, so its geometry, fingerprint and frames
  # describe that clip and NOT the whole title. Discs routinely open several playlists with the same
  # logo/intro clip, which makes unrelated titles fingerprint identically: on OHMSS a 30:27
  # documentary "matched" a 1:01 clip purely because both playlists start on 00522.m2ts. Recording
  # the scope is what stops that reading as a duplicate.
  $t.probeScope = if(-not $probe){ 'none' } elseif("$($t.source)" -match '\.mpls$'){ 'first-clip' } else { 'title' }
  if($probe){
    $v = @(& $fp -v error -select_streams v:0 -show_entries stream=width,height,field_order,r_frame_rate -of csv=p=0 $probe 2>$null) | Select-Object -First 1
    if($v){ $pp = $v -split ','; $t.width=[int]$pp[0]; $t.height=[int]$pp[1]; $t.fieldOrder=$pp[2]; $t.frameRate=$pp[3] }
    $md5 = @(& $ff -v error -i $probe -map 0:a:0 -t 120 -f md5 - 2>$null) | Select-Object -First 1
    if($md5){ $t.audioMd5 = ($md5 -replace '^MD5=','') }
    # CLAMP THE SAMPLE POINTS TO THE TITLE. A fixed 30 s/95 s lands past the end of a short clip and
    # yields a BLACK frame, which reads as "nothing here" rather than "sampled past the end" - on
    # Serenity that silently blanked the 11-35 s set-tour clips, the very titles hardest to identify.
    # Keep any requested point that fits, and fall back to fractions of the duration when none does.
    $durSec = 0
    if("$($t.duration)" -match '^(\d+):(\d\d):(\d\d)$'){ $durSec = [int]$Matches[1]*3600 + [int]$Matches[2]*60 + [int]$Matches[3] }
    $points = @($FrameAt | Where-Object { $durSec -eq 0 -or $_ -lt $durSec * 0.95 })
    if(-not $points -and $durSec -gt 0){ $points = @([math]::Max(1,[int]($durSec*0.25)), [math]::Max(2,[int]($durSec*0.65))) | Sort-Object -Unique }
    foreach($sec in $points){
      $png = Join-Path $frameDir ("t{0:D3}-{1:D4}.png" -f $id, $sec)
      # Fixed cell size via pad: a sheet built from differently-sized frames silently misaligns and
      # you end up reading the wrong title into the wrong cell.
      $vf = "yadif,scale=480:270:force_original_aspect_ratio=decrease,pad=480:270:(ow-iw)/2:(oh-ih)/2:black," +
            "drawtext=text='t$id @ ${sec}s':x=8:y=8:fontsize=22:fontcolor=yellow:box=1:boxcolor=black@0.7"
      & $ff -v error -ss $sec -i $probe -frames:v 1 -vf $vf -y $png 2>$null
      if(Test-Path -LiteralPath $png){ $t.frames += $png }
    }

    # ---- HEAD STRIP: the first 40 s at 1 fps, tiled -------------------------------------------
    #
    # WHY, and why it belongs HERE rather than after the rip. Sample points at 30 s and 95 s show
    # what a title LOOKS like, which is enough to spot structure - duplicates, play-alls, HD/SD
    # pairs. It is NOT enough to NAME anything, because a title card appears in the first seconds
    # and is gone. So naming was being guessed from a mid-title frame, then re-done properly from
    # a dense head sweep AFTER the rip - the same work twice, with the first pass worthless and
    # occasionally WRONG: on 2026-08-23 a You Only Live Twice title was recorded as "Whicker's
    # World part 2" from a mid-title frame; its head strip reads "KEN ADAM'S PRODUCTION FILMS".
    #
    # The catalogue already has the title open. Capturing the head costs one more pass over 40 s
    # and lets identification happen ONCE, before a single byte is ripped.
    #
    # LIMIT, and it matters: for a PLAYLIST title this samples the FIRST CLIP only (see
    # probeScope). On a compilation the head strip therefore shows the first ITEM, not the
    # title - You Only Live Twice t02 is a 52-minute playlist whose head is trailer material,
    # which would name the whole thing after its opening segment. Treat a head strip as
    # naming evidence only when probeScope is NOT 'first-clip', or when the runtime matches
    # what the card claims.
    # ---- SPEECH SAMPLE: what the title SAYS ----------------------------------------------------
    #
    # Pictures alone kept failing to name things, and the fallback was always an ad-hoc
    # transcription afterwards - the manual step this catalogue exists to remove.
    #
    #   t02 "Welcome to Japan, Mr. Bond" - the on-screen card was there but read as a film caption;
    #        the promotional NARRATION settled it.
    #   t03 / t04 - MGM documentaries whose title cards never appear in the first 35 s at all.
    #
    # A title card is optional; speech is not. Capture both here, once, so identification never
    # needs a second pass. Titles with no audio, or too short to say anything, are skipped.
    if($script:Whisper -and $durSec -ge 30){
      $wav = Join-Path $env:TEMP ("cat-t{0:D3}.wav" -f $id)
      $at  = [int]([math]::Min(60, [math]::Max(5, $durSec * 0.15)))
      & $ff -v error -ss $at -i $probe -t 45 -map '0:a:0?' -ac 1 -ar 16000 -y $wav 2>$null
      if(Test-Path -LiteralPath $wav){
        $txt = & python $script:Whisper $wav 2>$null
        if($txt){ $t.speechSample = (($txt -join ' ') -replace '\s+',' ').Trim() }
        Remove-Item -LiteralPath $wav -Force -ErrorAction SilentlyContinue
      }
    }

    $head = Join-Path $frameDir ("t{0:D3}-head.png" -f $id)
    $headLen = if($durSec -gt 0 -and $durSec -lt 40){ $durSec } else { 40 }
    $hvf = "fps=1,scale=300:169:force_original_aspect_ratio=decrease," +
           "pad=300:169:(ow-iw)/2:(oh-ih)/2:black,tile=8x5"
    & $ff -v error -t $headLen -i $probe -vf $hvf -frames:v 1 -y $head 2>$null
    if(Test-Path -LiteralPath $head){ $t.headStrip = $head } else { $t.headStrip = $null }
  }
  # Filled in by the operator. assert-accounted.ps1 refuses to release the raw disc until every
  # title has one, which is the check that "every title accounted for" never actually had.
  $t.disposition = $null
}

# ---- 4. CONTACT SHEETS --------------------------------------------------------------------
# Built by copying to a CONTIGUOUS numbered sequence and using ffmpeg's tile filter. Hand-built
# xstack layout strings are fragile, and non-contiguous input numbering makes tile skip cells.
$all = @($ids | ForEach-Object { $byId[$_].frames } | Where-Object { $_ })
$seqDir = Join-Path $frameDir '_seq'
if(Test-Path -LiteralPath $seqDir){ Get-ChildItem -LiteralPath $seqDir -File | Remove-Item -Force }
New-Item -ItemType Directory -Force -Path $seqDir | Out-Null
$sheetN = 0
for($i=0; $i -lt $all.Count; $i += 16){
  $batch = $all[$i..([math]::Min($i+15, $all.Count-1))]
  Get-ChildItem -LiteralPath $seqDir -File | Remove-Item -Force
  $k = 0
  foreach($c in $batch){ Copy-Item -LiteralPath $c -Destination (Join-Path $seqDir ("f{0:D3}.png" -f $k)); $k++ }
  $sheetN++
  $sheet = Join-Path $OutDir ("{0}-sheet{1}.png" -f $discName, $sheetN)
  $cols = 4; $rows = [math]::Ceiling($batch.Count / 4)
  & $ff -v error -framerate 1 -start_number 0 -i (Join-Path $seqDir 'f%03d.png') -frames:v 1 -vf "tile=${cols}x${rows}" -y $sheet 2>$null
  if(Test-Path -LiteralPath $sheet){ Write-Output "  sheet: $sheet" }
}

# ---- 5. WRITE THE ARTIFACT ----------------------------------------------------------------
$cat = [ordered]@{
  disc = $discName; discPath = $Disc; minLength = $MinLength
  titleCount = $byId.Count
  titles = @($ids | ForEach-Object { $byId[$_] })
}
$catPath = Join-Path $OutDir "$discName.catalogue.json"
$cat | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $catPath -Encoding UTF8

# ---- 5b. THE DISC'S OWN EXTRAS LIST -------------------------------------------------------
# mymovies.xml frequently carries an <ExtraFeatures> block naming every extra on the disc. That is
# the single highest-value identification source there is, and reading it was already a documented
# rule that got missed anyway - on Serenity it named all eight featurettes including "The Green
# Clan", a title no amount of frame-staring would produce, and it arrived only after the frames and
# transcripts had already been done. Printing it as part of the catalogue makes it unmissable.
#
# It NAMES the extras; it does not map them to title ids, and it may list DVD-era items this
# particular disc does not carry. Confirm each from content before using it as a name.
$mm = Join-Path $Disc 'mymovies.xml'
if(Test-Path -LiteralPath $mm){
  $xmlText = Get-Content -LiteralPath $mm -Raw -Encoding UTF8
  if($xmlText -match '(?s)<ExtraFeatures[^>]*>\s*(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?\s*</ExtraFeatures>'){
    $listed = ($Matches[1] -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if($listed){
      Write-Output ""
      Write-Output "THE DISC'S OWN EXTRAS LIST (mymovies.xml) - names, not title ids. Confirm each from"
      Write-Output "content before using it, and expect DVD-era entries this disc may not carry:"
      $listed | ForEach-Object { Write-Output "  - $_" }
    }
  }
  if($xmlText -match '(?s)<LocalTitle>(.*?)</LocalTitle>'){ Write-Output ("  disc says title: {0}" -f $Matches[1].Trim()) }
  if($xmlText -match '(?s)<IMDB>(.*?)</IMDB>'){ Write-Output ("  disc says imdb : {0}" -f $Matches[1].Trim()) }
}

# ---- 6. REPORT ----------------------------------------------------------------------------
Write-Output ""
Write-Output ("{0,-5} {1,9} {2,10} {3,-14} {4,-11} {5,-10} {6}" -f 'id','duration','size','source','video','fields','audio')
foreach($id in $ids){
  $t = $byId[$id]
  $vid = if($t.width){ "{0}x{1}" -f $t.width, $t.height } else { '-' }
  $h   = if($t.audioMd5){ $t.audioMd5.Substring(0,8) } else { '-' }
  Write-Output ("t{0:D2}   {1,9} {2,10} {3,-14} {4,-11} {5,-10} {6}" -f $id, $t.duration, $t.sizeText, $t.source, $vid, $t.fieldOrder, $h)
}
# Group ONLY whole-title fingerprints. A first-clip fingerprint says nothing about the title.
$dupes = @($ids | Where-Object { $byId[$_].audioMd5 -and $byId[$_].probeScope -eq 'title' } |
            Group-Object { $byId[$_].audioMd5 } | Where-Object { $_.Count -gt 1 })
if($dupes){
  Write-Output ""
  Write-Output "SHARED SOUNDTRACKS (whole-title fingerprints only) - LOOK at the frames before"
  Write-Output "deciding. Alternate angle, textless master and true duplicate all present like this:"
  foreach($g in $dupes){ Write-Output ("  {0}" -f (($g.Group | ForEach-Object { "t{0:D2}" -f $_ }) -join ' = ')) }
}
if($isIso){
  Write-Output ""
  Write-Output "ISO SOURCE - no frames or fingerprints. The clips are inside the image, so nothing was"
  Write-Output "probed: durations, sizes and MakeMKV's stream descriptions above are all you have here."
  Write-Output "Rip the titles to identify them, or mount the image first."
}
$partial = @($ids | Where-Object { $byId[$_].probeScope -eq 'first-clip' })
if($partial){
  Write-Output ""
  Write-Output "FIRST-CLIP ONLY - these are PLAYLIST titles; the geometry, fingerprint and frames above"
  Write-Output "describe their opening clip, not the title. Rip them to judge duration or content:"
  Write-Output ("  {0}" -f (($partial | ForEach-Object { "t{0:D2}" -f $_ }) -join ' '))
}
$sd = @($ids | Where-Object { $byId[$_].width -and $byId[$_].width -le 720 -and $byId[$_].height -le 576 })
if($sd){ Write-Output ""; Write-Output ("SD titles on this disc (kind must NOT be `"BD`"): {0}" -f (($sd | ForEach-Object { "t{0:D2}" -f $_ }) -join ' ')) }
$int = @($ids | Where-Object { $byId[$_].fieldOrder -and $byId[$_].fieldOrder -ne 'progressive' })
if($int){ Write-Output ("INTERLACED titles: {0}" -f (($int | ForEach-Object { "t{0:D2}" -f $_ }) -join ' ')) }
Write-Output ""
Write-Output "catalogue: $catPath"
Write-Output "$($byId.Count) title(s) - every one needs a disposition before the raw disc is released (assert-accounted.ps1)"
