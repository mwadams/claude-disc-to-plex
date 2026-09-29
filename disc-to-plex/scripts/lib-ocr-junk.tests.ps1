# Tests for lib-ocr-junk.ps1 - the OCR quality gate's per-line junk test.
#   pwsh -File lib-ocr-junk.tests.ps1      (exit 0 = all pass)
. (Join-Path $PSScriptRoot 'lib-ocr-junk.ps1')
$fail = 0
function T([string]$label, [bool]$ok) { if ($ok) { "PASS  $label" } else { "FAIL  $label"; $script:fail++ } }

# Life of Brian Deleted Scene 4 (2026-09-29): real, perfectly-read dialogue that the old rule called junk.
foreach ($l in '-Yes.', '-Men.', 'Men...', '...forward.', 'Oh, my cock.', 'You lucky, shabby bastards.',
               'The sign that is the sign?', 'Our time has come. Our leader calls.') {
  T "dialogue is not junk: '$l'" (-not (Test-OcrJunkLine $l))
}
# Short but real words that the old rule already passed must still pass.
foreach ($l in 'Oh!', 'No.', "I'm", 'Yes') { T "short real word is not junk: '$l'" (-not (Test-OcrJunkLine $l)) }

# What the gate exists to catch must still be caught.
foreach ($l in 'I', '.', '|', '...', '--', '-.', '|=|=| 1 2 3', '0 0 0 0 0 0', '#@! %&* ()') {
  T "junk is still junk: '$l'" (Test-OcrJunkLine $l)
}

# NO LOOSENING BEYOND PUNCTUATION: on any line that carries none of the removed punctuation, the new
# rule must give exactly the verdict the old one did. (The header's gibberish examples are here as
# they really behave: "2 RES SI ASS SS)" is 88% letters+spaces and was never junk to the PER-LINE
# test under either rule - the dictionary gates are what catch a read like that.)
function Test-OldRule([string]$Line) {
  $t = $Line.Trim(); if ($t.Length -le 2) { return $true }
  $alpha = @($t.ToCharArray() | Where-Object { [char]::IsLetter($_) -or $_ -eq ' ' }).Count
  return (($alpha / $t.Length) -lt 0.65)
}
foreach ($l in '= | dea oe ae esa ll', '2 RES SI ASS SS)', '|=|=| 1 2 3', 'l1l1 0O0O', 'Hello there', 'ab', 'x7 y8 z9 q0', '(( ))') {
  T "unchanged verdict without dialogue punctuation: '$l'" ((Test-OcrJunkLine $l) -eq (Test-OldRule $l))
}

# The whole-file effect: Scene 4's eight cues used to measure 33% junk (over the 30% gate).
$scene4 = @('You lucky, shabby bastards.', 'It is the sign.', 'The sign that is the sign?', '-Yes.', '-Men.',
            'Our time has come. Our leader calls.', 'Men...', '...forward.', 'Oh, my cock.')
$pct = [math]::Round(100 * @($scene4 | Where-Object { Test-OcrJunkLine $_ }).Count / $scene4.Count)
T "Deleted Scene 4 now measures 0% junk (was over 30%): $pct%" ($pct -eq 0)

if ($fail) { "$fail FAILED"; exit 1 }
'all lib-ocr-junk tests passed'; exit 0
