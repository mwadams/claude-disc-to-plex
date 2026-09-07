<#
.SYNOPSIS
  Restore sentence case to a MACHINE TRANSCRIPT .srt. Deterministic, no model, no tokens.

.WHY
  faster-whisper emits sentence-final punctuation but frequently no capitalisation, so a transcript
  reads as one long lowercase run. Measured on `Clayhanger (1976) - S01E01`: 440 of 838 text lines -
  53% - began with a lowercase letter mid-sentence, with the full stops and question marks all
  present. The LLM correction pass had already run on that file and correctly applied 23 proper-noun
  fixes; capitalisation is simply not what that pass is for, and paying ~46k tokens an episode to
  re-letter text a regex can letter is waste.

.WHAT IT WILL NOT DO - this matters more than what it will
  * It NEVER lowercases anything. The correction pass has already fixed proper nouns (CLAYANGER ->
    CLAYHANGER, Stiffett -> Stifford) and title cards are legitimately ALL CAPS. Only a lowercase
    letter at a sentence start is ever touched, so this pass cannot undo that work or flatten a card.
  * It NEVER touches an OCR sidecar. Those are readings of the disc's OWN subtitles and are not ours
    to rewrite - the same rule _correct-loop.ps1 states. Eligibility is the provenance file saying
    `method: audio-transcription`, exactly as the correction pass decides it.
  * It does not repunctuate, resegment, or retime. A cue's line breaks are preserved byte for byte;
    only individual characters change case.

.WHAT A SENTENCE START IS
    - the first letter of a cue;
    - the first letter after . ! ? or an ellipsis, allowing closing quotes/brackets between;
  and separately the pronoun "i" (also i'm, i'll, i've, i'd) which is unambiguous in English and is
  the one non-positional fix included, because a lowercased transcript is full of it.

  A cue's continuation LINES are deliberately NOT treated as sentence starts: a cue wrapped mid
  sentence would otherwise gain a capital in its middle. Sentence detection runs over the cue's
  joined text; the original line breaks are then restored.

.SAFETY
  The original is copied to **D:/video/_correction-originals/_pre-sentence-case/**, mirroring the
  path, before this pass writes anything - and only if THIS pass has not already backed that file
  up. That is a true snapshot of the file as this pass found it.

  ⚠ IT DID NOT USED TO BE. Until 2026-09-07 this defaulted to `_correction-originals` itself, which
  is _correct-loop.ps1's tree for PRE-CORRECTION text. Sharing one path across two passes made the
  "copy only if absent" rule mean the wrong thing: an already-corrected file had a backup, so this
  pass wrote none, and the pre-sentence-case state was never captured. A 329-file bulk run was then
  started believing every file was recoverable - the SAFETY note said "the original is copied
  before anything is written", with no mention of the condition. Only 3 files had a usable snapshot.
  The other 326 are unrecoverable to their pre-pass text; see follow-up.md for that day's entry.

  Two consequences worth carrying:
    * a backup location must belong to ONE writer, or "already backed up" is ambiguous;
    * before any BULK run, take your own verified backup anyway - hash-checked, with a manifest.
      A per-file copy taken inside the modifying loop is only ever as complete as that loop's run.

  The provenance gains a `sentenceCasePass` block recording how many lines changed, so the work is
  auditable and a second run is a no-op.

  pwsh -NoProfile -File fix-sentence-case.ps1 -Srt '\\NAS\...\X.eng.srt' -WhatIf
  pwsh -NoProfile -File fix-sentence-case.ps1 -Dir '\\NAS\...\Season 01'
#>
param(
  [string]$Srt,
  [string]$Dir,
  # ITS OWN LOCATION, NOT THE CORRECTION PASS'S.
  # This defaulted to `_correction-originals`, which is where _correct-loop.ps1 puts PRE-CORRECTION
  # text. Two passes sharing one backup path means the second can never take a snapshot: the copy is
  # written only if none exists, so an already-corrected file kept its pre-correction backup and the
  # pre-SENTENCE-CASE state was silently never captured. That is what made the 2026-09-07 bulk run
  # irreversible for 326 of 329 files. Each pass now owns its own tree, so "only if none exists"
  # means "only if THIS pass has not already backed this file up" - which is what it always meant.
  [string]$BackupRoot = 'D:/video/_correction-originals/_pre-sentence-case',
  [switch]$Force,
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
if (-not $Srt -and -not $Dir) { throw 'give -Srt <file> or -Dir <folder>' }

function Set-SentenceCase([string]$text, [bool]$StartsSentence = $true) {
  # Capitalise the first letter of a SENTENCE, and the first letter after sentence-final
  # punctuation. Closing quotes/brackets may intervene ( ." -> Next ). Only ever raises case.
  #
  # $StartsSentence says whether this cue BEGINS a sentence. It is false when the previous cue
  # ended mid-sentence, and getting that wrong is the defect this parameter exists to prevent:
  #
  #   A SUBTITLE CUE IS NOT A SENTENCE. Cues are timing units; a sentence routinely runs across
  #   two or three of them. This function used to assume every cue started a sentence, so it
  #   capitalised the first letter of EVERY cue unconditionally. Measured 2026-09-07 on one file
  #   (Tales S03E04) against its pre-pass backup: 80 words wrongly capitalised mid-sentence -
  #   "restaurants and nightclubs," / "And there he feeds", "dropped to him" / "By a host of",
  #   "rich dukes and duchesses," / "Or, best of all". Across a 60-file sample, EVERY file was
  #   affected, 2,525 instances.
  #
  #   The rule, as the operator put it: "Only if we had a terminating punctuation mark at the end
  #   of the previous cue block should we be capitalizing the start of the next."
  $sb = [Text.StringBuilder]::new($text)
  $expectCap = $StartsSentence
  for ($i = 0; $i -lt $sb.Length; $i++) {
    $ch = $sb[$i]
    if ($expectCap -and [char]::IsLetter($ch)) {
      if ([char]::IsLower($ch)) { $sb[$i] = [char]::ToUpper($ch) }
      $expectCap = $false
      continue
    }
    if ($ch -eq '.' -or $ch -eq '!' -or $ch -eq '?') { $expectCap = $true; continue }
    # whitespace and closing punctuation do not consume the pending capital
    if ([char]::IsWhiteSpace($ch) -or $ch -eq '"' -or $ch -eq "'" -or $ch -eq ')' -or $ch -eq ']' -or $ch -eq '>' -or $ch -eq '-') { continue }
    if ([char]::IsDigit($ch)) { $expectCap = $false; continue }
    if ($ch -eq ',' -or $ch -eq ';' -or $ch -eq ':') { $expectCap = $false; continue }
  }
  $out = $sb.ToString()
  # The English first-person pronoun, the one fix that does not depend on position.
  $out = [regex]::Replace($out, "(?<![\w'])i(?![\w'])", 'I')
  $out = [regex]::Replace($out, "(?<![\w'])i('(?:m|ll|ve|d|s))\b", 'I$1')
  return $out
}

function Invoke-One([string]$path) {
  $prov = [IO.Path]::ChangeExtension($path, $null) + 'provenance.json'
  # `X.eng.srt` -> ChangeExtension gives `X.eng.` so the concat above yields `X.eng.provenance.json`
  if (-not (Test-Path -LiteralPath $prov -PathType Leaf)) {
    Write-Output ("  SKIP {0} - no provenance sidecar; not provably a machine transcript" -f (Split-Path -Leaf $path)); return
  }
  $pj = $null
  try { $pj = Get-Content -LiteralPath $prov -Raw | ConvertFrom-Json } catch { }
  if (-not $pj -or "$($pj.method)" -ne 'audio-transcription') {
    Write-Output ("  SKIP {0} - provenance method is '{1}', not audio-transcription (an OCR sidecar is the disc's own subtitles and is not ours to rewrite)" -f (Split-Path -Leaf $path), "$($pj.method)"); return
  }
  if ($pj.sentenceCasePass -and -not $Force) {
    Write-Output ("  skip {0} - already sentence-cased ({1} line(s) on {2})" -f (Split-Path -Leaf $path), $pj.sentenceCasePass.linesChanged, $pj.sentenceCasePass.applied); return
  }

  $lines = [IO.File]::ReadAllLines($path)
  $out = [string[]]::new($lines.Length)
  $changed = 0
  $i = 0
  $startsSentence = $true   # the first cue of a file begins a sentence; after that, see below
  while ($i -lt $lines.Length) {
    $out[$i] = $lines[$i]
    # an index line, a timestamp line, or a blank: copied through untouched
    if ($lines[$i] -match '^\d+\s*$' -or $lines[$i] -match '^\d\d:\d\d:\d\d' -or [string]::IsNullOrWhiteSpace($lines[$i])) { $i++; continue }
    # a run of text lines belonging to ONE cue - join for sentence detection, split back after
    $start = $i
    while ($i -lt $lines.Length -and -not [string]::IsNullOrWhiteSpace($lines[$i]) -and $lines[$i] -notmatch '^\d\d:\d\d:\d\d') { $i++ }
    $block = @($lines[$start..($i - 1)])
    $joined = ($block -join "`n")
    # CARRY THE SENTENCE STATE ACROSS THE CUE BOUNDARY. The first cue of the file starts a
    # sentence; every later cue does so only if the PREVIOUS cue's text ended in terminal
    # punctuation (allowing a closing quote or bracket, and an ellipsis, to follow).
    $fixed = Set-SentenceCase $joined -StartsSentence $startsSentence
    $split = $fixed -split "`n"
    # State for the NEXT cue, taken from what this cue actually ends with. An ellipsis is treated
    # as NOT terminating: "..." at a cue end is the standard subtitle convention for a sentence
    # deliberately continued into the next cue, which is precisely the case in question.
    $tail = ($split -join "`n").TrimEnd()
    $startsSentence = ($tail -match '(?<!\.)[.!?]["'')\]]?\s*$') -or ($tail -match '[.!?]{2}["'')\]]?\s*$' -and $tail -notmatch '\.\.\.\s*$')
    for ($k = 0; $k -lt $block.Count; $k++) {
      $out[$start + $k] = $split[$k]
      if ($split[$k] -cne $block[$k]) { $changed++ }
    }
  }

  if ($changed -eq 0) { Write-Output ("  ok   {0} - already correctly cased" -f (Split-Path -Leaf $path)); return }
  if ($WhatIf) { Write-Output ("  WOULD {0} - {1} line(s) would change" -f (Split-Path -Leaf $path), $changed); return }

  # BACK UP FIRST, mirroring the path, exactly as _correct-loop.ps1 does.
  $rel = $path -replace '(?i)^\\\\NASTEAMV\\Multimedia\\', '' -replace '(?i)^D:\\video\\', ''
  $bak = Join-Path $BackupRoot $rel
  New-Item -ItemType Directory -Path (Split-Path $bak -Parent) -Force | Out-Null
  if (-not (Test-Path -LiteralPath $bak)) { Copy-Item -LiteralPath $path -Destination $bak -Force }

  [IO.File]::WriteAllLines($path, $out)
  $pj | Add-Member -NotePropertyName sentenceCasePass -NotePropertyValue ([ordered]@{
      applied = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); linesChanged = $changed
      original = $bak
      note = 'Deterministic capitalisation only - no model, no tokens. Never lowercases, so the correction pass proper nouns and ALL-CAPS title cards are untouched.'
    }) -Force
  ($pj | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $prov -Encoding UTF8
  Write-Output ("  FIXED {0} - {1} line(s) re-cased (original: {2})" -f (Split-Path -Leaf $path), $changed, $bak)
}

$targets = @()
if ($Srt) { $targets += $Srt }
if ($Dir) { $targets += @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Filter '*.srt' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
foreach ($t in $targets) { Invoke-One $t }
exit 0
