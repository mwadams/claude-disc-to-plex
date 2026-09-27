<#
  Tests for sweep-drive.ps1's per-disc enumeration cache (D:/video/_disc-info/<name>.txt).

  Run: pwsh -File sweep-drive.tests.ps1   (exit 0 = all passed)

  THE DEFECT UNDER TEST (2026-09-27, media5): the cache dump is keyed by FOLDER NAME ALONE, and was
  reused whenever a file existed at that path - so a disc on a NEW drive whose folder name happens to
  match a disc on an EARLIER drive silently inherited the earlier disc's enumeration and was never
  actually read. Measured: "The Prisoner Disk 1" / "Disk 2" on media5 are the 2009 remake, but their
  cache files were reused from media0's 1967 series discs of the same folder names.

  THE FIX: every dump now carries a leading '# source-identity: <sig>' line (the disc's dvdid.xml
  <ID> when present, else a file-count+bytes folder fingerprint), and is reused only when that line
  matches the disc being swept right now. A dump with no such line (pre-fix / legacy) or a mismatching
  one is unverified and is re-enumerated.

  Drives the REAL script against scratch "drive" folders and a FAKE MakeMKV (a .ps1 stand-in passed
  via -MakeMkv, invoked exactly as the real script invokes it) so what is tested is the script's own
  cache-validity logic, not a re-implementation of it. Touches nothing on E:, the NAS, or the optical
  drive - Drive/Cache/Store/MakeMkv are all redirected into a scratch root under the system temp dir.
#>
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'sweep-drive.ps1'
if (-not (Test-Path -LiteralPath $script)) { Write-Output "FAIL: $script missing"; exit 1 }

$fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}
function CheckTrue($name, [bool]$cond) {
  if ($cond) { Write-Output "  ok   $name" } else { Write-Output "  FAIL $name"; $script:fails++ }
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('sweepdrive-tests-' + [guid]::NewGuid().ToString('N'))
$cache = Join-Path $root 'disc-info'
$store = Join-Path $root 'disc-identity'
New-Item -ItemType Directory -Path $root, $cache, $store | Out-Null

# ---- fake MakeMKV: a .ps1 the call operator invokes exactly like the real exe, minus the drive ----
$fakeLog = Join-Path $root 'fake-makemkv-calls.log'
New-Item -ItemType File -Path $fakeLog | Out-Null
$fakeMakeMkv = Join-Path $root 'fake-makemkv.ps1'
@'
$fileArg = $args | Where-Object { "$_".StartsWith("file:") } | Select-Object -First 1
$src = "$fileArg".Substring(5)
Add-Content -LiteralPath $env:FAKE_MAKEMKV_LOG -Value $src
$prof = "default"
$pf = Join-Path $src "profile.txt"
if (Test-Path -LiteralPath $pf) { $prof = (Get-Content -LiteralPath $pf -Raw).Trim() }
if ($prof -eq "B") {
  Write-Output 'TINFO:0,9,0,"0:45:00"'
  Write-Output 'TINFO:0,11,0,"9000000000"'
  Write-Output 'SINFO:0,0,1,0,"Audio"'
} else {
  Write-Output 'TINFO:0,9,0,"0:10:00"'
  Write-Output 'TINFO:0,11,0,"1000000000"'
  Write-Output 'SINFO:0,0,1,0,"Audio"'
  Write-Output 'SINFO:0,1,1,0,"Subtitles"'
  Write-Output 'SINFO:0,1,4,0,"eng"'
}
'@ | Set-Content -LiteralPath $fakeMakeMkv -Encoding UTF8
$env:FAKE_MAKEMKV_LOG = $fakeLog

function CallCount { @(Get-Content -LiteralPath $fakeLog -ErrorAction SilentlyContinue).Count }

function Run([string]$drive, [string]$label, [string]$report) {
  $out = & pwsh -NoProfile -File $script -Drive $drive -Label $label -Store $store -Cache $cache `
           -MakeMkv $fakeMakeMkv -Report $report 2>&1
  $code = $LASTEXITCODE
  [pscustomobject]@{ Code = $code; Text = ($out | Out-String) }
}

Write-Output '--- test 1: same disc name, different content on two drives -> NOT reused, both enumerated correctly ---'
$driveA = Join-Path $root 'driveA'; $discA = Join-Path $driveA 'The Prisoner Disk 1'
$driveB = Join-Path $root 'driveB'; $discB = Join-Path $driveB 'The Prisoner Disk 1'   # SAME folder name
New-Item -ItemType Directory -Path $discA, $discB | Out-Null
Set-Content -LiteralPath (Join-Path $discA 'profile.txt') -Value 'A'
Set-Content -LiteralPath (Join-Path $discA 'padding.bin') -Value ('x' * 100)
Set-Content -LiteralPath (Join-Path $discB 'profile.txt') -Value 'B'
Set-Content -LiteralPath (Join-Path $discB 'padding.bin') -Value ('y' * 999)   # different size -> different folder fingerprint

$reportA = Join-Path $root 'sweep-A.csv'
$r1 = Run $driveA 'testA' $reportA
CheckTrue 'run A exits 0' ($r1.Code -eq 0)
Check 'run A calls fake MakeMKV once' (CallCount) 1
$rowsA = @(Import-Csv -LiteralPath $reportA)
Check 'run A: one row' $rowsA.Count 1
Check 'run A: subtitle streams (profile A = has subs)' $rowsA[0].SubtitleStreams '1'

$reportB = Join-Path $root 'sweep-B.csv'
$r2 = Run $driveB 'testB' $reportB
CheckTrue 'run B exits 0' ($r2.Code -eq 0)
# THE ACTUAL DEFECT: pre-fix this stayed at 1 (cache reused by name), and run B's row would carry
# profile A's data despite being a different disc.
Check 'run B calls fake MakeMKV again (cache NOT reused across differing content)' (CallCount) 2
$rowsB = @(Import-Csv -LiteralPath $reportB)
Check 'run B: one row' $rowsB.Count 1
Check 'run B: subtitle streams (profile B = no subs)' $rowsB[0].SubtitleStreams '0'
CheckTrue 'run A and run B got DIFFERENT DiscIds' ($rowsA[0].DiscId -ne $rowsB[0].DiscId)

Write-Output '--- test 2: re-running the SAME drive/disc reuses the cache (no re-enumeration) ---'
# A DIFFERENT disc name from test 1's, deliberately: once test 1 runs driveB's "The Prisoner Disk 1"
# through the shared cache, that slot legitimately holds driveB's signature (whichever disc was last
# swept there) - re-sweeping driveA's disc of the same name SHOULD re-enumerate, and does (that is
# the fix working, not a bug). This test isolates the "nothing changed" case on its own cache slot.
$driveD = Join-Path $root 'driveD'; $discD = Join-Path $driveD 'Stable Disc 1'
New-Item -ItemType Directory -Path $discD | Out-Null
Set-Content -LiteralPath (Join-Path $discD 'profile.txt') -Value 'A'
$reportD1 = Join-Path $root 'sweep-D1.csv'
$callsBeforeD = CallCount
$rD1 = Run $driveD 'testD' $reportD1
CheckTrue 'run D1 exits 0' ($rD1.Code -eq 0)
Check 'run D1 calls fake MakeMKV once' ((CallCount) - $callsBeforeD) 1
$reportD2 = Join-Path $root 'sweep-D2.csv'
$rD2 = Run $driveD 'testD' $reportD2
CheckTrue 'run D2 exits 0' ($rD2.Code -eq 0)
Check 'run D2 does NOT call fake MakeMKV again (unchanged disc, cache reused)' ((CallCount) - $callsBeforeD) 1
$rowsD1 = @(Import-Csv -LiteralPath $reportD1)
$rowsD2 = @(Import-Csv -LiteralPath $reportD2)
Check 'run D2: same subtitle streams as run D1' $rowsD2[0].SubtitleStreams $rowsD1[0].SubtitleStreams
Check 'run D2: same DiscId as run D1' $rowsD2[0].DiscId $rowsD1[0].DiscId

Write-Output '--- test 3: a legacy dump with no source-identity line is unverified and is re-enumerated ---'
$driveC = Join-Path $root 'driveC'; $discC = Join-Path $driveC 'Legacy Named Disc'
New-Item -ItemType Directory -Path $discC | Out-Null
Set-Content -LiteralPath (Join-Path $discC 'profile.txt') -Value 'A'
# Pre-seed a cache dump in the OLD format: raw MakeMKV lines, no leading '# source-identity:' line.
Set-Content -LiteralPath (Join-Path $cache 'Legacy Named Disc.txt') -Value @(
  'TINFO:0,9,0,"0:20:00"'
  'TINFO:0,11,0,"555"'
  'SINFO:0,0,1,0,"Audio"'
) -Encoding UTF8
$reportC = Join-Path $root 'sweep-C.csv'
$callsBeforeC = CallCount
$r4 = Run $driveC 'testC' $reportC
CheckTrue 'run C exits 0' ($r4.Code -eq 0)
CheckTrue 'run C re-enumerated the legacy dump (fake MakeMKV called)' ((CallCount) -gt $callsBeforeC)
$dumpC = @(Get-Content -LiteralPath (Join-Path $cache 'Legacy Named Disc.txt'))
CheckTrue 'run C: dump now carries a source-identity line' ($dumpC[0] -match '^# source-identity:')
$rowsC = @(Import-Csv -LiteralPath $reportC)
Check 'run C: subtitle streams reflect the RE-enumeration (profile A), not the stale legacy dump' $rowsC[0].SubtitleStreams '1'

Write-Output ''
if ($fails -eq 0) { Write-Output 'ALL PASSED'; exit 0 } else { Write-Output "$fails FAILED"; exit 1 }
