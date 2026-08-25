# Print a line ONLY when the number of busy GPU lanes changes, so a Monitor can notify on
# transitions instead of spamming.
#
# WHAT COUNTS AS A BUSY LANE
# --------------------------
# An encode lane is an ffmpeg WRITING INTO THE LIBRARY - D:\video\Movies or
# D:\video\Television Shows. That is the only property unique to a lane.
#
# Matching on `_stage` instead (the previous test) counts every OTHER ffmpeg that reads staging,
# and identification is full of them: the disposition agents extract frames and probe titles
# straight out of _stage all day. On 2026-08-25 that reported a busy lane while both lanes were
# genuinely idle, for over an hour, with nothing queued. The header already excluded "other agents'
# ffmpeg (subtitle sync against the NAS)" - the same reasoning applies to agents reading _stage,
# it just had not been noticed yet.
#
# ONE QUERY, NOT TWO
# ------------------
# The count and the names used to come from two independent Get-CimInstance calls, so they could
# disagree, and the message was built from the SECOND one. Combined with a name regex that only
# matched a quoted .mkv at end-of-line, a lane whose command line did not end that way produced
# `1/2 busy - BOTH IDLE` - a line that contradicts its own measurement in seven characters. This
# project has already recorded that a monitor which misreports trains the reader to ignore it, and
# the reader then decides by feel. Snapshot ONCE, derive both from the snapshot.
#
# And when a lane is running but unnameable, SAY SO ("1 unidentified") rather than falling through
# to the idle wording. Absence of a name is not absence of a lane.
param([int]$Want = 2, [string]$StateFile = 'D:\video\.transcode-tools\lanestate.txt')

# NORMALISE THE SLASHES. ffmpeg is invoked with FORWARD-slash paths here (the manifests use them,
# because a backslash in a generated string literal silently becomes a control character), so a
# backslash-only comparison matches nothing and every lane reads as idle. Compare on one canonical
# separator, lowercased. Getting this wrong is not cosmetic: on 2026-08-25 a lane check that
# matched nothing contributed to a wrong conclusion about what was running, and legitimate encodes
# were killed on the strength of it.
$libRoots = @('d:\video\movies', 'd:\video\television shows')

# ONE snapshot - everything below is derived from it.
$lanes = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
           Where-Object {
             $c = $_.CommandLine
             if (-not $c) { return $false }
             $n = ($c -replace '/', '\').ToLowerInvariant()
             [bool]($libRoots | Where-Object { $n.Contains($_) })
           })
$busy = $lanes.Count

$prev = if (Test-Path -LiteralPath $StateFile) { [int](Get-Content -LiteralPath $StateFile -Raw).Trim() } else { -1 }
if ($busy -eq $prev) { return }

Set-Content -LiteralPath $StateFile -Value $busy
if ($busy -ge $Want) { return }

# Name each lane by its OUTPUT file. Accept quoted or bare, anywhere in the line - ffmpeg's output
# is the last argument but may be followed by nothing at all, and the old `\s*$` anchor made a
# trailing space enough to lose the name.
$names = @($lanes | ForEach-Object {
  $m = [regex]::Matches($_.CommandLine, '"?([A-Za-z]:[^"]*?\.mkv)"?')
  if ($m.Count -gt 0) { Split-Path $m[$m.Count - 1].Groups[1].Value -Leaf }
})

$detail = if ($busy -eq 0) {
  ' - ALL IDLE'
} elseif ($names.Count -eq $busy) {
  " - still running: $($names -join ', ')"
} elseif ($names.Count -gt 0) {
  " - still running: $($names -join ', ') (+$($busy - $names.Count) unidentified)"
} else {
  " - $busy running, unidentified"
}
Write-Output ("LANE FREE: {0}/{1} busy{2}" -f $busy, $Want, $detail)
