<#
.SYNOPSIS
  Refuse to release a disc's raw staging until EVERY catalogued title has a recorded disposition.

.WHY THIS EXISTS
  The per-unit gate's check #1 - "every title accounted for" - was prose, so it was signed off by
  recalling that the rips looked fine. Twice that was wrong in a way that cost a re-fetch:

  - **Colonel Blimp** (2026-08-21): staging freed having ripped 4 of 7 titles. Duration-verifying
    the rips you took proves those rips are good; it says NOTHING about titles you never looked at.
  - **The Man with the Golden Gun** (2026-08-22): enumerated at MakeMKV's default 120 s floor, so
    29 of its 42 titles were never listed at all. Encoded, published and confirmed in Plex before
    anyone noticed.

  A disposition is a WRITTEN decision per title. Not a count, not a spot check - if a title has no
  line here, nobody looked at it, and the disc is not finished.

.DISPOSITIONS FILE
  <OutDir>\<disc>.dispositions.txt, pipe-delimited, one line per title, '#' comments ignored:

    t05|feature|Moonraker (1979)
    t33|extra|Inside The Man with the Golden Gun
    t14|episode|S01E03 The Sea Devils
    t01|exclude|copyright warning card
    t40|exclude|textless master of t33 - same audio md5, caption absent

  `exclude` REQUIRES a reason, and the reason must identify what the title IS. "too short",
  "duplicate" and "not needed" are rejected: every expensive loss in this project was a real extra
  dropped for looking like the wrong length or a duplicate.

.EXAMPLE
  pwsh -File assert-accounted.ps1 -Disc "MAN_GOLDEN_GUN_F1"
#>
param(
  [Parameter(Mandatory)][string]$Disc,
  [string]$OutDir = 'D:\video\_catalogue'
)
$ErrorActionPreference = 'Stop'
$discName = Split-Path $Disc -Leaf
$catPath  = Join-Path $OutDir "$discName.catalogue.json"
$dispPath = Join-Path $OutDir "$discName.dispositions.txt"

if(-not (Test-Path -LiteralPath $catPath)){
  Write-Output "*** NO CATALOGUE for $discName ***"
  Write-Output "Run: pwsh -File catalogue-disc.ps1 -Disc `"<staged disc path>`""
  exit 2
}
$cat = Get-Content -LiteralPath $catPath -Raw | ConvertFrom-Json

# A catalogue taken at a high floor cannot answer the question at all.
if($cat.minLength -gt 10){
  Write-Output ("*** CATALOGUE FLOOR TOO HIGH: minlength={0} ***" -f $cat.minLength)
  Write-Output "Titles shorter than that were never enumerated, so completeness is unknowable. Re-catalogue at 10."
  exit 2
}

$disp = @{}
$badReason = @()
if(Test-Path -LiteralPath $dispPath){
  foreach($line in (Get-Content -LiteralPath $dispPath)){
    $l = $line.Trim()
    if(-not $l -or $l.StartsWith('#')){ continue }
    $p = $l -split '\|', 3
    if($p.Count -lt 2){ continue }
    if($p[0] -notmatch '^t(\d+)$'){ continue }
    $id = [int]$Matches[1]
    $kind = $p[1].Trim().ToLower()
    $note = if($p.Count -ge 3){ $p[2].Trim() } else { '' }
    $disp[$id] = @{ kind = $kind; note = $note }
    if($kind -eq 'exclude'){
      # An exclusion must name what the thing IS. Non-identifications are how real extras get lost.
      if(-not $note -or $note.Length -lt 8 -or $note -match '^(too short|short|duplicate|dupe|not needed|n/?a|junk|skip)\.?$'){
        $badReason += ("t{0:D2}  exclude reason does not identify the title: '{1}'" -f $id, $note)
      }
    }
  }
}

$missing = @()
foreach($t in $cat.titles){ if(-not $disp.ContainsKey([int]$t.title)){ $missing += $t } }

Write-Output ("$discName - {0} title(s) catalogued at minlength={1}, {2} with a disposition" -f $cat.titleCount, $cat.minLength, $disp.Count)

if($missing){
  Write-Output ""
  Write-Output ("*** {0} TITLE(S) HAVE NO DISPOSITION - THE DISC IS NOT ACCOUNTED FOR ***" -f $missing.Count)
  Write-Output ""
  Write-Output ("{0,-5} {1,9} {2,10} {3,-14} {4}" -f 'id','duration','size','source','video')
  foreach($t in $missing){
    $vid = if($t.width){ "{0}x{1}" -f $t.width, $t.height } else { '-' }
    Write-Output ("t{0:D2}   {1,9} {2,10} {3,-14} {4}" -f $t.title, $t.duration, $t.sizeText, $t.source, $vid)
  }
  Write-Output ""
  Write-Output "Look at each (frames are in $OutDir\$discName-frames), then add a line to:"
  Write-Output "  $dispPath"
  Write-Output "DO NOT release the raw staging."
  exit 2
}
if($badReason){
  Write-Output ""
  Write-Output "*** EXCLUSIONS THAT DO NOT IDENTIFY THE TITLE ***"
  $badReason | ForEach-Object { Write-Output "  $_" }
  Write-Output ""
  Write-Output "Say what it IS (copyright card, textless master of tNN, promo for another title)."
  exit 2
}

$byKind = $disp.Values | Group-Object { $_.kind } | Sort-Object Name
Write-Output ""
foreach($g in $byKind){ Write-Output ("  {0,-9} {1}" -f $g.Name, $g.Count) }
Write-Output ""
Write-Output "ACCOUNTED FOR - every catalogued title has a written disposition."
Write-Output "Raw staging may be released once the encoded outputs are byte-verified on the NAS."
exit 0
