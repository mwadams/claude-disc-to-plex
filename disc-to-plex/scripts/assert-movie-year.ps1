<#
.SYNOPSIS
  A film whose DISPOSITION states a year must be published into a folder carrying that year.
  Exit 0 = nothing to say. Exit 2 = a movie folder is missing a year its own evidence already has.

.WHY THIS EXISTS
  Plex guesses a movie's identity from the folder name, and an undated folder invites it to guess
  wrong. Four films on the Ghost Stories for Christmas strand were published undated and every one
  matched a different work entirely:

      Whistle and I'll Come to You     -> a 1956 film
      A Warning to the Curious         -> "A Warning to the Curious (2013)"  imdb tt2691514
      Stigma                           -> a 2012 film
      The Signalman                    -> a 1997 film

  Each was found by the operator looking at Plex, days later, and each cost a folder rename, a
  manifest rewrite, a republish and a hand-deletion on the NAS. Adding "(YYYY)" fixed all four
  immediately, which is the tell: nothing was wrong with the media, only with the name.

.WHY IT DOES NOT SIMPLY REFUSE EVERY UNDATED FOLDER
  198 of the library's 409 movie folders carry no year, and almost all of them are matched
  correctly - Citizen Kane and Dirty Harry are not ambiguous. A guard firing on half the library
  would be noise, and noise is how a guard gets ignored.

  What separates the four failures is not that they were undated. It is that WE ALREADY KNEW THE
  YEAR AND DID NOT WRITE IT DOWN. Every one of them has a `feature` disposition naming it:

      t00|feature|The Signalman (1976, dir. Lawrence Gordon Clark, ...)
      t02|feature|A Warning to the Curious (1972, dir. Lawrence Gordon Clark) - ...

  So this fires ONLY where the evidence exists and the manifest contradicts it by omission. A film
  whose disposition states no year is not this guard's business; a legacy undated folder nobody is
  republishing is not either.

.WHY IT REFUSES RATHER THAN REWRITING THE PATH
  The house rule is that a guard which knows the right value should APPLY it, not complain. That is
  right for a measurable field; it is wrong for an OUTPUT PATH, because a path is also the key for
  `supersedes`, the retire list, and any already-published folder being replaced in place. Silently
  renaming an output would re-point all of those at a folder that does not exist yet. So this names
  the exact folder to use and lets the author make the change deliberately.

.EXAMPLE
  pwsh -File assert-movie-year.ps1 -Manifest D:/video/_queue/pending/some-disc.json
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [string]$Catalogue = 'D:/video/_catalogue',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

function Get-DispositionYears {
  <# title(lowercased, punctuation-stripped) -> year, for every `feature` row that states one.
     Matches `<Title> (YYYY` with the year followed by a comma or a closing bracket, which is how
     every dispositions file in this library writes it: "(1976, dir. ...)" or "(1972)". #>
  param([Parameter(Mandatory)][string]$Text)
  $map = @{}
  foreach ($line in ($Text -split "`r?`n")) {
    if ($line -notmatch '^\s*t\d+\|feature\|') { continue }
    if ($line -match '^\s*t\d+\|feature\|(.+?)\s*\((19|20)(\d{2})\s*[,)]') {
      $title = $Matches[1]
      $year  = $Matches[2] + $Matches[3]
      $key = ($title -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
      if ($key) { $map[$key] = $year }
    }
  }
  return $map
}

function Get-MovieFolder {
  <# The work folder of a Movies output, or '' for anything else. Television is not covered: a
     series folder's year comes from the show, not from a per-disc feature row. #>
  param([Parameter(Mandatory)][string]$OutPath)
  if ($OutPath -notmatch '(?i)[\\/]Movies[\\/]([^\\/]+)[\\/]') { return '' }
  return $Matches[1]
}

if ($SelfTest) {
  $fail = 0
  function T($n, $c) { if ($c) { "  ok   $n" } else { $script:fail++; "  FAIL $n" } }
  $d = @(
    't00|feature|The Signalman (1976, dir. Lawrence Gordon Clark, TV adaptation) - new to the library|card:"..."',
    't01|feature|Stigma (1977, dir. Lawrence Gordon Clark, written by Clive Exton) - new|card:"..."',
    't02|feature|A Warning to the Curious (1972, dir. Lawrence Gordon Clark) - the BBC feature|duration:...',
    't03|feature|Something With No Year At All - just a description|card:"..."',
    't04|extra|Ignored (1999, not a feature row)|card:"..."'
  ) -join "`n"
  $m = Get-DispositionYears -Text $d
  T 'reads a year before a comma'      ($m['thesignalman'] -eq '1976')
  T 'reads a year before a bracket'    ($m['awarningtothecurious'] -eq '1972')
  T 'reads the second feature row'     ($m['stigma'] -eq '1977')
  T 'a feature with no year is absent' (-not $m.ContainsKey('somethingwithnoyearatall'))
  T 'an extra row is not read'         (-not $m.ContainsKey('ignored'))
  T 'movie folder is extracted'        ((Get-MovieFolder -OutPath 'D:/video/Movies/Stigma/Stigma.mkv') -eq 'Stigma')
  T 'movie extra resolves to the work' ((Get-MovieFolder -OutPath 'D:/video/Movies/The Signalman/Other/x.mkv') -eq 'The Signalman')
  T 'television is not covered'        ((Get-MovieFolder -OutPath 'D:/video/Television Shows/Spaced/Season 01/x.mkv') -eq '')
  T 'backslashes work too'             ((Get-MovieFolder -OutPath 'D:\video\Movies\Stigma\Stigma.mkv') -eq 'Stigma')
  if ($fail) { "SELFTEST FAILED - $fail case(s)"; exit 1 }
  'SELFTEST OK'; exit 0
}

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { exit 0 }
try { $rows = @(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json) } catch { exit 0 }
if (-not $rows.Count) { exit 0 }

# The dispositions that could speak for this manifest are those of the discs it reads. `src` names
# the staged disc; its dispositions file is keyed by the same unit name.
$units = @($rows | ForEach-Object { "$($_.src)" } | Where-Object { $_ } |
           ForEach-Object { if ($_ -match '[\\/]_stage[\\/]([^\\/]+)') { $Matches[1] } } |
           Sort-Object -Unique)
$years = @{}
foreach ($u in $units) {
  $f = Join-Path $Catalogue ($u + '.dispositions.txt')
  if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { continue }
  foreach ($kv in (Get-DispositionYears -Text (Get-Content -LiteralPath $f -Raw)).GetEnumerator()) {
    $years[$kv.Key] = $kv.Value
  }
}
if (-not $years.Count) { exit 0 }

$bad = @()
foreach ($folder in @($rows | ForEach-Object { Get-MovieFolder -OutPath "$($_.out)" } | Where-Object { $_ } | Sort-Object -Unique)) {
  # Already carries a year - nothing to say, whatever the year is. Correcting a WRONG year is a
  # different question with different evidence, and is deliberately not asked here.
  if ($folder -match '\((19|20)\d{2}\)') { continue }
  $key = ($folder -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
  if (-not $years.ContainsKey($key)) { continue }
  $bad += [pscustomobject]@{ Folder = $folder; Year = $years[$key] }
}

if (-not $bad.Count) { exit 0 }

Write-Output ("REFUSE - {0} movie folder(s) omit a year their own disposition states:" -f $bad.Count)
foreach ($b in $bad) {
  Write-Output ("    Movies/{0}/   ->   Movies/{0} ({1})/" -f $b.Folder, $b.Year)
}
Write-Output '  An undated movie folder lets Plex guess, and on this strand it guessed wrong four times'
Write-Output '  in a row (Whistle -> 1956, A Warning to the Curious -> 2013, Stigma -> 2012, The'
Write-Output '  Signalman -> 1997). Rename the folder in every `out` (and the feature leaf with it, so'
Write-Output '  the year shows in both places), then re-gate. Nothing else about the rows changes.'
Write-Output ''
Write-Output '  IF THIS WORK IS ALREADY IN PLEX AND ALREADY MATCHED CORRECTLY, use the year PLEX shows,'
Write-Output '  not the one above, when the two differ. A disposition records the year on the disc, and'
Write-Output '  that is not always the year the databases index a film under - a 2026-09-21 sweep of all'
Write-Output '  65 undated films in this library found 61 matched correctly and 2 disagreeing by a single'
Write-Output '  year (The Cockleshell Heroes: disc 1954, Plex 1955; Truly Madly Deeply: disc 1991, Plex'
Write-Output '  1990 - both the right film, differing on release date). Forcing the disc year into the'
Write-Output '  folder in a case like that would BREAK a correct match to fix nothing.'
exit 2
