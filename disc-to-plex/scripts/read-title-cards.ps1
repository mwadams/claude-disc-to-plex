<#
.SYNOPSIS
  Read the ON-SCREEN story/episode title out of each file's title sequence, by OCR, and compare it
  with the title the filename claims.

.WHY
  An anthology series is the worst case for slot assignment: every episode is the same length, the
  same cast changes every week, and the disc's title order need not be the broadcast order. Nothing
  structural can catch a wrong assignment - the file count is right, the durations are plausible,
  and Plex faithfully displays whatever the filename says.

  Measured on Tales of the Unexpected (1979), 2026-09-06: seventeen episodes published, and the file
  named `S02E01 - Royal Jelly.mkv` carries an on-screen caption reading "in THE HITCH-HIKER". The
  user spotted it by eye. Plex agreed with the filename throughout, because Plex was never asked.

  This series states its own answer: the title sequence carries "in <STORY TITLE>" in large white
  caps. That is the disc telling you what the episode IS - the strongest evidence class available,
  and far cheaper than transcribing. The caption's TIME VARIES between episodes (measured: 19 s,
  23 s, 26 s), so a fixed offset does not work; this sweeps a window.

.WHAT IT DOES NOT DO
  It does not rename anything. It reports filename vs caption and leaves the decision alone -
  reassigning episodes is a library change with a supersedes/retire trail, not a side effect of a
  reading tool.

.OCR IS EVIDENCE, NOT PROOF
  Tesseract on a caption over moving footage misreads. Every hit is reported WITH the frame it came
  from and the second it sits at, so a human can look. A file whose caption cannot be read is
  reported as UNREAD, never guessed - silence here is how a wrong assignment survives a check that
  claims to have run.

.EXAMPLE
  pwsh -File read-title-cards.ps1 -Dir '\\NAS\...\Tales of the Unexpected (1979)\Season 01' -OutDir D:/video/_pending/totu
#>
param(
  [Parameter(Mandatory)][string]$Dir,
  [Parameter(Mandatory)][string]$OutDir,
  [int]$StartSeconds = 10,
  [int]$WindowSeconds = 30,
  # The caption line this series uses. Captured group 1 is the title.
  [string]$Pattern = '(?im)^\s*(?:in\s+)?([A-Z][A-Z''\-\.,! ]{4,60})\s*$',
  [switch]$KeepFrames
)
$ErrorActionPreference = 'Stop'

$tools = Get-Content -LiteralPath 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
$ff = $tools.ffmpeg
$tess = $tools.tesseract
foreach ($t in @($ff, $tess)) { if (-not (Test-Path -LiteralPath $t)) { Write-Output "REFUSE - missing tool: $t"; exit 2 } }

if (-not (Test-Path -LiteralPath $Dir)) { Write-Output "REFUSE - no such directory: $Dir"; exit 2 }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

# Words that are NOT the story title but do appear in the same window in large caps.
$noise = @('ROALD DAHL','TALES OF THE UNEXPECTED','INTRODUCED BY','ADAPTED BY','DIRECTED BY',
           'PRODUCED BY','MUSIC BY','SCREENPLAY BY','AND','WITH','STARRING','GUEST STARRING',
           'THE END','A ANGLIA TELEVISION PRODUCTION','ANGLIA TELEVISION')

$files = @(Get-ChildItem -LiteralPath $Dir -File -Filter '*.mkv' | Sort-Object Name)
Write-Output "reading title cards from $($files.Count) file(s) in $Dir"
Write-Output "window: ${StartSeconds}s .. $($StartSeconds + $WindowSeconds)s, one frame per second"
Write-Output ""

$rows = @()
foreach ($f in $files) {
  $stem = [IO.Path]::GetFileNameWithoutExtension($f.Name)
  $work = Join-Path $OutDir ($stem -replace '[^A-Za-z0-9]+','_')
  New-Item -ItemType Directory -Path $work -Force | Out-Null

  # ONE sequential read of the window, not N seeks: far kinder to the NAS link.
  & $ff -hide_banner -loglevel error -y -ss $StartSeconds -t $WindowSeconds -i $f.FullName `
        -vf "bwdif=mode=send_frame,scale=trunc(iw*sar/2)*2:ih,fps=1,scale=960:-1,format=gray,eq=contrast=1.3" `
        (Join-Path $work 'f%03d.png') *> (Join-Path $work 'ffmpeg.log')

  $frames = @(Get-ChildItem -LiteralPath $work -Filter 'f*.png' | Sort-Object Name)
  $hits = @()
  foreach ($fr in $frames) {
    $sec = $StartSeconds + ([int]($fr.BaseName -replace '\D','')) - 1
    $txtBase = Join-Path $work $fr.BaseName
    & $tess $fr.FullName $txtBase --psm 6 *> $null
    $txtPath = "$txtBase.txt"
    if (-not (Test-Path -LiteralPath $txtPath)) { continue }
    $text = Get-Content -LiteralPath $txtPath -Raw -ErrorAction SilentlyContinue
    if (-not $text) { continue }
    foreach ($m in [regex]::Matches($text, $Pattern)) {
      $cand = ($m.Groups[1].Value -replace '\s+',' ').Trim(" .,!-'")
      if ($cand.Length -lt 5) { continue }
      if ($noise -contains $cand.ToUpperInvariant()) { continue }
      if ($cand -match '^[IVXL ]+$') { continue }          # tarot numerals
      $hits += [pscustomobject]@{ Seconds = $sec; Text = $cand; Frame = $fr.FullName }
    }
  }

  # The caption holds for several seconds, so the RIGHT answer is usually the most repeated one.
  $best = $null
  if ($hits.Count) {
    $best = $hits | Group-Object Text | Sort-Object Count, {$_.Group[0].Seconds} -Descending | Select-Object -First 1
  }

  $claimed = ''
  if ($stem -match ' - S\d+E\d+ - (.+)$') { $claimed = $Matches[1] }

  if ($best) {
    $read = $best.Name
    $norm = { param($s) ($s -replace '[^A-Za-z0-9]','').ToLowerInvariant() }
    $agree = ((& $norm $read) -eq (& $norm $claimed))
    $rows += [pscustomobject]@{
      File = $f.Name; Claimed = $claimed; Read = $read; Agree = $agree
      Seconds = $best.Group[0].Seconds; Hits = $best.Count; Frame = $best.Group[0].Frame
    }
    Write-Output ("  {0,-6} {1,-34} claims '{2}'  reads '{3}'  (@{4}s, {5} frame(s))" -f `
      $(if ($agree) { 'OK' } else { 'DIFFER' }), ($stem -replace '^.*- (S\d+E\d+).*$','$1'), $claimed, $read, $best.Group[0].Seconds, $best.Count)
  } else {
    $rows += [pscustomobject]@{ File = $f.Name; Claimed = $claimed; Read = ''; Agree = $false; Seconds = -1; Hits = 0; Frame = '' }
    Write-Output ("  {0,-6} {1,-34} claims '{2}'  NO CAPTION READ - widen the window or look by hand" -f 'UNREAD', ($stem -replace '^.*- (S\d+E\d+).*$','$1'), $claimed)
  }

  if (-not $KeepFrames) {
    Get-ChildItem -LiteralPath $work -Filter 'f*.png' | Where-Object { $_.FullName -ne $(if ($best) { $best.Group[0].Frame } else { '' }) } |
      Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $work -Filter '*.txt' | Remove-Item -Force -ErrorAction SilentlyContinue
  }
}

$csv = Join-Path $OutDir 'title-cards.csv'
$rows | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
Write-Output ""
Write-Output ("{0} file(s): {1} agree, {2} DIFFER, {3} unread -> {4}" -f $rows.Count,
  @($rows | Where-Object { $_.Agree }).Count,
  @($rows | Where-Object { -not $_.Agree -and $_.Read }).Count,
  @($rows | Where-Object { -not $_.Read }).Count, $csv)
exit 0
