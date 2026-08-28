# Read a DVD title's ON-SCREEN episode title card and say WHICH canonical episode it is.
#
# verify-title-cards.ps1 scores a card against the title the FILENAME already claims - it can only
# confirm or deny a name already chosen. This is the identification step that comes first: OCR the
# same evidence, then score it against EVERY canonical episode of the show and report the best
# match, so the name comes out of the disc rather than out of disc order.
#
# Frames are read through `-f dvdvideo -title N`, the same path transcode.ps1 uses, so the ordinal
# in the answer is the ordinal you rip with.
#
# PREPROCESSING IS THE WHOLE TRICK, and it was measured, not guessed:
#   * The Saint lays thin white type over live action. Plain greyscale OCR of that frame returns
#     noise - "THE LATIN TOUCH" read as "fs gos av _- ee". Binarising the luma and inverting leaves
#     black type on white, and the same frame reads "THE LATIN TOUCH" exactly.
#   * ONE threshold is not enough, and the failure is silent - it reports "no match", which looks
#     like a disc with no card. At 225 four cards on D1/D10 read perfectly and D11's THE SCORPION
#     read as nothing at all; at 180 all five read. Hence a SWEEP, brightest-first-that-works.
#   * The uppercase whitelist removes most of the picture noise, which is what lets a card be found
#     among the stray glyphs the picture behind it contributes.
#
# Read-only. Prints; changes nothing.
# WHERE -Canon COMES FROM, AND WHAT HAPPENS WITHOUT ONE.
# It is a JSON array of {season, ep, title} for the show, taken from the SAME provider query
# plex-season-map.ps1 uses - i.e. metadata.provider.plex.tv with the section's own `episodeOrder`.
# Do NOT build it from `/children` with no parameter: that returns the watch.plex.tv tree, which
# the scanner never matches against, and for some shows it puts a whole season somewhere else.
# Build it once per show, e.g.:
#     $tok  = [Environment]::GetEnvironmentVariable('PLEX_TOKEN','User')
#     $u    = "https://metadata.provider.plex.tv/library/metadata/<seasonRatingKey>/children" +
#             "?X-Plex-Container-Size=100&X-Plex-Token=$tok"     # container size: the default pages at 20
#     [xml]$x = (Invoke-WebRequest $u -UseBasicParsing).Content
#     $x.MediaContainer.Video | ForEach-Object { [pscustomobject]@{season=N; ep=[int]$_.index; title=$_.title} }
#
# WITH NO CANON FILE the script still runs and still prints the `card-like lines seen` list, which
# is the raw OCR of the card and the guest-star credits - useful, and often enough to name an
# episode by hand. What you lose is the SCORING, so nothing is matched for you and the
# identification rests entirely on the reader. That is a real downgrade, not a minor one: say so in
# the disposition if you name a title that way.
param(
  [Parameter(Mandatory)][string]$Disc,        # D:/video/_stage/<disc>
  [Parameter(Mandatory)][string]$Titles,      # dvdvideo title numbers, comma-separated
  [string]$Canon = '',                        # JSON array of {season, ep, title}; omit to skip scoring
  [int]$Start = 20,
  [int]$End = 380,
  [int]$Step = 2,
  [string]$Thresholds = '180,140,225',        # swept in order until something matches convincingly
  [double]$Enough = 0.75,                     # stop sweeping once a canonical title scores this
  [int]$Top = 3,
  # THE SHOW'S FIXED MAIN-TITLE CARD, which must be stripped before scoring - see the note below.
  # Give the words that appear on it. Defaults are The Saint's, as the worked example.
  #   -CreditNames    words that ONLY ever appear in a credit, never in an episode title. Any line
  #                   containing one is dropped. (The Saint: the star and the author.)
  #   -ShowTitleWords the words of the show's own title card plus generic credit furniture. A line
  #                   made ONLY of these is dropped - but only if it also contains -TitleAnchor,
  #                   so a bare "THE" survives (see the false-negative note).
  #   -TitleAnchor    the distinctive word of the show's title.
  #   -KeepLines      exact normalised lines never to strip - for an episode whose real card
  #                   collides with the main title.
  [string]$CreditNames    = 'moore,charteris',
  [string]$ShowTitleWords = 'the,saint,caint,shint,skint,sant,hint,by,starring,moore,roger,leslie,charteris',
  [string]$TitleAnchor    = 'saint',
  [string]$KeepLines      = 'starring the saint',
  [string]$ToolPaths = 'D:/video/.transcode-tools/tool-paths.json'
)
$ErrorActionPreference = 'Stop'
$tools = Get-Content $ToolPaths -Raw | ConvertFrom-Json
$ff = $tools.ffmpeg; $ts = $tools.tesseract
# NOT $canon: PowerShell variable names are case-insensitive, so `$canon = ...` would assign into
# the [string]$Canon PARAMETER, whose declared type silently coerces the 71-element array back to a
# string. The scorer then saw one item, matched nothing, and reported "no canonical title scored
# above zero" on a frame that plainly read TALENTED HUSBAND.
$episodes = if($Canon -and (Test-Path -LiteralPath $Canon)){ Get-Content $Canon -Raw | ConvertFrom-Json } else { @() }
if(-not $episodes){ "  (no canon supplied - printing card-like OCR lines only; NOTHING is matched for you)" }

function Normalize([string]$s){ if(-not $s){ return '' } ($s.ToLower() -replace "[^a-z0-9 ]",' ' -replace '\s+',' ').Trim() }

# THE SHOW'S OWN MAIN TITLE COLLIDES WITH ONE OF ITS EPISODE TITLES.
# Every episode opens on "THE SAINT / BY LESLIE CHARTERIS / STARRING ROGER MOORE". Scored against
# the canon that reads as a PERFECT match for S02E02 "Starring the Saint" - {starring, saint} are
# both present - so every title on every disc returns a confident 1.00 for an episode it is not.
# Observed on D2, where all four titles scored 1.00 for it and only one of them is even Series 2.
# So the main-title credits are stripped LINE BY LINE before scoring. Stripping the WORDS instead
# would make the real "Starring the Saint" unfindable; dropping whole lines keeps it, because its
# card reads "STARRING THE SAINT" - a different line from "THE SAINT STARRING ROGER MOORE".
$mainTitleTokens = @($ShowTitleWords -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
$creditNameList  = @($CreditNames    -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
$keepLineList    = @($KeepLines      -split ',' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })
$anchor          = $TitleAnchor.Trim().ToLower()
function Is-MainTitleLine([string]$norm){
  if(-not $norm){ return $true }
  if($keepLineList -contains $norm){ return $false }   # e.g. the genuine S02E02 "STARRING THE SAINT"
  # A name that only ever appears in a credit. OCR routinely drops the first name, leaving lines
  # like "CC THE SAINT MOORE", so match the surname anywhere rather than the whole credit.
  foreach($n in $creditNameList){ if($norm -match ('\b' + [regex]::Escape($n) + '\b')){ return $true } }
  # Pure credit furniture, never an episode title on its own line. Worth stripping because token
  # matching is deliberately SUBSTRING-based (so OCR run-ons like "BARBARASHELLEY" still match),
  # and that tolerance let "ring" match inside "STARRING": the main-title card scored 0.67 for
  # S04E03 "The Crooked Ring". Not enough to beat a true 1.00, but it is noise in the ranking.
  if($norm -match '^(starring|by|with|and|guest|star|stars|with guest star|with guest stars)$'){ return $true }
  # THE LINE MUST CONTAIN THE ANCHOR TO COUNT AS THE MAIN TITLE.
  # Without this the filter also ate a bare "THE" - which OCR routinely puts on its own line above
  # the story title - and since almost every Saint episode title begins with "The", that silently
  # capped CORRECT matches at 0.67 and defeated the early-exit, so every title swept all three
  # thresholds. Measured on D2 dvdvideo 3: "THE / ARROW OF GOD" is a perfect read and scored 0.67.
  # It never produced a wrong answer - it made good evidence look weak and everything run 3x
  # slower. See references/identification.md: a guard against a false positive can introduce false
  # negatives, and those present as sluggishness rather than as an error.
  if($anchor -and $norm -notmatch ('\b' + [regex]::Escape($anchor) + '\b')){ return $false }
  $toks = @($norm -split ' ' | Where-Object { $_ })
  if(-not $toks){ return $true }
  return @($toks | Where-Object { $mainTitleTokens -notcontains $_ }).Count -eq 0
}
function Strip-MainTitle([string]$txt){
  (@($txt -split "`r?`n" | ForEach-Object { Normalize $_ } |
     Where-Object { -not (Is-MainTitleLine $_) }) -join ' ').Trim()
}
# Token overlap, not edit distance: OCR of a card laid over a moving picture always picks up stray
# glyphs, which edit distance punishes even on a perfect read.
function Score([string]$expected,[string]$got){
  $e = (Normalize $expected) -split ' ' | Where-Object { $_.Length -gt 2 -or $_ -match '^(\d+|i{1,3}|iv|v|vi{0,3}|ix|x)$' }
  if(-not $e){ return 0 }
  $g = Normalize $got
  if(-not $g){ return 0 }
  $hit = @($e | Where-Object { $g -match [regex]::Escape($_) }).Count
  [math]::Round($hit / $e.Count, 2)
}

foreach($t in ($Titles -split ',' | ForEach-Object { [int]$_.Trim() })){
  $best = @{}; $rawFor = @{}; $cardLines = [ordered]@{}; $usedThr = @()
  foreach($thr in ($Thresholds -split ',' | ForEach-Object { [int]$_.Trim() })){
    if(($best.Values | ForEach-Object { $_.score } | Measure-Object -Maximum).Maximum -ge $Enough){ break }
    $usedThr += $thr
    $tmp = Join-Path $env:TEMP ("card-" + [guid]::NewGuid().ToString('N').Substring(0,8))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    try {
      & $ff -hide_banner -loglevel error -f dvdvideo -title $t -i $Disc -ss $Start -to $End `
            -vf "fps=1/$Step,format=gray,lutyuv=y='if(gt(val,$thr),0,255)',scale=iw*2:ih*2" `
            -q:v 3 (Join-Path $tmp 'f%04d.png') -y 2>&1 | Out-Null
      $frames = @(Get-ChildItem $tmp -Filter '*.png' | Sort-Object Name)
      # Early exit: once a canonical title reads perfectly, keep going a little longer to pick up
      # the guest-star card that follows it (independent corroboration), then stop.
      $perfectAt = -1; $seen = 0
      foreach($f in $frames){
        $seen++
        if($perfectAt -ge 0 -and ($seen - $perfectAt) -gt 8){ break }
        $base = Join-Path $tmp $f.BaseName
        & $ts $f.FullName $base --psm 6 -c tessedit_char_whitelist='ABCDEFGHIJKLMNOPQRSTUVWXYZ ' 2>&1 | Out-Null
        # -Raw on an empty file returns $null, not '' - calling .Trim() on it throws.
        $txt = [string]$(if(Test-Path "$base.txt"){ Get-Content "$base.txt" -Raw } else { '' })
        if([string]::IsNullOrWhiteSpace($txt)){ continue }
        $sec = $Start + ($Step * ([int]($f.BaseName -replace '\D','') - 1))
        # Card-like lines: short, and dominated by capitals. This is where the guest-star and
        # director credits come from, which corroborate a title independently of the title itself.
        foreach($ln in ($txt -split "`r?`n")){
          $ln = $ln.Trim()
          if($ln.Length -lt 6 -or $ln.Length -gt 60){ continue }
          if(($ln -replace '[^A-Za-z]','').Length -lt 6){ continue }
          # Drop the scatter of single letters the picture contributes.
          if(@($ln -split '\s+' | Where-Object { $_.Length -ge 3 }).Count -lt 2){ continue }
          if(-not $cardLines.Contains($ln)){ $cardLines[$ln] = "${sec}s/thr$thr" }
        }
        $scoreTxt = Strip-MainTitle $txt
        if([string]::IsNullOrWhiteSpace($scoreTxt)){ continue }
        foreach($c in $episodes){
          $sc = Score $c.title $scoreTxt
          if($sc -le 0){ continue }
          $key = "S{0:d2}E{1:d2} {2}" -f $c.season, $c.ep, $c.title
          if((-not $best.Contains($key)) -or $sc -gt $best[$key].score){
            $best[$key] = [pscustomobject]@{ score=$sc; sec=$sec; thr=$thr }
            $rawFor[$key] = ($txt -replace '\s+',' ').Trim()
          }
          if($sc -ge 1.0 -and $perfectAt -lt 0){ $perfectAt = $seen }
        }
      }
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  }
  "=== $(Split-Path $Disc -Leaf)  dvdvideo title $t   (${Start}-${End}s step ${Step}s, thresholds tried: $($usedThr -join ','))"
  if($best.Count -eq 0){ "  NO MATCH - look at a contact sheet for this title before naming it" }
  $best.GetEnumerator() | Sort-Object { -$_.Value.score } | Select-Object -First $Top | ForEach-Object {
    "  {0,-5} {1,-45} at {2,4}s (thr {3})" -f $_.Value.score, $_.Key, $_.Value.sec, $_.Value.thr
    $r = $rawFor[$_.Key]
    "        OCR: " + $r.Substring(0, [math]::Min(200, $r.Length))
  }
  "  -- card-like lines seen --"
  $cardLines.GetEnumerator() | ForEach-Object { "     {0,-12} {1}" -f $_.Value, $_.Key }
}
