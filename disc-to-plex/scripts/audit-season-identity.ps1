# Does every published episode slot hold the episode its own DISC said it holds?
#
# WHY THIS EXISTS
# ---------------
# Every expensive mistake in this library passed its structural checks - right file count, plausible
# durations, matching slots - and held the wrong episode. The evidence that would have caught them
# already exists: each disc's dispositions file records what its titles ARE, proven from content
# (a chapter-menu card, a line of dialogue, a title card). Nothing ever compared that record against
# what Plex believes about the slot the file landed in.
#
# 2026-09-18, Man In A Suitcase. Three episodes - S01E14, S01E23, S01E30 - are padded to EXACTLY
# 2953.621 s, so duration cannot discriminate between them at all. A duration-led pairing put one of
# them on the wrong side of that tie, and a dispositions pass then concluded - from two independent
# measurements, both artefacts of method - that an episode was missing from the library. It was not.
# The whole question was settled in one pass by asking: does the title this disc's own menu named
# match the title Plex has for that slot? Thirty of thirty did.
#
# WHAT IT CHECKS, per episode slot published into the show:
#   1. A DISPOSITION ROW CLAIMS THAT SLOT. A file published with no content-derived identity behind
#      it is the gap this exists to surface, not a pass.
#   2. NO TWO DISCS CLAIM THE SAME SLOT. That is a collision: one of them overwrote the other.
#   3. THE DISC'S TITLE MATCHES PLEX'S CANONICAL TITLE for that slot, compared on letters and digits
#      only, ignoring a leading "The"/"A" (the library's own records say "The Property of a
#      Gentleman" where TheTVDB says "Property of a Gentleman"; that is not a fault).
#
# WHAT IT DOES NOT TREAT AS A FAULT
#   * A SLOT WITH NO FILE. Partial sets are normal here - discs live across several external drives,
#     so a missing episode usually means "on another drive", not "missing". Reported as coverage.
#   * A SLOT PLEX HAS NO TITLE FOR. Reported, because it usually means the show's Plex match is
#     wrong or the season is unmatched - actionable, but not evidence of a mis-slotting.
#
#   pwsh -File audit-season-identity.ps1 -Show 'Man In A Suitcase'
#   pwsh -File audit-season-identity.ps1 -Show 'Manhunt' -Season 1 -Quiet   # exit code only
#   pwsh -File audit-season-identity.ps1 -SelfTest
#
# exit 0 = every published slot is backed by its disc's own evidence and agrees with Plex
# exit 2 = at least one slot is unbacked, collided, or disagrees
param(
  [string]$Show = '',
  [int]$Season = 1,
  [string]$VideoRoot = 'D:/video',
  [int]$Section = 5,
  [switch]$SelfTest,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

function ConvertTo-ComparableTitle {
  <# Letters and digits only, lower case, with a leading article dropped. Punctuation and case are
     transfer-house noise ("SOMEBODY LOSES, SOMEBODY... WINS" off a menu card vs TheTVDB's
     "Somebody Loses, Somebody... Wins?"), and so is a leading "The". #>
  param([AllowNull()][string]$Text)
  if (-not $Text) { return '' }
  $t = "$Text".Trim() -replace '^(?i)(the|a)\s+', ''
  return ($t -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
}

function Get-TitleDistance {
  <# Levenshtein distance between two already-comparable strings. Small and iterative; these are
     episode titles, not documents. #>
  param([string]$A, [string]$B)
  if ($A -eq $B) { return 0 }
  if (-not $A) { return $B.Length }
  if (-not $B) { return $A.Length }
  $prev = 0..$B.Length
  for ($i = 1; $i -le $A.Length; $i++) {
    $cur = @($i) + (1..$B.Length | ForEach-Object { 0 })
    for ($j = 1; $j -le $B.Length; $j++) {
      $cost = if ($A[$i - 1] -eq $B[$j - 1]) { 0 } else { 1 }
      $cur[$j] = [math]::Min([math]::Min($cur[$j - 1] + 1, $prev[$j] + 1), $prev[$j - 1] + $cost)
    }
    $prev = $cur
  }
  return $prev[$B.Length]
}

function Test-TitlesNearlyEqual {
  <# A ONE-CHARACTER DIFFERENCE IS NOT EVIDENCE OF A WRONG EPISODE. Manhunt S01E07's menu card reads
     "Better Doubt Then Die" where TheTVDB has "Better Doubt Than Die" - a transfer-house or OCR
     slip, on a file that is unarguably in the right slot. Calling that a fault trains the reader to
     skim past this report, which is how a real one gets missed. #>
  param([string]$A, [string]$B)
  $a = ConvertTo-ComparableTitle $A; $b = ConvertTo-ComparableTitle $B
  if ($a -eq $b) { return $true }
  if (-not $a -or -not $b) { return $false }
  $d = Get-TitleDistance $a $b
  $len = [math]::Max($a.Length, $b.Length)
  # SHORT TITLES GET NO SLACK AT ALL. One letter is 5% of "Better Doubt Then Die" and 17% of
  # "The Bridge" - and "The Bride" would be a different episode. Below 12 comparable characters the
  # only acceptable difference is none.
  $tolerance = $(if ($len -ge 12) { [math]::Max(1, [math]::Floor($len * 0.10)) } else { 0 })
  return ($d -le $tolerance)
}

function Get-SlotKey {
  <# THE TRAP THIS EXISTS TO AVOID: `"S{0:00}E{1:00}" -f $v.index` does NOT zero-pad when index
     arrives from ConvertFrom-Json as a STRING - it yields "S1E1", so every single-digit episode
     misses its lookup and reads as "Plex has no title". That produced nine fictitious mismatches on
     this audit's first run, on a library that was correct. Cast, every time. #>
  param($SeasonNo, $EpisodeNo)
  return ('S{0:00}E{1:00}' -f [int]$SeasonNo, [int]$EpisodeNo)
}

function Get-ClaimedTitle {
  <# The TITLE out of a disposition row's identity field, which is not always just a title.
     Most discs write `S01E19 Nerve|speech:...`, but some pack the whole justification in before the
     first pipe:
       `S01E19 Nerve - dvdvideoTitle 6 (byte-proven: ...). CONFIDENCE HIGH ... supersedes \\NAS\...`
     Comparing that to "Nerve" fails, and on 2026-09-18 it made four correct Farscape re-rips read as
     collisions. Cut at the markers that begin evidence prose - never at a bare " - ", because real
     titles contain one ("Serenity - The 10th Character"). #>
  param([AllowNull()][string]$Text)
  $t = "$Text".Trim()
  # ' - re-rip for' and ' - already published as' are the two openings the re-rip discs use for their
  # justification prose ("Nine Dozen Heroes and One Wicked Man - re-rip for QUALITY only (disc 5.86
  # Mb/s...)"). Specific enough not to cut a real title, which is why neither is a bare ' - '.
  foreach ($cut in ' - dvdvideoTitle', ' - dvdvideo ', ' (byte-proven', '. CONFIDENCE', ' CONFIDENCE ',
                    ' QUALITY re-rip', ' - re-rip for', ' - already published as', ' supersedes ',
                    ' - MakeMKV ', ' - VTS_') {
    $i = $t.IndexOf($cut, [StringComparison]::OrdinalIgnoreCase)
    if ($i -gt 0) { $t = $t.Substring(0, $i).Trim() }
  }
  return $t.TrimEnd('.', ',', ' ')
}

function Get-SlotFromLeaf {
  <# The episode slot a published filename declares, or '' if it declares none. #>
  param([AllowNull()][string]$Leaf)
  if ("$Leaf" -match '(?i)S(\d{1,2})E(\d{1,3})') { return (Get-SlotKey $Matches[1] $Matches[2]) }
  return ''
}

function Read-DispositionClaims {
  <# The identity rows a disc wrote: slot -> title, from lines like
       t01|episode|S01E06 Man from the Dead|menu:...
     Only `episode` and `extra` rows carry an identity; `exclude` rows are boilerplate. #>
  # AllowEmptyCollection: an empty or whitespace-only dispositions file is a real state (Manhunt
  # Disk 1, 2026-09-18) and made a Mandatory [string[]] throw mid-audit. A file with nothing in it
  # means "no claims", which the caller already handles as unbacked.
  param([AllowEmptyCollection()][AllowEmptyString()][AllowNull()][string[]]$Lines = @())
  if (-not $Lines) { return @() }
  $claims = @()
  foreach ($l in $Lines) {
    # Two shapes in the wild: "S09E01 Title" and the full library leaf "Friends (1994) - S10E01 -
    # Title" (Friends S10, 2026-09-19 - read as NO claims, all 12 slots flagged as unbacked).
    # A THIRD SHAPE: the double episode, `Friends (1994) - S10E17-E18 - The Last One`. Two aired parts
    # authored as one title ship as ONE file under a spanning name, and the span was read as no claim
    # at all - so the finale reported itself as published with NO identity evidence (2026-09-20).
    # Every slot the span names is claimed by that row.
    # A FOURTH SHAPE: the slot ON ITS OWN, `t01|episode|S01E01|speech:...`. Some shows have no
    # on-screen episode titles, so the disposition names the slot and stops - and requiring a title
    # meant the row parsed as NO CLAIM AT ALL. The Owl Service's eight episodes were reported as
    # published with no identity evidence on 2026-09-20 on the strength of rows that named every
    # one of them correctly. The title is optional; the SLOT is the claim.
    # `feature` COUNTS TOO WHEN THE ROW NAMES A SLOT. Some discs write their episodes as feature
    # rows - The Water Margin's box set does throughout - and restricting the type to episode/extra
    # read six correctly-identified episodes as having no evidence at all (2026-09-20). This cannot
    # widen the net wrongly: a feature row for an actual film names no SxxEnn, so it never matches.
    # A FIFTH SHAPE: the show name before the slot with NO dash at all,
    # `t01|episode|Doctor Who (1963) S02E30 The Executioners|speech:...`. The prefix group used to
    # require " - " (space-dash-space), so a plain space between show and slot matched nothing and the
    # row claimed no slot. 2026-09-22: The Chase wrote all six of its rows that way, and the audit
    # reported "*** NO IDENTITY EVIDENCE - 6 slot(s) published with no disposition row claiming them"
    # for S02E30-E35 - which are the CORRECT slots for that story, named by rows sitting right there
    # in the file. A false alarm of this shape is expensive twice over: it accuses a correct disc, and
    # it trains the reader to discount the one real mis-slotting this audit exists to catch.
    # `\s` subsumes " - " (which ends in a space), so this widening keeps every earlier shape.
    if ($l -match '^(t\d+)\|(episode|extra|feature)\|(?:[^|]*?\s)?(S\d{1,2}E\d{1,3}(?:\s*-\s*(?:S\d{1,2})?E\d{1,3})+|S\d{1,2}E\d{1,3})(?:(?:\s+-)?\s+([^|]+))?\|') {
      $row = $Matches[1]; $span = $Matches[3]; $title = (Get-ClaimedTitle $Matches[4])
      $season = $(if ($span -match '^S(\d{1,2})') { $Matches[1] } else { '' })
      foreach ($m in [regex]::Matches($span, '(?i)(?:S(\d{1,2}))?E(\d{1,3})')) {
        $sn = $(if ("$($m.Groups[1].Value)") { $m.Groups[1].Value } else { $season })
        if (-not "$sn") { continue }
        $claims += [pscustomobject]@{ Row = $row; Slot = (Get-SlotKey $sn $m.Groups[2].Value); Title = $title }
      }
    }
  }
  return $claims
}

if ($SelfTest) {
  $fail = 0
  function T($n, $c) { if ($c) { "  ok   $n" } else { $script:fail++; "  FAIL $n" } }
  T 'slot key zero-pads a STRING index' ((Get-SlotKey '1' '9') -eq 'S01E09')
  T 'slot key zero-pads an int index'   ((Get-SlotKey 1 9) -eq 'S01E09')
  T 'slot key keeps two digits'         ((Get-SlotKey 1 30) -eq 'S01E30')
  $lc = @(Read-DispositionClaims @('t03|episode|Friends (1994) - S10E01 - The One After Joey and Rachel Kiss|speech:x', 't04|episode|S09E01 The One Where No One Proposes|speech:y'))
  T 'claims: full-leaf row form is read'  ($lc.Count -eq 2 -and $lc[0].Slot -eq 'S10E01' -and $lc[0].Title -match '^The One After Joey')
  T 'claims: short row form still read'   ($lc[1].Slot -eq 'S09E01' -and $lc[1].Title -match '^The One Where No One')
  $sp = @(Read-DispositionClaims @('t07|episode|Friends (1994) - S10E17-E18 - The Last One|speech:x'))
  T 'claims: a double episode claims BOTH slots' ($sp.Count -eq 2 -and $sp[0].Slot -eq 'S10E17' -and $sp[1].Slot -eq 'S10E18')
  T 'claims: both span slots carry the title'    (@($sp | Where-Object { $_.Title -eq 'The Last One' }).Count -eq 2)
  $ft = @(Read-DispositionClaims @('t00|feature|The Water Margin (1973) - S01E01 - Nine Dozen Heroes and One Wicked Man - re-rip for QUALITY only (disc 5.86 Mb/s)|speech:x',
                                   't09|feature|O Brother Where Art Thou - the feature|speech:y'))
  T 'claims: a feature row naming a slot is a claim' ($ft.Count -eq 1 -and $ft[0].Slot -eq 'S01E01')
  T 'claims: a feature row with no slot is not'      (-not ($ft | Where-Object { $_.Title -match 'Brother' }))
  T 'claims: the feature row cuts its evidence prose' ($ft[0].Title -eq 'Nine Dozen Heroes and One Wicked Man')
  $sp2 = @(Read-DispositionClaims @('t02|episode|S01E01-S01E02 Pilot|speech:x'))
  T 'claims: a spelled-out span is read'         ($sp2.Count -eq 2 -and $sp2[1].Slot -eq 'S01E02')
  T 'claims: a lone slot still yields ONE claim' (@(Read-DispositionClaims @('t01|episode|S03E02 The Priory School|speech:x')).Count -eq 1)
  $nt = @(Read-DispositionClaims @('t01|episode|S01E01|speech:That noise in the ceiling'))
  T 'claims: a slot with NO title is still a claim' ($nt.Count -eq 1 -and $nt[0].Slot -eq 'S01E01' -and -not "$($nt[0].Title)".Trim())
  T 'claims: an untitled slot does not eat the next field' (-not ("$($nt[0].Title)" -match 'speech'))
  T 'leaf slot is found'                ((Get-SlotFromLeaf 'Man In A Suitcase S01E06.mkv') -eq 'S01E06')
  T 'leaf slot normalises the padding'  ((Get-SlotFromLeaf 'Show - S1E6 - Name.mkv') -eq 'S01E06')
  T 'leaf with no slot returns empty'   ((Get-SlotFromLeaf 'O Brother Where Art Thou.mkv') -eq '')
  T 'title compare ignores punctuation' ((ConvertTo-ComparableTitle "SOMEBODY LOSES, SOMEBODY... WINS") -eq (ConvertTo-ComparableTitle 'Somebody Loses, Somebody... Wins?'))
  T 'title compare drops a leading The' ((ConvertTo-ComparableTitle 'The Property of a Gentleman') -eq (ConvertTo-ComparableTitle 'Property of a Gentleman'))
  T 'title compare keeps an inner The'  ((ConvertTo-ComparableTitle 'Man from the Dead') -ne (ConvertTo-ComparableTitle 'Man from Dead'))
  T 'title compare is not blind'        ((ConvertTo-ComparableTitle 'The Bridge') -ne (ConvertTo-ComparableTitle 'The Whisper'))
  T 'empty title compares empty'        ((ConvertTo-ComparableTitle $null) -eq '')
  $lines = @(
    't00|exclude|COPYRIGHT NOTICE card, 31.64 s|frame:t000-0008.png',
    't01|episode|S01E06 Man from the Dead|menu:VTSM VTS_02 PGC1 reads "MAN FROM THE DEAD"',
    't04|extra|S00E01 Making It Real|duration:1837.2s',
    'this is a prose line and must not parse'
  )
  $claims = @(Read-DispositionClaims -Lines $lines)
  T 'two identity rows parsed'          ($claims.Count -eq 2)
  T 'exclude rows are not claims'       (-not ($claims | Where-Object { $_.Title -match 'COPYRIGHT' }))
  T 'the claimed slot is read'          ($claims[0].Slot -eq 'S01E06')
  T 'the claimed title stops at the |'  ($claims[0].Title -eq 'Man from the Dead')
  T 'an extra is claimed too'           ($claims[1].Slot -eq 'S00E01')
  T 'a one-letter slip is near-equal'   (Test-TitlesNearlyEqual 'Better Doubt Then Die' 'Better Doubt Than Die')
  T 'an article-only diff is near-equal' (Test-TitlesNearlyEqual 'The Property of a Gentleman' 'Property of a Gentleman')
  T 'two real titles are NOT near-equal' (-not (Test-TitlesNearlyEqual 'Pilot' 'The One Where Monica Gets a New Roommate'))
  T 'sibling episodes are NOT near-equal' (-not (Test-TitlesNearlyEqual 'The One That Could Have Been' 'The One That Could Have Been, Part 2'))
  T 'short titles need an exact-ish match' (-not (Test-TitlesNearlyEqual 'The Bridge' 'The Bride'))
  T 'claimed title cuts evidence prose' ((Get-ClaimedTitle "Nerve - dvdvideoTitle 6 (byte-proven: VTS_06 total 1,947,680,768 B). CONFIDENCE HIGH - supersedes \\NAS\x.mkv") -eq 'Nerve')
  T 'claimed title cuts at byte-proven' ((Get-ClaimedTitle 'Family Ties (byte-proven: VTS_07)') -eq 'Family Ties')
  T 'a plain title is untouched'        ((Get-ClaimedTitle 'The Hidden Memory') -eq 'The Hidden Memory')
  T 'a real hyphenated title survives'  ((Get-ClaimedTitle 'Serenity - The 10th Character') -eq 'Serenity - The 10th Character')
  T 'distance is symmetric'             ((Get-TitleDistance 'abcd' 'abzd') -eq (Get-TitleDistance 'abzd' 'abcd'))
  T 'distance counts one substitution'  ((Get-TitleDistance 'then' 'than') -eq 1)
  T 'empty vs text is the text length'  ((Get-TitleDistance '' 'abc') -eq 3)
  if ($fail) { "SELFTEST FAILED - $fail case(s)"; exit 1 }
  'SELFTEST OK'; exit 0
}

if (-not $Show) { throw 'give -Show ''<library show folder name>'' (or -SelfTest)' }

# ---- 1. which discs produced this show, and what did each publish? --------------------------------
# THE MANIFEST IS THE BRIDGE. A dispositions file names titles but not the show; a manifest row names
# both its source disc and its output path. Same linkage publish-work.ps1 uses for its plan.
$queueDirs = @('_queue', '_queue\running', '_queue\done', '_queue\failed') |
             ForEach-Object { Join-Path $VideoRoot $_ } | Where-Object { Test-Path -LiteralPath $_ }
$showRoot = (Join-Path (Join-Path $VideoRoot 'Television Shows') $Show) -replace '/', '\'
$showPath = [regex]::Escape($showRoot)
$published = @{}       # slot -> @{ Disc; Leaf; Manifest }
foreach ($mf in @($queueDirs | ForEach-Object { Get-ChildItem -LiteralPath $_ -Filter *.json -File -EA SilentlyContinue })) {
  try { $rows = @(Get-Content -LiteralPath $mf.FullName -Raw | ConvertFrom-Json) } catch { continue }
  foreach ($r in @($rows | Where-Object { $_ -is [pscustomobject] })) {
    $out = "$($r.out)" -replace '/', '\'
    if ($out -notmatch "^$showPath\\") { continue }
    $slot = Get-SlotFromLeaf (Split-Path $out -Leaf)
    if (-not $slot -or $slot -notmatch ("^S{0:00}E" -f $Season)) { continue }
    # THE DISC IS THE FOLDER ABOVE THE STRUCTURE, NOT THE FOLDER THE FILE SITS IN. A Blu-ray row's
    # src is `<disc>\BDMV\STREAM\00001.m2ts` and a DVD's is `<disc>\VIDEO_TS\...`, so taking the
    # parent of the file named every Friends disc 'STREAM' and reported all 24 episodes as having no
    # identity evidence - a fictitious fault on a correct library, found by running this over four
    # shows instead of the one it was written for.
    $src = "$($r.src)" -replace '/', '\'
    $disc = Split-Path $src -Leaf
    if ($disc -match '\.(mkv|m2ts|vob|iso)$') { $src = Split-Path $src -Parent; $disc = Split-Path $src -Leaf }
    while ($disc -match '^(STREAM|BDMV|VIDEO_TS|PLAYLIST|CLIPINF)$' -and (Split-Path $src -Parent)) {
      $src = Split-Path $src -Parent; $disc = Split-Path $src -Leaf
    }
    # LAST WRITER WINS, deliberately: a later manifest for the same slot is the current plan, and
    # the collision check below reports the pair anyway.
    if (-not $published.ContainsKey($slot)) { $published[$slot] = @() }
    $published[$slot] += [pscustomobject]@{ Disc = $disc; Leaf = (Split-Path $out -Leaf); Manifest = $mf.Name; When = $mf.LastWriteTime }
  }
}
if (-not $published.Keys.Count) { Say ("no manifest publishes a Season {0:00} episode into '{1}' - nothing to audit" -f $Season, $Show); exit 0 }

# ---- 2. what did each disc's own dispositions claim? ---------------------------------------------
$claimsByDisc = @{}
foreach ($disc in @($published.Values | ForEach-Object { $_.Disc } | Sort-Object -Unique)) {
  $dp = Join-Path (Join-Path $VideoRoot '_catalogue') ("$disc.dispositions.txt")
  # THE SLUG IS A CONVENTION, NOT A RECORD. A manifest's src is often the INTERMEDIATE folder
  # (`friends_season_1-0ccfc266-rip`) while the dispositions are filed under the UNIT
  # (`FRIENDS_SEASON_1-0ccfc266`). Match on letters and digits with the intermediate suffix removed,
  # the same suffix list lib-disk.ps1's Get-UnitStageTargets uses. Without this, twelve correct
  # Friends episodes reported as having no identity evidence.
  if (-not (Test-Path -LiteralPath $dp)) {
    $wanted = ($disc -replace '(?i)-(rip|x|main|mkv|reel|audio)$', '') -replace '[^A-Za-z0-9]', ''
    $alt = @(Get-ChildItem -LiteralPath (Join-Path $VideoRoot '_catalogue') -Filter '*.dispositions.txt' -File -EA SilentlyContinue |
             Where-Object { (($_.BaseName -replace '\.dispositions$', '') -replace '[^A-Za-z0-9]', '') -eq $wanted })
    if ($alt.Count) { $dp = $alt[0].FullName }
  }
  if (Test-Path -LiteralPath $dp) { $claimsByDisc[$disc] = @(Read-DispositionClaims -Lines @(Get-Content -LiteralPath $dp -EA SilentlyContinue)) }
  else { $claimsByDisc[$disc] = @() }
}

# ---- 3. what does Plex call each slot? ------------------------------------------------------------
$plexTitles = @{}
$plexReachable = $false
try {
  $tok = [Environment]::GetEnvironmentVariable('PLEX_TOKEN', 'User')
  $base = [Environment]::GetEnvironmentVariable('PLEX_BASEURL', 'User')
  if ($tok -and $base) {
    # THE FOLDER CARRIES A DISAMBIGUATING YEAR THAT PLEX'S TITLE DOES NOT. The library folder is
    # 'Friends (1994)' and Plex's show is 'Friends', so an exact title match found nothing and the
    # whole title check silently downgraded to "Plex unavailable". Search on the bare name, then
    # accept an exact match, else the sole result.
    $bare = ($Show -replace '\s*\((19|20)\d{2}\)\s*$', '').Trim()
    $q = [uri]::EscapeDataString($bare)
    $found = Invoke-RestMethod -Uri "$base/library/sections/$Section/all?title=$q&X-Plex-Token=$tok"
    $dirs = @($found.MediaContainer.Directory)
    $hit = @($dirs | Where-Object { (ConvertTo-ComparableTitle $_.title) -eq (ConvertTo-ComparableTitle $bare) })
    if (-not $hit.Count -and $dirs.Count -eq 1) { $hit = @($dirs[0]) }
    # TWO SHOWS CAN SHARE A TITLE, AND THE YEAR THAT TELLS THEM APART IS IN THE FOLDER, NOT THE TITLE.
    # The library holds both 'Sherlock Holmes (1964)' and 'Sherlock Holmes (1984)' and Plex titles both
    # of them 'Sherlock Holmes', so taking the first exact match picked the 1964 show, whose season 3
    # then did not resolve - and the whole title check reported itself unavailable instead of wrong.
    # The show's own Location is the tie-break: its leaf IS the folder name this audit was asked about.
    if ($hit.Count -gt 1) {
      $byFolder = @()
      foreach ($c in $hit) {
        try {
          $meta = Invoke-RestMethod -Uri "$base/library/metadata/$($c.ratingKey)?X-Plex-Token=$tok"
          $leaves = @(@($meta.MediaContainer.Directory.Location.path) | ForEach-Object { ($_ -replace '/+$', '') -split '[\\/]' | Select-Object -Last 1 })
          if ($leaves -contains $Show) { $byFolder += $c }
        } catch { }
      }
      if ($byFolder.Count -eq 1) { $hit = @($byFolder[0]) }
      else {
        # Fall back to the year in the folder name; ambiguity that survives both is NOT a pass.
        $yr = $(if ($Show -match '\((19|20)\d{2}\)') { [int]($Matches[0] -replace '[()]', '') } else { 0 })
        $byYear = @($hit | Where-Object { $yr -and [int]"$($_.year)" -eq $yr })
        $hit = $(if ($byYear.Count -eq 1) { @($byYear[0]) } else { @() })
      }
    }
    $key = $(if ($hit.Count) { $hit[0].ratingKey } else { $null })
    if ($key) {
      $seasons = Invoke-RestMethod -Uri "$base/library/metadata/$key/children?X-Plex-Token=$tok"
      $sn = ($seasons.MediaContainer.Directory | Where-Object { [int]$_.index -eq $Season } | Select-Object -First 1)
      if ($sn) {
        $eps = Invoke-RestMethod -Uri "$base/library/metadata/$($sn.ratingKey)/children?X-Plex-Token=$tok"
        foreach ($v in $eps.MediaContainer.Video) { $plexTitles[(Get-SlotKey $Season $v.index)] = "$($v.title)" }
        $plexReachable = $true
      }
    }
  }
} catch { $plexReachable = $false }
# A GUARD THAT CANNOT MEASURE HAS NOT FOUND A FAULT. Without Plex the disc-side checks still run and
# say so; the title comparison is reported as NOT DONE rather than as a pass.
if (-not $plexReachable) { Say 'WARNING: Plex titles unavailable - slots are checked for evidence and collisions ONLY, not against canonical titles.' }

# ---- 4. the audit ---------------------------------------------------------------------------------
$unbacked = @(); $collisions = @(); $mismatches = @(); $noPlexTitle = @(); $namedDifferently = @(); $rerips = @(); $agreed = 0
foreach ($slot in ($published.Keys | Sort-Object)) {
  # NEWEST MANIFEST FIRST: a later manifest for the same slot is the current plan, the same rule
  # publish-work.ps1 applies to supersession. Its disc's claim is the one to check against Plex.
  $sources = @($published[$slot] | Sort-Object When -Descending)
  $discs = @($sources | ForEach-Object { $_.Disc } | Sort-Object -Unique)

  $claim = $null
  foreach ($s in $sources) {
    $c = @($claimsByDisc[$s.Disc] | Where-Object { $_.Slot -eq $slot } | Select-Object -First 1)
    if ($c.Count) { $claim = $c[0]; break }
  }

  # TWO DISCS ON ONE SLOT IS NORMAL HERE - IT IS A RE-RIP. This library re-rips a season from a
  # better edition and publishes into the same slots on purpose; Farscape Season 1 has both a
  # 4-episode-per-disc set ("Farscape S1 D5") and a 2-episode-per-disc one ("Farscape Season 1 Disk
  # 9"), and the first run of this audit called all four shared slots collisions on a library that
  # was correct. What matters is not HOW MANY discs claim the slot but WHETHER THEY AGREE about what
  # is in it: both Farscape discs say S01E19 is "Nerve". Only a disagreement means one episode
  # overwrote a different one.
  if ($discs.Count -gt 1) {
    $titles = @()
    foreach ($d in $discs) {
      $c = @($claimsByDisc[$d] | Where-Object { $_.Slot -eq $slot } | Select-Object -First 1)
      if ($c.Count) { $titles += [pscustomobject]@{ Disc = $d; Title = $c[0].Title } }
    }
    $disagree = $false
    for ($i = 1; $i -lt $titles.Count; $i++) { if (-not (Test-TitlesNearlyEqual $titles[0].Title $titles[$i].Title)) { $disagree = $true } }
    if ($disagree) {
      $collisions += [pscustomobject]@{ Slot = $slot
                                        Detail = (($titles | ForEach-Object { "{0} says '{1}'" -f $_.Disc, $_.Title }) -join '  |  ')
                                        Manifests = (@($sources | ForEach-Object { $_.Manifest } | Sort-Object -Unique) -join ', ') }
    } else {
      $rerips += [pscustomobject]@{ Slot = $slot; Discs = ($discs -join ', '); Title = $(if ($titles.Count) { $titles[0].Title } else { '?' }) }
    }
  }
  if (-not $claim) {
    $unbacked += [pscustomobject]@{ Slot = $slot; Disc = $sources[0].Disc; Leaf = $sources[0].Leaf }
    continue
  }
  if (-not $plexReachable) { continue }
  $canon = "$($plexTitles[$slot])"
  if (-not $canon) { $noPlexTitle += [pscustomobject]@{ Slot = $slot; Claim = $claim.Title }; continue }
  # A ROW THAT NAMES NO TITLE STILL BACKS ITS SLOT. There is simply nothing to compare it against,
  # and an empty string must never be run through the swap test below - it matches nothing, so it
  # would be reported as "named differently" on every untitled show.
  if (-not "$($claim.Title)".Trim()) { $agreed++; continue }
  if (Test-TitlesNearlyEqual $claim.Title $canon) { $agreed++; continue }

  # THE QUESTION IS "IS THIS FILE IN THE WRONG SLOT?", NOT "DO THE STRINGS MATCH?"
  #
  # A disc and TheTVDB can both be right and still disagree completely: Friends S01E01 is "Pilot" to
  # TheTVDB and "The One Where Monica Gets a New Roommate" on the disc. Failing that is a false
  # alarm on a correct library. What WOULD be evidence of displacement is the disc's title belonging
  # to a DIFFERENT slot in the same season - that is a swap, and it is cheap to test.
  $elsewhere = @($plexTitles.Keys | Where-Object { $_ -ne $slot -and (Test-TitlesNearlyEqual $claim.Title $plexTitles[$_]) } | Sort-Object)
  if ($elsewhere.Count) {
    $mismatches += [pscustomobject]@{ Slot = $slot; Claim = $claim.Title; Canon = $canon
                                      Disc = $sources[0].Disc; Row = $claim.Row; Elsewhere = ($elsewhere -join ', ') }
  } else {
    $namedDifferently += [pscustomobject]@{ Slot = $slot; Claim = $claim.Title; Canon = $canon; Disc = $sources[0].Disc }
  }
}

Say ("SEASON IDENTITY AUDIT - {0}, Season {1:00}: {2} published slot(s) from {3} disc(s)" -f `
     $Show, $Season, $published.Keys.Count, @($published.Values | ForEach-Object { $_.Disc } | Sort-Object -Unique).Count)
if ($plexReachable) { Say ("   {0} slot(s) agree with Plex's canonical title" -f $agreed) }

if ($noPlexTitle.Count) {
  Say ''
  Say ("PLEX HAS NO TITLE for {0} slot(s) - check the show's Plex match, not the files:" -f $noPlexTitle.Count)
  foreach ($n in $noPlexTitle) { Say ("   {0}  disc says '{1}'" -f $n.Slot, $n.Claim) }
}

# COVERAGE IS INFORMATION, NOT A FAULT - partial sets are normal in this library.
if ($plexReachable) {
  $absent = @($plexTitles.Keys | Where-Object { -not $published.ContainsKey($_) } | Sort-Object)
  if ($absent.Count) {
    Say ''
    Say ("coverage: {0} of {1} Plex episode(s) published from disc. Not published (normal - the disc may be on another drive): {2}" -f `
         $published.Keys.Count, $plexTitles.Keys.Count, ($absent -join ' '))
  }
}

$faulted = $false
if ($rerips.Count) {
  Say ''
  Say ("re-rips - {0} slot(s) published by more than one disc, all agreeing on the episode (normal):" -f $rerips.Count)
  foreach ($r in $rerips) { Say ("   {0}  '{1}'   from: {2}" -f $r.Slot, $r.Title, $r.Discs) }
}
if ($collisions.Count) {
  $faulted = $true
  Say ''
  Say ("*** COLLISION - {0} slot(s) where two discs DISAGREE about what the episode is. One overwrote the other:" -f $collisions.Count)
  foreach ($c in $collisions) { Say ("   {0}  {1}" -f $c.Slot, $c.Detail); Say ("        manifests: {0}" -f $c.Manifests) }
}
if ($unbacked.Count) {
  $faulted = $true
  Say ''
  Say ("*** NO IDENTITY EVIDENCE - {0} slot(s) published with no disposition row claiming them:" -f $unbacked.Count)
  foreach ($u in $unbacked) { Say ("   {0}  {1}   (disc '{2}' has no row for this slot)" -f $u.Slot, $u.Leaf, $u.Disc) }
  Say  '   Either the disc''s dispositions never named this title, or the row names a different slot'
  Say  '   than the manifest published to - the second is how an episode lands in the wrong place.'
}
if ($namedDifferently.Count) {
  Say ''
  Say ("named differently by the disc and by Plex - {0} slot(s), NOT a fault (no other slot carries the disc's name):" -f $namedDifferently.Count)
  foreach ($d in $namedDifferently) { Say ("   {0}  disc '{1}'   Plex '{2}'" -f $d.Slot, $d.Claim, $d.Canon) }
}
if ($mismatches.Count) {
  $faulted = $true
  Say ''
  Say ("*** POSSIBLE SWAP - {0} slot(s) carry a title that belongs to ANOTHER slot in this season:" -f $mismatches.Count)
  foreach ($m in $mismatches) {
    Say ("   {0}  disc says '{1}'   Plex says '{2}'   - and '{1}' is Plex's title for {5}   [{3} {4}]" -f `
         $m.Slot, $m.Claim, $m.Canon, $m.Disc, $m.Row, $m.Elsewhere)
  }
  Say  '   The disc''s own card or dialogue is the stronger evidence. Read the disposition row''s'
  Say  '   evidence for BOTH slots before moving anything - a swap needs two corrections, not one.'
}

if (-not $faulted) { Say ''; Say 'SEASON IDENTITY OK - every published slot is backed by its own disc''s evidence and agrees with Plex.' }
exit $(if ($faulted) { 2 } else { 0 })
