# Repair the commonest OCR artefact in already-published subtitles: a capital I read as a pipe.
#
# "|" is essentially never legitimate in dialogue; "I" is one of the commonest characters in
# English. The substitution is therefore safe in this one direction. Nothing else is touched -
# l/I and ./, are genuinely ambiguous and a wrong "fix" would corrupt correct text.
#
# Only cue TEXT is rewritten; index and "-->" timing lines are passed through untouched. This
# CREATES/OVERWRITES sidecar .srt files and never deletes, moves or renames anything, so it does
# not run into the NAS protection guard.

param([switch]$WhatIf)

$rows = Import-Csv 'D:\video\_ocr-progress.csv' | Where-Object Result -eq 'ok'
$done = 0; $totalFixed = 0; $skipped = 0

foreach ($r in $rows) {
  $dir  = Split-Path $r.Path -Parent
  $base = [IO.Path]::GetFileNameWithoutExtension($r.Path)
  $srt  = Join-Path $dir "$base.eng.srt"
  if (-not (Test-Path -LiteralPath $srt)) { $skipped++; continue }

  $text  = Get-Content -LiteralPath $srt -Raw
  $pipes = ([regex]::Matches($text, '\|')).Count
  if ($pipes -eq 0) { continue }

  $fixed = ($text -split "`r?`n" | ForEach-Object {
    if ($_ -match '^\d+$' -or $_ -match '-->') { $_ } else { $_ -replace '\|', 'I' }
  }) -join "`r`n"

  if ($WhatIf) {
    Write-Host ("would fix {0,5} in {1}" -f $pipes, $base)
  } else {
    Set-Content -LiteralPath $srt -Value $fixed -Encoding UTF8
    # prove it took, and that the cue count is unchanged
    $after = Get-Content -LiteralPath $srt -Raw
    $left  = ([regex]::Matches($after, '\|')).Count
    $cuesBefore = [regex]::Matches($text,  '(?m)^\d+\s*$').Count
    $cuesAfter  = [regex]::Matches($after, '(?m)^\d+\s*$').Count
    if ($left -ne 0 -or $cuesBefore -ne $cuesAfter) {
      Write-Warning ("VERIFY FAILED {0}: {1} pipes left, cues {2}->{3}" -f $base, $left, $cuesBefore, $cuesAfter)
    } else {
      Write-Host ("  fixed {0,5} in {1}" -f $pipes, $base)
      $done++; $totalFixed += $pipes
    }
  }
}
Write-Host ""
Write-Host ("files repaired: {0}   substitutions: {1}   sidecars missing: {2}" -f $done, $totalFixed, $skipped)
