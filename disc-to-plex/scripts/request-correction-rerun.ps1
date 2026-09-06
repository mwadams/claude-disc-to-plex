<#
.SYNOPSIS
  Queue machine transcripts for ANOTHER correction pass, by stamping a dated request onto their
  provenance. _correct-loop.ps1 picks them up on its next sweep.

.WHY
  A transcript that has had a correction pass is skipped for ever, and that default is right: the
  pass costs ~46k tokens and about two minutes an episode, and re-running it unchanged is waste.

  But the pass is only as good as the prompt and the lexicon it was given, and both can improve
  after the fact. On 2026-09-06 the pass was widened from "character or actor names" to proper nouns
  of ANY kind, after it applied 23 correct character-name fixes to Clayhanger S01E01 and left "rung
  corn" standing twice - Runcorn, a Cheshire town - one cue after Whisper had spelled it correctly.
  Nothing in a cast list could have caught that. Every transcript corrected before that change was
  reviewed under the narrower rule, so a second pass is genuinely different work.

.A REQUEST, NOT A DELETION
  The obvious way to re-queue is to strip `correctionPass` from the provenance. That destroys the
  record of what the first pass did and that it ran at all - and this project has learned that a
  guard which erases its own history is how the same ground gets covered twice.

  So this stamps `correctionRerunRequested = { at, reason, requestedBy }` instead. Get-CorrectDecision
  honours it ONLY while it is newer than the recorded pass, so one request yields exactly one re-run
  and cannot loop, and both facts stay in the file.

.SCOPE
  -Work / -Dir / -Srt select what to stamp; -Before limits it to transcripts corrected before a
  given time, which is the usual case ("everything done under the old prompt"). Files with no
  correctionPass are left alone: they are already queued by the ordinary route and do not need a
  request.

  pwsh -NoProfile -File request-correction-rerun.ps1 -Dir '\\NAS\...\Clayhanger (1976)' -Reason '...' -WhatIf
  pwsh -NoProfile -File request-correction-rerun.ps1 -Work 'Clayhanger (1976)' -Reason 'prompt widened to all proper nouns'
#>
param(
  [string]$Srt,
  [string]$Dir,
  [string]$Work,
  [string]$NasRoot = '\\NASTEAMV\Multimedia\Television Shows',
  [Parameter(Mandatory)][string]$Reason,
  [datetime]$Before = [datetime]::MaxValue,
  [string]$RequestedBy = 'orchestrator',
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
if ("$Reason".Trim().Length -lt 20) { Write-Output 'REFUSE - -Reason must say what changed (>= 20 chars); a re-run costs real tokens and the record should say why.'; exit 2 }

$roots = @()
if ($Srt) { $roots += $Srt }
if ($Dir) { $roots += @(Get-ChildItem -LiteralPath $Dir -Recurse -File -Filter '*.eng.srt' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
if ($Work) {
  $wd = Join-Path $NasRoot $Work
  if (-not (Test-Path -LiteralPath $wd -PathType Container)) { Write-Output "REFUSE - no such work folder: $wd"; exit 2 }
  $roots += @(Get-ChildItem -LiteralPath $wd -Recurse -File -Filter '*.eng.srt' -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}
if (-not $roots.Count) { Write-Output 'nothing selected - give -Srt, -Dir or -Work'; exit 2 }

$stamped = 0; $skipped = 0; $notOurs = 0
foreach ($s in ($roots | Sort-Object -Unique)) {
  $prov = ($s -replace '\.eng\.srt$', '.eng.provenance.json')
  if (-not (Test-Path -LiteralPath $prov -PathType Leaf)) { $notOurs++; continue }
  $p = $null
  try { $p = Get-Content -LiteralPath $prov -Raw | ConvertFrom-Json } catch { $notOurs++; continue }
  if ("$($p.method)" -ne 'audio-transcription') { $notOurs++; continue }   # OCR - not ours to rewrite

  if ($null -eq $p.correctionPass) {
    # Never corrected: the ordinary route already queues it. A request would add nothing.
    $skipped++; continue
  }
  # `correctionPass.applied` is the COUNT of corrections, not a time - the block records no
  # timestamp. The provenance file's own mtime is when the pass last wrote here, and it is what
  # _correct-loop.ps1 compares against, so use the same thing rather than a second notion of "when".
  # The `.eng.corrections.json` diff, NOT the provenance mtime: this script writes the provenance,
  # so using its mtime would mean the act of requesting reset the very clock the request is measured
  # against. _correct-loop.ps1 compares the same artefact, so both agree on "when the pass ran".
  $diff = ($s -replace '\.eng\.srt$', '.eng.corrections.json')
  $applied = [datetime]::MinValue
  if (-not [datetime]::TryParse("$($p.correctionPass.at)", [ref]$applied)) {
    if (Test-Path -LiteralPath $diff) { $applied = (Get-Item -LiteralPath $diff).LastWriteTime }
  }
  if ($applied -ge $Before) { $skipped++; continue }

  if ($WhatIf) { Write-Output ("  WOULD request re-run: {0} (corrected {1})" -f (Split-Path -Leaf $s), $applied.ToString('yyyy-MM-dd HH:mm')); $stamped++; continue }

  $p | Add-Member -NotePropertyName correctionRerunRequested -NotePropertyValue ([ordered]@{
      at = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); reason = "$Reason".Trim(); requestedBy = $RequestedBy
      # The prior pass's TIME (from the provenance mtime - see the note above), not
      # correctionPass.applied, which is the number of corrections and reads as nonsense here.
      supersedes = $applied.ToString('yyyy-MM-dd HH:mm:ss')
      supersededPassCorrections = $p.correctionPass.applied
    }) -Force
  ($p | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $prov -Encoding UTF8
  Write-Output ("  requested: {0} (previous pass {1})" -f (Split-Path -Leaf $s), $applied.ToString('yyyy-MM-dd HH:mm'))
  $stamped++
}
Write-Output ("request-correction-rerun: {0} stamped, {1} skipped (never corrected, or already newer), {2} not machine transcripts" -f $stamped, $skipped, $notOurs)
exit 0
