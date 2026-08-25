# Apply the systematic OCR glyph repairs to sidecars that were written BEFORE those repairs
# existed. Replaces fix-srt-pipes.ps1, which did only the pipe and could no longer run at all.
#
# WHY IT WAS REWRITTEN
# --------------------
# The old script read its work list from `D:\video\_ocr-progress.csv`, the state file of a
# finished one-off campaign. That file no longer exists, so the script threw on its first line -
# it had been dead for some time and nothing said so. A maintenance tool keyed to a temporary
# artefact stops working the moment the artefact is cleaned up. This one enumerates the sidecars
# themselves, which are the actual subject and cannot go missing while the work still matters.
#
# It also now applies BOTH repairs, from the same `Repair-OcrGlyphs` in lib-subtitles.ps1 that
# ocr-subtitles.ps1 uses on new conversions. That sharing is the point: two copies of the
# substitution rules would drift, and this sweep would quietly stop matching what the live pass
# produces.
#
# SCOPE. `-Root` defaults to the LOCAL library only, because this project forbids broad recursive
# scans of the NAS and E: - they are slow and remote. Published sidecars live on the NAS, so
# repairing those is a deliberate act: pass the NAS roots explicitly when you mean it, and expect
# it to take a while.
#
# SAFETY. This CREATES or OVERWRITES `.srt` sidecars and never deletes, moves or renames anything,
# on any drive - so it does not go near the NAS protection guard. It never touches the media.
#
#   pwsh -File fix-srt-glyphs.ps1 -WhatIf
#   pwsh -File fix-srt-glyphs.ps1
#   pwsh -File fix-srt-glyphs.ps1 -Root '\\NAS\media\Television Shows' -WhatIf

param(
  [string[]]$Root = @('D:\video\Movies', 'D:\video\Television Shows'),
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'

$lib = "$PSScriptRoot/lib-subtitles.ps1"   # DOUBLE quotes so $PSScriptRoot expands
if (-not (Test-Path -LiteralPath $lib)) { throw "subtitle library missing: $lib" }
. $lib
if (-not (Get-Command Repair-OcrGlyphs -ErrorAction SilentlyContinue)) {
  throw 'lib-subtitles.ps1 failed to load - refusing to run without the repair rules'
}

$files = @()
foreach ($r in $Root) {
  if (-not (Test-Path -LiteralPath $r)) { Write-Warning "root not found, skipping: $r"; continue }
  $files += @(Get-ChildItem -LiteralPath $r -Recurse -File -Filter *.srt -ErrorAction SilentlyContinue)
}
Write-Host ("scanning {0} sidecar(s) across {1} root(s)" -f $files.Count, $Root.Count)

$touched = 0; $pipeTotal = 0; $noteTotal = 0; $failed = 0

foreach ($f in $files) {
  $before = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
  if (-not $before) { continue }

  $rep = Repair-OcrGlyphs -Text $before
  if ($rep.Pipes -eq 0 -and $rep.Notes -eq 0) { continue }

  if ($WhatIf) {
    Write-Host ("would fix  pipes={0,-4} notes={1,-4} {2}" -f $rep.Pipes, $rep.Notes, $f.Name)
    $touched++; $pipeTotal += $rep.Pipes; $noteTotal += $rep.Notes
    continue
  }

  Set-Content -LiteralPath $f.FullName -Value $rep.Text -Encoding UTF8

  # PROVE IT TOOK, and prove nothing else moved. Re-reading costs nothing next to an unnoticed
  # corruption, and a cue-count change is the signature of a substitution that ate a line.
  $after      = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8
  $recheck    = Repair-OcrGlyphs -Text $after
  $cuesBefore = ([regex]::Matches($before, '(?m)^\d+\s*$')).Count
  $cuesAfter  = ([regex]::Matches($after,  '(?m)^\d+\s*$')).Count

  if ($recheck.Pipes -ne 0 -or $recheck.Notes -ne 0 -or $cuesBefore -ne $cuesAfter) {
    Write-Warning ("VERIFY FAILED {0}: {1} pipe(s) and {2} note(s) still match, cues {3} to {4}" -f
                   $f.Name, $recheck.Pipes, $recheck.Notes, $cuesBefore, $cuesAfter)
    $failed++
  } else {
    Write-Host ("  fixed  pipes={0,-4} notes={1,-4} {2}" -f $rep.Pipes, $rep.Notes, $f.Name)
    $touched++; $pipeTotal += $rep.Pipes; $noteTotal += $rep.Notes
  }
}

Write-Host ''
Write-Host ("{0}: {1} file(s), {2} pipe substitution(s), {3} music-note substitution(s)" -f
            $(if ($WhatIf) { 'would repair' } else { 'repaired' }), $touched, $pipeTotal, $noteTotal)
if ($failed -gt 0) { Write-Warning "$failed file(s) failed verification - inspect before trusting them" }
