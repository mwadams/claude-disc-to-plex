<#
  scan-disc.ps1 — enumerate and CLASSIFY every title on a DVD (or set of discs) so nothing is
  ever silently dropped. This exists because a blind "keep only episode-length titles" filter
  once discarded real extras without anyone noticing (see gotchas.md, "silent extras drop").
  The rule this enforces: EVERY real title must be accounted for — mapped to an episode, kept as
  a Season 00 extra, or excluded only as identified boilerplate (a copyright/promo reel). Junk is
  proven, never assumed.

  Usage:
    # one disc
    pwsh -File scan-disc.ps1 -Root "E:\Movies\The West Wing Season 4 Disk 1"

    # a whole show — glob several disc folders so cross-disc boilerplate is detected
    pwsh -File scan-disc.ps1 -SrcRoot "E:\Movies" -Pattern "The West Wing Season 4 Disk *"

    # write a JSON of the real (non-artifact) titles for manifest building
    pwsh -File scan-disc.ps1 -SrcRoot "E:\Movies" -Pattern "The Thin Man*" -JsonOut scan.json

  LABELS (heuristic — you confirm the REVIEW/PLAYALL rows, the script never finalises them):
    ARTIFACT   no video, or < 15 s, or phantom audio (sample_rate=0) on a short clip — menu junk.
    BOILERPLATE a short title whose EXACT duration repeats on >=3 discs — copyright/anti-piracy or
               promo reel (e.g. the 273.000s Warner "SCHWEIZ" warning). Excluded, but reported.
    PLAYALL?   the longest title when its duration >= ~1.5x the next — usually a play-all
               concatenation of the disc's episodes. Skip it (its episodes are the real outputs).
    EPISODE?   a title in the dominant equal-length cluster — the likely episodes.
    REVIEW     a real title that is none of the above — a probable EXTRA. Extract a frame and
               decide: Season 00 extra, or exclude if it turns out to be boilerplate. NEVER drop
               a REVIEW row without looking at it.
#>
param(
  [string]$Root,                    # a single disc root (folder containing VIDEO_TS), OR
  [string]$SrcRoot,                 # a parent folder + -Pattern to scan many discs at once
  [string]$Pattern,
  [int]$MaxTitle = 40,              # highest DVD title index to probe
  [int]$ArtifactMaxSec = 15,        # <= this with no real content = artifact
  [string]$JsonOut                  # optional: write the real (non-artifact) titles as JSON
)
$ErrorActionPreference = 'Stop'

# locate ffprobe from the toolchain (tool-paths.json), else PATH
$ffprobe = $null
$tp = Join-Path (Split-Path $PSScriptRoot -Parent) '..\..\.transcode-tools\tool-paths.json'
if(Test-Path $tp){ try { $ffprobe = (Get-Content $tp -Raw | ConvertFrom-Json).ffprobe } catch {} }
if(-not $ffprobe -or -not (Test-Path $ffprobe)){
  $cand = Get-ChildItem "D:\video\.transcode-tools" -Recurse -Filter ffprobe.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if($cand){ $ffprobe = $cand.FullName }
}
if(-not $ffprobe){ $ffprobe = 'ffprobe' }

# resolve the list of disc roots
$discs = @()
if($Root){ $discs = @($Root) }
elseif($SrcRoot -and $Pattern){ $discs = @(Get-ChildItem $SrcRoot -Directory -Filter $Pattern | Select-Object -ExpandProperty FullName | Sort-Object) }
else { throw "Provide -Root <disc>, or -SrcRoot <parent> + -Pattern <glob>." }
if($discs.Count -eq 0){ throw "No disc folders matched." }

function Probe($root,$t){
  $dur = [double](& $ffprobe -v error -f dvdvideo -title $t -i $root -show_entries format=duration -of csv=p=0 2>$null)
  if(-not $dur -or $dur -le 0){ return $null }
  $v = (& $ffprobe -v error -f dvdvideo -title $t -i $root -select_streams v:0 -show_entries stream=width,height,display_aspect_ratio -of csv=p=0 2>$null)
  $hasVideo = [bool]$v
  $ar = @(& $ffprobe -v error -f dvdvideo -title $t -i $root -select_streams a -show_entries stream=sample_rate -of csv=p=0 2>$null)
  $na = ($ar | Where-Object { $_ -match '^\d+$' }).Count
  $phantom = ($ar.Count -gt 0) -and -not ($ar | Where-Object { $_ -match '^[1-9]' })
  [pscustomobject]@{ disc=(Split-Path $root -Leaf); title=$t; sec=[math]::Round($dur,3); min=[math]::Round($dur/60,1); video=$v; hasVideo=$hasVideo; audio=$na; phantom=$phantom }
}

# gather every non-empty title across all discs
$all = foreach($d in $discs){
  Write-Host ("Scanning {0} ..." -f (Split-Path $d -Leaf)) -ForegroundColor Cyan
  for($t=1;$t -le $MaxTitle;$t++){ $p = Probe $d $t; if($p){ $p } }
}

# cross-disc boilerplate: identical exact duration on >=3 discs, and short (< 10 min)
$boiler = @{}
$all | Where-Object { $_.sec -lt 600 } | Group-Object { '{0:F3}' -f $_.sec } | ForEach-Object {
  if(($_.Group | Select-Object -ExpandProperty disc -Unique).Count -ge 3){ $boiler[$_.Name] = $true }
}

# per-disc classification
$rows = foreach($d in ($all | Select-Object -ExpandProperty disc -Unique)){
  $titles = @($all | Where-Object disc -eq $d)
  $real = @($titles | Where-Object { $_.hasVideo -and $_.sec -gt $ArtifactMaxSec -and -not ($_.phantom -and $_.sec -lt 120) })
  $durs = @($real | Select-Object -ExpandProperty sec | Sort-Object)
  $longest = ($real | Sort-Object sec -Descending | Select-Object -First 1)
  $secondSec = ($real | Sort-Object sec -Descending | Select-Object -Skip 1 -First 1).sec
  # dominant cluster = titles within +/-25% of the median of the non-longest titles
  $mid = @($real | Where-Object { -not ($longest -and $_.title -eq $longest.title -and $_.disc -eq $longest.disc) })
  $med = if($mid.Count){ ($mid | Select-Object -ExpandProperty sec | Sort-Object)[[int]($mid.Count/2)] } else { 0 }
  foreach($x in $titles){
    $label =
      if(-not $x.hasVideo -or $x.sec -le $ArtifactMaxSec -or ($x.phantom -and $x.sec -lt 120)){ 'ARTIFACT' }
      elseif($boiler.ContainsKey(('{0:F3}' -f $x.sec))){ 'BOILERPLATE' }
      elseif($longest -and $x.title -eq $longest.title -and $secondSec -and $x.sec -ge 1.5*$secondSec){ 'PLAYALL?' }
      elseif($med -and [math]::Abs($x.sec-$med) -le 0.25*$med){ 'EPISODE?' }
      else { 'REVIEW' }
    $x | Add-Member -NotePropertyName label -NotePropertyValue $label -PassThru
  }
}

# report
$rows | Sort-Object disc,title | Format-Table disc,title,min,@{n='dar';e={($_.video -split ',')[2]}},audio,label -AutoSize | Out-String | Write-Host
$revs = @($rows | Where-Object label -eq 'REVIEW')
Write-Host ("`nEPISODE?={0}  REVIEW(extras?)={1}  PLAYALL?={2}  BOILERPLATE={3}  ARTIFACT={4}" -f `
  ($rows|?{$_.label -eq 'EPISODE?'}).Count, $revs.Count, ($rows|?{$_.label -eq 'PLAYALL?'}).Count, `
  ($rows|?{$_.label -eq 'BOILERPLATE'}).Count, ($rows|?{$_.label -eq 'ARTIFACT'}).Count) -ForegroundColor Yellow
if($revs.Count){
  Write-Host "REVIEW titles are probable EXTRAS — extract a frame and decide S00 vs exclude. Do NOT drop unseen:" -ForegroundColor Yellow
  $revs | ForEach-Object { Write-Host ("  {0}  title {1}  {2} min" -f $_.disc,$_.title,$_.min) }
}

if($JsonOut){
  $real = $rows | Where-Object { $_.label -in @('EPISODE?','PLAYALL?','REVIEW') } |
    Select-Object disc,title,sec,min,audio,@{n='dar';e={($_.video -split ',')[2]}},label
  $real | ConvertTo-Json | Set-Content $JsonOut -Encoding UTF8
  Write-Host ("Wrote {0} real titles -> {1}" -f @($real).Count, $JsonOut) -ForegroundColor Green
}
