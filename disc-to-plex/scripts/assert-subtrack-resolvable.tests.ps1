# Tests for assert-subtrack-resolvable.ps1 - the gate check that refuses `subTrack: "eng"` on a raw
# Blu-ray clip whose CLPI declares several comparable English subtitle streams (Moon, 2026-09-29).
#
# Hermetic: each case builds a fake BDMV tree with a SYNTHETIC CLPI (only the bytes lib-clpi.ps1's
# Get-ClpiStreamLangs reads) and an empty .m2ts, and points the check at a STUB ffprobe that answers
# from a per-clip JSON. No disc, no ffprobe, no staging - so the test outlives Moon's staging.
#
#   pwsh -File assert-subtrack-resolvable.tests.ps1      (exit 0 = all pass)

$ErrorActionPreference = 'Stop'
$assert = Join-Path $PSScriptRoot 'assert-subtrack-resolvable.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ("subtrack-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $root | Out-Null

# Stub ffprobe: answers the two queries the check makes, from <src>.stub.json =
# [ { "pid": 4608, "lang": "eng", "pkts": 7192 }, ... ]. Stream indexes start at 2 (video + audio
# first), and every line is printed TWICE, as ffprobe does for a .m2ts (program + streams).
$stub = Join-Path $root 'ffprobe-stub.ps1'
@'
$src = $args[-1]
$streams = @(Get-Content -LiteralPath "$src.stub.json" -Raw | ConvertFrom-Json)
$counting = $args -contains '-count_packets'
for ($pass = 0; $pass -lt 2; $pass++) {
  for ($i = 0; $i -lt $streams.Count; $i++) {
    if ($counting) { "{0},{1}" -f ($i + 2), $streams[$i].pkts }
    else { "{0},0x{1:x}" -f ($i + 2), [int]$streams[$i].pid }
  }
}
'@ | Set-Content -LiteralPath $stub -Encoding utf8

# A synthetic CLPI carrying only what Get-ClpiStreamLangs parses: 'HDMV', the ProgramInfo address at
# byte 12, one program, and one PG (coding type 0x90) entry per stream with its language.
function New-Clpi([string]$path, $streams) {
  $b = New-Object System.Collections.Generic.List[byte]
  [Text.Encoding]::ASCII.GetBytes('HDMV0200') | ForEach-Object { $b.Add($_) }
  0..3 | ForEach-Object { $b.Add(0) }                 # bytes 8-11
  $b.AddRange([byte[]](0, 0, 0, 20))                  # 12-15: ProgramInfo starts at byte 20
  0..3 | ForEach-Object { $b.Add(0) }                 # 16-19
  0..3 | ForEach-Object { $b.Add(0) }                 # 20-23: ProgramInfo length (unused)
  $b.Add(0)                                           # 24: reserved
  $b.Add(1)                                           # 25: number of programs
  0..5 | ForEach-Object { $b.Add(0) }                 # 26-31: SPN / PMT PID / ...
  $b.Add([byte]$streams.Count)                        # 32: number of streams
  $b.Add(0)                                           # 33
  foreach ($s in $streams) {
    $b.Add([byte](($s.pid -shr 8) -band 0xFF)); $b.Add([byte]($s.pid -band 0xFF))
    $b.Add(5)                                         # attribute length
    $b.Add(0x90)                                      # PG
    [Text.Encoding]::ASCII.GetBytes($s.lang) | ForEach-Object { $b.Add($_) }
    $b.Add(0)
  }
  [IO.File]::WriteAllBytes($path, $b.ToArray())
}

$n = 0
function New-Case([string]$name, $streams, [bool]$withClpi = $true) {
  $script:n++
  $disc = Join-Path $root "disc$script:n"
  New-Item -ItemType Directory -Path (Join-Path $disc 'BDMV/STREAM'), (Join-Path $disc 'BDMV/CLIPINF') -Force | Out-Null
  $src = Join-Path $disc 'BDMV/STREAM/00011.m2ts'
  New-Item -ItemType File -Path $src | Out-Null
  ConvertTo-Json -InputObject @($streams) | Set-Content -LiteralPath "$src.stub.json" -Encoding utf8
  if ($withClpi) { New-Clpi (Join-Path $disc 'BDMV/CLIPINF/00011.clpi') $streams }
  return ($src -replace '\\', '/')
}
function Run-Check($rows) {
  $m = Join-Path $root ("m{0}.json" -f [guid]::NewGuid().ToString('N').Substring(0, 6))
  ConvertTo-Json -InputObject @($rows) -Depth 5 | Set-Content -LiteralPath $m -Encoding utf8
  $out = & pwsh -NoProfile -File $assert -Manifest $m -Ffprobe $stub 2>&1
  return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
}

$moon = @(
  @{ pid = 0x1200; lang = 'eng'; pkts = 7192 }, @{ pid = 0x1201; lang = 'eng'; pkts = 7192 },
  @{ pid = 0x1202; lang = 'eng'; pkts = 8504 }, @{ pid = 0x1203; lang = 'zho'; pkts = 7184 },
  @{ pid = 0x1204; lang = 'hin'; pkts = 7312 }, @{ pid = 0x1205; lang = 'ind'; pkts = 7296 },
  @{ pid = 0x1206; lang = 'tha'; pkts = 7312 }, @{ pid = 0x1207; lang = 'eng'; pkts = 15340 },
  @{ pid = 0x1208; lang = 'eng'; pkts = 12210 })

$fail = 0
function Check([string]$label, $res, [int]$wantCode, [string]$wantText = '') {
  $ok = $res.Code -eq $wantCode -and (-not $wantText -or $res.Out -match [regex]::Escape($wantText))
  if ($ok) { Write-Output "PASS  $label" }
  else { Write-Output "FAIL  $label (exit $($res.Code), wanted $wantCode)`n$($res.Out)"; $script:fail++ }
}

# A. Moon's real declaration, subTrack "eng": five comparable English streams -> REFUSED, naming them.
$src = New-Case 'moon' $moon
Check 'A  five comparable English streams + "eng" is refused' (Run-Check @(@{ out = 'Moon (2009).mkv'; kind = 'BD'; src = $src; subTrack = 'eng' })) 2 's:0 (7192 pkts), s:1 (7192 pkts), s:2 (8504 pkts), s:7 (15340 pkts), s:8 (12210 pkts)'

# B. Same disc, subTrack ABSENT - transcode.ps1 reads an absent subTrack as "eng", so also refused.
Check 'B  absent subTrack on the same disc is refused' (Run-Check @(@{ out = 'Moon (2009).mkv'; kind = 'BD'; src = $src })) 2 '(absent = "eng")'

# C. Same disc, an explicit ordinal - the author's choice, passes.
Check 'C  explicit ordinal passes' (Run-Check @(@{ out = 'Moon (2009).mkv'; kind = 'BD'; src = $src; subTrack = 0 })) 0

# D. Same disc, "none" - an explicit decision, passes.
Check 'D  subTrack none passes' (Run-Check @(@{ out = 'Moon (2009).mkv'; kind = 'BD'; src = $src; subTrack = 'none' })) 0

# E. Friends S3 D1's shape: a populated English track beside an 8-packet forced-only one.
#    transcode.ps1 picks the dominant one, so the gate must NOT refuse it.
$src = New-Case 'friends' @(@{ pid = 0x1200; lang = 'jpn'; pkts = 3000 }, @{ pid = 0x1201; lang = 'eng'; pkts = 3120 }, @{ pid = 0x1202; lang = 'eng'; pkts = 8 })
Check 'E  one dominant English track (3120 vs 8) passes' (Run-Check @(@{ out = 'Friends.mkv'; kind = 'BD'; src = $src; subTrack = 'eng' })) 0

# F. A single English stream resolves unambiguously.
$src = New-Case 'single' @(@{ pid = 0x1200; lang = 'fra'; pkts = 900 }, @{ pid = 0x1201; lang = 'eng'; pkts = 950 })
Check 'F  a single English stream passes' (Run-Check @(@{ out = 'Single.mkv'; kind = 'BD'; src = $src; subTrack = 'eng' })) 0

# G. Two English streams, both under the 100-packet floor - transcode.ps1 will not pick either.
$src = New-Case 'thin' @(@{ pid = 0x1200; lang = 'eng'; pkts = 60 }, @{ pid = 0x1201; lang = 'eng'; pkts = 4 })
Check 'G  two thin English streams (60/4, under the floor) are refused' (Run-Check @(@{ out = 'Thin.mkv'; kind = 'BD'; src = $src; subTrack = 'eng' })) 2

# H. No CLPI - cannot measure, so nothing is refused.
$src = New-Case 'noclpi' $moon $false
Check 'H  no CLPI: unmeasurable, passes' (Run-Check @(@{ out = 'NoClpi.mkv'; kind = 'BD'; src = $src; subTrack = 'eng' })) 0

# I. A rip .mkv (not a raw BDMV clip) is out of scope.
$mkv = Join-Path $root 'rip.mkv'; New-Item -ItemType File -Path $mkv | Out-Null
Check 'I  a non-BDMV source is out of scope' (Run-Check @(@{ out = 'Rip.mkv'; kind = 'BD'; src = ($mkv -replace '\\', '/'); subTrack = 'eng' })) 0

# J. A ONE-ROW manifest (ConvertFrom-Json unwraps it) is still checked, not silently skipped.
$src = New-Case 'onerow' $moon
$one = Join-Path $root 'one.json'
'[{"out":"Moon (2009).mkv","kind":"BD","src":"' + $src + '","subTrack":"eng"}]' | Set-Content -LiteralPath $one -Encoding utf8
$o = & pwsh -NoProfile -File $assert -Manifest $one -Ffprobe $stub 2>&1
Check 'J  a one-row manifest is checked' ([pscustomobject]@{ Code = $LASTEXITCODE; Out = ($o -join "`n") }) 2

Remove-Item -LiteralPath $root -Recurse -Force
if ($fail) { Write-Output "$fail FAILED"; exit 1 }
Write-Output 'all assert-subtrack-resolvable tests passed'
exit 0
