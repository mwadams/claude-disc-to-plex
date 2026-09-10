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
  # Read-only, and only ever with Test-Path: the guard asks whether the library ALREADY holds an
  # output's path, because that is what makes a bare filename forced rather than sloppy.
  [string]$NasRoot = '\\NASTEAMV\Multimedia',
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
$unnamed = @()
$checked = 0
foreach ($it in $items) {
  $out = "$($it.out)"
  if (-not $out) { continue }
  $leaf = Split-Path -Leaf $out
  if ($leaf -notmatch $rxSeason00) { continue }
  $checked++
  if ($leaf -match $rxNamed) { continue }

  # A BARE NAME NEEDS AN EXCUSE, AND ONLY `supersedes` IS ONE.
  #
  # references/naming.md is unambiguous: an extra is `<Show (Year)> - S00Exx - <Extra title>.mkv`.
  # The ONLY reason to depart from that is an in-place `supersedes`, where the output must keep the
  # existing NAS filename or it ships a duplicate instead of a replacement - and a legacy file is
  # usually bare (`The Sweeney S00E18.mkv`).
  #
  # A NEW extra has no such constraint, so a bare name there is simply the convention not being
  # followed. Left to `plexTitle` alone it would look fine in Plex and wrong everywhere else: on the
  # NAS, in the coverage and OCR reports, and to anyone reading a directory listing. The first cut of
  # this guard accepted exactly that, because it asked "can this be titled?" when the question is
  # also "is this named correctly?".
  #
  # Measured against what actually ships: the 14 Blake's 7 Series 3 extras published 2026-09-06 are
  # all in the full form (`Blakes 7 - S00E21 - Nationwide - Look North, 31 July 1979.mkv`), so this
  # asks for nothing new - it stops the convention being quietly dropped.
  # ...AND THE EXCUSE IS THE FACT, NOT THE FIELD.
  #
  # This asked only for a `supersedes` field, and _briefs/manifest.md rule 3 says in terms:
  # "In-place overwrites carry no `supersedes`" - because `supersedes` feeds build-retire-list.ps1,
  # and an overwrite at the SAME path retires nothing. So an author replacing a bare-named legacy
  # extra at its own path had to choose between two written rules, and the correct manifest was
  # INEXPRESSIBLE.
  #
  # 2026-09-10: Star Cops Disks 1-3 (10 extras) and The Feathered Serpent D1 (1) were all refused
  # on this, all four units held for the operator, while every one of those outputs was a genuine
  # in-place replacement of a file the NAS already holds - `Star Cops S00E01.mkv` and its nine
  # siblings, right there, bare-named, exactly as the rule anticipates.
  #
  # So measure the thing itself. "Is this bare name forced?" is answered by whether the library
  # already holds that exact path: if it does, renaming ships a duplicate beside the original
  # instead of replacing it, which is the whole reason the exemption exists. A `supersedes` field
  # still counts - a legacy file being replaced at a DIFFERENT path is the other shape of the same
  # excuse - but it is no longer the only evidence accepted.
  #
  # Deliberately NOT weakened elsewhere: a bare name still needs `plexTitle` below, and a NEW extra
  # at a path the library does not hold is still refused, which is the case this guard was built for.
  $sup = @($it.supersedes | Where-Object { "$_".Trim() })
  $inPlace = $false
  if ($sup.Count -eq 0) {
    $nasPath = ($out -replace '^(?i)D:/video/', ($NasRoot.TrimEnd('\') + '\') -replace '^(?i)D:\\video\\', ($NasRoot.TrimEnd('\') + '\')) -replace '/', '\'
    if ($nasPath -ne ($out -replace '/', '\') -and (Test-Path -LiteralPath $nasPath -PathType Leaf)) { $inPlace = $true }
  }
  if ($sup.Count -eq 0 -and -not $inPlace) {
    $unnamed += $leaf
    continue
  }

  $t = "$($it.plexTitle)".Trim()
  if ($t) { continue }
  $bad += $leaf
}

# ---- IS EACH SEASON 00 TITLE BACKED BY AN ON-SCREEN CARD? ---------------------------------------
# WARNED, never refused. A title card is the strongest evidence an extra's name can have, but plenty
# of legitimate extras have none - a stills gallery, mute footage, a clean-titles export - so
# refusing would block real work. What must not happen is a name resting on something weaker
# LOOKING exactly like one that was read off the screen.
#
# The case, 2026-09-06: Blake's 7 Series 3 Disk 5 shipped ten extras. Nine carried evidence beginning
# `card:` - "title card reads INTRODUCING TARRANT", "lower-third reads Stuart Fell / Stunt
# Co-ordinator". The tenth began `frame:` and was named "Series 3 Clean Titles" from mymovies.xml's
# ExtraFeatures list. Its own evidence line recorded "a production clapperboard reading 58|2" and it
# was named anyway: the content said raw slated model-effects footage, the label said finished
# title-sequence export, and the label won. The user spotted it in Plex within the hour.
#
# The discriminator was already sitting in the dispositions file. One item out of ten had no card,
# and that was exactly the one that was wrong - so surface it at the gate rather than leaving it to
# whoever happens to look at Plex.
$dispDir = 'D:/video/_catalogue'
$unbacked = @()
foreach ($it in $items) {
  $out = "$($it.out)"; $src = "$($it.src)"
  if (-not $out -or (Split-Path -Leaf $out) -notmatch $rxSeason00) { continue }
  if ($src -notmatch '_stage[\\/]([^\\/"]+)') { continue }
  $dp = Join-Path $dispDir ("{0}.dispositions.txt" -f $Matches[1])
  if (-not (Test-Path -LiteralPath $dp -PathType Leaf)) { continue }
  $tnum = "$($it.title)".Trim()
  if (-not $tnum) { continue }
  # The disposition row for this source title: "tNN|kind|prose|evidence"
  $row = @(Get-Content -LiteralPath $dp -ErrorAction SilentlyContinue |
           Where-Object { $_ -match ('^t\d{2}\|') } |
           Where-Object { $_ -match ('(?i)dvdvideoTitle\s+' + [regex]::Escape($tnum) + '\b') })
  if ($row.Count -ne 1) { continue }              # ambiguous: not this guard's call
  if ($row[0] -match '(?i)\|card:') { continue }  # read off the screen - the strong case
  $unbacked += ("{0}  (evidence is not a title card)" -f (Split-Path -Leaf $out))
}
if ($unbacked.Count) {
  Say ''
  Say ("NOTE - {0} Season 00 item(s) carry a title NOT backed by an on-screen card:" -f $unbacked.Count)
  foreach ($u in $unbacked) { Say ("    {0}" -f $u) }
  Say 'Not a refusal: galleries, mute footage and technical exports legitimately have no card. But a'
  Say 'name resting on a packaging list or an elimination is a HYPOTHESIS - if the content does not'
  Say 'positively show it, say so in the title ("(unidentified)") rather than shipping a confident'
  Say 'guess. Blake''s 7 S00E26 shipped as "Series 3 Clean Titles" over slated model-effects footage.'
}

if ($unnamed.Count -gt 0) {
  Say ("SEASON 00 NAMING - {0} of {1} Season 00 item(s) are NEW extras (no `supersedes`) but use a BARE filename:" -f $unnamed.Count, $checked)
  foreach ($u in $unnamed) { Say ("    {0}" -f $u) }
  Say ''
  Say 'references/naming.md requires `<Show (Year)> - S00Exx - <Extra title>.mkv` for an extra. A bare'
  Say 'name is only justified by an in-place `supersedes` that must keep an existing NAS filename;'
  Say 'these have none, so nothing forces it. Name them properly - a `plexTitle` would make Plex look'
  Say 'right while the NAS, the coverage reports and every directory listing stayed wrong.'
  exit 2
}
if ($bad.Count -eq 0) {
  Say ("season00 titles OK - {0} Season 00 item(s), every one named or titled" -f $checked)
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
