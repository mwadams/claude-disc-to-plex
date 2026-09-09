<#
  Tests for the MENU-DOMAIN key space in assert-accounted.ps1.

  These cover the hole that let an 85-page Storyboard Archive be written down as missing content and
  released anyway (Star Trek: The Motion Picture extras disc, 2026-09-09): menu-domain galleries have
  no catalogue row and no declared dvdvideo title, so "every title accounted for" was true and
  silent about them.

  Each case builds a throwaway catalogue + dispositions pair in the session scratch and asserts the
  EXIT CODE, because that is what the release path acts on.

    pwsh -File assert-accounted.menu.tests.ps1
#>
param(
  [string]$Script = 'D:/video/.claude/skills/disc-to-plex/scripts/assert-accounted.ps1'
)
$ErrorActionPreference = 'Stop'

$root = Join-Path ([IO.Path]::GetTempPath()) ("aamenu-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$shipped = Join-Path $root 'shipped'
New-Item -ItemType Directory -Path $shipped -Force | Out-Null

$pass = 0; $fail = 0
function Check([string]$name, [int]$want, [int]$got, [string]$detail) {
  if ($want -eq $got) { $script:pass++; Write-Output ("  PASS  {0}" -f $name) }
  else { $script:fail++; Write-Output ("  FAIL  {0} - want exit {1}, got {2}. {3}" -f $name, $want, $got, $detail) }
}

# One catalogued title, dispositioned, so the title-domain half is always clean and the exit code is
# attributable to the menu-domain rule alone.
function New-Case([string]$name, [string[]]$dispLines) {
  $out = Join-Path $root $name
  New-Item -ItemType Directory -Path $out -Force | Out-Null
  # `discPath` and `discType` are not optional: the script derives paths from them, and a catalogue
  # without discPath dies with "Cannot bind argument to parameter 'Path' because it is an empty
  # string" long before any menu rule runs. discPath points at a directory that does not exist,
  # which is correct for these cases - the disc is released, and the menu rule must not need it.
  @{ disc = $name; discPath = (Join-Path $out 'stage'); discType = 'DVD'; sourceVerified = $true
     titleCount = 1; minLength = 10; titles = @(@{ title = 1; seconds = 3600 }) } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $out "$name.catalogue.json") -Encoding UTF8
  # `mymovies` deliberately, NOT `card:` - a card/frame/speech citation is machine-verified against
  # the catalogue's captured frames, and a synthetic catalogue has none, so it refuses with
  # "card cited but the catalogue captured NO frames". That is the gate working correctly; it just
  # made every case here fail for a reason that had nothing to do with the menu domain.
  @('t01|feature|The Feature|mymovies') + $dispLines |
    Set-Content -LiteralPath (Join-Path $out "$name.dispositions.txt") -Encoding UTF8
  return $out
}
function Run([string]$name, [string]$out) {
  & pwsh -NoProfile -File $Script -Disc $name -OutDir $out -NasRoot (Join-Path $root 'nas') *> $null
  return $LASTEXITCODE
}

Write-Output 'assert-accounted.ps1 - menu-domain obligations'

# 1. A menu gallery declared as content with NO shipped evidence must REFUSE. This is the exact
#    Star Trek case: the decision was written, the artefact never built.
$n='caseA'; $o = New-Case $n @('menu1p78-161|extra|Storyboard Archive, 84 frames|user:confirmed by eye')
Check 'content menu item with no shipped: evidence refuses' 2 (Run $n $o) 'an intention is not an artefact'

# 2. Claiming a path that does not exist must REFUSE - a claim is not a fact.
$n='caseB'; $o = New-Case $n @('menu1p78-161|extra|Storyboard Archive|shipped:Movies/Nope/Gallery - Absent.mkv')
Check 'shipped: naming a missing file refuses' 2 (Run $n $o) 'the gate must verify, not believe'

# 3. Claiming a path that DOES exist must PASS. Placed under the fake NAS root, which also proves a
#    published-then-reclaimed item still closes its obligation.
$n='caseC'
$rel = 'Movies\Star Trek The Motion Picture\Other\Gallery - Storyboard Archive.mkv'
$nasFile = Join-Path (Join-Path $root 'nas') $rel
New-Item -ItemType Directory -Path (Split-Path -Parent $nasFile) -Force | Out-Null
Set-Content -LiteralPath $nasFile -Value 'x' -Encoding UTF8
$o = New-Case $n @('menu1p78-161|extra|Storyboard Archive|shipped:Movies/Star Trek The Motion Picture/Other/Gallery - Storyboard Archive.mkv')
Check 'shipped: naming an existing file passes' 0 (Run $n $o) 'obligation closes on the artefact'

# 4. An EXCLUDE needs a reason that identifies the content, same discipline as tNN/dvNN.
$n='caseD'; $o = New-Case $n @('menu1p10-14|exclude|not needed')
Check 'exclude with a non-identifying reason refuses' 2 (Run $n $o) 'every lost extra was excluded for "not needed"'

# 5. A properly reasoned exclude passes - menu backgrounds are not galleries and must stay cheap to
#    dismiss, or the rule becomes something people route around.
$n='caseE'; $o = New-Case $n @('menu1p10-14|exclude|the five animated main-menu backgrounds, no still content')
Check 'exclude with an identifying reason passes' 0 (Run $n $o) ''

# 6. A placeholder kind is the absence of a decision, exactly as for tNN.
$n='caseF'; $o = New-Case $n @('menu1p78-161|?|maybe a gallery')
Check 'placeholder kind refuses' 2 (Run $n $o) ''

# 7. NO menu line at all must still pass: most discs have no menu-domain content, and a gate that
#    refused every disc without one would be routed around within a day.
$n='caseG'; $o = New-Case $n @()
Check 'a disc with no menu-domain line passes' 0 (Run $n $o) 'this rule must not tax ordinary discs'

Write-Output ''
Write-Output ("{0} passed, {1} failed" -f $pass, $fail)
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { exit 1 }
exit 0
