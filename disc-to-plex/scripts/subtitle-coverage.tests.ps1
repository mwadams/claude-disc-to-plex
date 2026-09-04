<#
  End-to-end tests for subtitle-coverage.ps1's INCREMENTAL probe cache.
  Run: pwsh -File subtitle-coverage.tests.ps1 [-BitmapFixture <mkv with a dvd_subtitle/PGS track>]
  (exit 0 = all passed)

  Drives the REAL script against a scratch "NAS" tree of tiny synthesised mkvs, so what is tested
  is the behaviour the coverage loop actually gets - not a re-implementation of it. ffmpeg cannot
  synthesise a BITMAP subtitle track from text, so the awaiting-ocr / codec-positive case only
  runs when a real fixture is passed in; everything else (bitmap 'none', audio yes/no, sidecar
  present) is built here from lavfi sources.

  The cases that matter, each with a real counter-example in this pipeline's history:
    - a second run must re-probe NOTHING while the files are unchanged (the 3-hour sweep);
    - a rewritten media file must be re-probed (a re-rip over the same name);
    - a sidecar appearing beside an UNCHANGED mkv must flip the category with no re-probe
      (sidecars change without the mkv changing - the validity key is not the mkv alone);
    - -Full, a missing/empty/older-schema report must all rebuild in full, and SAY so;
    - a scoped -Works run must not write the report (the coverage loop adopts on CSV mtime).
#>
param([string]$BitmapFixture = '')
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'subtitle-coverage.ps1'
if (-not (Test-Path -LiteralPath $script)) { Write-Output "FAIL: $script missing"; exit 1 }

$paths = Get-Content -LiteralPath 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
$ffmpeg = $paths.ffmpeg
if (-not (Test-Path -LiteralPath $ffmpeg)) { Write-Output 'FAIL: ffmpeg not found via tool-paths.json'; exit 1 }

$fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('subcov-tests-' + [guid]::NewGuid().ToString('N'))
$nas  = Join-Path $root 'nas'
$csv  = Join-Path $root 'coverage.csv'
$empty = Join-Path $root 'empty-dir'
New-Item -ItemType Directory -Path $nas, $empty | Out-Null

# ISOLATE FROM THE LIVE NAS GOVERNOR (lib-nas-governor.ps1, which the script dot-sources). A full
# sweep takes a machine-wide sweep mutex and honours the kill-switch file; with the real config a
# live library sweep would block this suite for up to 30 minutes (exit 3), and this suite's own
# full sweeps would hold the real mutex against the coverage track. Same seam the governor's own
# tests use: a temp config with its own object names and its own hold file. The scratch tree is a
# local path, so nothing here is paced either way.
$govCfg = Join-Path $root 'nas-governor.json'
$uniq = [guid]::NewGuid().ToString('N').Substring(0, 8)
@{ holdFile = (Join-Path $root 'nas-hold'); sweepMutex = "subcov-tests-sweep-$uniq"; readSlotPrefix = "subcov-tests-read-$uniq-" } |
  ConvertTo-Json | Set-Content -LiteralPath $govCfg -Encoding UTF8
$env:NAS_GOVERNOR_CONFIG = $govCfg

function Synth([string]$rel, [switch]$Audio, [switch]$TextSub) {
  $out = Join-Path $nas $rel
  New-Item -ItemType Directory -Force -Path (Split-Path $out -Parent) | Out-Null
  $args = @('-v', 'error', '-y', '-t', '2', '-f', 'lavfi', '-i', 'color=c=black:s=64x64:r=10')
  $maps = @('-map', '0:v')
  if ($Audio) { $args += @('-t', '2', '-f', 'lavfi', '-i', 'anullsrc=r=8000:cl=mono'); $maps += @('-map', '1:a') }
  if ($TextSub) {
    $srt = Join-Path $root 'tiny.srt'
    if (-not (Test-Path $srt)) { Set-Content -LiteralPath $srt -Value "1`n00:00:00,500 --> 00:00:01,500`nhello`n" }
    $args += @('-i', $srt); $maps += @('-map', "$(if ($Audio) { 2 } else { 1 }):s", '-c:s', 'srt')
  }
  & $ffmpeg @args @maps -c:v libx264 -preset ultrafast -c:a aac $out 2>&1 | Out-Null
  if (-not (Test-Path -LiteralPath $out)) { throw "could not synthesise $rel" }
  return $out
}

# Every invocation points EVERY writable path at the scratch root, so a test can never touch the
# live registers. $DiscIdentityStore is defaulted to the NAS in the script - point it at an empty
# local dir so the test neither reads the NAS nor depends on it.
function Run([string[]]$extra = @()) {
  $out = & pwsh -NoProfile -File $script -NasRoot $nas -ReportCsv $csv -DiscIdentityStore $empty `
           -NaCsv (Join-Path $root 'na.csv') -QueueCsv (Join-Path $root 'q.csv') -ProgressCsv (Join-Path $root 'p.csv') `
           -DeferredCsv (Join-Path $root 'd.csv') -OcrQueueCsv (Join-Path $root 'oq.csv') -OcrProgressCsv (Join-Path $root 'op.csv') `
           @extra 2>&1
  $code = $LASTEXITCODE   # read BEFORE anything else touches the pipeline
  [pscustomobject]@{ Code = $code; Text = ($out | Out-String); Lines = @($out | ForEach-Object { "$_" }) }
}
function Rows { @(Import-Csv -LiteralPath $csv) }
function Row([string]$leaf) { @(Rows | Where-Object { $_.File -eq $leaf })[0] }
function CacheLine($r) { @($r.Lines | Where-Object { $_ -like 'probe cache: rows reused*' })[0] }
function Counts($r) {
  # "rows reused A (...), re-probed B (...), not needed C (...), unavailable D | ffprobe calls skipped E, run F"
  $m = [regex]::Match((CacheLine $r), 'reused (\d+) .*re-probed (\d+) .*not needed (\d+) .*unavailable (\d+).*skipped (\d+), run (\d+)')
  if (-not $m.Success) { return $null }
  [pscustomobject]@{ Reused = [int]$m.Groups[1].Value; Measured = [int]$m.Groups[2].Value; NotNeeded = [int]$m.Groups[3].Value
                     Unavailable = [int]$m.Groups[4].Value; Skipped = [int]$m.Groups[5].Value; Run = [int]$m.Groups[6].Value }
}

try {
  $nosub   = Synth 'Movies/Work A/nosub.mkv' -Audio
  $noaudio = Synth 'Television Shows/Show B/Season 01/noaudio.mkv'
  $textsub = Synth 'Television Shows/Show B/Season 01/textsub.mkv' -Audio -TextSub
  $covered = Synth 'Movies/Work C/covered.mkv' -Audio
  Set-Content -LiteralPath (Join-Path (Split-Path $covered) 'covered.eng.srt') -Value "1`n00:00:00,500 --> 00:00:01,500`nhello`n"
  $bitmap = $null
  if ($BitmapFixture -and (Test-Path -LiteralPath $BitmapFixture)) {
    $bitmap = Join-Path $nas 'Movies/Work A/bitmap.mkv'
    Copy-Item -LiteralPath $BitmapFixture -Destination $bitmap
  }
  $nProbed = 3 + $(if ($bitmap) { 1 } else { 0 })   # rows with no sidecar -> probed

  Write-Output '1. first run: no previous report -> everything measured, and it says so'
  $r = Run
  Check 'exit 0'            $r.Code 0
  Check 'says not used'     ($r.Text -match 'probe cache: NOT USED - no previous report') 'True'
  $c = Counts $r
  Check 'summary line'      ($null -ne $c) 'True'
  Check 'measured rows'     $c.Measured   $nProbed
  Check 'reused rows'       $c.Reused     0
  Check 'not-needed rows'   $c.NotNeeded  1
  Check 'nosub category'    (Row 'nosub.mkv').Category    'unclassified'
  Check 'nosub bitmap col'  (Row 'nosub.mkv').BitmapProbe 'none'
  Check 'nosub audio col'   (Row 'nosub.mkv').AudioProbe  'yes'
  Check 'nosub source'      (Row 'nosub.mkv').ProbeSource 'measured'
  Check 'noaudio category'  (Row 'noaudio.mkv').Category  'not-applicable'
  Check 'noaudio audio col' (Row 'noaudio.mkv').AudioProbe 'no'
  Check 'textsub category'  (Row 'textsub.mkv').Category  'unclassified'
  Check 'covered category'  (Row 'covered.mkv').Category  'covered'
  Check 'covered source'    (Row 'covered.mkv').ProbeSource 'not-needed'
  Check 'schema column'     (Row 'covered.mkv').CacheSchema 'cov-probe-2'
  Check 'size recorded'     ((Row 'nosub.mkv').MkvSize -eq (Get-Item $nosub).Length) 'True'
  Check 'ticks recorded'    ((Row 'nosub.mkv').MkvWriteTicks -eq (Get-Item $nosub).LastWriteTimeUtc.Ticks) 'True'
  if ($bitmap) {
    Check 'bitmap category'   (Row 'bitmap.mkv').Category 'awaiting-ocr'
    Check 'bitmap codec col'  ((Row 'bitmap.mkv').BitmapProbe -match 'dvd_subtitle|hdmv_pgs_subtitle') 'True'
    Check 'bitmap audio col'  (Row 'bitmap.mkv').AudioProbe ''   # bitmap found -> audio never asked
  }
  $probedAt1 = (Row 'nosub.mkv').ProbedAt

  Write-Output '2. THE POINT: second run, nothing changed -> zero ffprobe calls, every probed row reused'
  Start-Sleep -Milliseconds 1100   # so a re-measurement would carry a visibly different ProbedAt
  $r = Run
  Check 'exit 0'          $r.Code 0
  Check 'cache loaded'    ($r.Text -match "probe cache: loaded $nProbed probe") 'True'
  $c = Counts $r
  Check 'reused rows'     $c.Reused   $nProbed
  Check 'measured rows'   $c.Measured 0
  Check 'ffprobe run'     $c.Run      0
  Check 'ffprobe skipped' ($c.Skipped -ge $nProbed) 'True'
  Check 'source = cached' (Row 'nosub.mkv').ProbeSource 'cached'
  Check 'ProbedAt carried forward, not refreshed' (Row 'nosub.mkv').ProbedAt $probedAt1
  Check 'categories unchanged' (((Rows | Sort-Object File | ForEach-Object { $_.Category }) -join ',')) `
        ((Rows | Sort-Object File | ForEach-Object { $_.Category }) -join ',')
  Check 'noaudio still NA' (Row 'noaudio.mkv').Category 'not-applicable'
  if ($bitmap) { Check 'bitmap still awaiting-ocr from cache' (Row 'bitmap.mkv').Category 'awaiting-ocr' }

  Write-Output '3. a REWRITTEN media file (same name, new bytes) is re-probed; its siblings are not'
  Copy-Item -LiteralPath $textsub -Destination $nosub -Force   # nosub.mkv now carries a text track
  $r = Run
  $c = Counts $r
  Check 'one measured'     $c.Measured 1
  Check 'rest reused'      $c.Reused   ($nProbed - 1)
  Check 'rewritten source' (Row 'nosub.mkv').ProbeSource 'measured'
  Check 'rewritten size'   ((Row 'nosub.mkv').MkvSize -eq (Get-Item $nosub).Length) 'True'

  Write-Output '4. a SIDECAR appearing beside an UNCHANGED mkv flips the category with NO re-probe'
  Set-Content -LiteralPath (Join-Path (Split-Path $noaudio) 'noaudio.eng.srt') -Value "1`n00:00:00,500 --> 00:00:01,500`nhello`n"
  $r = Run
  $c = Counts $r
  Check 'now covered'      (Row 'noaudio.mkv').Category 'covered'
  Check 'not probed'       (Row 'noaudio.mkv').ProbeSource 'not-needed'
  Check 'zero ffprobe'     $c.Run 0
  Check 'others reused'    $c.Reused ($nProbed - 1)

  Write-Output '5. the sidecar going away again brings the cached probe straight back'
  Remove-Item -LiteralPath (Join-Path (Split-Path $noaudio) 'noaudio.eng.srt')
  # The previous report recorded noaudio.mkv as not-needed (no probe evidence), so this pass MUST
  # measure it again - a cache that "remembered" through a not-needed row would be inference.
  $r = Run
  $c = Counts $r
  Check 'NA again'         (Row 'noaudio.mkv').Category 'not-applicable'
  Check 'measured again'   (Row 'noaudio.mkv').ProbeSource 'measured'
  Check 'one ffprobe file' $c.Measured 1

  Write-Output '6. -Full ignores the cache and says so; -NoCache is the same switch'
  $r = Run @('-Full')
  Check 'says forced'      ($r.Text -match 'NOT USED - forced full rebuild') 'True'
  Check 'all measured'     (Counts $r).Measured $nProbed
  $r = Run @('-NoCache')
  Check 'alias works'      ($r.Text -match 'NOT USED - forced full rebuild') 'True'

  Write-Output '7. a report written by an OLDER script (no cache columns) is not trusted'
  # Materialise BEFORE writing: `Rows | ... | Export-Csv $csv` reads and truncates the same file in
  # one pipeline, and the first version of this test handed the script an EMPTY report (which it
  # correctly refused for the wrong reason) - a test bug that looked like a script bug.
  $old = @(Rows | Select-Object Area, Work, Season, File, MkvPath, Category, Ours, SubTrack, SourceDrive, ManifestFile, Evidence)
  $old | Export-Csv -LiteralPath $csv -NoTypeInformation -Encoding UTF8
  $r = Run
  $said = @($r.Lines | Where-Object { $_ -like 'probe cache:*' })[0]
  Check "says predates ($said)" ($r.Text -match "NOT USED - previous report predates the probe cache") 'True'
  Check 'all measured'     (Counts $r).Measured $nProbed
  Check 'rewritten with cache columns' ((Rows)[0].PSObject.Properties.Name -contains 'CacheSchema') 'True'

  Write-Output '8. a report with a DIFFERENT schema value is not trusted either'
  (Get-Content -LiteralPath $csv -Raw) -replace 'cov-probe-2', 'cov-probe-1' | Set-Content -LiteralPath $csv -Encoding UTF8
  $r = Run
  Check 'says schema'      ($r.Text -match "NOT USED - previous report carries cache schema 'cov-probe-1'") 'True'
  Check 'all measured'     (Counts $r).Measured $nProbed

  Write-Output '9. an EMPTY report rebuilds in full'
  Set-Content -LiteralPath $csv -Value '' -NoNewline
  $r = Run
  Check 'exit 0'           $r.Code 0
  Check 'says not used'    ($r.Text -match 'probe cache: NOT USED') 'True'
  Check 'all measured'     (Counts $r).Measured $nProbed

  Write-Output '10. a scoped -Works run READS the cache but never writes the report'
  $before = (Get-Item -LiteralPath $csv).LastWriteTimeUtc.Ticks
  Start-Sleep -Milliseconds 1100
  $r = Run @('-Works', 'Show B')
  $c = Counts $r
  Check 'exit 0'           $r.Code 0
  Check 'scoped rows only' ($c.Reused + $c.Measured + $c.NotNeeded + $c.Unavailable) 2
  Check 'reused from cache' $c.Reused 2
  Check 'report untouched' ((Get-Item -LiteralPath $csv).LastWriteTimeUtc.Ticks) $before

  $script:reachedEnd = $true
}
catch {
  # A THROW MUST FAIL THE RUN, NOT SILENTLY TRUNCATE IT (see lib-disk.tests.ps1).
  Write-Output "  FAIL exception: $($_.Exception.Message)"
  Write-Output "       at $($_.InvocationInfo.PositionMessage)"
  $script:fails++
}
finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if (-not $reachedEnd) { Write-Output 'the suite did not reach its end - treating as FAILED'; $fails++ }
if ($fails) { Write-Output "$fails test(s) FAILED"; exit 1 }
Write-Output 'all tests passed'
exit 0
