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
# called 0:59). The fix in that case is to read the title PROGRAM BY PROGRAM:
#
#     ffmpeg -f dvdvideo -title M -chapter_start N -chapter_end N -i "<disc>" ...
#
# which recovers content that -preindex and -trim do not.
#
# 🔴 DO NOT LOOP OVER -pg. `-pg` is an ENTRY point, not a selection: ffmpeg documents it as "entry
# PG number", it has no exit counterpart, and it returns program N **and everything after it to the
# end of the PGC**. Measured on a 625-frame / 4-program PGC (The Saint Monochrome D15, VTS_01):
# -pg 1 = 625 frames, -pg 2 = 335, -pg 3 = 155 -- nested, not disjoint. Looping N over -pg and
# concatenating therefore yields a reel several times the true length, every item repeated with one
# more of its neighbours each time.
#
# 🔴 AND DO NOT TRUST A CHAPTER *RANGE* EITHER - ASK FOR ONE UNIT AT A TIME, THEN VERIFY IT.
# On D15 VTS_01, `-chapter_start N -chapter_end N` returned 290 and 180 frames: disjoint, summing to
# the title exactly. But on The Saint Monochrome D10 title 6 - four programs across seven cells,
# 212.8 s declared - a flat read stopped at 49.8 s, `-preindex 1` returned the same 49.8 s, and
# `-chapter_start 1 -chapter_end 4` ALSO returned 49.8 s. The range arguments were accepted and
# SILENTLY IGNORED; only reading ONE chapter at a time returned each program whole. A one-pass encode
# there would have shipped a valid, plausible 49.8 s file that had silently lost three extras.
#
# So neither `-pg` nor a chapter RANGE can be relied on to honour what you asked for. What survived
# on both discs is: request ONE unit, COUNT ITS PACKETS, and check the units sum to the title.
#
# TWO SIGNATURES THAT LOOK IDENTICAL IN A DURATION COLUMN - both are "the read stopped early":
#   * first-cell truncation - the read returns the length of cell 1 (D13 title 8: 59 s of 996 s)
#   * first-chapter truncation - the read returns the length of chapter 1 (D10 title 6: 49.8 s of 212.8 s)
# Neither announces itself. Both look like "the title is simply that long" until you compare against
# the PGC's declared time or the VTS byte size.
#
# ⚠ AND A FRAME COUNT THAT MATCHES THE DISC SAYS NOTHING ABOUT WHETHER THOSE FRAMES ARE RIGHT.
# The Saint (1962) S00E22 "Trailer Reel" totalled 996.66 s / 24,910 frames, identical to a flat VOB
# read, and carried 8-30 frames of saturated green/red fill at every one of its 17 seams (269
# frames). All PRESENT, ~269 of them wrong. Only the picture can see that.
#
# 🔴 BUT DO NOT ASSUME THE ASSEMBLY CAUSED IT. The obvious theory - that reading a program in
# isolation leaves its final GOP incomplete - was written here first and was WRONG. Rebuilding from
# a single CONTINUOUS read of the VTS VOB (no -pg, no chapter args, no concat, no joins at all)
# reproduced the defect EXACTLY: same 17 seams, same 269 frames, same per-seam counts and chroma.
# The stream decodes with ZERO decoder messages, and a full-size frame shows the picture SLIDING
# horizontally with green filling the gap, film grain and dirt visible in the green -- a picture
# slip baked into the disc's own master. Nothing to recover; no re-encode can fix it.
#
# So when seams are dirty, FIRST take a continuous read, stream-copy it losslessly and re-check
# THAT. It costs minutes and separates "our assembly broke it" from "the source is like this".
#
# So after concatenating, SCAN THE SEAMS FROM THE PICTURE. Black leader between items is normal
# and proves nothing; what separates the defect from the leader is the direction saturation moves.
# A real fade to black DESATURATES; decoder fill SATURATES. Locate the joins with blackdetect,
# then look at the ~2 s before each one:
#
#     ffmpeg -i reel.mkv -vf blackdetect=d=0.15:pix_th=0.10 -an -f null -
#     ffmpeg -i reel.mkv -vf signalstats,metadata=print:file=stats.txt -an -f null -
#
# ...or just run the guard that does both and exits 2 on a dirty seam:
#
#     pwsh -File scripts/check-seam-integrity.ps1 -Path "<concatenated item>"
#
# and flag frames with SATMAX >= 60 while UAVG/VAVG sit >= 12 off neutral (128). On the shipped
# reel those frames ran SATMAX 109-130 with UAVG/VAVG down at 57-93 or up at 227-236, against
# SATMAX ~22 for the surrounding picture. A GOP-aligned disc gives no such frames at all: on the
# D15 control, the single-program read was BIT-IDENTICAL to the continuous read for all 290 frames
# (psnr=inf, mse 0.00), so this is a per-disc property to be measured, never assumed either way.
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

  # PAIR BY THE PROVEN MAPPING, NOT BY POSITION.
  #
  # This compared MakeMKV's Nth title against ffmpeg's title N. That assumes the two enumerations
  # run in step, and they do not always: on The World's Fastest Indian (2005) TT_SRPT declares six
  # titles of which three are navigation stubs, so MakeMKV's first REAL title is dvdvideo 3 and the
  # whole comparison sits three out. It probed the stubs, called the feature "short", and printed
  # `*** USE MakeMKV ***` for a disc whose dvdvideo path was fine.
  #
  # A false alarm is the harmless half. THE SAME OFFSET CAN PAIR A TITLE AGAINST A LONGER SIBLING
  # AND REPORT "ok" ON A GENUINELY TRUNCATED ONE - a truncation check that passes truncated
  # content, which is the failure this script exists to prevent.
  #
  # `prove-dvd-mapping.py` already answers this from the disc's own tables (TT_SRPT plus exact VTS
  # byte totals), so use its answer and fall back to position only when it cannot prove one - and
  # say so, loudly, because an unproven pairing is exactly the state that produced the wrong verdict.
  $map = $null
  $proverPath = Join-Path $PSScriptRoot 'prove-dvd-mapping.py'
  if (Test-Path -LiteralPath $proverPath) {
    try {
      $pj = & python $proverPath $src --json --minlength 1 2>$null | ConvertFrom-Json
      if ($pj -and $pj.mapping) {
        $map = @{}
        foreach ($row in $pj.mapping) {
          if ($null -ne $row.dvdvideoTitle) { $map[[int]$row.makemkvTitle] = [int]$row.dvdvideoTitle }
        }
        if ($map.Count -lt $mk.Count) { $map = $null }   # partial proof is not a mapping
      }
    } catch { $map = $null }
  }
  if (-not $map) {
    Write-Host ("{0,-34} !! mapping NOT proven - pairing MakeMKV title N against dvdvideo N by" -f $d)
    Write-Host    "      POSITION. If this disc has navigation stubs the pairing is offset and this"
    Write-Host    "      verdict is unreliable in BOTH directions. Check prove-dvd-mapping.py by hand."
  }

  $short = @()
  for ($i = 0; $i -lt $mk.Count; $i++) {
    # $mk is 0-based over MakeMKV's titles; MakeMKV title ids are 0-based, so title id = $i.
    # $ff is 0-based over dvdvideo titles 1..N, so dvdvideo title D sits at $ff[$D-1].
    $dv = if ($map -and $map.ContainsKey($i)) { $map[$i] } else { $i + 1 }
    $ffIdx = $dv - 1
    # ${i} NOT $i - PowerShell reads "$i:" as a DRIVE-qualified variable and fails to parse.
    if ($ffIdx -lt 0 -or $ffIdx -ge $ff.Count) { $short += "t${i}: dvdvideo $dv not probed"; continue }
    if ($ff[$ffIdx] -lt 0) { $short += "t${i} (dvdvideo $dv): ffmpeg could not read"; continue }
    $gap = $mk[$i] - $ff[$ffIdx]
    if ($gap -gt $ToleranceSec) {
      $short += ("t{0} (dvdvideo {1}): ffmpeg {2} vs MakeMKV {3} (-{4}s)" -f $i, $dv,
                 [timespan]::FromSeconds($ff[$ffIdx]).ToString('hh\:mm\:ss'),
                 [timespan]::FromSeconds($mk[$i]).ToString('hh\:mm\:ss'), $gap)
    }
  }

  if ($short) {
    Write-Host ("{0,-34} *** USE MakeMKV *** ({1}/{2} titles short)" -f $d, $short.Count, $mk.Count)
    $short | ForEach-Object { Write-Host "      $_" }
    Write-Host "      REMEDY if MakeMKV is also short, or you want to stay on the dvdvideo path:"
    Write-Host "        ffmpeg -f dvdvideo -title M -chapter_start N -chapter_end N -i `"<disc>`" ...  # ONE unit, N=N"
    Write-Host "      Read the title ONE UNIT AT A TIME and concatenate the units into ONE item."
    Write-Host "      Do NOT loop over -pg: it is an ENTRY point, not a selection - it returns program N"
    Write-Host "      AND everything after it, so concatenating those gives a reel several times too long."
    Write-Host "      Do NOT trust a chapter RANGE either: on Monochrome D10 title 6, -chapter_start 1"
    Write-Host "      -chapter_end 4 was accepted and SILENTLY IGNORED, returning chapter 1's 49.8s of a"
    Write-Host "      declared 212.8s - a valid file that had lost three extras. COUNT EACH UNIT'S PACKETS"
    Write-Host "      and check they sum to the title:  assert-stream-packets.ps1 -Disc <disc> -Title M"
    Write-Host "      THEN CHECK THE SEAMS FROM THE PICTURE, not from the totals. Where cells are not"
    Write-Host "      GOP-aligned, each segment's last ~8-30 frames decode as saturated green/red DECODER"
    Write-Host "      FILL. Those frames are all present, so duration and frame count still match the disc"
    Write-Host "      exactly - that is how a corrupt reel shipped (The Saint S00E22, 17/17 seams bad)."
    Write-Host "        ffmpeg -i reel.mkv -vf blackdetect=d=0.15:pix_th=0.10 -an -f null -   # find the joins"
    Write-Host "        ffmpeg -i reel.mkv -vf signalstats,metadata=print:file=stats.txt -an -f null -"
    Write-Host "      In the ~2 s before each join, fill shows as SATMAX >= 60 with UAVG/VAVG >= 12 off 128."
    Write-Host "      Leader black is NOT the defect (it sits at U=V=128, SATMAX ~0); a fade desaturates,"
    Write-Host "      fill saturates. If seams are dirty, take the VIDEO from a continuous read of the VTS"
    Write-Host "      VOB and use the per-program reads only for the audio the flat read cannot give you."
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
  # otherwise - then use the per-program remedy above.
  #
  # And note how the recovery itself then went wrong, because the second half of the job is the
  # half that gets skipped: the 17 programs were recovered, they tiled the reel exactly, and the
  # item shipped with a second of decoder fill at every join. The recovery was verified against
  # ARITHMETIC (996.66 s, 24,910 frames, both exact) when the failure was PICTORIAL. Recovering
  # the frames and recovering the picture are two claims, and only one of them was checked.
  Write-Host ("{0,-34} note: agreement is NOT completeness - both tools read only a title's first cell." -f '')
  Write-Host ("{0,-34}       Cross-check byte sizes with prove-dvd-mapping.py; if a title is a small" -f '')
  Write-Host ("{0,-34}       fraction of its VTS, read it per-PROGRAM with -chapter_start/-chapter_end" -f '')
  Write-Host ("{0,-34}       (NOT -pg, which is an entry point), then LOOK AT THE SEAMS - an exact" -f '')
  Write-Host ("{0,-34}       frame count says nothing about whether those frames decoded correctly." -f '')

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
