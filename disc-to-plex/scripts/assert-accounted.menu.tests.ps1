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
# -ManifestRoots points at a scratch directory in EVERY case. Left at its default these tests would
# read the live D:/video/_manifests, so a test disc that happened to share a name with a real one
# would close its obligations against a real artefact - a passing suite proving nothing.
$mroot = Join-Path $root 'manifests'
New-Item -ItemType Directory -Path $mroot -Force | Out-Null
function Run([string]$name, [string]$out) {
  & pwsh -NoProfile -File $Script -Disc $name -OutDir $out -NasRoot (Join-Path $root 'nas') -ManifestRoots $mroot *> $null
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

# ---- PHASE ----------------------------------------------------------------------------------
# The same file is asked two different questions. `release` (the default, cases 1-7 above) asks "may
# I delete the source?" and an unbuilt gallery must refuse. `decision` asks "is this disc decided?"
# and is called by _dispositions-loop.ps1 the moment the agent finishes, when NOTHING is built yet -
# so requiring an artefact there makes the correct disposition inexpressible. Reilly Ace of Spies
# Disks 1-4 all escalated on this, 2026-09-10.
function RunPhase([string]$name, [string]$out, [string]$phase) {
  & pwsh -NoProfile -File $Script -Disc $name -OutDir $out -NasRoot (Join-Path $root 'nas') -ManifestRoots $mroot -Phase $phase *> $null
  return $LASTEXITCODE
}

# 8. THE REGRESSION ITSELF: the case that refused for all four Reilly disks must pass at decision.
$n='caseH'; $o = New-Case $n @('menu1p78-161|extra|Sam Neill Biography, 13 pages|user:confirmed by eye')
Check 'unbuilt gallery PASSES at decision phase' 0 (RunPhase $n $o 'decision') 'nothing is built when the decision is made'

# 9. ...and the SAME dispositions file must still refuse at release. If this ever passes, the phase
#    split has stopped protecting the staging and has merely disabled the rule.
Check 'the same unbuilt gallery still REFUSES at release' 2 (RunPhase $n $o 'release') 'the delete gate is the one that binds'

# 10. Release is the DEFAULT. A caller that says nothing must get the strict answer, or every
#     existing call site silently loosens the day this parameter was added.
Check 'omitting -Phase defaults to release' 2 (Run $n $o) 'fail safe, not fail open'

# 11. A false `shipped:` path refuses in decision phase TOO. This is the load-bearing half of the
#     split: if a claim that names no file were tolerated anywhere, an agent could satisfy the
#     release gate by inventing a path, and the unbuilt gallery would walk straight through.
$n='caseI'; $o = New-Case $n @('menu1p78-161|extra|Storyboard Archive|shipped:Movies/Nope/Gallery - Absent.mkv')
Check 'a shipped: path naming no file refuses at decision too' 2 (RunPhase $n $o 'decision') 'a false claim is worse than none'

# 12. Identity evidence is still required under -RequireEvidence in decision phase. `shipped:` says
#     where the artefact went, never what it is, and identity is the half that cannot be rebuilt
#     once the staging is gone - so a shipped-only line must not buy its way past the citation rule.
$n='caseJ'
$rel2 = 'Movies\Phase Test\Other\Gallery - Built.mkv'
$nasFile2 = Join-Path (Join-Path $root 'nas') $rel2
New-Item -ItemType Directory -Path (Split-Path -Parent $nasFile2) -Force | Out-Null
Set-Content -LiteralPath $nasFile2 -Value 'x' -Encoding UTF8
$o = New-Case $n @('menu1p78-161|extra|Built Gallery|shipped:Movies/Phase Test/Other/Gallery - Built.mkv')
& pwsh -NoProfile -File $Script -Disc $n -OutDir $o -NasRoot (Join-Path $root 'nas') -ManifestRoots $mroot -Phase decision -RequireEvidence *> $null
Check 'shipped: alone is not identity evidence under -RequireEvidence' 2 $LASTEXITCODE 'a path says where, not what'

# 13. ...and with identity evidence beside it, the same line passes. Nosferatu, 2026-09-09: dropping
#     the card evidence to satisfy the gate was the wrong repair, so both must be expressible at once.
$n='caseK'; $o = New-Case $n @('menu1p78-161|extra|Built Gallery|mymovies|shipped:Movies/Phase Test/Other/Gallery - Built.mkv')
& pwsh -NoProfile -File $Script -Disc $n -OutDir $o -NasRoot (Join-Path $root 'nas') -ManifestRoots $mroot -Phase decision -RequireEvidence *> $null
Check 'identity evidence AND shipped: together pass' 0 $LASTEXITCODE 'both halves must fit in one line'

# 14. An unbuilt gallery WITH identity evidence passes decision under -RequireEvidence - this is
#     precisely the shape all four Reilly agents wrote, run with the flag the loop actually uses.
$n='caseL'; $o = New-Case $n @('menu1p78-161|extra|Sam Neill Biography, 13 pages|mymovies')
& pwsh -NoProfile -File $Script -Disc $n -OutDir $o -NasRoot (Join-Path $root 'nas') -ManifestRoots $mroot -Phase decision -RequireEvidence *> $null
Check 'the Reilly shape passes decision + -RequireEvidence' 0 $LASTEXITCODE 'this is the exact escalated case'

# 15. ...but an unbuilt gallery with NO evidence of any kind still refuses. "I saw some pages" is
#     not a decision, and the phase split must not become a way to record one.
$n='caseM'; $o = New-Case $n @('menu1p78-161|extra|Some Gallery')
& pwsh -NoProfile -File $Script -Disc $n -OutDir $o -NasRoot (Join-Path $root 'nas') -ManifestRoots $mroot -Phase decision -RequireEvidence *> $null
Check 'unbuilt AND unevidenced still refuses at decision' 2 $LASTEXITCODE 'the phase relaxes the artefact, never the identity'

# ---- MANIFEST-DERIVED CLOSURE ----------------------------------------------------------------
# A still set built by the pipeline must close its own obligation. `shipped:` was hand-stamped for
# the five galleries the orchestrator carved by hand; now that transcode.ps1 builds them from a
# kind:"STILLS" row, requiring the stamp would reintroduce as a manual step the very thing this key
# space exists to stop being manual.
function New-StillsManifest([string]$file, [string]$unit, [int]$vts, [string]$pgcs, [string]$domain, [string]$outPath) {
  @{ outputs = @(@{ kind = 'STILLS'; domain = $domain; vts = $vts; pgcs = $pgcs
                    src = "D:/video/_stage/$unit"; expectPages = 3; out = $outPath }) } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $mroot $file) -Encoding UTF8
}
# The artefact the rows below point at. Under the fake NAS root, which also proves a
# published-then-reclaimed gallery still closes.
$relG = 'Television Shows\Reilly\Season 00\Reilly - S00E01 - Sam Neill Biography.mkv'
$nasG = Join-Path (Join-Path $root 'nas') $relG
New-Item -ItemType Directory -Path (Split-Path -Parent $nasG) -Force | Out-Null
Set-Content -LiteralPath $nasG -Value 'x' -Encoding UTF8
$outG = 'D:/video/Television Shows/Reilly/Season 00/Reilly - S00E01 - Sam Neill Biography.mkv'

# 16. THE POINT OF THE WHOLE MECHANISM: a built STILLS row closes an unstamped obligation at
#     RELEASE - the phase that guards the delete. No hand-editing of the dispositions.
$n='caseN'; $o = New-Case $n @('menu1p12-14|extra|Sam Neill Biography, 3 pages|mymovies')
New-StillsManifest 'reilly-n.json' $n 1 '12-14' 'menu' $outG
Check 'a built STILLS row closes the obligation at release' 0 (RunPhase $n $o 'release') 'the pipeline records what it built'

# 17. COVERAGE, not equality: one artefact may span a wider range than the key names (Reilly Disk 4
#     ships the cast grid at PGC14 alongside the six actor pages). Every named page is inside a file
#     that exists, which is the whole of what the obligation asserts.
$n='caseO'; $o = New-Case $n @('menu1p12-14|extra|Sam Neill Biography, 3 pages|mymovies')
New-StillsManifest 'reilly-o.json' $n 1 '11-20' 'menu' $outG
Check 'a row covering a WIDER range closes it' 0 (RunPhase $n $o 'release') 'galleries ship as one item'

# 18. PARTIAL coverage must NOT close. This is the containment direction that matters: a row holding
#     12-13 leaves page 14 unbuilt, and closing on it would lose a page while reporting success.
$n='caseP'; $o = New-Case $n @('menu1p12-14|extra|Sam Neill Biography, 3 pages|mymovies')
New-StillsManifest 'reilly-p.json' $n 1 '12-13' 'menu' $outG
Check 'a row covering only PART of the range does not close it' 2 (RunPhase $n $o 'release') 'a missing page is lost content'

# 19. Wrong VTS must not close. The two domains and the VTS index are separate sector spaces; a
#     match on pages alone would close against plausible garbage from elsewhere on the disc.
$n='caseQ'; $o = New-Case $n @('menu1p12-14|extra|Sam Neill Biography, 3 pages|mymovies')
New-StillsManifest 'reilly-q.json' $n 6 '12-14' 'menu' $outG
Check 'a row for a different VTS does not close it' 2 (RunPhase $n $o 'release') 'VTS indexes are separate sector spaces'

# 20. A TITLE-domain row must not close a MENU-domain obligation, for the same reason
#     dvd-still-cells.py refuses to guess between them.
$n='caseR'; $o = New-Case $n @('menu1p12-14|extra|Sam Neill Biography, 3 pages|mymovies')
New-StillsManifest 'reilly-r.json' $n 1 '12-14' 'title' $outG
Check 'a title-domain row does not close a menu obligation' 2 (RunPhase $n $o 'release') 'the domains never substitute'

# 21. A row for a DIFFERENT DISC must not close it. Sibling discs in one set carry near-identical
#     menu structures - Reilly Disks 1, 2 and 3 all author a 3-page Sam Neill Biography at VTS 1 -
#     so matching on vts+pages without the disc would let Disk 1's artefact close Disk 3's.
$n='caseS'; $o = New-Case $n @('menu1p12-14|extra|Sam Neill Biography, 3 pages|mymovies')
New-StillsManifest 'reilly-s.json' 'Some Other Disk' 1 '12-14' 'menu' $outG
Check 'a row from another disc does not close it' 2 (RunPhase $n $o 'release') 'sibling discs share menu structure'

# 22. A matching row whose OUTPUT DOES NOT EXIST must not close it. The row is a plan; the file is
#     the fact. A manifest that was written and never ran is the ordinary case here.
$n='caseT'; $o = New-Case $n @('menu1p12-14|extra|Sam Neill Biography, 3 pages|mymovies')
New-StillsManifest 'reilly-t.json' $n 1 '12-14' 'menu' 'D:/video/Television Shows/Reilly/Season 00/Never Built.mkv'
Check 'a matching row whose output is absent does not close it' 2 (RunPhase $n $o 'release') 'a row is a plan, the file is the fact'

# 23. Comma-separated singletons are the shape dvd-still-cells.py actually consumes (it splits on
#     comma and int()s each part), so the closure must read them identically to the builder.
$n='caseU'; $o = New-Case $n @('menu1p12-14|extra|Sam Neill Biography, 3 pages|mymovies')
New-StillsManifest 'reilly-u.json' $n 1 '12,13,14' 'menu' $outG
Check 'a comma-separated pgcs spec closes it' 0 (RunPhase $n $o 'release') 'same parse as build-still-slideshow.py'

Write-Output ''
Write-Output ("{0} passed, {1} failed" -f $pass, $fail)
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
if ($fail) { exit 1 }
exit 0
