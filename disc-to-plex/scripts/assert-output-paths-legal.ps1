<#
.SYNOPSIS
  REFUSE a manifest whose output filename contains a character Windows cannot put in a file name.

.WHY THIS EXISTS
  2026-09-07, Tales of the Unexpected S04E01 "Would You Believe It?". The manifest declared

      .../Season 04/Tales of the Unexpected (1979) - S04E01 - Would You Believe It?.mkv

  and `?` is one of the nine characters Windows forbids in a leaf name. ffmpeg decoded nothing and
  died on the OUTPUT open:

      Error opening output ... .mkv: Invalid argument
      !! FAILED (0 s, ffmpeg exit -22)

  What made it expensive to read was the company it kept: every item on that disc - the six that
  encoded perfectly included - printed a wall of `libdvdcss ... CSS authentication not available`
  warnings first, so the one line that mattered sat under fourteen lines of benign noise. The
  episode was simply missing from Plex afterwards, with no obvious cause.

  A punctuated episode title is completely ordinary ("Who Killed...?", "Are You...?"), so this will
  recur. It costs nothing to catch: the check is a regex over a string that is already in hand,
  and the repair - drop the character from the FILENAME - loses nothing, because Plex takes the
  displayed title from its agent (or from `plexTitle`), never from the punctuation on disk.

.NOTES
  Checks the LEAF only. A colon is legal in `D:/video/...` and forbidden inside a name, so testing
  the whole path would refuse every valid manifest on this machine.

.EXAMPLE
  pwsh -NoProfile -File assert-output-paths-legal.ps1 -Manifest D:/video/_queue/x.json
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Say "assert-output-paths-legal: no manifest at $Manifest"; exit 0 }
try { $rows = @(Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json) }
catch { Say ("assert-output-paths-legal: unreadable manifest ({0}) - not this guard's call to refuse on" -f $_.Exception.Message); exit 0 }

# The nine Windows-forbidden characters, plus a trailing dot or space (silently stripped by the
# filesystem, which turns "verify the file we wrote" into a name that does not match).
$forbidden = '[<>:"/\\|?*]'
$bad = @()
foreach ($r in $rows) {
  $out = "$($r.out)"
  if (-not $out) { continue }
  $leaf = Split-Path $out -Leaf
  $hits = @([regex]::Matches($leaf, $forbidden) | ForEach-Object { $_.Value } | Sort-Object -Unique)
  $trail = ($leaf -match '[ .]$')
  if ($hits.Count -or $trail) {
    $bad += [pscustomobject]@{ Leaf = $leaf; Chars = ($hits -join ' '); Trailing = $trail }
  }
}

if (-not $bad.Count) {
  Say ("assert-output-paths-legal: OK - all {0} output name(s) are legal on Windows" -f @($rows).Count)
  exit 0
}

Say ("assert-output-paths-legal: REFUSED - {0} output name(s) cannot be created on Windows:" -f $bad.Count)
foreach ($b in $bad) {
  $why = @()
  if ($b.Chars)    { $why += "forbidden character(s): $($b.Chars)" }
  if ($b.Trailing) { $why += 'ends in a dot or space (the filesystem strips it silently)' }
  Say ("   {0}" -f $b.Leaf)
  Say ("        {0}" -f ($why -join '; '))
}
Say ''
Say '   ffmpeg fails this as "Error opening output ...: Invalid argument" / exit -22 AFTER decoding'
Say '   nothing, and on a DVD the message lands under a wall of benign libdvdcss warnings.'
Say '   Repair: strip the character from the FILENAME. The displayed title is unaffected - Plex'
Say '   takes it from its agent, or from the manifest''s plexTitle, never from the name on disk.'
exit 2
