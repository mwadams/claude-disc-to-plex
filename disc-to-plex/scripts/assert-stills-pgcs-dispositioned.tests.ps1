<#
  Tests for assert-stills-pgcs-dispositioned.ps1.

  The fault it exists to catch is invisible downstream: a menu-domain STILLS row carrying a SIBLING
  disc's page numbers still yields N pages and still satisfies expectPages, so it publishes a
  plausible gallery made of the wrong pages. The numbers below are the real Reilly Ace of Spies
  layouts (Disk 1 Biography 12-14 / grid at 15; Disk 2 Biography 11-13 / grid at 14), because a
  synthetic offset would not show that PGC 14 is a biography page on one disc and a cast grid on
  the other.

    pwsh -File assert-stills-pgcs-dispositioned.tests.ps1
#>
param(
  [string]$Script = 'D:/video/.claude/skills/disc-to-plex/scripts/assert-stills-pgcs-dispositioned.ps1'
)
$ErrorActionPreference = 'Stop'

$root = Join-Path ([IO.Path]::GetTempPath()) ("stillspgc-" + [guid]::NewGuid().ToString('N').Substring(0,8))
$cat  = Join-Path $root 'catalogue'
New-Item -ItemType Directory -Path $cat -Force | Out-Null

$pass = 0; $fail = 0
function Check([string]$name, [int]$want, [int]$got, [string]$detail) {
  if ($want -eq $got) { $script:pass++; Write-Output ("  PASS  {0}" -f $name) }
  else { $script:fail++; Write-Output ("  FAIL  {0} - want exit {1}, got {2}. {3}" -f $name, $want, $got, $detail) }
}

function New-Dispositions([string]$unit, [string[]]$lines) {
  Set-Content -LiteralPath (Join-Path $cat "$unit.dispositions.txt") -Value (@('t01|feature|The Feature|mymovies') + $lines) -Encoding UTF8
}
function New-Manifest([string]$name, [array]$rows) {
  $p = Join-Path $root "$name.json"
  ,$rows | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $p -Encoding UTF8
  return $p
}
function Row([string]$srcUnit, [int]$vts, [string]$pgcs, [string]$domain, [string]$outName) {
  @{ kind = 'STILLS'; domain = $domain; vts = $vts; pgcs = $pgcs; expectPages = 3
     src = "D:/video/_stage/$srcUnit"; out = "D:/video/Television Shows/X/Season 00/$outName" }
}
function Run([string]$manifest) {
  & pwsh -NoProfile -File $Script -Manifest $manifest -Catalogue $cat *> $null
  return $LASTEXITCODE
}

# The two real layouts, offset by one.
New-Dispositions 'Reilly Disk 1' @(
  'menu1p12-14|extra|Sam Neill Biography, 3 pages|mymovies',
  'menu1p16-21|extra|Filmographies, 6 pages reached from the PGC15 grid|mymovies',
  'menu1p22-24|extra|Production Notes, 3 pages|mymovies')
New-Dispositions 'Reilly Disk 2' @(
  'menu1p11-13|extra|Sam Neill Biography, 3 pages|mymovies',
  'menu1p15-20|extra|Filmographies, 6 pages reached from the PGC14 grid|mymovies',
  'menu1p21-23|extra|Production Notes, 3 pages|mymovies')

Write-Output 'assert-stills-pgcs-dispositioned.ps1'

# 1. THE FAULT: Disk 1's numbers against Disk 2's disc. PGC 14 is a cast grid on Disk 2, so this
#    builds Biography-p2, Biography-p3 and a grid, and loses page 1 - while expectPages still fits.
$m = New-Manifest 'copied-row' @((Row 'Reilly Disk 2' 1 '12,13,14' 'menu' 'Sam Neill Biography.mkv'))
Check "a sibling's page numbers against this disc REFUSE" 2 (Run $m) 'PGC 14 is not in Disk 2 menu dispositions'

# 2. The same numbers against the disc they belong to must pass.
$m = New-Manifest 'own-row' @((Row 'Reilly Disk 1' 1 '12,13,14' 'menu' 'Sam Neill Biography.mkv'))
Check "the same numbers against their OWN disc pass" 0 (Run $m) 'Disk 1 declares 12-14'

# 3. THE DELIBERATE CROSS-DISC SHIP, which is correct authoring and must not be refused: keep the
#    sibling's pgcs AND point src at the sibling. Reilly Disk 2's real manifest does exactly this.
$m = New-Manifest 'cross-disc' @(
  (Row 'Reilly Disk 1' 1 '12,13,14' 'menu' 'Sam Neill Biography.mkv'),
  (Row 'Reilly Disk 2' 1 '15,16,17,18,19,20' 'menu' 'Filmographies (Disk 2).mkv'))
Check 'a deliberate cross-disc row with matching src passes' 0 (Run $m) 'this is how Reilly Disk 2 ships its duplicates'

# 4. PARTIAL overlap must refuse. One stray page is the whole fault - a row that is right about two
#    of three pages still ships a gallery with a wrong page in it.
$m = New-Manifest 'partial' @((Row 'Reilly Disk 2' 1 '11,12,14' 'menu' 'Sam Neill Biography.mkv'))
Check 'one undeclared page among declared ones refuses' 2 (Run $m) '14 is undeclared on Disk 2'

# 5. Wrong VTS must refuse: menu PGCs are per-VTS, so the same number in another VTS is another page.
$m = New-Manifest 'wrong-vts' @((Row 'Reilly Disk 1' 6 '12,13,14' 'menu' 'Sam Neill Biography.mkv'))
Check 'the right pages at the wrong VTS refuse' 2 (Run $m) 'menu PGCs are per-VTS'

# 6. Ranges and comma lists must read identically - build-still-slideshow.py accepts both.
$m = New-Manifest 'range-form' @((Row 'Reilly Disk 1' 1 '12-14' 'menu' 'Sam Neill Biography.mkv'))
Check 'a range spec reads the same as a comma list' 0 (Run $m) 'same parse as parse_pgcs'

# 7. TITLE-domain rows are a different key space (tNN/dvdvideoTitle) and are not this guard's
#    business; it must not refuse them for having no menu disposition.
$m = New-Manifest 'title-domain' @((Row 'Reilly Disk 1' 1 '2' 'title' 'Some Title Stills.mkv'))
Check 'a title-domain row is not judged here' 0 (Run $m) 'title domain has its own key space'

# 8. A manifest with no STILLS rows at all must pass - most manifests have none, and a guard that
#    taxed ordinary discs would be routed around.
$m = New-Manifest 'no-stills' @(@{ kind = 'DVD'; title = 2; src = 'D:/video/_stage/Reilly Disk 1'
                                   out = 'D:/video/Television Shows/X/Season 01/X - S01E01.mkv' })
Check 'a manifest with no STILLS rows passes' 0 (Run $m) 'must not tax ordinary discs'

# 9. CANNOT JUDGE must not refuse, but must SAY so: a disc with no dispositions file blocks the line
#    for a reason that is not a fault. Same stance as assert-dvd-title-numbering.ps1.
$m = New-Manifest 'unknown-disc' @((Row 'Some Unswept Disk' 1 '12,13,14' 'menu' 'Gallery.mkv'))
Check 'a disc with no dispositions is skipped, not refused' 0 (Run $m) 'missing evidence is not a fault'
$out = @(& pwsh -NoProfile -File $Script -Manifest $m -Catalogue $cat 2>&1 | ForEach-Object { "$_" })
$said = @($out | Where-Object { $_ -match 'SKIPPED' }).Count
Check 'and the skip is REPORTED, not silent' 1 ([int]($said -gt 0)) 'a check that skips is not a check that passes'

Write-Output ''
Write-Output ("{0} passed, {1} failed" -f $pass, $fail)
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { exit 1 }
exit 0
