<#
.SYNOPSIS
  Refuse a TV manifest that writes into an episode slot the library ALREADY holds under a different
  filename, without declaring what it supersedes. Exit 0 = nothing to say. Exit 2 = it would duplicate.

.WHY THIS EXISTS
  Plex identifies a TV episode by the SxxExx in its filename, not by the rest of the name. So two
  files in one season folder carrying the same SxxExx are the same episode twice - whatever they are
  called - and the library shows a duplicate with no indication which one plays.

  2026-09-21, Deep Space Nine Season 6. The re-rip programme replaces episodes whose only subtitle
  stream is Danish mistagged `eng`. Seasons 2 and 4 wrote to the library's own convention,
  `Star Trek Deep Space Nine (1993) - SxxExx - Title.mkv`, and superseded the originals in place.
  The Season 6 disc 1-3 manifests wrote `SxxExx - Title.mkv` and declared NO `supersedes`, so the
  pipeline read them as new content and published them ALONGSIDE:

      S06E01 - A Time to Stand.mkv                         2026-09-21, with .eng.srt   (the re-rip)
      Star Trek Deep Space Nine (1993) - S06E01 - ....mkv  2026-08-10, no sidecar      (the original)

  Twelve episodes existed twice, the superseded Danish copies stayed in the library, and the retire
  list knew nothing because nothing had been declared superseded. Repairing it afterwards cost
  9.4 GB of NAS copying and twelve hand-deletions by the operator.

  Nothing else could have caught it. Every gate passed: the paths were legal, the durations were
  right, the titles were right, the episodes really were on that disc. The manifest was internally
  consistent and simply wrote to the wrong name.

.WHAT IT CHECKS
  For every TV row, take the season folder it writes into and the SxxExx it claims. If the PUBLISHED
  library already holds that slot under a DIFFERENT filename, then this row is either a replacement -
  in which case it must say so in `supersedes` - or a duplicate, which is a fault. Declaring the
  supersede satisfies this check; so does writing to the existing filename, because then it replaces
  in place and there is no second file.

  Multi-episode files (S01E01-E02) are matched on every slot they span, so a single-episode row
  cannot quietly duplicate half of a double.

.WHAT IT DOES NOT DO
  It does not judge WHICH copy is better, rename anything, or look at content. It answers one
  question - would this produce two files for one episode? - and leaves the decision to the author.

.EXAMPLE
  pwsh -File assert-episode-slot-free.ps1 -Manifest D:/video/_queue/pending/some-disc.json
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [string]$NasRoot = '\\NASTEAMV\Multimedia',
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

function Get-EpisodeSlots {
  <# Every SxxExx a filename claims, including both ends of a span like S01E01-E02 or S01E01-E03.
     Returned uppercase so comparison is case-insensitive by construction. #>
  param([Parameter(Mandatory)][string]$Name)
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

if ($SelfTest) {
  $fail = 0
  function T($n, $c) { if ($c) { "  ok   $n" } else { $script:fail++; "  FAIL $n" } }
  # PARENTHESISE THE WHOLE COMPARISON. Written first as `T 'x' (expr) -eq 'S06E01'`, which passes
  # the JOINED STRING as the condition (truthy, non-empty) and compares T's own output to 'S06E01' -
  # a test that cannot fail. It "passed" on the first run, which is exactly how it would have gone
  # unnoticed.
  T 'single slot'        (((Get-EpisodeSlots -Name 'Show - S06E01 - A Time to Stand.mkv') -join ',') -eq 'S06E01')
  T 'known-negative: a wrong expectation DOES fail' (-not (((Get-EpisodeSlots -Name 'Show - S06E01 - x.mkv') -join ',') -eq 'S06E99'))
  T 'span expands'       (((Get-EpisodeSlots -Name 'Show - S01E01-E02 - Emissary.mkv') -join ',') -eq 'S01E01,S01E02')
  T 'span with season'   (((Get-EpisodeSlots -Name 'Show - S04E01-S04E02 - The Way.mkv') -join ',') -eq 'S04E01,S04E02')
  T 'short name matches' (((Get-EpisodeSlots -Name 'S06E01 - A Time to Stand.mkv') -join ',') -eq 'S06E01')
  T 'no slot'            ((Get-EpisodeSlots -Name 'Some Featurette.mkv').Count -eq 0)
  T 'case insensitive'   (((Get-EpisodeSlots -Name 'show - s06e07 - x.mkv') -join ',') -eq 'S06E07')
  T 'title token is not a slot' (((Get-EpisodeSlots -Name 'The Avengers (1961) - S00E95 - Did You Know - Trivia (S05E01-03).mkv') -join ',') -eq 'S00E95')
  T 'gallery title token is not a slot' (((Get-EpisodeSlots -Name 'The Avengers (1961) - S00E53 - Set Pictures Gallery (S05E19-22).mkv') -join ',') -eq 'S00E53')
  if ($fail) { "SELFTEST FAILED - $fail case(s)"; exit 1 }
  'SELFTEST OK'; exit 0
}

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { exit 0 }
try { $rows = @(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json) } catch { exit 0 }
if (-not $rows.Count) { exit 0 }

$dirCache = @{}
$bad = @()

foreach ($r in $rows) {
  $out = "$($r.out)"
  if ($out -notmatch '(?i)[\\/]Television Shows[\\/]') { continue }
  $leaf = Split-Path $out -Leaf
  $slots = Get-EpisodeSlots -Name $leaf
  if (-not $slots.Count) { continue }

  # The NAS folder this row writes into - the local path with the root swapped, the same mapping
  # every other script here uses.
  $nasOut = $out -replace '(?i)^D:[\\/]video[\\/]', ($NasRoot.TrimEnd('\') + '\')
  $nasDir = Split-Path $nasOut -Parent
  if (-not $dirCache.ContainsKey($nasDir)) {
    $dirCache[$nasDir] = @(Get-ChildItem -LiteralPath $nasDir -File -Filter *.mkv -ErrorAction SilentlyContinue)
  }
  $existing = $dirCache[$nasDir]
  if (-not $existing.Count) { continue }

  # What does this row declare it replaces? Compared on the LEAF, so a forward-slash / backslash or
  # local / NAS spelling of the same path still matches - the paths in `supersedes` are authored by
  # hand and their spelling varies.
  $supLeaves = @()
  if ($r.PSObject.Properties.Name -contains 'supersedes' -and $r.supersedes) {
    $supLeaves = @($r.supersedes | ForEach-Object { Split-Path ("$_" -replace '/', '\') -Leaf })
  }

  foreach ($f in $existing) {
    if ($f.Name -eq $leaf) { continue }                       # replaced in place: no second file
    $theirs = Get-EpisodeSlots -Name $f.Name
    $clash = @($theirs | Where-Object { $slots -contains $_ })
    if (-not $clash.Count) { continue }
    if ($supLeaves -contains $f.Name) { continue }            # declared: this is a replacement
    $bad += [pscustomobject]@{ New = $leaf; Existing = $f.Name; Slots = ($clash -join ',') }
  }
}

if (-not $bad.Count) { exit 0 }

Write-Output ("REFUSE - {0} row(s) would publish a SECOND file for an episode the library already holds:" -f $bad.Count)
foreach ($b in $bad) {
  Write-Output ("    {0}" -f $b.Slots)
  Write-Output ("        writing : {0}" -f $b.New)
  Write-Output ("        already : {0}" -f $b.Existing)
}
Write-Output '  Plex identifies an episode by its SxxExx, so both files are the same episode and the'
Write-Output '  library shows a duplicate with no indication which one plays.'
Write-Output '  If this REPLACES the existing file, either write to its exact filename (replaced in place)'
Write-Output '  or name it in `supersedes` so the retire list can account for it. If it is genuinely a'
Write-Output '  different item - an extra, an alternate cut - it does not belong in an episode slot.'
exit 2
