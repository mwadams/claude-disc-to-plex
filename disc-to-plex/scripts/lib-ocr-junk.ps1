# The OCR quality gate's per-line JUNK test, shared by ocr-subtitles.ps1 and its tests.
#
# Junk = a line that is too short to be dialogue, OR that is mostly not letters (digits, symbols,
# brackets). A track the engine cannot read still emits long lines, so length alone is not enough.
# Letter-heavy gibberish such as "= | dea oe ae esa ll" or "2 RES SI ASS SS)" passes THIS per-line
# test under any rule - the dictionary gates in ocr-subtitles.ps1 are what catch those.
#
# ORDINARY DIALOGUE PUNCTUATION IS NOT EVIDENCE OF A FAILED READ. Monty Python's Life of Brian,
# Deleted Scene 4 (2026-09-29): an eight-cue clip whose bitmaps read perfectly - but "-Yes." and
# "-Men." are 60% letters, "Men..." 50% and "...forward." 64%, all under the 0.65 floor, so a third of
# the cues counted as junk, the file failed the gate as "the nOCR signature", OCR recorded that it
# would never retry, and the one 74-second extra held its fourteen siblings off the NAS. Speaker
# dashes, ellipses and sentence punctuation are therefore removed BEFORE the fraction is taken.
# Brackets, digits, '=' and '|' - the characters real gibberish is made of - still count against it.

function Test-OcrJunkLine {
  param([string]$Line)
  $t = "$Line".Trim()
  if ($t.Length -le 2) { return $true }
  $core = ($t -replace "[-–—.,!?'`"…:;]", '').Trim()
  if ($core.Length -eq 0) { return $true }                 # punctuation only ("...", "--")
  $alpha = @($core.ToCharArray() | Where-Object { [char]::IsLetter($_) -or $_ -eq ' ' }).Count
  return (($alpha / $core.Length) -lt 0.65)
}
