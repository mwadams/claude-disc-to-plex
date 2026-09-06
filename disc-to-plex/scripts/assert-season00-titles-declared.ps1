<#
.SYNOPSIS
  REFUSE a manifest that ships a BARE-NAMED Season 00 item without declaring its `plexTitle`.

.WHY THIS EXISTS
  Plex's TV agent titles an episode it does not recognise BY INDEX - "Episode 16", or worse, a real
  title belonging to a different item. Nothing in the library corrects that on its own, and an
  unlocked title is re-guessed on every refresh, so a hand-fix does not stay fixed either.

  The pipeline has two ways to give an item its true name, and exactly one class of item falls
  between them:

    * NAMED OUTPUT  `The League of Gentlemen (1999) - S00E63 - In Conversation ....mkv`
      fix-plex-extras.ps1 parses the title out of the filename and locks it. Nothing more needed.

    * BARE OUTPUT   `The League Of Gentlemen S00E22.mkv`
      There is nothing in the name to parse. Bare names are not sloppiness - they are FORCED: an
      in-place `supersedes` must keep the existing NAS filename or it ships a duplicate instead of
      a replacement. So every quality re-rip of a legacy special lands bare, and the ONLY carrier
      for its title is the manifest's `plexTitle`, which apply-plex-titles.ps1 sets and locks after
      the publish.

  When a bare item ships with no `plexTitle`, the title is silently left to the agent's guess. The
  failure is invisible at every stage: the encode is correct, the publish verifies, the board is
  clean, and the defect surfaces days later as the user looking at Plex. It has now happened twice
  - five Sweeney specials on 2026-09-05, and The League of Gentlemen S00E63 on 2026-09-06, which
  Plex titled "Christmas Special - Extended Scene - Papa Lazarou" over a 63-minute Paul Jackson
  interview. Both times the disposition step KNEW the right name; it simply had nowhere to put it
  that anything read.

  _briefs/manifest.md rule 5a requires `plexTitle` on Season 00 items. That rule is prose, and prose
  rules in this project get violated within hours - so this is the check.

.WHAT IT REFUSES
  A manifest item whose `out` basename is a Season 00 file (S00Exx) in BARE form - no ` - S00Exx - `
  title segment - and which carries no non-empty `plexTitle`. Everything else passes:
    * named outputs (the title is in the filename, which fix-plex-extras.ps1 reads);
    * items that are not Season 00 at all (a numbered episode's title comes from the TV agent and
      is correct, because the agent knows the show's episode list);
    * film extras, which live in subfolders and carry no SxxExx at all.

.EXIT CODES
  0 = every Season 00 item can be titled   2 = at least one cannot; the caller must not queue it
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Say "assert-season00-titles-declared: no manifest at $Manifest"; exit 0 }
try { $items = @(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json) }
catch { Say ("assert-season00-titles-declared: unreadable manifest ({0}) - not this guard's call to refuse on" -f $_.Exception.Message); exit 0 }

# A manifest may be a bare array of items or an object with an `items` array; accept both, because
# refusing on shape here would block a manifest the encoder itself reads happily.
if ($items.Count -eq 1 -and $items[0].PSObject.Properties.Name -contains 'items') { $items = @($items[0].items) }

$rxSeason00 = '(?i)S00E\d{1,3}'
# The NAMED form: " - S00Exx - " with something after it. The separators matter - `Show S00E22.mkv`
# must not match, and that is the whole distinction this guard turns on.
$rxNamed    = '(?i)-\s*S00E\d{1,3}\s*-\s*\S'

$bad = @()
$checked = 0
foreach ($it in $items) {
  $out = "$($it.out)"
  if (-not $out) { continue }
  $leaf = Split-Path -Leaf $out
  if ($leaf -notmatch $rxSeason00) { continue }
  $checked++
  if ($leaf -match $rxNamed) { continue }
  $t = "$($it.plexTitle)".Trim()
  if ($t) { continue }
  $bad += $leaf
}

if ($bad.Count -eq 0) {
  Say ("season00 titles OK - {0} Season 00 item(s), every one titleable" -f $checked)
  exit 0
}

Say ("SEASON 00 TITLE NOT DECLARED - {0} of {1} Season 00 item(s) would publish with no title Plex could get right:" -f $bad.Count, $checked)
foreach ($b in $bad) { Say ("    {0}" -f $b) }
Say ''
Say 'These filenames are BARE: there is no title in them for fix-plex-extras.ps1 to parse, so Plex will'
Say 'title them by INDEX ("Episode 22") or assign a real title belonging to a different item, and an'
Say 'unlocked title is re-guessed on every refresh. Add a "plexTitle" to each of these manifest items -'
Say 'the disposition step already established what each one is - and apply-plex-titles.ps1 will set and'
Say 'lock it after the publish. See _briefs/manifest.md rule 5a.'
exit 2
