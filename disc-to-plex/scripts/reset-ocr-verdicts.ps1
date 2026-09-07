<#
.SYNOPSIS
  Retire cached OCR verdicts that a CODE FIX has invalidated, so the OCR loop tries those files
  again instead of trusting a conclusion the old code reached.

.WHY THIS EXISTS
  2026-09-07, Moulin Rouge. The OCR of the feature came back at 9% function words, under the 15%
  floor, and Resolve-OcrOutcome recorded the PERMANENT verdict

      blocked:wrong-language subtitle track - disc mislabels it; needs a re-encode selecting the
      real English stream

  Every part of that sentence was wrong. Rendering the cues showed correct English SDH; ffprobe
  showed the disc carries exactly ONE eng subtitle stream and transcode.ps1 had selected it. The
  real fault was in our own OCR: Repair-VobSubPalette decided whether to merge the anti-alias into
  the fill from the first THREE decodable cues of the file, measured 0.143 against a 0.15
  threshold, and declined - where the whole-track figure is 0.217. seconv then isolated the
  anti-alias instead of the fill and turned 1,986 clean lines into "FES OSE t ys". With the
  sampling widened, the same track OCRs at 59%.

  So the verdict was an artefact of a defect, and it was recorded as permanent. The film sat
  unpublishable for five hours, blocking all 72 finished files of the work behind it, and it would
  have sat there forever: 'blocked' means stop retrying AND keep publish blocked, and nothing
  invalidates a cache entry when the code that produced it changes.

  THAT IS THE GAP THIS FILLS. A cached verdict is evidence about a FILE gathered by a particular
  VERSION of the OCR path. Fix the OCR path and the evidence is stale, not wrong-headed - but the
  cache cannot know that. This script is how a fix reaches back and retires what it invalidated.

  Scale as measured the day it was written: 2,563 cache entries, of which 178 said
  "wrong-language" and 12 said "dictionary gate rejected ... letters split" - the latter being
  literally the palette defect just fixed. Some of the 178 will be genuine foreign tracks. The
  point is not that they are all wrong; it is that the pipeline had no way to ASK again.

.HOW IT WORKS
  Cache entries are named for an MD5 of "fullpath|length|lastWriteUtcTicks" and carry no path, so
  they cannot be enumerated backwards. The only way to find the entry for a file is to walk the
  library and recompute the key - which is what this does. A file re-encoded since the verdict
  gets a different key anyway, so its old entry is already orphaned and harmless.

.NOTES
  DRY RUN BY DEFAULT. Nothing is cleared without -Apply. Clearing a verdict costs an OCR re-run
  (minutes of CPU per file on a self-draining track), never data: the media file is not touched,
  and a verdict the fix does NOT overturn is simply recorded again.

.EXAMPLE
  # what would be retired, and why - reads nothing but the cache and the file's own metadata
  pwsh -NoProfile -File reset-ocr-verdicts.ps1

.EXAMPLE
  # retire only the verdicts the palette-sampling fix speaks to
  pwsh -NoProfile -File reset-ocr-verdicts.ps1 -Verdict '*letters split*' -Apply

.EXAMPLE
  # a single file, by name
  pwsh -NoProfile -File reset-ocr-verdicts.ps1 -PathMatch 'Moulin Rouge' -Apply
#>
param(
  # Where to look for the media. Local library by default: the NAS is remote and a full walk of it
  # is a governed sweep, so pointing this at \\NASTEAMV\... must be a deliberate act, not a default.
  [string[]]$Root = @('D:/video/Movies', 'D:/video/Television Shows'),

  # Which verdicts to consider, as a wildcard against the cache entry's text. The default takes
  # every 'blocked' verdict and NOTHING else: 'populated' entries are a cache of real work,
  # 'empty' and 'exhausted' are positive findings about the media rather than about our OCR.
  [string]$Verdict = 'blocked:*',

  # Optional wildcard on the file path, for working a single title or one show.
  [string]$PathMatch = '*',

  # Without this the script only reports. With it, the matching cache entries are deleted.
  [switch]$Apply,

  [string]$CacheDir = (Join-Path $env:LOCALAPPDATA 'disc-to-plex\subcache')
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib-subtitles.ps1"

if (-not (Test-Path -LiteralPath $CacheDir)) {
  Write-Output "reset-ocr-verdicts: no cache at $CacheDir - nothing to retire"
  exit 0
}

$roots = @($Root | Where-Object { Test-Path -LiteralPath $_ })
if (-not $roots.Count) {
  Write-Output ("reset-ocr-verdicts: none of the given root(s) exist: {0}" -f ($Root -join ', '))
  exit 0
}

Write-Output ("reset-ocr-verdicts: walking {0} root(s) for .mkv" -f $roots.Count)
$files = @($roots | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter *.mkv -File -Recurse -ErrorAction SilentlyContinue })
Write-Output ("   {0} media file(s) found; matching against verdict '{1}'" -f $files.Count, $Verdict)

$hits = @()
foreach ($f in $files) {
  if ($f.FullName -notlike $PathMatch) { continue }
  # Get-BitmapSubsCachePath stats the file, so a file that vanished mid-walk must not abort the run.
  try { $cache = Get-BitmapSubsCachePath -Path $f.FullName -CacheDir $CacheDir } catch { continue }
  if (-not (Test-Path -LiteralPath $cache)) { continue }
  $v = (Get-Content -LiteralPath $cache -Raw).Trim()
  if ($v -notlike $Verdict) { continue }

  # A file that ALREADY has a sidecar is not blocked by this verdict, whatever the verdict says.
  # Re-OCRing it would burn CPU to reproduce something we already have, so report it apart rather
  # than clearing it. (Not silently skipped: if a 'blocked' file has a sidecar, one of the two is
  # lying and someone should look.)
  $sidecar = [IO.Path]::ChangeExtension($f.FullName, '.eng.srt')
  $hits += [pscustomobject]@{
    File     = $f.FullName
    Cache    = $cache
    Verdict  = $v
    HasSrt   = (Test-Path -LiteralPath $sidecar)
  }
}

if (-not $hits.Count) {
  Write-Output "   no cached verdict matches - nothing to retire"
  exit 0
}

$clearable = @($hits | Where-Object { -not $_.HasSrt })
$withSrt   = @($hits | Where-Object { $_.HasSrt })

Write-Output ''
Write-Output ("MATCHED {0} file(s), by verdict:" -f $hits.Count)
$hits | Group-Object { ($_.Verdict -split ' - ')[0] } | Sort-Object Count -Descending |
  ForEach-Object { Write-Output ("   {0,4}  {1}" -f $_.Count, $_.Name) }

if ($withSrt.Count) {
  Write-Output ''
  Write-Output ("{0} of them ALREADY HAVE a sidecar - the verdict is not blocking them, so they are left alone:" -f $withSrt.Count)
  $withSrt | Select-Object -First 10 | ForEach-Object { Write-Output ("   {0}" -f $_.File) }
  if ($withSrt.Count -gt 10) { Write-Output ("   ... and {0} more" -f ($withSrt.Count - 10)) }
}

Write-Output ''
if (-not $Apply) {
  Write-Output ("DRY RUN - {0} verdict(s) would be retired, sending those files back to the OCR loop:" -f $clearable.Count)
  $clearable | Select-Object -First 25 | ForEach-Object { Write-Output ("   {0}" -f $_.File) }
  if ($clearable.Count -gt 25) { Write-Output ("   ... and {0} more" -f ($clearable.Count - 25)) }
  Write-Output ''
  Write-Output '   Re-run with -Apply to clear them. Each one costs an OCR attempt; a verdict the'
  Write-Output '   fix does not overturn is simply recorded again, so the downside is CPU, not data.'
  exit 0
}

$cleared = 0
foreach ($h in $clearable) {
  Remove-Item -LiteralPath $h.Cache -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $h.Cache)) { $cleared++ }
}
Write-Output ("RETIRED {0} of {1} verdict(s). Those files are now 'not tried yet' and the OCR loop will" -f $cleared, $clearable.Count)
Write-Output '   pick them up on its next pass. Watch _tail.ps1 ocr; publish unblocks per work as'
Write-Output '   every file of that work gains a sidecar or a fresh positive finding.'
exit 0
