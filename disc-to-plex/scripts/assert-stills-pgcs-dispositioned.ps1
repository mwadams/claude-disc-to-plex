<#
.SYNOPSIS
  REFUSE a manifest whose menu-domain STILLS row carves PGCs that its OWN disc's dispositions
  never named - the sibling-disc page numbers that build a gallery out of the wrong pages.

.WHY THIS EXISTS
  A menu-domain `pgcs` list is only meaningful for the ONE disc named in that row's `src`. Sibling
  discs in a box set carry the same extras at DIFFERENT PGC numbers, so a row moved or copied
  between manifests without its `src` being corrected asks the carver for real pages of the wrong
  thing - and nothing downstream can see it, because N named PGCs really do yield N pages and
  `expectPages` is satisfied. Same shape as assert-dvd-title-numbering.ps1's off-by-one: a
  mechanical claim, checkable here, invisible to every duration and count test after it.

  MEASURED, 2026-09-10, Reilly Ace of Spies. Disks 1 and 2 carry the same three extras (Sam Neill
  Biography, Filmographies, Production Notes) with verbatim-identical text - and layouts offset by
  one:

    Disk 1 dispositions   Biography menu1p12-14   Filmographies grid at PGC15   Notes menu1p22-24
    Disk 2 dispositions   Biography menu1p11-13   Filmographies grid at PGC14   Notes menu1p21-23

  So on Disk 2, PGC 14 is a cast GRID exactly where Disk 1's PGC 14 is a biography page. A row
  carrying Disk 1's `pgcs: "12,13,14"` but pointed at Disk 2 would build Biography-page-2,
  Biography-page-3 and a cast grid under the name "Sam Neill Biography", missing page 1 entirely.

  Reilly is the case that MEASURED the hazard, not an instance of it: Disk 2's manifest was authored
  correctly, setting `src` to Disk 1 for the two duplicated extras and to Disk 2 only for its own
  unique Filmographies. This guard exists because the near-miss variant - copy the row, keep the
  numbers, forget the `src` - is the ordinary way that authoring goes wrong, and its product is a
  plausible gallery of real pages that no later check questions.

  WHY AT THE GATE. A still set that carves the wrong pages is not detectably wrong afterwards -
  it is a plausible gallery of real pages from the same disc. The only cheap moment is before the
  carve, and the repair is editing two numbers in a JSON file.

  THE CHECK, precisely: every PGC a menu-domain STILLS row names must appear in some
  `menu<VTS>p<first>-<last>` disposition line for THAT ROW'S OWN DISC, at that row's `vts`. It does
  NOT check the reverse (that every disposition is covered by a row) - that is the release-time
  obligation assert-accounted.ps1 enforces, and the two are deliberately opposite directions.

  It is also NOT a check that the gallery is correctly IDENTIFIED. That is judgement and needs
  content evidence. This checks only the mechanical claim: "the pages I am asking the carver for
  are pages this disc's dispositions actually described."

.NOTES
  Silent (exit 0) when it cannot judge: no STILLS rows, no `menu` domain rows, a row with no `src`
  or no parseable `pgcs`, or a disc with no dispositions file. A guard that refuses on missing
  evidence blocks the line for reasons that are not faults - the same stance as
  assert-edition-layout.ps1 and assert-dvd-title-numbering.ps1. Every such skip is REPORTED rather
  than passed over in silence, because a check that skips is not a check that passes.

.EXAMPLE
  pwsh -NoProfile -File assert-stills-pgcs-dispositioned.ps1 -Manifest D:/video/_queue/pending/x.json
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [string]$Catalogue = 'D:/video/_catalogue',
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'

function Say([string]$m){ if(-not $Quiet){ Write-Output $m } }

if(-not (Test-Path -LiteralPath $Manifest)){ Say "assert-stills-pgcs: no manifest at $Manifest - nothing to check."; exit 0 }
try { $mj = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json }
catch { Say "assert-stills-pgcs: $Manifest is not readable JSON - leaving it to the gate's own parser."; exit 0 }

# CONVERTFROM-JSON UNWRAPS A SINGLE-ELEMENT ARRAY, so a manifest holding exactly ONE row comes back
# as a bare object, not an array of one. Testing `-is [System.Array]` first therefore reads zero
# rows out of a perfectly good one-row manifest and passes silently - which is how this guard
# skipped every case in its own test suite while reporting exit 0. Ask about `outputs` FIRST, then
# wrap whatever is left, so one row and many rows take the same path.
$rows = @()
if($null -ne $mj){
  if($mj -isnot [System.Array] -and $mj.PSObject.Properties.Name -contains 'outputs'){ $rows = @($mj.outputs) }
  else { $rows = @($mj) }
}
if(-not $rows.Count){ Say 'assert-stills-pgcs: no rows in this manifest.'; exit 0 }

# Parsed exactly as build-still-slideshow.py's parse_pgcs does - comma-separated singletons and
# inclusive a-b ranges. A second parser that disagreed with the builder would validate a row
# against pages the builder will not actually carve.
function Expand-PgcSpec([string]$spec){
  $out = New-Object System.Collections.Generic.List[int]
  foreach($part in ("$spec" -split ',')){
    $part = $part.Trim()
    if(-not $part){ continue }
    if($part -match '^(\d+)\s*-\s*(\d+)$'){
      $a = [int]$Matches[1]; $b = [int]$Matches[2]
      if($b -lt $a){ continue }   # 0..-1 counts DOWN in PowerShell; a reversed spec must yield nothing
      for($i = $a; $i -le $b; $i++){ $out.Add($i) }
    } elseif($part -match '^\d+$'){ $out.Add([int]$part) }
  }
  return ,$out.ToArray()
}

# The menu keys a disc's dispositions declare, as vts -> set of PGCs. EVERY kind counts, `exclude`
# included: a row carving pages the dispositions deliberately dismissed as menu backgrounds is a
# different fault, and one this guard has no business adjudicating. What it exists to catch is a
# page number NOBODY on this disc ever wrote down.
$dispCache = @{}
function Get-DiscMenuPgcs([string]$unit){
  if($dispCache.ContainsKey($unit)){ return $dispCache[$unit] }
  $path = Join-Path $Catalogue "$unit.dispositions.txt"
  $res = @{ Found = $false; ByVts = @{} }
  if(Test-Path -LiteralPath $path){
    $res.Found = $true
    foreach($line in (Get-Content -LiteralPath $path -ErrorAction SilentlyContinue)){
      $t = "$line".Trim()
      if(-not $t -or $t.StartsWith('#')){ continue }
      $key = ($t -split '\|')[0].Trim()
      if($key -notmatch '^menu(\d+)p(\d+)(?:-(\d+))?$'){ continue }
      $v = [int]$Matches[1]; $a = [int]$Matches[2]
      $b = if($Matches[3]){ [int]$Matches[3] } else { $a }
      if($b -lt $a){ continue }
      if(-not $res.ByVts.ContainsKey($v)){ $res.ByVts[$v] = [System.Collections.Generic.HashSet[int]]::new() }
      for($i = $a; $i -le $b; $i++){ [void]$res.ByVts[$v].Add($i) }
    }
  }
  $dispCache[$unit] = $res
  return $res
}

$bad = @()
$skipped = @()
$checked = 0

foreach($r in $rows){
  if("$($r.kind)" -ne 'STILLS'){ continue }
  if("$($r.domain)".ToLowerInvariant() -ne 'menu'){ continue }
  $label = if("$($r.out)"){ Split-Path "$($r.out)" -Leaf } else { '<row with no out>' }

  $src = "$($r.src)"
  if(-not $src){ $skipped += ("{0} - row has no `src`, so which disc's dispositions to read is unknown" -f $label); continue }
  $unit = Split-Path ($src -replace '/', '\') -Leaf
  # `src` may name the disc dir or its VIDEO_TS; transcode.ps1 accepts both.
  if($unit -ieq 'VIDEO_TS'){ $unit = Split-Path (Split-Path ($src -replace '/', '\') -Parent) -Leaf }

  $pages = Expand-PgcSpec "$($r.pgcs)"
  if(-not $pages.Count){ $skipped += ("{0} - `pgcs` '{1}' names no pages this parser can read" -f $label, "$($r.pgcs)"); continue }

  $d = Get-DiscMenuPgcs $unit
  if(-not $d.Found){ $skipped += ("{0} - no dispositions file for '{1}', so its menu layout is unknown" -f $label, $unit); continue }

  $vts = [int]("$($r.vts)")
  # Built as a plain list, not an `if`-expression yielding a HashSet: the inline form returned $null
  # for the else branch and `$have.Contains(...)` then threw, turning a REFUSAL into exit 1. A guard
  # that dies is not a guard that refuses - the gate reads a non-zero exit either way, but the
  # operator gets a stack trace instead of the two page numbers they need to fix.
  $have = @()
  if($d.ByVts.ContainsKey($vts)){ $have = @($d.ByVts[$vts]) }
  $missing = @($pages | Where-Object { $have -notcontains $_ })
  $checked++
  if($missing.Count){
    $declared = '(none at this VTS)'
    if($have.Count){ $declared = (($have | Sort-Object) -join ',') }
    $bad += [pscustomobject]@{
      Label = $label; Unit = $unit; Vts = $vts
      Asked = ($pages -join ','); Missing = ($missing -join ','); Declared = $declared
    }
  }
}

foreach($s in $skipped){ Say ("assert-stills-pgcs: SKIPPED {0}" -f $s) }

if($bad.Count){
  Write-Output ''
  Write-Output ("*** {0} MENU-DOMAIN STILLS ROW(S) CARVE PAGES THIS DISC'S DISPOSITIONS NEVER NAMED ***" -f $bad.Count)
  Write-Output ''
  foreach($b in $bad){
    Write-Output ("  {0}" -f $b.Label)
    Write-Output ("     disc         : {0}  (VTS {1})" -f $b.Unit, $b.Vts)
    Write-Output ("     row asks for : PGC {0}" -f $b.Asked)
    Write-Output ("     NOT declared : PGC {0}" -f $b.Missing)
    Write-Output ("     this disc's menu dispositions name: PGC {0}" -f $b.Declared)
    Write-Output ''
  }
  Write-Output 'Sibling discs in one set carry the SAME extras at DIFFERENT PGC numbers - Reilly Disks 1'
  Write-Output 'and 2 are offset by one, and Disk 2 PGC 14 is a cast grid where Disk 1 PGC 14 is a'
  Write-Output 'biography page. Copying a row from the sibling disc builds a plausible gallery out of'
  Write-Output 'the wrong pages, and no count or duration check downstream can see it.'
  Write-Output ''
  Write-Output 'TWO CORRECT REPAIRS, and which one depends on where the pages are being read FROM:'
  Write-Output ''
  Write-Output "  1. Carving THIS disc's copy - use THIS disc's numbers, from its own dispositions:"
  Write-Output ("       {0}\<disc>.dispositions.txt" -f $Catalogue)
  Write-Output "  2. Deliberately shipping the SIBLING's copy because the two are verbatim identical -"
  Write-Output "     keep the sibling's `pgcs` and point `src` at the SIBLING's staging directory. That"
  Write-Output '     is what Reilly Disk 2 does for its Biography and Production Notes, and it is the'
  Write-Output '     clearer of the two: the row then says plainly which disc the pages came off.'
  exit 2
}

if($checked -gt 0){ Say ("assert-stills-pgcs: OK - {0} menu-domain STILLS row(s) carve only pages their own disc declared." -f $checked) }
else { Say 'assert-stills-pgcs: no menu-domain STILLS row could be checked.' }
exit 0
