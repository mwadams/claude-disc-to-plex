# Read each episode's ON-SCREEN title card and check it against the filename. OCR, not inference.
#
# WHY. Episode numbering is the single most expensive thing this pipeline gets wrong, and every
# wrong answer so far passed its structural checks: right file count, plausible runtimes, tidy
# disc-order mapping. Runtime matching in particular has now produced two successive WRONG answers
# on the same show (The Newsroom S2), because several episodes of a series are near-identical in
# length and a one-slot shift still "fits".
#
# Title-card verification is ESTABLISHED PRACTICE here, not a new idea: identification.md documents
# it and extract-title-cards.ps1 tiles the frames for it. Both need a human to look at the sheet,
# which is why in a long batch the step quietly gets skipped - as it was on The Newsroom S2 D1.
# This script is the unattended complement: same evidence, OCR'd, with a pass/fail verdict.
#   extract-title-cards.ps1 -> contact sheet to eyeball (use when OCR is doubtful, or to read
#                              guest-star credits as a backup identification)
#   verify-title-cards.ps1  -> automatic OK/MISMATCH per episode (use as the gate before publish)
#
# Read-only. Reports; changes nothing.
param(
  [Parameter(Mandatory)][string]$Path,                    # a season folder, or one .mkv
  # Search window. Cards do NOT land at a consistent point even WITHIN one series: Survivors S1
  # puts them at 60s, 68s, 108s - and 276s for "Corn Dolly", which opens on a long teaser. A
  # window that stops at 200s reports a confident MISMATCH on a correctly-named file, which is
  # worse than no check. Widen rather than narrow; the early-exit on a 1.00 score keeps it cheap.
  [int]$Start = 25,
  [int]$End   = 420,
  [int]$Step  = 2,                                        # sample every N seconds
  [double]$MinScore = 0.60,                               # below this = MISMATCH
  [string]$ToolPaths = 'D:\video\.transcode-tools\tool-paths.json'
)
$ErrorActionPreference = 'Stop'

$tools = Get-Content $ToolPaths -Raw | ConvertFrom-Json
$ff = $tools.ffmpeg
$ts = $tools.tesseract
foreach($t in @($ff,$ts)){ if(-not (Test-Path -LiteralPath $t)){ throw "tool not found: $t" } }

# tesseract is NOT on PATH in this environment and never has been - it is resolved from
# tool-paths.json. Testing `Get-Command tesseract` reports "missing" and is the wrong test.

$files = if ((Get-Item -LiteralPath $Path).PSIsContainer) {
           Get-ChildItem -LiteralPath $Path -Filter '*.mkv' -File | Sort-Object Name
         } else { @(Get-Item -LiteralPath $Path) }

function Normalize([string]$s){
  if(-not $s){ return '' }
  ($s.ToLower() -replace "[^a-z0-9 ]",' ' -replace '\s+',' ').Trim()
}
# Token-overlap score. Deliberately NOT Levenshtein: OCR of a lower-third card picks up stray
# glyphs from the picture behind it, so edit distance punishes a correct read. What matters is
# whether the card's words are present.
function Score([string]$expected,[string]$got){
  # KEEP short numeric/roman tokens. Dropping everything <= 2 chars made "Lights of London (1)"
  # and "(2)" reduce to the identical {lights, london}: the scorer returned 1.00 for whichever
  # part came first in the list and could NOT tell two-parters apart at all. "Election Night,
  # Part I" vs "Part II" had exactly the same hole, so those Newsroom "OK"s never actually
  # distinguished the parts either. A part number is often the ONLY difference between two
  # episodes, so it must survive tokenisation.
  $e = (Normalize $expected) -split ' ' |
       Where-Object { $_.Length -gt 2 -or $_ -match '^(\d+|i{1,3}|iv|v|vi{0,3}|ix|x)$' }
  if(-not $e){ return 0 }
  $g = Normalize $got
  if(-not $g){ return 0 }
  $hit = @($e | Where-Object { $g -match [regex]::Escape($_) }).Count
  [math]::Round($hit / $e.Count, 2)
}

$tmp = Join-Path $env:TEMP ("titlecards-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$rows = @()
try {
  foreach($f in $files){
    if($f.BaseName -notmatch '^(?<show>.+?) - S(?<s>\d+)E(?<e>\d+) - (?<title>.+)$'){
      $rows += [pscustomobject]@{ File=$f.Name; Expected='(unparsable name)'; Score=0; At=''; Verdict='SKIP'; Read='' }
      continue
    }
    $expected = $Matches['title']
    Get-ChildItem $tmp -File -EA SilentlyContinue | Remove-Item -Force
    # greyscale + upscale: the card is thin white type, and tesseract reads it far better at 2x
    & $ff -v error -ss $Start -to $End -i $f.FullName `
          -vf "fps=1/$Step,format=gray,scale=iw*2:ih*2" -q:v 3 (Join-Path $tmp 'f%03d.png') 2>$null

    $best = 0.0; $bestTxt = ''; $bestIdx = 0
    foreach($png in (Get-ChildItem $tmp -Filter '*.png' | Sort-Object Name)){
      $out = Join-Path $tmp 'o'
      & $ts $png.FullName $out --psm 6 2>$null
      $txt = if(Test-Path "$out.txt"){ (Get-Content "$out.txt" -Raw) } else { '' }
      $sc = Score $expected $txt
      if($sc -gt $best){
        $best = $sc; $bestIdx = [int]($png.BaseName -replace '\D','')
        $bestTxt = (($txt -split "`n" | Where-Object { $_.Trim() }) -join ' / ').Trim()
      }
      if($best -ge 1.0){ break }
    }
    $at = $Start + ($bestIdx - 1) * $Step
    $rows += [pscustomobject]@{
      File     = ($f.BaseName -replace '^.+ - S','S')
      Expected = $expected
      Score    = $best
      At       = "${at}s"
      Verdict  = if($best -ge $MinScore){ 'OK' } else { 'MISMATCH' }
      Read     = if($bestTxt.Length -gt 60){ $bestTxt.Substring(0,60) } else { $bestTxt }
    }
    $rows[-1] | Format-Table -HideTableHeaders -AutoSize | Out-String | Write-Host -NoNewline
  }
} finally { Remove-Item $tmp -Recurse -Force -EA SilentlyContinue }

''
$rows | Format-Table File, Expected, Score, At, Verdict -AutoSize
$bad = @($rows | Where-Object { $_.Verdict -eq 'MISMATCH' })
if($bad){ "$($bad.Count) MISMATCH(es) - the filename disagrees with the on-screen card. Investigate before publishing." }
else    { "all $($rows.Count) episode(s) matched their on-screen title card." }
