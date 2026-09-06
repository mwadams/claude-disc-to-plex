<#
  Tests for lib-subtitle-coverage.ps1's SOURCE-DRIVE / OPTICAL branch.

  WHY THIS FILE EXISTS
  This library decides, library-wide, what may be transcribed. It had NO tests. On 2026-09-06 it was
  found to have deferred 26 published files for ever - all 17 Tales of the Unexpected episodes and
  all 9 Clayhanger episodes - by asking "is this file's source drive attached?" of units that came
  off a PHYSICAL DISC and therefore have no source drive at all. The user expected them queued; the
  board reported them "deferred until that drive can be re-checked", naming a drive that does not
  exist. Nothing failed, nothing errored, and the lane simply never started.

  The exemption keys on `_optical-staged.tsv` - the optical lane's own register - and NOT on a name
  pattern. That distinction is load-bearing and is tested below: optical units are named BOTH
  `DVDVolume-<hash>` (disc had no usable label) and by title (`Clayhanger D1`). A `DVDVolume-` name
  test would have exempted 7 of Clayhanger's 9 episodes and left two behind silently - the kind of
  partial fix that looks like it worked.
#>
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib-subtitle-coverage.ps1"

$fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('cov-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

Write-Output '1. Get-OpticalStagedUnits reads the register, lowercases, and survives absence'
$tsv = Join-Path $tmp 'optical.tsv'
@(
  "Name`tFingerprint`tWhen`tBytes"
  "Clayhanger D1`tda8c31a5`t2026-09-06T06:42:05`t8158105600"
  "DVDVolume-cee383b5`tf5999c49`t2026-09-06T06:42:05`t8159797248"
) | Set-Content -LiteralPath $tsv -Encoding UTF8
$u = Get-OpticalStagedUnits -Path $tsv
Check 'two units loaded'            $u.Count 2
Check 'titled unit, lowercased'     $u.ContainsKey('clayhanger d1') $true
Check 'hash unit, lowercased'       $u.ContainsKey('dvdvolume-cee383b5') $true
# PowerShell hashtables are case-INSENSITIVE, so the original casing resolves too. Asserted rather
# than assumed: the lookup in the exemption lowercases its key, and if this library ever moved to an
# ordered/typed dictionary that stopped being true, every titled unit would silently stop matching.
Check 'original casing also resolves' $u.ContainsKey('Clayhanger D1') $true
Check 'unknown unit absent'         $u.ContainsKey('survivors series 2 disk 3') $false
$missing = Get-OpticalStagedUnits -Path (Join-Path $tmp 'no-such-file.tsv')
Check 'missing register -> empty, not throw' $missing.Count 0

Write-Output '2. THE NAME PATTERN IS NOT THE TEST - a titled optical unit must be recognised'
# This is the case a `DVDVolume-` regex would miss. Clayhanger staged BOTH ways, so a pattern-based
# fix would have exempted its dvdvolume-* discs and silently left `Clayhanger D1`/`D2` deferred.
Check 'titled unit is in the register'  $u.ContainsKey('clayhanger d1') $true
Check 'and it does NOT look like a DVDVolume name' ('clayhanger d1' -match '^dvdvolume') $false

Write-Output '3. Get-ManifestSourceDrive: DVD src leaf is the disc folder; unknown -> $null'
$idx = @{ 'survivors series 2 disk 3' = 'media2' }
Check 'known disc resolves to its drive' `
  (Get-ManifestSourceDrive -Manifest ([pscustomobject]@{ Src='D:/video/_stage/Survivors Series 2 Disk 3'; Kind='DVD' }) -DiscDriveIndex $idx) 'media2'
Check 'unknown disc -> null' `
  ([string](Get-ManifestSourceDrive -Manifest ([pscustomobject]@{ Src='D:/video/_stage/Clayhanger D1'; Kind='DVD' }) -DiscDriveIndex $idx)) ''
Check 'no src -> null' `
  ([string](Get-ManifestSourceDrive -Manifest ([pscustomobject]@{ Kind='DVD' }) -DiscDriveIndex $idx)) ''

Write-Output '4. The unit key the exemption uses is the src LEAF, matching the register'
# Regression guard: the exemption looks up Split-Path -Leaf of the manifest src. If that ever
# changes shape (a trailing slash, a nested path) the lookup silently misses and the file defers
# again - which is exactly the failure this whole file exists to prevent.
foreach ($case in @(
    @{ Src='D:/video/_stage/Clayhanger D1';        Want='clayhanger d1' },
    @{ Src='D:\video\_stage\Clayhanger D1';        Want='clayhanger d1' },
    @{ Src='D:/video/_stage/DVDVolume-cee383b5';   Want='dvdvolume-cee383b5' })) {
  $leaf = (Split-Path ($case.Src -replace '\\', '/') -Leaf).ToLowerInvariant()
  Check ("src leaf '$($case.Src)'") $leaf $case.Want
  Check ("  ...and the register exempts it") ($u.ContainsKey($leaf)) $true
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($fails) { Write-Output "TESTS FAILED - $fails case(s)"; exit 1 }
Write-Output 'all tests passed'
exit 0
