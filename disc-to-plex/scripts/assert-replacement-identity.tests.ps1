<#
.SYNOPSIS
  Tests for assert-replacement-identity.ps1, against a scratch catalogue and a scratch "library".
  Transcription is stubbed (-SampleStub), so the suite is deterministic and needs no audio.
  Exit 0 = all passed.
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'assert-replacement-identity.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('ari-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fail = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { Write-Host "  PASS  $name" } else { $script:fail++; Write-Host "  FAIL  $name $detail" }
}

# Distinct vocabularies, 20 words each, so an episode's text is unmistakable.
$vocab = @{
  E01 = 'lighthouse keeper storm harbour lantern fisherman trawler anchor seagull cliffs keys count beacon tide shipwreck oilskin rowing compass driftwood gale'
  E02 = 'embassy passport diplomat cipher attache ambassador visa consulate treaty courier envelope typewriter telegram protocol summit minister delegation interpreter garrison frontier'
  E03 = 'orchestra violin conductor rehearsal symphony cellist trombone overture podium baton soprano libretto concerto encore auditorium tuning clarinet percussion maestro sonata'
  E05 = 'volcano geologist magma crater eruption lava sulphur tremor seismograph caldera pumice obsidian basalt fissure vent ashcloud summit helicopter evacuation glacier'
  E06 = 'bakery sourdough croissant oven flour yeast pastry baguette dough apron rolling icing ganache meringue souffle brioche crumble kneading whisk tartlet'
  THEME = 'singing along chorus melody refrain harmony humming lyrics tambourine jingle banjo whistling rhythm dancing clapping cheerful ukulele serenade ballad anthem'
}
function Words([string]$k, [int]$from, [int]$n) { (($vocab[$k] -split ' ')[$from..($from + $n - 1)]) -join ' ' }

try {
  $cat = Join-Path $root 'cat'; $nas = Join-Path $root 'nas'; $q = Join-Path $root 'q'
  $season = Join-Path $nas 'Television Shows/Test Show (2001)/Season 01'
  New-Item -ItemType Directory -Force -Path $cat, $season, (Join-Path $q '_queue') | Out-Null
  New-Item -ItemType Directory -Force -Path (Join-Path $nas 'Television Shows/Test Show (2001)/Season 00') | Out-Null
  foreach ($e in 'E01', 'E02', 'E03', 'E06') {
    $base = Join-Path $season "Test Show (2001) - S01$e - Title"
    Set-Content -LiteralPath "$base.mkv" -Value 'x'
    # Cues at 70 s, 310 s and 550 s, each carrying the episode's whole vocabulary.
    $srt = @(); $i = 1
    foreach ($s in 70, 310, 550) { $srt += "$i`r`n00:{0:D2}:{1:D2},000 --> 00:{0:D2}:{2:D2},000`r`n{3}`r`n" -f [int][math]::Floor($s / 60), ($s % 60), (($s % 60) + 5), $vocab[$e]; $i++ }
    Set-Content -LiteralPath "$base.eng.srt" -Value ($srt -join "`r`n")
  }

  function New-Disc([string]$disc, [string[]]$rows, [hashtable]$samples, [hashtable]$stubs) {
    $titles = @(foreach ($k in $samples.Keys) {
      [ordered]@{ title = [int]$k; duration = '0:30:00'; speechStatus = 'ok'; speechSample = "[en 1.00] $($samples[$k].Text)"
                  speechFrom = "disc=D:/stage/$disc|dvdvideoTitle=$($samples[$k].Dv)|offset=60s|wav=x" }
    })
    Set-Content -LiteralPath (Join-Path $cat "$disc.catalogue.json") -Value (@{ titles = $titles } | ConvertTo-Json -Depth 5)
    Set-Content -LiteralPath (Join-Path $cat "$disc.dispositions.txt") -Value (@("# $disc", "# library: \\NAS\Multimedia\Television Shows\Test Show (2001)\Season 01\x.mkv") + $rows)
    $stubPath = Join-Path $root "$disc.stub.json"
    Set-Content -LiteralPath $stubPath -Value ($stubs | ConvertTo-Json)
    return $stubPath
  }
  function Run([string]$disc, [string]$stubPath) {
    $o = @(& pwsh -NoProfile -File $script -Disc $disc -Catalogue $cat -NasRoot $nas -LocalRoot (Join-Path $root 'nolocal') -QueueRoot $q -SampleStub $stubPath 2>&1 | ForEach-Object { "$_" })
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = $o; Text = ($o -join "`n") }
  }

  Write-Host 'replacement identity - refusal case'
  $stubA = New-Disc 'Disc A' @(
    't01|episode|S01E01 Lighthouse|speech:x',
    't02|episode|S01E02 Embassy|speech:x',
    't03|episode|S01E03 Orchestra|speech:x',
    't04|episode|S01E09 Not In Library|speech:x'
  ) @{
    '1' = @{ Dv = 1; Text = (Words E01 0 16) }
    '2' = @{ Dv = 2; Text = (Words E05 0 16) }     # really an unpublished episode
    '3' = @{ Dv = 3; Text = (Words THEME 0 16) }   # the stored sample caught the theme song
    '4' = @{ Dv = 4; Text = (Words E06 0 16) }
  } @{
    'dv2@300' = (Words E05 4 14); 'dv2@540' = (Words E05 2 15)
    'dv3@300' = (Words E03 0 16)
  }
  $r = Run 'Disc A' $stubA
  Check 'a wrong claim on a published episode refuses (exit 2)' ($r.Code -eq 2) "exit $($r.Code)`n$($r.Text)"
  Check 'the refused row is t02, as MISMATCH over 3 samples' ($r.Text -match 'MISMATCH\s+t02 S01E02 - NOT THE PUBLISHED EPISODE: 3 independent samples')
  Check 'a right claim matches' ($r.Text -match 'MATCH\s+t01 S01E01')
  Check 'a theme-song sample does not refuse; a fresh sample settles it' ($r.Text -match 'MATCH\s+t03 S01E03 - @60s .*@300s')
  Check 'an episode the library lacks is NEW, not a replacement' ($r.Text -match 'NEW\s+t04 S01E09')
  Check 'a sample containing "count" and "keys" still counts words' ($r.Text -match 'MATCH\s+t01 S01E01 - @60s 16/16 words')

  Write-Host 'replacement identity - no refusal cases'
  $stubB = New-Disc 'Disc B' @(
    't01|episode|S01E01 Lighthouse|speech:x',
    't02|episode|S01E02 Embassy|duration:catalogue guessed dv1 - BYTE PROOF shows this title is dv7',
    't03|episode|S01E06 Bakery|speech:x',
    't04|extra|Deleted scene - companion to the S01E02 plot (proposed S00E01)|frame:x'
  ) @{
    '1' = @{ Dv = 1; Text = (Words E01 0 16) }
    '2' = @{ Dv = 1; Text = (Words E01 2 16) }     # sampled from the wrong title
    '3' = @{ Dv = 3; Text = (Words E01 1 16) }     # sampled from t01's title, no correction written
    '4' = @{ Dv = 4; Text = (Words E02 0 16) }
  } @{
    'dv7@60' = (Words E02 0 16)
    'dv3@300' = (Words E01 3 15); 'dv3@540' = (Words E01 0 14)
  }
  $r = Run 'Disc B' $stubB
  Check 'no refusal when nothing is wrong or unproven (exit 0)' ($r.Code -eq 0) "exit $($r.Code)`n$($r.Text)"
  Check 'a byte-proven "this title is dvN" sets the stored sample aside and samples title N' ($r.Text -match 'MATCH\s+t02 S01E02 - stored sample set aside \(dispositions prove this title is dvdvideo 7\)')
  Check 'a title that pooled-matches ANOTHER claimed episode is CROSSED, not refused' ($r.Text -match 'INCONCLUSIVE t03 S01E06 - CROSSED: this row''s sample matches t01 S01E01')
  Check 'an extra''s "proposed S00Exx" is its claim, not the episode it mentions' ($r.Text -match 'NEW\s+t04 S00E01')
  Check 'show resolved from the dispositions, not the folder name' ($r.Text -match '\(from named in the dispositions\)')

  Write-Host 'replacement identity - cannot run'
  $r = [pscustomobject]@{ Code = 0 }
  & pwsh -NoProfile -File $script -Disc 'No Such Disc' -Catalogue $cat -NasRoot $nas -QueueRoot $q *> $null
  Check 'missing dispositions exits 3' ($LASTEXITCODE -eq 3)
}
finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($fail) { Write-Host "$fail test(s) FAILED"; exit 1 }
Write-Host 'all tests passed'
exit 0
