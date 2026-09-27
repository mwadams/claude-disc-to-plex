<#
  Tests for assert-slot-not-claimed.ps1 (and the matcher in lib-slot-claims.ps1) - the gate check that
  stops a manifest declaring an episode slot another in-flight claim already holds.
  Run: pwsh -NoProfile -File assert-slot-not-claimed.tests.ps1   (exit 0 = all passed)

  WHAT THESE HAVE TO PROVE:
    - THE CASE IT EXISTS FOR: Robot (queued, registered S00E320-E324) and The Androids of Tara
      (gated second, same five numbers, different titles) - the Androids manifest is REFUSED on all
      five slots, by the manifest, by the local folder and by the register independently;
    - a clean pair (Androids renumbered to E325-E329) passes, registered or not;
    - a manifest that REPLACES its own earlier declaration passes: the same leaf re-gated as
      .retry.json, and a retry that retitles its own row when nothing is on disk yet;
    - but a retitling retry whose OLD output is already encoded locally is refused (two files);
    - `supersedes` naming the other leaf is a declared replacement and passes;
    - Plex stack parts (- pt1/- pt2) in one manifest pass; two different items in one slot do not;
    - another show, and "Doctor Who (2023)" register rows against "Doctor Who (1963)", never bind;
    - pending-vs-pending: the register breaks the tie in favour of the title it records;
    - the register parser attributes the mid-file "**UFO (1970) - RECORDED" block and a "## ..."
      subsection to the right show, and reads "S00E15-E17" range rows;
    - the title matcher accepts the register's paraphrases and refuses different numbered items;
    - an unreadable manifest and a movie manifest are not this guard's business (exit 0).
  Everything runs in an isolated scratch tree: no path under D:/video is read or written.
#>
$ErrorActionPreference = 'Stop'
$fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}

$script = Join-Path $PSScriptRoot 'assert-slot-not-claimed.ps1'
. (Join-Path $PSScriptRoot 'lib-slot-claims.ps1')
$tmp = Join-Path ([IO.Path]::GetTempPath()) ('slotclaims-' + [guid]::NewGuid().ToString('N'))

$show = 'Doctor Who (1963)'
function Out-Path([string]$root, [string]$slot, [string]$title, [string]$s = $show, [string]$season = 'Season 00') {
  "$root/Television Shows/$s/$season/$s - $slot - $title.mkv"
}
function Row([string]$out, [string]$plexTitle = '', [string[]]$supersedes = @()) {
  $h = [ordered]@{ title = 2; src = 'x'; kind = 'DVD'; out = $out }
  if ($plexTitle) { $h.plexTitle = $plexTitle }
  if ($supersedes.Count) { $h.supersedes = $supersedes }
  [pscustomobject]$h
}
function Write-Manifest([string]$path, [object[]]$rows) {
  New-Item -ItemType Directory -Force -Path (Split-Path $path -Parent) | Out-Null
  ConvertTo-Json -InputObject @($rows) -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
}
$robotTitles = 'A New Frontier', 'Next Episode Trailer - The Ark in Space', 'Robot - Blue Peter', 'Robot Photo Gallery', 'The Title Sequences'
$taraTitles  = 'Now and Then - The Androids of Tara', 'The Androids of Tara Photo Gallery', 'The Humans of Tara', 'Double Trouble', 'The Androids of Tara (Feature-Length Compilation Edition)'

# A fresh world per case: queue (root/running/done), pending, register, local library.
function New-World {
  $w = Join-Path $tmp ([guid]::NewGuid().ToString('N'))
  $o = [pscustomobject]@{ Root = $w; Queue = "$w/_queue"; Pending = "$w/_pending"; Local = "$w/video"; Register = "$w/_pending/SEASON00-ALLOCATION.md" }
  foreach ($d in $o.Queue, "$($o.Queue)/running", "$($o.Queue)/done", $o.Pending, $o.Local) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  Set-Content -LiteralPath $o.Register -Value '# Nothing - Season 00 number allocation (authoritative)' -Encoding UTF8
  $o
}
function Set-Register($world, [string]$text) { Set-Content -LiteralPath $world.Register -Value $text -Encoding UTF8 }
function Register-Rows([int]$first, [string[]]$titles, [string]$disc) {
  $i = $first
  @($titles | ForEach-Object { '| S00E{0} | {1} (annotated description) | {2} | ALLOCATED |' -f $i, $_, $disc; $i++ }) -join "`n"
}
function Run($world, [string]$manifest) {
  $o = & pwsh -NoProfile -File $script -Manifest $manifest -QueueRoot $world.Queue -PendingDir $world.Pending -Register $world.Register -LocalRoot $world.Local 2>&1 | ForEach-Object { "$_" }
  [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($o -join "`n") }
}
function Robot-Rows($world) { $i = 320; @($robotTitles | ForEach-Object { Row (Out-Path $world.Local ('S00E{0}' -f $i++) $_) $_ }) }
function Tara-Rows($world, [int]$first) { $i = $first; @($taraTitles | ForEach-Object { Row (Out-Path $world.Local ('S00E{0}' -f $i++) $_) $_ }) }
function Touch-Local($world, [string]$slot, [string]$title) {
  $p = Out-Path $world.Local $slot $title
  New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null
  Set-Content -LiteralPath $p -Value 'x'
}

try {
  # ---------------------------------------------------------------------------------------------
  # THE INCIDENT, reconstructed. Robot is registered and sits in _queue/done with its outputs
  # encoded locally; The Androids of Tara arrives at the gate from _pending claiming E320-E324.
  $w = New-World
  Set-Register $w ("# Doctor Who (1963) - Season 00 number allocation (authoritative)`n`n| number | extra | disc | state |`n|---|---|---|---|`n" + (Register-Rows 320 $robotTitles 'Robot') + "`n`n**Next free Doctor Who (1963) number: S00E325.**")
  Write-Manifest "$($w.Queue)/done/robot.json" (Robot-Rows $w)
  $i = 320; foreach ($t in $robotTitles) { Touch-Local $w ('S00E{0}' -f $i++) $t }
  $tara = "$($w.Pending)/the-androids-of-tara.json"
  Write-Manifest $tara (Tara-Rows $w 320)
  $r = Run $w $tara
  Check 'Robot/Androids collision -> REFUSED'                   $r.Code 2
  foreach ($n in 320..324) { Check "  names S00E$n"              ($r.Out -like "*S00E$n*") 'True' }
  Check '  cites the Robot manifest'                            ($r.Out -like '*done*robot.json*') 'True'
  Check '  cites the local file'                                ($r.Out -like '*local file*A New Frontier*' -or $r.Out -like '*A New Frontier*local file*') 'True'
  Check '  cites the register line'                             ($r.Out -like '*SEASON00-ALLOCATION.md line *') 'True'
  Check '  and says what to do'                                 ($r.Out -like '*Next free*') 'True'

  # Each source on its own must be enough - the incident had all three, the next one may have one.
  $w1 = New-World; Write-Manifest "$($w1.Queue)/running/robot.json" (Robot-Rows $w1)
  $t1 = "$($w1.Pending)/tara.json"; Write-Manifest $t1 (Tara-Rows $w1 320)
  Check 'manifest in _queue/running alone -> REFUSED'          (Run $w1 $t1).Code 2
  $w1 = New-World; Write-Manifest "$($w1.Queue)/robot.json" (Robot-Rows $w1)
  $t1 = "$($w1.Pending)/tara.json"; Write-Manifest $t1 (Tara-Rows $w1 320)
  Check 'manifest in _queue root alone -> REFUSED'             (Run $w1 $t1).Code 2
  $w1 = New-World; Write-Manifest "$($w1.Pending)/robot.json" (Robot-Rows $w1)
  $t1 = "$($w1.Pending)/tara.json"; Write-Manifest $t1 (Tara-Rows $w1 320)
  Check 'ungated manifest in _pending alone -> REFUSED'        (Run $w1 $t1).Code 2
  $w1 = New-World; $i = 320; foreach ($t in $robotTitles) { Touch-Local $w1 ('S00E{0}' -f $i++) $t }
  $t1 = "$($w1.Pending)/tara.json"; Write-Manifest $t1 (Tara-Rows $w1 320)
  Check 'local file alone -> REFUSED'                          (Run $w1 $t1).Code 2
  $w1 = New-World
  Set-Register $w1 ("# Doctor Who (1963) - Season 00 number allocation (authoritative)`n`n" + (Register-Rows 320 $robotTitles 'Robot'))
  $t1 = "$($w1.Pending)/tara.json"; Write-Manifest $t1 (Tara-Rows $w1 320)
  $r = Run $w1 $t1
  Check 'register row alone (no manifest written yet) -> REFUSED' $r.Code 2
  Check '  on all five slots'                                   ([regex]::Matches($r.Out, 'line \d+').Count) 5

  # ---------------------------------------------------------------------------------------------
  # THE FIX: the same world, Androids renumbered to E325-E329 - unregistered, then registered.
  Write-Manifest $tara (Tara-Rows $w 325)
  $r = Run $w $tara
  Check 'clean pair (E325-E329, not yet registered) -> passes' $r.Code 0
  Set-Register $w ((Get-Content -LiteralPath $w.Register -Raw) + "`n" + (Register-Rows 325 $taraTitles 'The Androids of Tara'))
  Check 'clean pair, registered -> passes'                     (Run $w $tara).Code 0
  Check 'and Robot re-checked against it -> passes'            (Run $w "$($w.Queue)/done/robot.json").Code 0

  # ---------------------------------------------------------------------------------------------
  # A MANIFEST REPLACING ITS OWN EARLIER DECLARATION.
  Write-Manifest "$($w.Queue)/done/the-androids-of-tara.json" (Tara-Rows $w 325)
  Remove-Item -LiteralPath $tara
  $retry = "$($w.Pending)/the-androids-of-tara.retry.json"
  Write-Manifest $retry (Tara-Rows $w 325)
  Check 'same leaves re-gated as .retry.json -> passes'        (Run $w $retry).Code 0
  # The retry retitles one of its own rows. Nothing on disk yet: it replaces its own claim.
  $rows = @(Tara-Rows $w 325); $rows[2] = Row (Out-Path $w.Local 'S00E327' 'The Humans of Tara (Making Of)') 'The Humans of Tara (Making Of)'
  Write-Manifest $retry $rows
  Check 'retry retitling its own row, nothing encoded -> passes' (Run $w $retry).Code 0
  # ...but once the OLD name is already encoded locally, the retitle would leave two files in one slot.
  Touch-Local $w 'S00E327' 'The Humans of Tara'
  $r = Run $w $retry
  Check 'retry retitle with the old output on disk -> REFUSED'  $r.Code 2
  Check '  names the stranded local file'                       ($r.Out -like '*S00E327 - The Humans of Tara.mkv*') 'True'
  # Declaring that file in supersedes makes it a deliberate replacement.
  $rows[2] = Row (Out-Path $w.Local 'S00E327' 'The Humans of Tara (Making Of)') 'The Humans of Tara (Making Of)' @("$show - S00E327 - The Humans of Tara.mkv")
  Write-Manifest $retry $rows
  Check 'same, with the old leaf in supersedes -> passes'       (Run $w $retry).Code 0

  # A DIFFERENT manifest family writing into a taken slot, but declaring the other leaf superseded.
  $w2 = New-World
  Write-Manifest "$($w2.Queue)/done/robot.json" (Robot-Rows $w2)
  $m2 = "$($w2.Pending)/robot-remaster.json"
  Write-Manifest $m2 @( (Row (Out-Path $w2.Local 'S00E320' 'A New Frontier (Remastered)') 'A New Frontier (Remastered)' @("\\NAS\x\$show - S00E320 - A New Frontier.mkv")) )
  Check 'other family + supersedes names the leaf -> passes'   (Run $w2 $m2).Code 0
  Write-Manifest $m2 @( (Row (Out-Path $w2.Local 'S00E320' 'A New Frontier (Remastered)') 'A New Frontier (Remastered)') )
  Check 'other family, no supersedes -> REFUSED'               (Run $w2 $m2).Code 2
  # Writing to the SAME leaf is a replacement in place, not a rival.
  Write-Manifest $m2 @( (Row (Out-Path $w2.Local 'S00E320' 'A New Frontier') 'A New Frontier') )
  Check 'other family, identical leaf -> passes'               (Run $w2 $m2).Code 0

  # ---------------------------------------------------------------------------------------------
  # WITHIN ONE MANIFEST.
  $w3 = New-World
  $m3 = "$($w3.Pending)/stack.json"
  Write-Manifest $m3 @( (Row (Out-Path $w3.Local 'S03E02' 'The Merchant of Venice - pt1' 'BBC Television Shakespeare' 'Season 03')),
                        (Row (Out-Path $w3.Local 'S03E02' 'The Merchant of Venice - pt2' 'BBC Television Shakespeare' 'Season 03')) )
  Check 'Plex stack parts pt1/pt2 in one slot -> passes'        (Run $w3 $m3).Code 0
  Write-Manifest $m3 @( (Row (Out-Path $w3.Local 'S00E05' 'Trailer')), (Row (Out-Path $w3.Local 'S00E05' 'Photo Gallery')) )
  Check 'two different items in one slot, one manifest -> REFUSED' (Run $w3 $m3).Code 2

  # ---------------------------------------------------------------------------------------------
  # SCOPE: other shows never bind; a register section with a year binds only that year.
  $w4 = New-World
  Write-Manifest "$($w4.Queue)/done/ufo.json" @( (Row (Out-Path $w4.Local 'S00E320' 'Something Else' 'UFO (1970)')) )
  Set-Register $w4 ("# Doctor Who (2023) - Season 00 / Season 90 allocation (authoritative)`n`n| S00E320 | A Different 2023 Special | x | ALLOCATED |")
  $m4 = "$($w4.Pending)/tara.json"; Write-Manifest $m4 (Tara-Rows $w4 320)
  Check 'other show in the queue + Doctor Who (2023) register rows -> passes' (Run $w4 $m4).Code 0
  $m4b = "$($w4.Pending)/dw23.json"; Write-Manifest $m4b @( (Row (Out-Path $w4.Local 'S00E320' 'Something Unregistered' 'Doctor Who (2023)')) )
  Check 'but a Doctor Who (2023) manifest IS bound by them -> REFUSED' (Run $w4 $m4b).Code 2

  # ---------------------------------------------------------------------------------------------
  # PENDING vs PENDING: the register breaks the tie.
  $w5 = New-World
  Set-Register $w5 ("# Doctor Who (1963) - Season 00 number allocation (authoritative)`n`n" + (Register-Rows 320 $robotTitles 'Robot'))
  Write-Manifest "$($w5.Pending)/tara.json" (Tara-Rows $w5 320)
  $robotPending = "$($w5.Pending)/robot.json"; Write-Manifest $robotPending (Robot-Rows $w5)
  $r = Run $w5 $robotPending
  Check 'pending rival, register records MY titles -> passes (waived)' $r.Code 0
  Check '  and says it waived it'                               ($r.Out -like '*waived*') 'True'
  Check 'pending rival, register records THEIRS -> REFUSED'    (Run $w5 "$($w5.Pending)/tara.json").Code 2
  # A QUEUED rival is never waived, even when the register backs this manifest.
  Move-Item -LiteralPath "$($w5.Pending)/tara.json" -Destination "$($w5.Queue)/running/tara.json"
  Check 'queued rival is never waived -> REFUSED'              (Run $w5 $robotPending).Code 2

  # ---------------------------------------------------------------------------------------------
  # NOT THIS GUARD'S BUSINESS.
  $w6 = New-World
  $bad = "$($w6.Pending)/broken.json"; Set-Content -LiteralPath $bad -Value '{ not json' -Encoding UTF8
  Check 'unreadable manifest -> exit 0'                        (Run $w6 $bad).Code 0
  $mov = "$($w6.Pending)/film.json"; Write-Manifest $mov @( (Row "$($w6.Local)/Movies/Some Film (1999)/Some Film (1999).mkv") )
  Check 'movie manifest -> exit 0'                             (Run $w6 $mov).Code 0
  Check 'missing manifest -> exit 0'                           (Run $w6 "$($w6.Pending)/nope.json").Code 0

  # ---------------------------------------------------------------------------------------------
  # THE REGISTER PARSER, on the real file's awkward shapes.
  $w7 = New-World
  Set-Register $w7 @'
# Doctor Who (1963) - Season 00 number allocation (authoritative)

| S00E320 | A New Frontier (making-of) | Robot | ALLOCATED |
| Picture Gallery - "Escape is not freedom" (S01E10) | Disk 5 only | 10 | batch |

**Robot** - the FIRST Doctor Who (1963) Season 12 disc; this bold intro must NOT switch the show.

| S00E321 | Next Episode Trailer - The Ark in Space | Robot | ALLOCATED |

---
**UFO (1970) - RECORDED 2026-09-25 by the main session.**

| S00E15-E17 | Production Stills, UFO Memorabilia Gallery 1, UFO Memorabilia Gallery 2 | UFO Disk 5 | RECORDED |

# The Avengers (1961) - Season 00 number allocation (authoritative)
| S00E95 | Did You Know - Trivia | Disk 7 | ALLOCATED |
## Star Trek: Deep Space Nine - Season 00 tail, second append: SETTLED 2026-09-25
| S00E150 | Hidden File 05 - clips from "The Siege" | S2 D7 | ALLOCATED |
'@
  $reg = @(Read-SlotRegister -Path $w7.Register)
  Check 'parser: DW row under its heading'                     (@($reg | Where-Object { $_.Slot -eq 'S00E320' }).Show) 'Doctor Who (1963)'
  Check 'parser: a bold per-disc intro does not switch show'   (@($reg | Where-Object { $_.Slot -eq 'S00E321' }).Show) 'Doctor Who (1963)'
  Check 'parser: a slot mentioned mid-cell is not a row'       (@($reg | Where-Object { $_.Slot -eq 'S01E10' }).Count) 0
  Check 'parser: "**UFO (1970) - RECORDED" switches show'      (@($reg | Where-Object { $_.Slot -eq 'S00E16' }).Show) 'UFO (1970)'
  Check 'parser: range row expands to 3 slots'                 (@($reg | Where-Object { $_.Show -eq 'UFO (1970)' }).Count) 3
  Check 'parser: "## <show> - Season 00" switches show'        (@($reg | Where-Object { $_.Slot -eq 'S00E150' }).Show) 'Star Trek: Deep Space Nine'
  Check 'parser: line numbers are 1-based file lines'          (@($reg | Where-Object { $_.Slot -eq 'S00E320' }).Line) 3
  Check 'show match: "Star Trek: Deep Space Nine" ~ folder'    (Test-SlotShowMatch 'Star Trek: Deep Space Nine' 'Star Trek Deep Space Nine (1993)') 'True'
  Check 'show match: "Friends" ~ "Friends (1994)"'             (Test-SlotShowMatch 'Friends' 'Friends (1994)') 'True'
  Check 'show match: 2023 register never binds 1963 folder'    (Test-SlotShowMatch 'Doctor Who (2023)' 'Doctor Who (1963)') 'False'

  # ---------------------------------------------------------------------------------------------
  # THE TITLE MATCHER. Positives are real register paraphrases from the 2026-09-27 corpus sweep;
  # negatives are real different-item pairs from the same register.
  $M = { param($cell, $cand, $sh = '') Test-SlotRegisterTitleMatch -Cell $cell -Candidates @($cand) -Show $sh }
  Check 'match: annotated cell contains the title'   (& $M 'A New Frontier (making-of documentary: the 1974 handover)' 'A New Frontier') 'True'
  Check 'match: "Additional Outtakes Reel" ~ "Bloopers - Additional Reel"' (& $M 'Bloopers - Additional Reel (DESCRIPTIVE - clapperboard)' 'Additional Outtakes Reel') 'True'
  Check 'match: "Title and Recap Sequence" ~ "Title / Recap Sequence"'     (& $M 'Title / Recap Sequence (86.6 s)' 'Title and Recap Sequence') 'True'
  Check 'match: "Deleted Scene 3" inside a 1-4 range row'  (& $M 'Deleted Scenes 1-4, Behind the Scenes' 'Deleted Scene 3') 'True'
  Check 'match: "Section 31 - Hidden File 05 - Season Two"' (& $M 'Hidden File 05 - clips from "The Siege" (S02E17)' 'Section 31 - Hidden File 05 - Season Two' 'Star Trek Deep Space Nine (1993)') 'True'
  Check 'differ: Deleted Scene 06 vs Deleted Scene 02'     (& $M 'Deleted Scene 02 (Monica)' 'Deleted Scene 06') 'False'
  Check 'differ: Photo Gallery - Killer vs - Weapon'       (& $M 'Photo Gallery - Weapon' 'Photo Gallery - Killer') 'False'
  Check 'differ: DS9 Chronicles - Siege vs - Homecoming'   (& $M 'Deep Space Nine Chronicles - The Homecoming' 'Deep Space Nine Chronicles - The Siege' 'Star Trek Deep Space Nine (1993)') 'False'
  $k = 0; foreach ($i in 0..4) { if (-not (& $M "$($robotTitles[$i]) (register annotation)" $taraTitles[$i] $show)) { $k++ } }
  Check 'differ: all five Robot/Androids slot pairs'       $k 5
}
finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

if ($fails) { Write-Output "FAILED - $fails case(s)"; exit 1 }
Write-Output 'ALL PASSED'
exit 0
