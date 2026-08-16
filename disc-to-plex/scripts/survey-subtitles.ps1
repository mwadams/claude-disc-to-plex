# Survey the NAS for BITMAP subtitle tracks (PGS / VOBSUB / DVB) that would benefit from an
# OCR-to-SRT pass. Text subtitles (subrip/ass/mov_text) are already scalable and are recorded
# as "text" so they can be excluded from the work.
#
# Read-only. Writes D:\video\_subs-survey.csv
#
# Films  : every file is probed.
# TV     : one episode per season is probed as a representative sample - seasons are
#          near-always encoded identically, and probing every episode over SMB would take hours.

$ffprobe = 'D:\video\.transcode-tools\ffmpeg-n7.1\ffmpeg-n7.1-latest-win64-gpl-7.1\bin\ffprobe.exe'
$films   = '\\NASTEAMV\Multimedia\Movies'
$tv      = '\\NASTEAMV\Multimedia\Television Shows'
$out     = 'D:\video\_subs-survey.csv'

$bitmap = @('hdmv_pgs_subtitle','dvd_subtitle','dvb_subtitle','xsub')
$rows   = New-Object System.Collections.Generic.List[object]

function Probe($file, $kind, $work, $group) {
  $codecs = & $ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 $file 2>$null
  if (-not $codecs) { $codecs = @() }
  $codecs = @($codecs | Where-Object { $_ })
  $bm = @($codecs | Where-Object { $bitmap -contains $_ })
  $tx = @($codecs | Where-Object { $bitmap -notcontains $_ })
  $script:rows.Add([pscustomobject]@{
    Kind       = $kind
    Work       = $work
    Group      = $group
    File       = Split-Path $file -Leaf
    BitmapSubs = $bm.Count
    TextSubs   = $tx.Count
    Codecs     = ($codecs -join '+')
    NeedsOcr   = if ($bm.Count -gt 0 -and $tx.Count -eq 0) { 'YES' } elseif ($bm.Count -gt 0) { 'partial' } else { 'no' }
    SizeGB     = [math]::Round((Get-Item -LiteralPath $file).Length / 1GB, 2)
  })
}

Write-Host "=== FILMS ==="
$i = 0
foreach ($d in Get-ChildItem -LiteralPath $films -Directory) {
  $i++
  # main feature = largest file at the folder root (extras live in subfolders)
  $main = Get-ChildItem -LiteralPath $d.FullName -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Extension -in '.mkv','.mp4','.m4v','.avi' } |
          Sort-Object Length -Descending | Select-Object -First 1
  if ($main) { Probe $main.FullName 'Film' $d.Name '' }
  if ($i % 25 -eq 0) { Write-Host "  films probed: $i" }
}

Write-Host "=== TV (one episode per season) ==="
$i = 0
foreach ($show in Get-ChildItem -LiteralPath $tv -Directory) {
  foreach ($season in Get-ChildItem -LiteralPath $show.FullName -Directory -ErrorAction SilentlyContinue) {
    $ep = Get-ChildItem -LiteralPath $season.FullName -File -ErrorAction SilentlyContinue |
          Where-Object { $_.Extension -in '.mkv','.mp4','.m4v','.avi' } |
          Sort-Object Name | Select-Object -First 1
    if ($ep) { Probe $ep.FullName 'TV' $show.Name $season.Name; $i++ }
  }
  if ($i % 25 -eq 0 -and $i -gt 0) { Write-Host "  seasons probed: $i" }
}

$rows | Export-Csv -LiteralPath $out -NoTypeInformation -Encoding UTF8
Write-Host ""
Write-Host "rows: $($rows.Count) -> $out"
$rows | Group-Object NeedsOcr | ForEach-Object { "  {0,-8} {1}" -f $_.Name, $_.Count }
Write-Host "SURVEY DONE"
