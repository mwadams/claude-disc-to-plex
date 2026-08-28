# Decide, per DVD, whether the fast ffmpeg `dvdvideo` path is safe or the disc needs a MakeMKV rip.
#
# WHY THIS IS A SCRIPT. `ffmpeg -f dvdvideo -title N` reads only a title's FIRST cell, so a
# multi-cell episode comes back short - silently, with no error, and the encode ships truncated.
# The counter-rule matters just as much: a short reading is NOT automatically truncation. If
# MakeMKV independently reports the same length, the disc is simply that length and the fast path
# is correct. Only a COMPARISON can tell those apart, so make the comparison mechanical.
#
# ⚠ BUT AGREEMENT IS NOT COMPLETENESS. Both tools read only a title's FIRST CELL, so on a
# multi-cell PGC they can agree while both being wrong, and this script prints "ok". See the note
# at the bottom of the loop (The Saint Colour D13 title 8: a 16:36 / 17-cell reel that both tools
# called 0:59). The fix in that case is to read each PROGRAM separately:
#
#     ffmpeg -f dvdvideo -pgc 1 -pg N -title M -i "<disc>" ...
#
# which returns every program IN FULL where -chapter_end, -preindex and -trim all still truncate.
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

  # ---- INTEGRITY FIRST: is this rip even COMPLETE? -------------------------------------------
  # The VMG (VIDEO_TS.IFO) declares how many title sets the disc has, at offset 0x3E. An aborted
  # rip leaves a folder that looks entirely normal - it mounts, it enumerates, it plays - but the
  # title sets that were never copied are simply absent, and any player following the menu into
  # them crashes.
  #
  # Real case: DIE_MUMINS_3 declares 27 title sets and holds 11. The missing ones were the whole
  # ENGLISH version of the programme, so the disc looked like a German-only release rather than a
  # broken copy, and VLC died whenever the English branch was selected. The last present title set
  # was also short its .BUP with a 64 MB VOB against ~430 MB siblings - truncated mid-write.
  #
  # Checking this BEFORE the duration comparison matters: on an incomplete rip the durations are
  # all perfectly consistent between tools, so the comparison happily reports "safe".
  $vmg = Join-Path $src 'VIDEO_TS\VIDEO_TS.IFO'
  if (Test-Path -LiteralPath $vmg) {
    $b = [IO.File]::ReadAllBytes($vmg)
    $declared = [int]$b[0x3E]*256 + [int]$b[0x3F]
    $present  = @(Get-ChildItem (Join-Path $src 'VIDEO_TS') -Filter 'VTS_*_0.IFO').Count
    if ($declared -gt 0 -and $present -lt $declared) {
      Write-Host ("{0,-34} *** INCOMPLETE RIP *** declares {1} title sets, {2} present - RE-RIP the disc" -f $d, $declared, $present)
      continue
    }
    # a set missing its .BUP is the signature of a copy that stopped mid-set
    $noBup = Get-ChildItem (Join-Path $src 'VIDEO_TS') -Filter 'VTS_*_0.IFO' |
             Where-Object { -not (Test-Path -LiteralPath ($_.FullName -replace '\.IFO$','.BUP')) }
    if ($noBup) {
      Write-Host ("{0,-34} !! {1} title set(s) missing their .BUP - possible truncated copy: {2}" -f $d, @($noBup).Count, (($noBup.Name) -join ' '))
    }
  }

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
    Write-Host "      REMEDY if MakeMKV is also short, or you want to stay on the dvdvideo path:"
    Write-Host "        ffmpeg -f dvdvideo -pgc 1 -pg N -title M -i `"<disc>`" ...   # N = 1..(programs in the PGC)"
    Write-Host "      Each PROGRAM is read IN FULL. -chapter_end, -preindex and -trim all still truncate;"
    Write-Host "      the program option is the one that works. Concatenate the programs into one item."
  } else {
    Write-Host ("{0,-34} ok - dvdvideo path safe ({1} titles agree)" -f $d, $mk.Count)
  }

  # ---- THE BLIND SPOT THIS COMPARISON CANNOT SEE ---------------------------------------------
  # "The two tools agree" is not "the disc is that length". Both readers share the SAME first-cell
  # limitation, so on a multi-cell PGC they can agree WHILE BOTH BEING WRONG - and this script then
  # prints "ok".
  #
  # Real case: The Saint Colour D13 title 8, a trailer reel authored as ONE PGC of 00:16:36 in 17
  # cells. MakeMKV reported 0:00:59 / 37.4 MB, `-f dvdvideo -title 8` decoded ~59 s, they agreed,
  # and this script reported "ok - dvdvideo path safe (9 titles agree)". What exposed it was the
  # BYTE comparison: 37 MB of reported title against a 663,889,920-byte VTS, which
  # prove-dvd-mapping.py already reports as UNPROVEN. Reading each of the 17 programs recovered the
  # full 24,910 frames.
  #
  # So a duration agreement is necessary, not sufficient. Run prove-dvd-mapping.py as well, and
  # treat any title whose MakeMKV size is a small fraction of its VTS as truncated until proven
  # otherwise - then use the -pg remedy above.
  Write-Host ("{0,-34} note: agreement is NOT completeness - both tools read only a title's first cell." -f '')
  Write-Host ("{0,-34}       Cross-check byte sizes with prove-dvd-mapping.py; if a title is a small" -f '')
  Write-Host ("{0,-34}       fraction of its VTS, read it per-PROGRAM: -f dvdvideo -pgc 1 -pg N -title M" -f '')

  # ---- Is this disc's mymovies.xml telling the truth about its own contents? -------------------
  # It is a NAMING hint, never a structural authority. On the Media10 drive it was wrong about
  # durations on three separate discs: Moomins on the Riviera listed its 74:00 feature as 13:59,
  # Ballet Shoes listed 59:03 + 56:16 for titles that measure 119:04 + 116:16, and The Snowman and
  # the Snowdog put MainMovie="True" on a 46:16 title when the film is the 23:57 one.
  #
  # Each of those is enough to pick the wrong title, or to conclude a feature is missing from a
  # disc that holds it. Compare the SETS of durations rather than pairing by index - mymovies title
  # Numbers are not ffmpeg title numbers, so index pairing has its own well-documented trap.
  $mmPath = Join-Path $src 'mymovies.xml'
  if (Test-Path -LiteralPath $mmPath) {
    try {
      [xml]$mm = Get-Content -LiteralPath $mmPath -Raw
      $claimed = @($mm.SelectNodes('//Title[@Number]') |
                   ForEach-Object { [int]$_.Hours*3600 + [int]$_.Minutes*60 + [int]$_.Seconds } |
                   Where-Object { $_ -ge 60 } | Sort-Object)
      $measured = @($mk | Where-Object { $_ -ge 60 } | Sort-Object)
      if ($claimed.Count) {
        # every claimed length should have a measured partner within tolerance
        $orphans = @()
        $pool = [System.Collections.ArrayList]@($measured)
        foreach ($c in $claimed) {
          $hit = $pool | Where-Object { [math]::Abs($_ - $c) -le 30 } | Select-Object -First 1
          if ($hit) { [void]$pool.Remove($hit) } else { $orphans += $c }
        }
        if ($orphans.Count) {
          Write-Host ("{0,-34} !! mymovies.xml DISAGREES with the disc - treat it as a naming hint only" -f $d)
          Write-Host ("      claims lengths with no measured match: {0}" -f
            (($orphans | ForEach-Object { [timespan]::FromSeconds($_).ToString('hh\:mm\:ss') }) -join ', '))
          Write-Host ("      measured: {0}" -f
            (($measured | ForEach-Object { [timespan]::FromSeconds($_).ToString('hh\:mm\:ss') }) -join ', '))
        }
      }
    } catch { Write-Host ("{0,-34} !! mymovies.xml unreadable" -f $d) }
  }
}
