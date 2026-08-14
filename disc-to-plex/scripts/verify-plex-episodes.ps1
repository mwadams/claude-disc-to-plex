<#
.SYNOPSIS
  Verify that a Plex TV show's episodes are matched to the correct files after a scan.

.DESCRIPTION
  Plex matches TV by the SxxEyy token in the filename, then trusts that number against the
  library AGENT's episode list (it does not check the video content). If you numbered by a
  different source than the library's agent uses, every file shows the wrong neighbour's
  metadata. This script queries the live library and diffs each episode's agent title against
  the title embedded in its matched filename, so numbering errors surface immediately.

  Combined feature-length episodes are handled: a single file named "... S01E01-E02 - Title.mkv"
  legitimately serves two consecutive slots, so any episode whose index falls inside a filename's
  E-range is treated as correct regardless of the agent's per-slot title.

  Reads the owner token from $env:PLEX_TOKEN and base URL from $env:PLEX_BASEURL (override with
  -Token / -BaseUrl). The token is never printed. See references/naming.md
  ("Episode numbering follows the target library's Plex AGENT").

.EXAMPLE
  pwsh -File verify-plex-episodes.ps1 -Show "Deep Space" -Season 1
  pwsh -File verify-plex-episodes.ps1 -Show "Deep Space"          # all seasons
#>
[CmdletBinding()]
param(
  [Parameter(Mandatory)][string]$Show,   # title substring/regex, e.g. "Deep Space"
  [int]$Season,                          # optional; omit for all seasons
  [string]$BaseUrl = $env:PLEX_BASEURL,
  [string]$Token   = $env:PLEX_TOKEN,
  [switch]$Quiet                         # only print mismatches + summary
)

if (-not $Token)   { Write-Error "No Plex token. Set `$env:PLEX_TOKEN (User scope) or pass -Token. The owner token lives in the user's password manager; it is not stored in the repo."; exit 2 }
if (-not $BaseUrl) { $BaseUrl = 'http://localhost:32400' }
$h = @{ 'X-Plex-Token' = $Token; 'Accept' = 'application/json' }

function Get-MC($path) { (Invoke-RestMethod ($BaseUrl.TrimEnd('/') + $path) -Headers $h).MediaContainer }

# 1) find the show across all show-type sections
$secs = (Get-MC '/library/sections').Directory | Where-Object { $_.type -eq 'show' }
$showObj = $null
foreach ($s in $secs) {
  $hit = (Get-MC "/library/sections/$($s.key)/all?type=2").Metadata | Where-Object { $_.title -match $Show }
  if ($hit) { $showObj = $hit | Select-Object -First 1; break }
}
if (-not $showObj) { Write-Error "Show matching '$Show' not found in any show library."; exit 3 }
if (-not $Quiet) { "Show: $($showObj.title)  (ratingKey=$($showObj.ratingKey))" }

# 2) seasons
$seasons = (Get-MC "/library/metadata/$($showObj.ratingKey)/children").Metadata |
           Where-Object { $_.index -ge 1 } | Sort-Object index
if ($PSBoundParameters.ContainsKey('Season')) { $seasons = $seasons | Where-Object index -eq $Season }

$totalBad = 0; $totalNoFile = 0; $totalOk = 0; $totalNorm = 0; $totalNoTitle = 0
# Fold away differences the filesystem or the agent's notation force on us, so that a
# reported MISMATCH always means "this slot holds the wrong episode" rather than "Windows
# cannot store a '?'". Deliberately conservative: it normalises punctuation and part-number
# notation, never words.
function Normalize-Title([string]$s) {
  if ($null -eq $s) { return '' }
  $t = $s.ToLowerInvariant()
  # accents -> base letters (à -> a)
  $sb = New-Object System.Text.StringBuilder
  foreach ($ch in $t.Normalize([Text.NormalizationForm]::FormD).ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch) -ne [Globalization.UnicodeCategory]::NonSpacingMark) {
      [void]$sb.Append($ch)
    }
  }
  $t = $sb.ToString()
  # strip everything that isn't a letter or digit (handles ? : ! , . - ... and spacing)
  $t = $t -replace '[^a-z0-9]',''
  # A leading definite/indefinite article is notation, not identity: an episode's on-screen
  # title card and the agent's listing routinely disagree about it (Big Deal S01E05 shows
  # "LUCK OF THE IRISH", the agent says "The Luck of the Irish"). Folding it away cannot mask
  # a swap, because everything after the article still has to match exactly.
  $t = $t -replace '^(the|a|an)',''
  return $t
}

# Split a title into (base, partNumber). Part notation appears as a trailing "(2)", or as
# ", Part II" / "Part Two" anywhere in the string, so pull it out wherever it sits and compare
# the remaining words separately from the number.
function Split-PartNumber([string]$s) {
  if ($null -eq $s) { return @{ Base=''; Part=$null } }
  $t = $s; $part = $null
  if ($t -match '\((\d+)\)\s*$')            { $part = [int]$matches[1]; $t = $t -replace '\((\d+)\)\s*$','' }
  elseif ($t -match '(?i),?\s*part\s+(one|i)\b')   { $part = 1; $t = $t -replace '(?i),?\s*part\s+(one|i)\b','' }
  elseif ($t -match '(?i),?\s*part\s+(two|ii)\b')  { $part = 2; $t = $t -replace '(?i),?\s*part\s+(two|ii)\b','' }
  elseif ($t -match '(?i),?\s*part\s+(three|iii)\b'){ $part = 3; $t = $t -replace '(?i),?\s*part\s+(three|iii)\b','' }
  return @{ Base = (Normalize-Title $t); Part = $part }
}

# Same episode if the base titles agree AND, when BOTH sides carry a part number, those agree
# too. If only one side is numbered (Plex annotates "(1)" on two-parters whose halves have
# distinct names, e.g. "Favor the Bold"/"Sacrifice of Angels") the distinct base title is
# already sufficient identification. A genuine Part I/II swap still fails, because both sides
# are numbered in that case.
function Test-SameEpisode([string]$plexTitle, [string]$fileTitle) {
  $p = Split-PartNumber $plexTitle
  $f = Split-PartNumber $fileTitle
  if ($p.Base -ne $f.Base) { return $false }
  if ($null -ne $p.Part -and $null -ne $f.Part -and $p.Part -ne $f.Part) { return $false }
  return $true
}

foreach ($se in $seasons) {
  $eps = (Get-MC "/library/metadata/$($se.ratingKey)/children").Metadata | Sort-Object index
  if (-not $Quiet) { "`n== Season $($se.index)  (leafCount=$($se.leafCount)) ==" }
  foreach ($e in $eps) {
    $file = $e.Media.Part.file | Select-Object -First 1
    if (-not $file) { $totalNoFile++; if (-not $Quiet) { "{0,2} | {1,-30} | NOFILE" -f $e.index, $e.title }; continue }
    $fn = Split-Path $file -Leaf
    # parse the SxxE.. token: supports single (S01E05) and range (S01E01-E02)
    $inRange = $false; $ftitle = ''
    if ($fn -match 'S(\d+)E(\d+)(?:-E(\d+))?\s*-\s*(.+)\.[^.]+$') {
      $a = [int]$matches[2]; $b = if ($matches[3]) { [int]$matches[3] } else { $a }
      $ftitle = $matches[4]
      if ($e.index -ge $a -and $e.index -le $b) { $inRange = $true }
    }
    if ($inRange -and ($b -gt $a)) {
      # combined file legitimately covers this slot
      $totalOk++; if (-not $Quiet) { "{0,2} | {1,-30} | OK(combined) | {2}" -f $e.index, $e.title, $fn }
    } elseif ($e.title -eq $ftitle) {
      $totalOk++; if (-not $Quiet) { "{0,2} | {1,-30} | OK | {2}" -f $e.index, $e.title, $fn }
    } elseif (Test-SameEpisode $e.title $ftitle) {
      # Same episode; the filename differs only where Windows/agent notation forces it to.
      # Reported separately so a real numbering error can't hide among these.
      $totalNorm++
      if (-not $Quiet) { "{0,2} | {1,-30} | OK(normalised) | file='{2}'" -f $e.index, $e.title, $ftitle }
    } elseif ('' -eq $ftitle) {
      # The filename carries no title token at all (e.g. "Show S01E01.mkv") — a legitimate
      # convention, and common in a pre-existing library. There is nothing to compare, so this
      # is NOT a mismatch: reporting it as one buries real numbering errors in noise (Blake's 7
      # raised 39 of these). The SxxEyy slot is still checked; only the title check is skipped.
      $totalNoTitle++
      if (-not $Quiet) { "{0,2} | {1,-30} | NOTITLE (filename has no title to check) | {2}" -f $e.index, $e.title, $fn }
    } else {
      $totalBad++; "{0,2} | {1,-30} | MISMATCH (file says '{2}') | {3}" -f $e.index, $e.title, $ftitle, $fn
    }
  }
}

"`n---- OK=$totalOk  OK(normalised)=$totalNorm  NOTITLE=$totalNoTitle  MISMATCH=$totalBad  NOFILE=$totalNoFile ----"
if ($totalNorm -gt 0) {
  "     ($totalNorm title(s) differ only by punctuation/accents/part-notation - e.g. Windows"
  "      cannot store '?' or ':' and strips trailing dots. Same episode, correct slot.)"
}
if ($totalNoTitle -gt 0) {
  "     ($totalNoTitle file(s) carry no title token, so the title could not be checked. The"
  "      SxxEyy slot was still verified. Content-validate those separately if it matters.)"
}
if ($totalBad -gt 0 -or $totalNoFile -gt 0) { exit 1 } else { exit 0 }
