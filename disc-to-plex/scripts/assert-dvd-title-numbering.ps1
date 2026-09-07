<#
.SYNOPSIS
  REFUSE a DVD manifest whose `title` numbers do not agree, BY DURATION, with the disc's own
  catalogue - the off-by-one that ships every episode one slot out.

.WHY THIS EXISTS
  2026-09-07, Tales of the Unexpected Season 4. Two discs of the same show were manifested by two
  different agents within the hour:

    DVDVolume-7c5172b2  S04E01-E07  titles 2..8   CORRECT   - 6 published
    DVDVolume-38d2ed75  S04E08-E14  titles 1..7   OFF BY ONE - all 7 quarantined

  The disc holds EIGHT titles, and `dvdvideoTitle 1` is a 23-second leader; the seven episodes are
  titles 2..8. The bad manifest numbered its seven chosen episodes `1..7` sequentially - the
  MakeMKV-style index of the selection - instead of each title's true `dvdvideoTitle`, which is
  what `transcode.ps1` passes to ffmpeg's dvdvideo demuxer. So every request returned the PREVIOUS
  title's content: title 1 gave the 23 s leader (24.88 s of output), title 2 gave episode 1
  labelled E09, and so on down the disc.

  The catalogue states the rule in its own `titleNumbering` field:
      "MakeMKV (0-based). Per-title dvdvideoTitle is matched by DURATION, not by a fixed offset."
  A guard can check exactly that, and it is the one check the two manifests would have disagreed on.

  WHY AT THE GATE. transcode.ps1's duration guard did catch it - after seven encodes had run,
  leaving seven `.mkv.wrong-length` files and a failed job. Nothing wrong reached the NAS, so the
  cost was GPU time and a stalled unit rather than a bad publish. Caught here it costs nothing:
  the manifest is refused before a single frame is encoded, and the repair (`title` + 1) is
  arithmetic on a JSON file, not a re-rip.

  This is deliberately NOT a check that the episode ASSIGNMENT is right - that is judgement, and
  it needs content evidence. This checks only the mechanical claim a manifest makes implicitly:
  "the title I am asking ffmpeg for is the title whose duration I recorded in expectSeconds."

.NOTES
  Silent (exit 0) when it cannot judge: no catalogue, no per-title durations, a non-DVD manifest,
  or rows with no `expectSeconds`. A guard that refuses on missing evidence blocks the line for
  reasons that are not faults - see assert-edition-layout.ps1's header for the same stance.

.EXAMPLE
  pwsh -NoProfile -File assert-dvd-title-numbering.ps1 -Manifest D:/video/_queue/x.json
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [string]$Catalogue = 'D:/video/_catalogue',
  [string]$Stage = 'D:/video/_stage',
  [double]$ToleranceSec = 3.0,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Say "assert-dvd-title-numbering: no manifest at $Manifest"; exit 0 }
try { $rows = @(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json) }
catch { Say ("assert-dvd-title-numbering: unreadable manifest ({0}) - not this guard's call to refuse on" -f $_.Exception.Message); exit 0 }

# Rows this guard can speak to: a DVD title request carrying a recorded duration.
$dvd = @($rows | Where-Object { $_.kind -eq 'DVD' -and $null -ne $_.title -and $null -ne $_.expectSeconds })
if (-not $dvd.Count) { Say 'assert-dvd-title-numbering: no DVD rows with a title + expectSeconds - nothing to check'; exit 0 }

# The disc is named by the staged source path the rows point at.
$srcDirs = @($dvd | ForEach-Object { "$($_.src)" } | Where-Object { $_ } |
             ForEach-Object { (Split-Path $_ -Leaf) } | Sort-Object -Unique)
if ($srcDirs.Count -ne 1) { Say ("assert-dvd-title-numbering: rows span {0} source(s) - cannot tie to one catalogue" -f $srcDirs.Count); exit 0 }
$unit = $srcDirs[0]

$catPath = Join-Path $Catalogue "$unit.catalogue.json"
if (-not (Test-Path -LiteralPath $catPath)) { Say "assert-dvd-title-numbering: no catalogue for '$unit' - cannot judge"; exit 0 }
try { $cat = Get-Content -LiteralPath $catPath -Raw | ConvertFrom-Json } catch { Say 'assert-dvd-title-numbering: unreadable catalogue'; exit 0 }

# dvdvideoTitle -> seconds, from the catalogue's own "H:MM:SS" durations.
$byTitle = @{}
foreach ($t in @($cat.titles)) {
  $n = $t.dvdvideoTitle
  if ($null -eq $n) { continue }
  $d = "$($t.duration)"
  if ($d -notmatch '^\d+:\d{2}:\d{2}$') { continue }
  $p = $d.Split(':')
  $byTitle[[int]$n] = ([int]$p[0]) * 3600 + ([int]$p[1]) * 60 + [int]$p[2]
}
if ($byTitle.Count -lt 2) { Say "assert-dvd-title-numbering: catalogue for '$unit' carries no usable per-title durations - cannot judge"; exit 0 }

# Per row: does the catalogue's duration for the title we are ASKING FOR match the duration we
# RECORDED? If not, is there a uniform offset that does? A consistent shift is the signature.
$bad = @(); $offsets = @()
foreach ($r in $dvd) {
  $n = [int]$r.title; $exp = [double]$r.expectSeconds
  $here = $byTitle[$n]
  if ($null -ne $here -and [math]::Abs($here - $exp) -le $ToleranceSec) { continue }
  $hit = $null
  foreach ($k in -3..3) {
    if ($k -eq 0) { continue }
    $c = $byTitle[$n + $k]
    if ($null -ne $c -and [math]::Abs($c - $exp) -le $ToleranceSec) { $hit = $k; break }
  }
  $bad += [pscustomobject]@{
    Title = $n; Expect = $exp
    Here  = $(if ($null -ne $here) { $here } else { 'no such title' })
    Shift = $hit
    Out   = (Split-Path "$($r.out)" -Leaf)
  }
  if ($null -ne $hit) { $offsets += $hit }
}

if (-not $bad.Count) {
  Say ("assert-dvd-title-numbering: OK - all {0} DVD row(s) of '{1}' match the catalogue by duration" -f $dvd.Count, $unit)
  exit 0
}

# REFUSE ONLY ON THE SHIFT SIGNATURE. A row that matches NO nearby title is not a numbering error.
#
# The catalogue records MakeMKV's declared length; transcode.ps1 checks the length ffmpeg actually
# EMITS, and the dvdvideo demuxer is known to under-declare (see CLAUDE.md). So a small unexplained
# delta is usually the demuxer, not the manifest - and refusing on it blocks correct work.
#
# 2026-09-07: this guard refused Lawrence of Arabia Disk 2 because one row declared 3,689.0 s while
# the catalogue said 3,677 (1:01:17) and the dispositions independently said 61:17. It looked like a
# clear error. It was not: `ffprobe -f dvdvideo -title 3` on the staged disc returns exactly
# 3689.000000. The manifest was right, MakeMKV's figure was 12 s short, and my guard escalated a
# good manifest to NEEDS-VALIDATION where it sat until a human asked.
#
# The off-by-one this guard exists for has an unmistakable signature: the recorded duration matches
# a DIFFERENT title, consistently across rows. That is what gets refused. Anything else is reported
# loudly and allowed through, because transcode.ps1's own duration gate is the authority on emitted
# length and it runs anyway - quarantining a bad encode rather than shipping it.
$shifted   = @($bad | Where-Object { $null -ne $_.Shift })
$unmatched = @($bad | Where-Object { $null -eq $_.Shift })

if (-not $shifted.Count) {
  Say ("assert-dvd-title-numbering: PASS WITH WARNINGS - {0} of {1} DVD row(s) of '{2}' do not match the catalogue, but NONE matches another title, so this is not a numbering shift:" -f $unmatched.Count, $dvd.Count, $unit)
  foreach ($b in $unmatched) {
    Say ("   title {0,-3} expectSeconds {1,8:N1}  catalogue says {2}" -f $b.Title, $b.Expect, $b.Here)
    Say ("        {0}" -f $b.Out)
  }
  Say  '   Most often the dvdvideo demuxer under-declaring: the catalogue holds MakeMKV''s figure while'
  Say  '   the manifest holds the emitted length. Verify with:'
  Say ("      ffprobe -v error -f dvdvideo -title <N> -i '{0}' -show_entries format=duration -of csv=p=0" -f ((Join-Path $Stage $unit) -replace '\\','/'))
  Say  '   transcode.ps1 checks the EMITTED duration regardless and quarantines a wrong-length output,'
  Say  '   so this is not gated here. Not refused.'
  exit 0
}

Say ("assert-dvd-title-numbering: REFUSED - {0} of {1} DVD row(s) of '{2}' ask for a title whose catalogue duration is not the one recorded:" -f $bad.Count, $dvd.Count, $unit)
foreach ($b in $bad) {
  Say ("   title {0,-3} expectSeconds {1,8:N1}  catalogue says {2,-14} {3}" -f $b.Title, $b.Expect, $b.Here,
       $(if ($null -ne $b.Shift) { "-> title {0} matches (shift {1:+#;-#})" -f ($b.Title + $b.Shift), $b.Shift } else { 'no nearby title matches' }))
  Say ("        {0}" -f $b.Out)
}

# A UNIFORM shift is the actionable case, and it is the one that has happened: say the repair out
# loud, because "off by one" is arithmetic on the manifest and never a re-rip.
$uniq = @($offsets | Sort-Object -Unique)
if ($offsets.Count -eq $bad.Count -and $uniq.Count -eq 1) {
  $k = $uniq[0]
  Say ''
  # SINGLE QUOTES, NOT DOUBLE. In a double-quoted PowerShell string a backtick is the escape
  # character, so writing `title` to mean the JSON field emitted a literal TAB ("<TAB>itle") -
  # the exact control-character defect check-control-chars.py exists to catch.
  Say ("   EVERY bad row is shifted by exactly {0:+#;-#}. The recorded durations are RIGHT; only the" -f $k)
  Say ('   "title" field is wrong. Repair: add ' + $k + ' to "title" on every DVD row, then re-gate. The')
  Say  '   staged VIDEO_TS is untouched and no re-rip is involved.'
  Say  '   Cause is nearly always numbering the CHOSEN titles 1..N instead of using each title''s'
  Say  '   true dvdvideoTitle - short leader/menu titles the selection skipped still occupy numbers.'
}
exit 2

