# Subtitle OCR campaign runner.
#
# Works through D:\video\_subs-survey.csv, converting bitmap subtitle tracks to sidecar SRTs on
# the NAS. Sidecar mode is CREATE-ONLY: it never rewrites or deletes the media, so it cannot
# collide with the E:/NAS protection guard.
#
# Offset is deliberately left at 0 - see ocr-subtitles.ps1 for why (Plex has a per-playback
# offset control for text subs; baking one in removes the viewer's choice).
#
#   pwsh -File D:\video\_ocr-batch.ps1 -Kind Film -Format pgs
#   pwsh -File D:\video\_ocr-batch.ps1 -Kind Film -Format dvd -Limit 20

param(
  [ValidateSet('Film','TV','All')][string]$Kind = 'Film',
  [ValidateSet('pgs','dvd','all')][string]$Format = 'all',
  [int]$Limit = 0,
  [switch]$IncludeLegacyMp4,
  # Pass the track guard's documented override down to ocr-subtitles.ps1.
  #
  # The guard refuses a hand-run of ocr-subtitles.ps1 while an OCR track is alive, because
  # the loop is stateless and a second worker DUPLICATES its work rather than sharing it -
  # two writers raced on one sidecar on 2026-08-23. That reasoning is about the LOCAL tree:
  # _ocr-loop.ps1 scans D:\video\Movies and D:\video\Television Shows. THIS script only ever
  # touches \\NASTEAMV\Multimedia, so the two work lists are disjoint and cannot collide.
  # Without this passthrough every single file here is refused and the campaign cannot run.
  # Still leave it OFF by default, so the guard applies unless the operator asks for it.
  #
  # 🔴 SINCE 2026-09-04 THE GUARD ALSO SEES `_ocr-queue-loop.ps1`, AND THAT ONE IS NOT DISJOINT
  # FROM THIS SCRIPT - it drains _ocr-queue.csv, every row a \\NASTEAMV\Multimedia path, which is
  # exactly this script's tree. The disjointness argument above holds ONLY against the local loop.
  # So while the queue track is draining, -Manual here buys you the 2026-08-23 race back, on the
  # same sidecar, over SMB. Stop that track first (drop D:\video\_ocr-queue-loop.stop, which it
  # honours at a row boundary) rather than overriding past it.
  [switch]$Manual
)

$ErrorActionPreference = 'Continue'
$env:PATH = "C:\Program Files\Tesseract-OCR;$env:PATH"

$survey = 'D:\video\_subs-survey.csv'
$log    = 'D:\video\_ocr-progress.csv'
$ocr    = 'D:\video\.claude\skills\disc-to-plex\scripts\ocr-subtitles.ps1'
$films  = '\\NASTEAMV\Multimedia\Movies'
$tv     = '\\NASTEAMV\Multimedia\Television Shows'

$rows = Import-Csv $survey | Where-Object { $_.NeedsOcr -eq 'YES' }
if ($Kind   -ne 'All') { $rows = $rows | Where-Object { $_.Kind -eq $Kind } }
if ($Format -eq 'pgs') { $rows = $rows | Where-Object { $_.Codecs -like '*pgs*' } }
if ($Format -eq 'dvd') { $rows = $rows | Where-Object { $_.Codecs -like '*dvd_subtitle*' } }

# Legacy low-bitrate .mp4 rips are excluded by decision (2026-08-16). ocr-subtitles.ps1 can now
# read them - it remuxes the subtitle stream into a temporary mkv first - but their VOBSUB is
# degraded enough that the output is visibly error-prone (Bridge on the River Kwai came back with
# "Get to it" as "Ge to nut," and "sick list" as "sick fist"), whereas a proper DVD rip of the same
# vintage produces word-accurate prose. They keep their bitmap subtitles instead.
# Pass -IncludeLegacyMp4 to override.
if (-not $IncludeLegacyMp4) {
  $before = $rows.Count
  $rows = $rows | Where-Object { [IO.Path]::GetExtension($_.File) -eq '.mkv' }
  $dropped = $before - $rows.Count
  if ($dropped) { Write-Host "skipping $dropped non-mkv item(s) - see -IncludeLegacyMp4" -ForegroundColor Yellow }
}

# smallest first - fastest feedback, and the cheap wins land early
$rows = $rows | Sort-Object { [double]$_.SizeGB }
if ($Limit -gt 0) { $rows = $rows | Select-Object -First $Limit }

# resume support: skip anything already logged as done
$done = @{}
if (Test-Path $log) { Import-Csv $log | ForEach-Object { $done[$_.Path] = $_.Result } }

Write-Host "queue: $($rows.Count) item(s)"
$n = 0
foreach ($r in $rows) {
  $n++
  $dir = if ($r.Kind -eq 'Film') { Join-Path $films $r.Work } else { Join-Path (Join-Path $tv $r.Work) $r.Group }
  $file = Join-Path $dir $r.File

  if ($done.ContainsKey($file)) { Write-Host "[$n/$($rows.Count)] skip (done): $($r.Work)"; continue }
  if (-not (Test-Path -LiteralPath $file)) {
    Write-Host "[$n/$($rows.Count)] MISSING: $file" -ForegroundColor Yellow
    [pscustomobject]@{ Path=$file; Work=$r.Work; Result='missing' } | Export-Csv $log -Append -NoTypeInformation
    continue
  }

  Write-Host "[$n/$($rows.Count)] $($r.Work)  ($($r.SizeGB) GB)" -ForegroundColor Cyan
  # -NoProfile: avoids the Terminal-Icons half-written-theme Import-Clixml noise on concurrent
  # pwsh starts; ocr-subtitles.ps1 has no profile dependence (checked 2026-09-02).
  $ocrArgs = @('-NoProfile', '-File', $ocr, '-Path', $file, '-Mode', 'Sidecar')
  if ($Manual) { $ocrArgs += '-Manual' }
  $out = & pwsh @ocrArgs 2>&1
  $ok  = ($out | Select-String 'converted' | Select-Object -Last 1) -match '(\d+) converted'
  $res = if ($ok -and $Matches[1] -eq '1') { 'ok' } else { 'failed' }
  $out | Select-Object -Last 3 | ForEach-Object { "    $_" }

  [pscustomobject]@{ Path=$file; Work=$r.Work; Result=$res } | Export-Csv $log -Append -NoTypeInformation
}

Write-Host ""
Write-Host "BATCH DONE"
if (Test-Path $log) { Import-Csv $log | Group-Object Result | ForEach-Object { "  {0,-8} {1}" -f $_.Name, $_.Count } }
