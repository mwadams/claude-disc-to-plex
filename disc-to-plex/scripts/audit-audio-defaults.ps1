# Which published files flag MORE THAN ONE audio stream as `default`?
#
# WHY THIS EXISTS
# ---------------
# Found 2026-09-01 by an independent validation pass over Babylon 5, not by any gate. Every one of
# Season 1's episodes E01-E20 and Season 00's E01-E03 has EVERY audio stream flagged default; the
# two encoded from a DVD source the same day have exactly one. A sample of twelve other shows found
# two more affected (Derren Brown Trick of the Mind, Enemy at the Door), so it is neither universal
# nor confined to one programme - which is exactly the shape that needs counting rather than
# guessing at.
#
# WHY IT MATTERS. The library's audio convention is: AAC first (a universal direct-play track),
# then a bit-for-bit passthru of the original. With every stream flagged default, which one a client
# selects is undefined - it may land on the AC3 passthru, or on a commentary. It is not corruption,
# and it is invisible on any player that happens to choose first-match, which is why it shipped
# repeatedly without anyone noticing.
#
# THIS SCRIPT ONLY REPORTS. Fixing is a container-level flag remux (no re-encode, no quality loss),
# and it rewrites files on the NAS, so it stays a separate decision.
#
#   pwsh -File audit-audio-defaults.ps1                          # whole library
#   pwsh -File audit-audio-defaults.ps1 -Roots '//NAS/.../Films' # one section
#   pwsh -File audit-audio-defaults.ps1 -Csv D:/video/_logs/audio-defaults.csv
param(
  [string[]]$Roots = @('//NASTEAMV/Multimedia/Television Shows', '//NASTEAMV/Multimedia/Films'),
  [string]$Csv = 'D:/video/_logs/audio-defaults.csv',
  # Files the audit could NOT clear, and why. A separate file because it answers a different
  # question: not "what is wrong" but "what did I fail to examine".
  [string]$Problems = 'D:/video/_logs/audio-defaults-problems.csv',
  [string]$ToolPaths = 'D:/video/.transcode-tools/tool-paths.json'
)

$ErrorActionPreference = 'Stop'
$tp = Get-Content -LiteralPath $ToolPaths -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $tp.ffmpeg) 'ffprobe.exe'
if (-not (Test-Path -LiteralPath $ffprobe)) { throw "ffprobe not found at $ffprobe" }

New-Item -ItemType Directory -Force (Split-Path $Csv) | Out-Null
'path,audioStreams,defaultFlagged,codecs' | Set-Content -LiteralPath $Csv -Encoding utf8

$scanned = 0; $bad = 0; $unreadable = 0; $noAudio = 0
'path,problem,reason' | Set-Content -LiteralPath $Problems -Encoding utf8
foreach ($root in $Roots) {
  if (-not (Test-Path -LiteralPath $root)) { Write-Output "SKIP (not reachable): $root"; continue }
  Write-Output "scanning $root ..."
  foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Include *.mkv, *.mp4 -ErrorAction SilentlyContinue) {
    $scanned++

    # ONE ffprobe PER FILE, reading only the header. A file that cannot be read is COUNTED AND
    # NAMED, never silently skipped: "no findings" must mean "looked and found nothing", not
    # "could not look".
    #
    # AND THE TWO ZERO-ROW CASES ARE NOT THE SAME THING. The first version of this script counted
    # them together as "unreadable", which was wrong in both directions:
    #   - a stills gallery or a silent extra genuinely HAS no audio. Nothing is wrong with it, and
    #     calling it unreadable invites someone to go hunting for a fault that does not exist.
    #   - a file ffprobe cannot open - moved, truncated, an SMB timeout - is a REAL gap in the
    #     audit's coverage, and the only honest thing to say about it is "not examined".
    # Lumping them produced a single number (77) that could not be acted on, next to a finding (658)
    # that looked complete. Distinguish by EXIT CODE, and record the reason.
    $err = & $ffprobe -v error -select_streams a `
             -show_entries stream=codec_name:stream_disposition=default `
             -of csv=p=0 $f.FullName 2>&1
    $probeOk = $?
    $rows = @($err | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] -and "$_" -match '\S' })
    if (-not $probeOk) {
      $unreadable++
      $reason = (@($err | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
                  ForEach-Object { "$_" }) -join ' ') -replace '"', "'" -replace '\s+', ' '
      if (-not $reason) { $reason = 'ffprobe exited non-zero with no message' }
      Write-Output ("  UNREADABLE  {0}  [{1}]" -f $f.FullName, $reason)
      ('"{0}","unreadable","{1}"' -f $f.FullName, $reason) | Add-Content -LiteralPath $Problems -Encoding utf8
      continue
    }
    if ($rows.Count -eq 0) {
      $noAudio++
      ('"{0}","no-audio-streams",""' -f $f.FullName) | Add-Content -LiteralPath $Problems -Encoding utf8
      continue
    }

    # csv=p=0 emits `<codec>,<default>` per stream.
    $codecs = @(); $flags = @()
    foreach ($r in $rows) {
      $parts = "$r".Trim().TrimEnd(',') -split ','
      if ($parts.Count -lt 2) { continue }
      $codecs += $parts[0]
      $flags  += $parts[1]
    }
    $n = @($flags | Where-Object { $_ -eq '1' }).Count
    if ($n -le 1) { continue }

    $bad++
    Write-Output ("  {0} audio / {1} default   {2}" -f $flags.Count, $n, $f.FullName)
    ('"{0}",{1},{2},"{3}"' -f $f.FullName, $flags.Count, $n, ($codecs -join ' ')) |
      Add-Content -LiteralPath $Csv -Encoding utf8
  }
}

Write-Output ''
Write-Output ("scanned {0} file(s); {1} have more than one default audio stream; {2} unreadable" -f $scanned, $bad, $unreadable)
if ($unreadable -gt 0) {
  Write-Output "  NB $unreadable file(s) returned no audio stream info - they are NOT cleared, they were not readable."
}
Write-Output "csv -> $Csv"
