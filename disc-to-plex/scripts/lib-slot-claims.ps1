<#
  Shared episode-SLOT vocabulary: which SxxEyy a filename claims, what title it carries, and who else
  has already claimed that slot - in the in-flight manifests, the local work folder, or the Season 00
  register (_pending/SEASON00-ALLOCATION.md). Dot-source it; it defines functions only. Collection functions emit their rows (wrap the call in @()).

  WHY IT IS SHARED: two guards reason about the same quantity. assert-episode-slot-free.ps1 asks
  "does the PUBLISHED library hold this slot under another name?" and assert-slot-not-claimed.ps1
  asks "has another IN-FLIGHT claim taken it?". If they parsed the slot differently, one would pass
  what the other refuses (see "two guards on one quantity must agree"). Get-EpisodeSlots moved here
  verbatim from assert-episode-slot-free.ps1 on 2026-09-27; that script now dot-sources this file.
#>

function Get-EpisodeSlots {
  <# Every SxxExx a filename claims, including both ends of a span like S01E01-E02 or S01E01-E03.
     Returned uppercase so comparison is case-insensitive by construction. #>
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Name)
  $slots = @()
  # ONLY THE FIRST SxxExx IS THE SLOT - it is the one Plex's scanner reads. A later token is part of
  # the TITLE, and this library names Season 00 extras after the episodes they accompany:
  # "The Avengers (1961) - S00E95 - Did You Know - Trivia (S05E01-03).mkv". Reading every token
  # (2026-09-25) refused that row as a second S05E01, "already" held by the four S00E49-52 galleries -
  # none of which is in slot S05E01 either. A span in the slot token itself (S01E01-E02) is still
  # expanded below, because it is part of the same first match.
  foreach ($m in @([regex]::Match($Name, '(?i)S(\d{1,2})E(\d{1,3})(?:\s*-\s*(?:S\d{1,2})?E(\d{1,3}))?') | Where-Object { $_.Success })) {
    $s = [int]$m.Groups[1].Value
    $a = [int]$m.Groups[2].Value
    $b = if ($m.Groups[3].Success) { [int]$m.Groups[3].Value } else { $a }
    if ($b -lt $a) { $b = $a }
    for ($e = $a; $e -le $b; $e++) { $slots += ('S{0:D2}E{1:D2}' -f $s, $e) }
  }
  return @($slots | Sort-Object -Unique)
}

function Get-SlotStackBase {
  <# The leaf with its extension and any Plex STACK suffix removed. "X - pt1.mkv" and "X - pt2.mkv"
     are ONE item in two parts (Plex stacks cd/disc/disk/dvd/part/pt + number), so they share a slot
     legitimately - the BBC Television Shakespeare and Time Team rows do exactly this. Lowercased. #>
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Leaf)
  $stem = [IO.Path]::GetFileNameWithoutExtension($Leaf)
  $stem = $stem -replace '(?i)[\s_.-]+(cd|disc|disk|dvd|part|pt)[\s_.-]*\d+$', ''
  return $stem.Trim().ToLowerInvariant()
}

function Get-SlotLeafTitle {
  <# The title part of an episode leaf: everything after the slot token's " - ", minus the stack
     suffix. "Doctor Who (1963) - S00E320 - A New Frontier.mkv" -> "A New Frontier". #>
  param([Parameter(Mandatory)][AllowEmptyString()][string]$Leaf)
  $stem = [IO.Path]::GetFileNameWithoutExtension($Leaf)
  $stem = $stem -replace '(?i)[\s_.-]+(cd|disc|disk|dvd|part|pt)[\s_.-]*\d+$', ''
  $m = [regex]::Match($stem, '(?i)S\d{1,2}E\d{1,3}(?:\s*-\s*(?:S\d{1,2})?E\d{1,3})?\s*-\s*(.+)$')
  if ($m.Success) { return $m.Groups[1].Value.Trim() }
  return ''
}

function ConvertTo-SlotTitleKey {
  # Comparison key for a title: lowercase alphanumerics only, '&' read as 'and'.
  param([AllowEmptyString()][string]$Text)
  return (("$Text".ToLowerInvariant() -replace '&', 'and') -replace '[^a-z0-9]', '')
}

function Test-SlotShowMatch {
  <# Does a register section's show name denote this library folder? The register writes
     "Star Trek: Deep Space Nine" and "Friends" where the folders are "Star Trek Deep Space Nine (1993)"
     and "Friends (1994)"; but "Doctor Who (2023)" must NOT match "Doctor Who (1963)". So: a register
     name WITH a year must match the folder exactly; one WITHOUT a year matches the folder's name with
     its year stripped. #>
  param([string]$RegisterShow, [string]$Folder)
  # Memoised: a register has ~850 rows over ~35 shows, and this is asked per row per claim.
  $ck = "$RegisterShow|$Folder"
  if ($script:SlotShowMatchCache.ContainsKey($ck)) { return $script:SlotShowMatchCache[$ck] }
  $r = ConvertTo-SlotTitleKey $RegisterShow
  $v = if ($r -eq (ConvertTo-SlotTitleKey $Folder)) { $true }
       elseif ($RegisterShow -match '\(\d{4}\)') { $false }
       else { $r -eq (ConvertTo-SlotTitleKey ($Folder -replace '\s*\(\d{4}\)\s*$', '')) }
  $script:SlotShowMatchCache[$ck] = $v
  return $v
}
$script:SlotShowMatchCache = @{}

function Read-SlotRegister {
  <# Parse SEASON00-ALLOCATION.md into rows { Show, Slot, Title, Line }. A section begins at a
     heading "# <Show> - Season 00 ..." (or "## ..."), or at a bold paragraph "**<Show> - RECORDED ...",
     which is how the UFO block was appended mid-file. A row is a table line whose FIRST cell starts
     with a slot (ranges expanded); its second cell is the title. Rows that merely MENTION a slot
     elsewhere (The Water Margin's "Picture Gallery - ... (S01E10)") are not allocations. #>
  param([Parameter(Mandatory)][string]$Path)
  $rows = [System.Collections.Generic.List[object]]::new()
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $rows.ToArray() }
  $show = ''
  $n = 0
  foreach ($line in [IO.File]::ReadAllLines($Path)) {
    $n++
    if ($line.Length -eq 0 -or '#*|'.IndexOf($line[0]) -lt 0) { continue }   # only headings, bold lines and table rows matter
    if ($line -match '^#{1,2}\s+(?<s>.+?)\s+-\s+Season 00\b') { $show = $Matches.s.Trim(); continue }
    if ($line -cmatch '^\*\*(?<s>[^*]+?)\s+-\s+RECORDED\b')   { $show = $Matches.s.Trim(); continue }
    if (-not $show) { continue }
    $m = [regex]::Match($line, '^\|\s*(?<slot>S\d{1,2}E\d{1,3}(?:\s*-\s*(?:S\d{1,2})?E\d{1,3})?)\s*\|(?<title>[^|]*)\|')
    if (-not $m.Success) { continue }
    foreach ($s in (Get-EpisodeSlots -Name $m.Groups['slot'].Value)) {
      $rows.Add([pscustomobject]@{ Show = $show; Slot = $s; Title = $m.Groups['title'].Value.Trim(); Line = $n })
    }
  }
  return $rows.ToArray()
}

# Words that say what KIND of item something is, not WHICH one. "Photo Gallery - Killer" and "Photo
# Gallery - Weapon" share two words and are different items; only the distinctive words decide.
$script:SlotStopWords = @('the','and','with','from','this','that','for','into','over','under','only','also','its',
  'his','her','their','which','what','when','where','were','was','has','have','had','are','not','per','own','same',
  'one','two','three','four','five','six','episode','part','disk','disc','serie','series','season','show','named',
  'menu','title','descriptive','confidence','high','medium','low','agent','manifest','table','bare','verbatim',
  'precedent','allocated','qualified','but','all','any','via','off','air','non')
$script:SlotGenericWords = @('gallery','photo','still','image','picture','trailer','interview','deleted','scene',
  'extended','featurette','documentary','behind','making','outtake','blooper','clip','excerpt','preview','promo',
  'sequence','textless','continuity','announcement','unidentified','cast','crew','commentary','extra','special',
  'feature','reel','montage','recap','opening','closing','credit','bonu')

function Get-SlotTitleWords {
  # Distinct lowercase words of 3+ letters, crude singular (a trailing 's' dropped), stop words removed.
  param([AllowEmptyString()][string]$Text)
  @(("$Text".ToLowerInvariant() -replace '&', ' and ' -split '[^a-z0-9]+') |
    Where-Object { $_ -match '^[a-z]' -and $_.Length -ge 3 } |
    ForEach-Object { if ($_.Length -gt 4 -and $_.EndsWith('s')) { $_.Substring(0, $_.Length - 1) } else { $_ } } |
    Where-Object { $script:SlotStopWords -notcontains $_ } | Sort-Object -Unique)
}

function Get-SlotTitleNumbers {
  # The standalone numbers in a title, as integers ("Deleted Scene 06" -> 6). "S02E17" is not one.
  # A range in the text ("Deleted Scenes 1-4") counts every number it spans.
  param([AllowEmptyString()][string]$Text)
  $nums = @([regex]::Matches("$Text", '(?<![A-Za-z0-9])\d+(?![A-Za-z0-9])') | ForEach-Object { [int64]$_.Value })
  foreach ($r in [regex]::Matches("$Text", '(?<![A-Za-z0-9])(\d+)\s*-\s*(\d+)(?![A-Za-z0-9])')) {
    $a = [int64]$r.Groups[1].Value; $b = [int64]$r.Groups[2].Value
    if ($b -gt $a -and ($b - $a) -le 50) { for ($i = $a; $i -le $b; $i++) { $nums += $i } }
  }
  @($nums | Sort-Object -Unique)
}

function Test-SlotRegisterTitleMatch {
  <# Is the register row's title cell the SAME item as this candidate title?

     The register annotates freely - "A New Frontier (making-of documentary: the 1974 production
     handover ...)" - paraphrases ("Bloopers - Additional Reel" for "Additional Outtakes Reel") and
     lists several items in a range row ("Deleted Scenes 1-4, Behind the Scenes"). So equality is
     useless. MEASURED 2026-09-27 over 799 manifest claims that the register also records, and 3,760
     known-negative pairs (row j's title tested against row k's cell, same show, different item):
       normalised containment only            14 false refusals, 94.4% of different items caught
       containment OR any shared word          0 false refusals, 64.7% caught (galleries leak)
       this function                           1 false refusal (The Mind Robber S00E216 - the register
                                               calls it 'Unidentified Off-Air Recording'), 94.7% caught
                                               (163 pairs with identical titles excluded - no title test can split them)
     Rule: the numbers must not disagree (Deleted Scene 06 is not Deleted Scene 02), then EITHER the
     normalised candidate sits inside the cell / the cell's head inside the candidate, OR at least
     a MAJORITY of the candidate's DISTINCTIVE words (not "gallery", "interview", nor a word of the show's own name) appear in the cell -
     and a candidate with no distinctive words needs every one of its words there. #>
  param([string]$Cell, [string[]]$Candidates, [string]$Show = '')
  $showWords = Get-SlotTitleWords ($Show -replace '\(\d{4}\)', '')
  $full = ConvertTo-SlotTitleKey $Cell
  $headText = ($Cell -split '\s\(', 2)[0]
  $head = ConvertTo-SlotTitleKey $headText
  $frags = @($headText -split '[,;]' | ForEach-Object { ConvertTo-SlotTitleKey $_ } | Where-Object { $_.Length -ge 4 })
  $cellWords = Get-SlotTitleWords $Cell
  $cellNums = Get-SlotTitleNumbers $Cell
  foreach ($cand in $Candidates) {
    $c = ConvertTo-SlotTitleKey $cand
    if ($c.Length -lt 3) { continue }
    $n = Get-SlotTitleNumbers $cand
    if ($n.Count -and $cellNums.Count -and -not @($n | Where-Object { $cellNums -contains $_ }).Count) { continue }
    if ($full.Contains($c)) { return $true }
    if ($head.Length -ge 4 -and $c.Contains($head)) { return $true }
    foreach ($f in $frags) { if ($c.Contains($f) -or $f.Contains($c)) { return $true } }
    $w = Get-SlotTitleWords $cand
    $d = @($w | Where-Object { $script:SlotGenericWords -notcontains $_ -and $showWords -notcontains $_ })
    if ($d.Count) {
      $hit = @($d | Where-Object { $cellWords -contains $_ }).Count
      if ($hit * 2 -gt $d.Count -or ($d.Count -eq 1 -and $hit -eq 1)) { return $true }
    } elseif ($w.Count -and -not @($w | Where-Object { $cellWords -notcontains $_ }).Count) {
      return $true
    }
  }
  return $false
}

function Get-ManifestFamily {
  <# A manifest and its re-gated retry are ONE claim: "x.json", "x.retry.json", "x.retry.retry.json"
     all belong to family "x". A retry replaces its own earlier declaration and must not be refused
     against it. #>
  param([Parameter(Mandatory)][string]$Path)
  $b = (Split-Path $Path -Leaf).ToLowerInvariant()
  $b = $b -replace '\.json$', ''
  while ($b -match '\.retry$') { $b = $b -replace '\.retry$', '' }
  return $b
}

function Get-ManifestSlotClaims {
  <# Every TV output slot one manifest declares: { Show, SeasonDir, Slot, Leaf, Base, Title, PlexTitle,
     Supersedes (leaves), Out }. Rows that are not under "Television Shows\<show>\<season>\" or carry
     no slot are ignored. An unreadable manifest yields nothing - it is not this library's call. #>
  param([Parameter(Mandatory)][string]$Path)
  $claims = [System.Collections.Generic.List[object]]::new()
  try { $doc = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop } catch { return $claims.ToArray() }
  $items = if ($doc -is [array]) { @($doc) } elseif ($doc.PSObject.Properties.Name -contains 'items') { @($doc.items) } else { @($doc) }
  foreach ($r in $items) {
    if ($null -eq $r) { continue }
    $out = "$($r.out)"
    $m = [regex]::Match($out, '(?i)[\\/]Television Shows[\\/](?<show>[^\\/]+)[\\/](?<season>[^\\/]+)[\\/](?<leaf>[^\\/]+)$')
    if (-not $m.Success) { continue }
    $leaf = $m.Groups['leaf'].Value
    $sup = @()
    if ($r.PSObject.Properties.Name -contains 'supersedes' -and $r.supersedes) {
      $sup = @($r.supersedes | ForEach-Object { (Split-Path ("$_" -replace '/', '\') -Leaf).ToLowerInvariant() })
    }
    $plex = if ($r.PSObject.Properties.Name -contains 'plexTitle') { "$($r.plexTitle)" } else { '' }
    foreach ($s in (Get-EpisodeSlots -Name $leaf)) {
      $claims.Add([pscustomobject]@{
        Show = $m.Groups['show'].Value; SeasonDir = $m.Groups['season'].Value; Slot = $s
        Leaf = $leaf; Base = (Get-SlotStackBase $leaf); Title = (Get-SlotLeafTitle $leaf)
        PlexTitle = $plex; Supersedes = $sup; Out = $out
      })
    }
  }
  return $claims.ToArray()
}
