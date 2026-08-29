<#
  make-manifest.ps1 — turn a compact, human-editable episode table into a transcode.ps1
  manifest JSON, with correct Plex paths. Removes the error-prone hand-building of big TV
  manifests (26+ items) and the PowerShell nested-array pitfalls that come with it.

  Usage:
    pwsh -File make-manifest.ps1 -Table eps.txt -ManifestOut items.json `
         -Show "The Water Margin" -Year 1973 -Kind DVD `
         -SrcRoot "E:\Movies" -DiscFmt "The Water Margin Disk {disc}"

  TABLE FORMAT (pipe-delimited; first non-# line is a HEADER naming the columns):
    disc|title|season|ep|name
    1|1|1|1|Nine Dozen Heroes and One Wicked Man
    7|1|1|13|When Liang Shan Po Robbed the Poor
    7|2|2|1|A Death for Love, More Deaths from Greed        # a disc can straddle seasons
    ...
  Required columns: season, ep, name, and a source key — `title` for DVD (dvdvideo PGC number)
  or `clip` for BD (m2ts basename, e.g. 00000). Optional columns, added only when present:
  chapterStart, chapterEnd (DVD chapter-range episodes), commentary (0-based source audio idx),
  subTrack (0-based English subtitle idx), crop (BD: auto|none, default auto).

  -SrcRoot + -DiscFmt build the source: DVD -> "<SrcRoot>\<DiscFmt>" (the disc root a dvdvideo
  title lives in); BD -> "<SrcRoot>\<DiscFmt>\BDMV\STREAM\<clip>.m2ts". `{disc}` in DiscFmt is
  substituted per row. -OutRoot defaults to the TV library; pass a Movies root for films.
#>
param(
  [Parameter(Mandatory)][string]$Table,
  [Parameter(Mandatory)][string]$ManifestOut,
  [Parameter(Mandatory)][string]$Show,
  # YEAR IS OPTIONAL, because not every show in this library carries one.
  #
  # This was mandatory and `$Show ($Year)` was hard-coded into both the folder and every filename.
  # That is right for most shows and WRONG where the existing NAS folder has no year - `Farscape`
  # and `Survivors` are both bare. Generating `Farscape (1999)` would not fail; it would silently
  # create a SECOND show beside the real one and split the series, which is the most expensive
  # naming mistake available here and has been a near-miss twice in this batch.
  #
  # Omit -Year to match a bare folder. Match what is ALREADY ON THE NAS; do not decide from taste.
  [int]$Year = 0,
  [ValidateSet('DVD','BD')][string]$Kind = 'DVD',
  [Parameter(Mandatory)][string]$SrcRoot,
  [Parameter(Mandatory)][string]$DiscFmt,
  [string]$OutRoot = "D:\video\Television Shows"
)
$ErrorActionPreference = 'Stop'
$lines = (Get-Content $Table) | Where-Object { $_.Trim() -and $_.Trim() -notmatch '^#' }
if($lines.Count -lt 2){ throw "Table needs a header line + at least one row." }
$cols = $lines[0].Trim() -split '\s*\|\s*'
$rows = $lines[1..($lines.Count-1)]

# forward slashes avoid JSON backslash-escaping headaches; ffmpeg/PowerShell accept them on Windows
# One name for both the folder and every filename, so they cannot drift apart.
$showName = if ($Year -gt 0) { "$Show ($Year)" } else { $Show }
$base = ("$OutRoot/$showName" -replace '\\','/')
$srcRootF = $SrcRoot -replace '\\','/'
$man = foreach($r in $rows){
  $v = @{}; $f = $r.Trim() -split '\s*\|\s*'
  for($i=0;$i -lt $cols.Count;$i++){ $v[$cols[$i]] = $f[$i] }
  $S = '{0:D2}' -f [int]$v['season']; $E = '{0:D2}' -f [int]$v['ep']
  $disc = $v['disc']
  $out  = "$base/Season $S/$showName - S${S}E${E} - $($v['name']).mkv"
  $item = [ordered]@{ out = $out; kind = $Kind }
  if($Kind -eq 'DVD'){
    $item.src   = "$srcRootF/$($DiscFmt -replace '\{disc\}',$disc)"
    $item.title = [int]$v['title']
    if($v['chapterStart']){ $item.chapterStart = [int]$v['chapterStart'] }
    if($v['chapterEnd']){   $item.chapterEnd   = [int]$v['chapterEnd'] }
  } else {
    $item.src  = "$srcRootF/$($DiscFmt -replace '\{disc\}',$disc)/BDMV/STREAM/$($v['clip']).m2ts"
    $item.crop = if($v['crop']){ $v['crop'] } else { 'auto' }
  }
  if($v['commentary'] -ne $null -and "$($v['commentary'])" -ne ''){ $item.commentary = [int]$v['commentary'] }
  # subTrack is NOT always an integer. `[int]` here could only express an ordinal, so a disc with
  # no subpicture streams at all - Farscape S1, every VTS, zero - could not be described, and the
  # generator was unusable for it. The manifest format accepts a language tag ("eng") or "none";
  # pass those through verbatim and only cast when it really is a number.
  if($v['subTrack']   -ne $null -and "$($v['subTrack'])"   -ne ''){
    $st = "$($v['subTrack'])".Trim()
    $item.subTrack = if ($st -match '^\d+$') { [int]$st } else { $st }
  }
  $item
}
$man | ConvertTo-Json | Set-Content $ManifestOut -Encoding UTF8
Write-Host ("Wrote {0} items -> {1}" -f $man.Count, $ManifestOut) -ForegroundColor Green
$man | Select-Object -First 2 | ForEach-Object { "  " + ($_.out.Split('/')[-1]) }
Write-Host "  ..."
$man | Select-Object -Last 1 | ForEach-Object { "  " + ($_.out.Split('/')[-1]) }
