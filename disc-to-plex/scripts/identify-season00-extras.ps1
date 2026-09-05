<#
.SYNOPSIS
  Build the EVIDENCE PACK for every Season 00 item a show cannot prove a title for, so ONE agent
  can name the whole show in a single pass instead of a human doing it a file at a time.

.WHY THIS EXISTS
  audit-season00-titles.ps1 DETECTS untitled/unverified specials. fix-plex-extras.ps1 APPLIES
  titles - but only ones already present in the FILENAME. Between those two sits the actual work,
  which had no tool at all: finding out what an extra IS.

  Left manual, it costs more than the identification. On 2026-08-20 eight of The Sweeney's 42
  specials were identified from on-screen text and written into transfer-status6.md. That file was
  archived on 2026-09-05 without its open items being carried forward, and the SAME work was
  started again from scratch that evening - 43 contact sheets regenerated, the same "S00E01 is
  Thick as Thieves" conclusion reached a second time, and the same wrong inference (that it is a
  misfiled foreign programme) heading for the same correction the user had already given once.

  The Plex agent is the reason this matters. It assigns TVDB's specials list BY INDEX, so it
  confidently labelled a 24-minute extra "Regan" (a 75-minute film), a 12-minute one "Sweeney!"
  (89 min) and a 3.7-minute one "Sweeney 2" (108 min). All three were provably wrong on runtime
  alone and sat unnoticed for weeks. An unlocked agent title is not a title; it is a guess.

.WHAT IT PRODUCES  (all under -OutRoot, never on the NAS)
    <job>/cards/<file>.png     a contact sheet over the opening - where Network-style extras
                               card themselves or caption the speaker in a lower third
    <job>/transcripts.txt      ~45 s of speech per item; an interviewee often names themselves
    <job>/PROPOSALS.tsv        one row per item, Title column EMPTY, for the agent to fill in
    <job>/EVIDENCE.md          the index an agent reads: slot, runtime, current Plex title,
                               whether that title is LOCKED, and where its evidence sits
  Then: fill the Title column, and apply with
    apply-plex-titles.ps1 -Tsv <job>/PROPOSALS.tsv -RatingKey <show>

.NOTES
  - Runtime is included per item BECAUSE it falsifies agent titles for free: a 3.7-minute file
    called "Sweeney 2" needs no further evidence to be rejected.
  - It NEVER writes into the media folder. extract-title-cards.ps1 defaults its output to
    <Dir>\_titlecards, which for a NAS folder would leave working files on the NAS - forbidden.
  - Items whose title is already LOCKED are skipped by default: a locked title was set by us from
    evidence, and re-deriving it wastes the run. -IncludeLocked overrides.
#>
param(
  [Parameter(Mandatory)][string]$RatingKey,        # the SHOW's Plex ratingKey
  [Parameter(Mandatory)][string]$MediaDir,         # the Season 00 folder (NAS or local), read-only
  [string]$OutRoot = 'd:/temp/claude/D--video/scratch',
  [int]$Start = 3, [int]$End = 60, [int]$Interval = 3,
  [int]$TranscribeSeconds = 45,
  [switch]$IncludeLocked,
  [switch]$NoTranscripts
)
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

$token = [Environment]::GetEnvironmentVariable('PLEX_TOKEN', 'User')
$base  = [Environment]::GetEnvironmentVariable('PLEX_BASEURL', 'User')
if (-not $token -or -not $base) { throw 'PLEX_TOKEN / PLEX_BASEURL not set.' }
$h = @{ 'X-Plex-Token' = $token }

$show = [xml](Invoke-WebRequest -Uri "$base/library/metadata/$RatingKey" -Headers $h -TimeoutSec 30).Content
$showTitle = "$($show.MediaContainer.Directory.title)"
if (-not $showTitle) { $showTitle = "$($show.MediaContainer.Video.grandparentTitle)" }
Write-Output ("show: {0} (ratingKey {1})" -f $showTitle, $RatingKey)

$leaves = [xml](Invoke-WebRequest -Uri "$base/library/metadata/$RatingKey/allLeaves" -Headers $h -TimeoutSec 90).Content
$s0 = @($leaves.MediaContainer.Video | Where-Object { $_.parentIndex -eq '0' })
if (-not $s0.Count) { Write-Output 'no Season 00 items'; exit 0 }

# WHICH ITEMS NEED WORK. A title is trustworthy only if WE locked it; anything else is either a
# bare "Episode N" or an agent guess, and the agent guesses by index.
$need = @()
foreach ($v in $s0) {
  $d = [xml](Invoke-WebRequest -Uri "$base/library/metadata/$($v.ratingKey)" -Headers $h -TimeoutSec 30).Content
  $locked = @($d.MediaContainer.Video.Field | Where-Object { $_.name -eq 'title' -and $_.locked -eq '1' }).Count -gt 0
  if ($locked -and -not $IncludeLocked) { continue }
  $need += [pscustomobject]@{
    Index = [int]$v.index; RatingKey = $v.ratingKey; Title = "$($v.title)"; Locked = $locked
    Minutes = [math]::Round([int]$v.duration / 60000, 1)
    File = [IO.Path]::GetFileName("$(@($v.Media.Part)[0].file)")
  }
}
Write-Output ("Season 00: {0} item(s); {1} need a proven title" -f $s0.Count, $need.Count)
if (-not $need.Count) { exit 0 }

$job = & (Join-Path $here 'mint-scratch.ps1') -Root $OutRoot -Label ('s00-' + ($showTitle -replace '[^A-Za-z0-9]', '').ToLowerInvariant())
$cards = Join-Path $job 'cards'
Write-Output ("evidence -> {0}" -f $job)

# CONTACT SHEETS over the OPENING, not the middle: this is where a card or lower third appears.
& (Join-Path $here 'extract-title-cards.ps1') -Dir $MediaDir -OutDir $cards -Start $Start -End $End -Interval $Interval | Out-Null

# TRANSCRIPTS - an interviewee frequently names themselves, and it costs nothing but time.
$tpath = Join-Path $job 'transcripts.txt'
if (-not $NoTranscripts) {
  '' | Set-Content -LiteralPath $tpath
  foreach ($n in $need) {
    $f = Join-Path $MediaDir $n.File
    if (-not (Test-Path -LiteralPath $f)) { continue }
    ("=== S00E{0:D2}  {1} min ===" -f $n.Index, $n.Minutes) | Add-Content -LiteralPath $tpath
    try {
      $t = & python (Join-Path $here 'identify-audio.py') $f --tracks 0 --start 20 --dur $TranscribeSeconds 2>&1 |
           Where-Object { $_ -notmatch 'loading whisper' }
      ($t | Out-String).Trim() | Add-Content -LiteralPath $tpath
    } catch { "  (transcription failed: $($_.Exception.Message))" | Add-Content -LiteralPath $tpath }
  }
}

# THE TSV THE AGENT FILLS IN, and the applier consumes.
$tsv = Join-Path $job 'PROPOSALS.tsv'
"Index`tRatingKey`tMinutes`tCurrentTitle`tFile`tTitle`tEvidence" | Set-Content -LiteralPath $tsv
foreach ($n in $need) {
  "{0}`t{1}`t{2}`t{3}`t{4}`t`t" -f $n.Index, $n.RatingKey, $n.Minutes, $n.Title, $n.File | Add-Content -LiteralPath $tsv
}

$md = Join-Path $job 'EVIDENCE.md'
@(
  "# Season 00 identification - $showTitle"
  ""
  "$($need.Count) of $($s0.Count) items need a PROVEN title. Fill the ``Title`` and ``Evidence``"
  "columns of ``PROPOSALS.tsv``, then:"
  ""
  '```'
  "pwsh -File apply-plex-titles.ps1 -Tsv '$tsv' -RatingKey $RatingKey"
  '```'
  ""
  "## Rules"
  "- Name it from ON-SCREEN TEXT where there is any: a title card, or a lower-third caption."
  "  Those beat any description you could write, and they are usually in the first ~15 s."
  "- A transcript is second best - an interviewee often names themselves."
  "- Only if neither exists, write a short DESCRIPTIVE name and say so in the Evidence column."
  "- RUNTIME FALSIFIES FOR FREE: if the current title names a feature film and the file is four"
  "  minutes long, that title is wrong whatever else you find."
  "- ⚠ A cast crossover is NOT a misfile. An extra can be a whole episode of ANOTHER programme"
  "  because it shares cast - The Sweeney carries a *Thick as Thieves* episode and a *Morecambe and"
  "  Wise* sketch for exactly that reason. Name it for what it IS and leave it in Season 00."
  ""
  "## Items"
  ""
  "| slot | min | current Plex title | locked | file | contact sheet |"
  "|---|---|---|---|---|---|"
) | Set-Content -LiteralPath $md
foreach ($n in $need) {
  $png = Join-Path $cards (($n.File -replace '\.mkv$', '') -replace '[^A-Za-z0-9]', '_') + '.png'
  "| S00E{0:D2} | {1} | {2} | {3} | {4} | {5} |" -f $n.Index, $n.Minutes, $n.Title, $n.Locked, $n.File, (Split-Path $png -Leaf) |
    Add-Content -LiteralPath $md
}
Write-Output ("wrote {0}" -f $md)
Write-Output ("wrote {0}" -f $tsv)
if (-not $NoTranscripts) { Write-Output ("wrote {0}" -f $tpath) }
