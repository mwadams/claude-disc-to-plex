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
# NOT EVERY SHOW HAS A TITLE CARD, so silence can never be a refusal.
#
# Plenty of series - and every film - put no episode title on screen at all, and OCR over moving
# footage fails on plenty that do. A check that refused whenever it could not read a card would
# block most of the library's legitimate work, so UNREAD is a PASS, always, and the summary counts
# them so the coverage is visible rather than assumed.
#
# The only refusal is a POSITIVE CONTRADICTION: a card was read, and it scores clearly better
# against a DIFFERENT episode of the same season than against the slot the filename claims. That
# turns "I could not read it" (an OCR failure) into "it says something else, and here is which
# episode it says" (an identification). On The West Wing Season 3 the distinction is stark - the
# file named E05 reads ON THE DAY BEFORE, which scores 1.00 against episode 4 and 0.00 against the
# War Crimes it claimed. -Margin is how much better the rival must be before that verdict is given.
#
# Deliberately NOT a contiguity check. Gaps in a season are normal here: episodes live across
# several drives, and a set in progress waits for gaps to be filled - so "E04 is missing" says
# nothing about whether E05 is E05. This asks only whether THIS file is the episode it claims, and
# never looks at its neighbours.
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
  [string]$ToolPaths = 'D:\video\.transcode-tools\tool-paths.json',
  # WHERE THE EXPECTED TITLE COMES FROM WHEN THE FILENAME HAS NONE.
  #
  # This script used to read the expected title out of the filename's ` - SxxEyy - Title ` segment
  # and SKIP anything else. Numbered episodes in this library are BARE (`The West Wing S03E01.mkv`)
  # because that is what references/naming.md specifies for them - so the check silently skipped
  # every episode of every series it was written to protect, and reported a clean run for doing
  # nothing. The West Wing Season 3 published eighteen episodes one slot too high, all with an
  # on-screen title card naming the true episode, and this script would have said SKIP to all of
  # them. Give it -Show and it asks Plex what episode N of this season IS, which is the same
  # authority Plex will use to display it.
  [string]$Show,                                          # e.g. 'The West Wing' - enables bare names
  [string]$BaseUrl = $env:PLEX_BASEURL,
  [string]$Token   = $env:PLEX_TOKEN,
  # HOW MUCH BETTER A RIVAL SLOT MUST SCORE BEFORE THIS CALLS IT WRONG. See the verdict rules below.
  [double]$Margin = 0.34,
  # WHERE THE VERDICTS ARE KEPT SO SOMETHING ELSE CAN READ THEM. OCR over a season takes minutes, so
  # nothing can afford to re-run this at the moment the user is asked to confirm a work in Plex -
  # and that is exactly the moment the answer is worth having. Verdicts are written per FILE and
  # merged with whatever the CSV already holds, so a season checked a disc at a time accumulates.
  [string]$OutCsv = 'D:/video/_episode-identity.csv'
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

# ---- CANONICAL TITLES, so a BARE filename has something to be checked against ------------------
# $canon[season][index] = title. Empty unless -Show was given and Plex answered.
$canon = @{}
if ($Show) {
  if (-not $Token)   { $Token   = [Environment]::GetEnvironmentVariable('PLEX_TOKEN','User') }
  if (-not $BaseUrl) { $BaseUrl = [Environment]::GetEnvironmentVariable('PLEX_BASEURL','User') }
  if (-not $Token -or -not $BaseUrl) { throw "-Show needs PLEX_TOKEN and PLEX_BASEURL (neither is ever printed)" }
  $h = @{ 'X-Plex-Token' = $Token; 'Accept' = 'application/json' }
  function Get-MC($p) { (Invoke-RestMethod ($BaseUrl.TrimEnd('/') + $p) -Headers $h).MediaContainer }
  $showObj = $null
  foreach ($s in ((Get-MC '/library/sections').Directory | Where-Object { $_.type -eq 'show' })) {
    $hit = (Get-MC "/library/sections/$($s.key)/all?type=2").Metadata | Where-Object { $_.title -match $Show }
    if ($hit) { $showObj = @($hit)[0]; break }
  }
  if (-not $showObj) { throw "no show matching '$Show' in any TV section" }
  foreach ($se in ((Get-MC "/library/metadata/$($showObj.ratingKey)/children").Metadata | Where-Object { $null -ne $_.index })) {
    $sn = [int]$se.index
    $canon[$sn] = @{}
    foreach ($ep in (Get-MC "/library/metadata/$($se.ratingKey)/children").Metadata) {
      if ($null -ne $ep.index) { $canon[$sn][[int]$ep.index] = "$($ep.title)" }
    }
  }
  Write-Host ("canonical titles from Plex for '{0}': {1}" -f $showObj.title,
    (($canon.Keys | Sort-Object | ForEach-Object { "S{0:D2}={1}" -f $_, $canon[$_].Count }) -join ' '))
}

$tmp = Join-Path $env:TEMP ("titlecards-" + [guid]::NewGuid().ToString('N').Substring(0,8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$rows = @()
try {
  foreach($f in $files){
    # NAMED form first - its title is in the filename and needs no lookup. Then the BARE form,
    # which is what every numbered episode in this library actually uses.
    $expected = ''; $sNum = -1; $eNum = -1
    if($f.BaseName -match '^(?<show>.+?) - S(?<s>\d+)E(?<e>\d+) - (?<title>.+)$'){
      $expected = $Matches['title']; $sNum = [int]$Matches['s']; $eNum = [int]$Matches['e']
    }
    elseif($f.BaseName -match '(?i)S(?<s>\d+)E(?<e>\d+)\s*$'){
      $sNum = [int]$Matches['s']; $eNum = [int]$Matches['e']
      if($canon.ContainsKey($sNum) -and $canon[$sNum].ContainsKey($eNum)){ $expected = $canon[$sNum][$eNum] }
    }
    if(-not $expected){
      $why = if($Show){ '(no canonical title for this slot)' } else { '(bare name - pass -Show to check it)' }
      $rows += [pscustomobject]@{ File=$f.Name; Expected=$why; Score=0; At=''; Verdict='SKIP'; Read='' }
      continue
    }
    Get-ChildItem $tmp -File -EA SilentlyContinue | Remove-Item -Force
    # greyscale + upscale: the card is thin white type, and tesseract reads it far better at 2x
    & $ff -v error -ss $Start -to $End -i $f.FullName `
          -vf "fps=1/$Step,format=gray,scale=iw*2:ih*2" -q:v 3 (Join-Path $tmp 'f%03d.png') 2>$null

    # KEEP EVERY FRAME'S TEXT, not just the best-scoring one. When a file is misnumbered the claimed
    # title scores 0.00 on every frame, so `if($sc -gt $best)` never fires and the card's actual
    # words are never captured - leaving nothing to identify it WITH. That is the whole evidence of
    # the fault, discarded by the loop that was looking for agreement.
    $best = 0.0; $bestTxt = ''; $bestIdx = 0; $texts = @()
    foreach($png in (Get-ChildItem $tmp -Filter '*.png' | Sort-Object Name)){
      $out = Join-Path $tmp 'o'
      & $ts $png.FullName $out --psm 6 2>$null
      $txt = if(Test-Path "$out.txt"){ (Get-Content "$out.txt" -Raw) } else { '' }
      if("$txt".Trim()){ $texts += $txt }
      $sc = Score $expected $txt
      if($sc -gt $best){
        $best = $sc; $bestIdx = [int]($png.BaseName -replace '\D','')
        $bestTxt = (($txt -split "`n" | Where-Object { $_.Trim() }) -join ' / ').Trim()
      }
      if($best -ge 1.0){ break }
    }

    # ---- VERDICT ---------------------------------------------------------------------------------
    # Agreement is enough on its own. Disagreement is not: before calling a file wrong, the card has
    # to NAME something, and what it names has to be another episode of this same season. Anything
    # short of that is UNREAD - a card this OCR could not read, or a show that prints none.
    $rivalTitle = ''; $rivalIdx = -1; $rivalScore = 0.0
    if($best -lt $MinScore -and $canon.ContainsKey($sNum)){
      foreach($k in $canon[$sNum].Keys){
        if($k -eq $eNum){ continue }
        foreach($t in $texts){
          $sc = Score $canon[$sNum][$k] $t
          if($sc -gt $rivalScore){ $rivalScore = $sc; $rivalIdx = $k; $rivalTitle = $canon[$sNum][$k] }
        }
      }
    }
    $verdict =
      if($best -ge $MinScore){ 'OK' }
      elseif($rivalScore -ge $MinScore -and ($rivalScore - $best) -ge $Margin){ 'MISMATCH' }
      else{ 'UNREAD' }

    $at = $Start + ($bestIdx - 1) * $Step
    $shown = if($verdict -eq 'MISMATCH'){ "card names E{0:D2} '{1}' ({2})" -f $rivalIdx, $rivalTitle, $rivalScore }
             else { $bestTxt }
    $rows += [pscustomobject]@{
      File     = ($f.BaseName -replace '^.+ - S','S')
      Expected = $expected
      Score    = $best
      At       = if($verdict -eq 'UNREAD'){ '' } else { "${at}s" }
      Verdict  = $verdict
      RivalIdx = $rivalIdx
      Read     = if($shown.Length -gt 60){ $shown.Substring(0,60) } else { $shown }
    }
    $rows[-1] | Format-Table -HideTableHeaders -AutoSize | Out-String | Write-Host -NoNewline
  }
} finally { Remove-Item $tmp -Recurse -Force -EA SilentlyContinue }

''
$rows | Format-Table File, Expected, Score, At, Verdict, Read -AutoSize

# ---- PERSIST, keyed by full path so a re-check REPLACES its own earlier verdict ------------------
if($OutCsv){
  try{
    $keep = @()
    if(Test-Path -LiteralPath $OutCsv){
      $mine = @{}; foreach($f in $files){ $mine[$f.FullName] = $true }
      $keep = @(Import-Csv -LiteralPath $OutCsv | Where-Object { -not $mine.ContainsKey($_.Path) })
    }
    $now = Get-Date -Format 's'
    $fresh = for($i=0; $i -lt $rows.Count; $i++){
      [pscustomobject]@{
        Path     = $files[$i].FullName
        Work     = (Split-Path -Leaf (Split-Path -Parent (Split-Path -Parent $files[$i].FullName)))
        Season   = (Split-Path -Leaf (Split-Path -Parent $files[$i].FullName))
        Expected = $rows[$i].Expected
        Verdict  = $rows[$i].Verdict
        Score    = $rows[$i].Score
        RivalIdx = $rows[$i].RivalIdx
        Read     = $rows[$i].Read
        Checked  = $now
      }
    }
    @($keep + $fresh) | Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Encoding UTF8
    "verdicts -> $OutCsv"
  } catch { Write-Warning "could not write $OutCsv : $($_.Exception.Message)" }
}
$bad     = @($rows | Where-Object { $_.Verdict -eq 'MISMATCH' })
$ok      = @($rows | Where-Object { $_.Verdict -eq 'OK' })
$unread  = @($rows | Where-Object { $_.Verdict -eq 'UNREAD' })
$skipped = @($rows | Where-Object { $_.Verdict -eq 'SKIP' })

# SAY WHAT WAS NOT CHECKED. An UNREAD is a pass, so a run that read nothing at all would otherwise
# report exactly like a clean one - which is how a check that skipped this library's entire naming
# convention went unnoticed in the first place.
"{0} checked: {1} OK, {2} MISMATCH, {3} unread (no card this OCR could read - passed), {4} skipped" -f `
  $rows.Count, $ok.Count, $bad.Count, $unread.Count, $skipped.Count
if($bad){
  ''
  "MISMATCH - the disc's own title card names a DIFFERENT episode of this season:"
  foreach($b in $bad){ "    {0}  claims '{1}'  but {2}" -f $b.File, $b.Expected, $b.Read }
  ''
  'Do not publish these. Re-check the numbering against the cards before anything reaches the NAS.'
  exit 2
}
exit 0
