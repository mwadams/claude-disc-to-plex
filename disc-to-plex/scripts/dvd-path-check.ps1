# Decide, per DVD, whether the fast ffmpeg `dvdvideo` path is safe or the disc needs a MakeMKV rip.
#
# WHY THIS IS A SCRIPT. `ffmpeg -f dvdvideo -title N` reads only a title's FIRST cell, so a
# multi-cell episode comes back short - silently, with no error, and the encode ships truncated.
# The counter-rule matters just as much: a short reading is NOT automatically truncation. If
# MakeMKV independently reports the same length, the disc is simply that length and the fast path
# is correct. Only a COMPARISON can tell those apart, so make the comparison mechanical.
#
# On the Media10 archive discs this found every title truncated by up to 5 minutes, which the
# slates' own stated durations then confirmed.
#
# Read-only. Reports; changes nothing.

param(
  [Parameter(Mandatory)][string]$Root,          # folder holding the disc folders
  [string[]]$Discs,                             # optional subset; default = every VIDEO_TS folder
  [int]$ToleranceSec = 20,                      # ignore trivial differences
  [string]$MakeMkv = 'C:\Program Files (x86)\MakeMKV\makemkvcon64.exe'
)

$paths   = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'

if (-not $Discs) {
  $Discs = Get-ChildItem -LiteralPath $Root -Directory |
           Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'VIDEO_TS') } |
           Select-Object -ExpandProperty Name
}

foreach ($d in $Discs) {
  $src = Join-Path $Root $d
  if (-not (Test-Path -LiteralPath (Join-Path $src 'VIDEO_TS'))) { Write-Host "$d : not a DVD"; continue }

  # MakeMKV is the authority on cell structure: "Title #N was added (K cell(s), H:MM:SS)"
  #
  # --minlength=1, NOT a useful-looking floor. This comparison pairs MakeMKV's Nth title with
  # ffmpeg's title N, and any filtering breaks that alignment: at --minlength=60 MakeMKV hides the
  # short titles ffmpeg still numbers, so t3 in one tool is t5 in the other and the "differences"
  # are nonsense. Enumerate everything and let the comparison do the judging.
  $info = & $MakeMkv -r --cache=1 --minlength=1 info "file:$src" 2>&1
  $mk = @()
  foreach ($line in $info) {
    if ($line -match '^TINFO:(\d+),9,0,"(\d+):(\d\d):(\d\d)"') {
      $mk += [int]$Matches[2]*3600 + [int]$Matches[3]*60 + [int]$Matches[4]
    }
  }
  if (-not $mk.Count) { Write-Host "$d : MakeMKV reported no titles"; continue }

  # ffmpeg's view, title by title. Probe two past MakeMKV's count so a count mismatch is visible
  # rather than silently truncating the comparison.
  $ff = @()
  for ($i = 1; $i -le $mk.Count + 2; $i++) {
    $v = "$(& $ffprobe -v error -f dvdvideo -title $i -i $src -show_entries format=duration -of csv=p=0 2>$null)".Trim()
    if ($v -and $v -ne 'N/A') { $ff += [int][double]$v } else { $ff += -1 }
  }
  $ffSeen = @($ff | Where-Object { $_ -ge 0 }).Count
  if ($ffSeen -ne $mk.Count) {
    Write-Host ("{0,-34} !! title COUNT differs: ffmpeg {1}, MakeMKV {2} - pairing unreliable, inspect by hand" -f $d, $ffSeen, $mk.Count)
    continue
  }

  $short = @()
  for ($i = 0; $i -lt $mk.Count; $i++) {
    if ($ff[$i] -lt 0) { $short += "t$($i+1): ffmpeg could not read"; continue }
    $gap = $mk[$i] - $ff[$i]
    if ($gap -gt $ToleranceSec) {
      $short += ("t{0}: ffmpeg {1} vs MakeMKV {2} (-{3}s)" -f ($i+1),
                 [timespan]::FromSeconds($ff[$i]).ToString('hh\:mm\:ss'),
                 [timespan]::FromSeconds($mk[$i]).ToString('hh\:mm\:ss'), $gap)
    }
  }

  if ($short) {
    Write-Host ("{0,-34} *** USE MakeMKV *** ({1}/{2} titles short)" -f $d, $short.Count, $mk.Count)
    $short | ForEach-Object { Write-Host "      $_" }
  } else {
    Write-Host ("{0,-34} ok - dvdvideo path safe ({1} titles agree)" -f $d, $mk.Count)
  }
}
