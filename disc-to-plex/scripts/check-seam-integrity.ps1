# Check a CONCATENATED item for decoder fill at its segment seams.
#
# WHY THIS IS A SCRIPT. When a title is recovered program-by-program and the parts are concatenated,
# the natural checks are duration and frame count - and on a disc whose cells are not GOP-aligned
# BOTH PASS while the picture is broken. Each segment's last frames decode from an incomplete GOP
# and render as saturated green/red DECODER FILL that grows until the frame is solid. The frames are
# all PRESENT; only their contents are wrong.
#
# That shipped: "The Saint (1962) - S00E22 - Trailer Reel.mkv" totalled 996.66 s / 24,910 frames,
# exactly matching a flat read of the source VOB, with 269 corrupt frames spread over ALL 17 of its
# program seams. Nothing arithmetic could have caught it, so the check has to look at the picture.
#
# THE DISCRIMINATOR. Black leader between items is NORMAL and proves nothing either way - on that
# reel blackdetect found 21 black segments and they were the reel's own structure. What separates
# the defect from the leader is the DIRECTION SATURATION MOVES:
#
#   * a real fade to black DESATURATES - SATMAX falls towards 0 as the picture goes dark
#   * decoder fill SATURATES  - the unwritten macroblocks carry the fill colour, so SATMAX SPIKES
#                               (109-130 measured) while UAVG/VAVG collapse away from neutral 128
#
# So: locate the joins with blackdetect, then inspect the window immediately BEFORE each one.
#
# Reports per seam and EXITS 2 if any seam is dirty, so it can gate a rebuild.
#
# ONE decode pass: blackdetect logs the joins to stderr and passes frames through, so signalstats
# runs in the same chain. The SATMAX threshold is applied INSIDE ffmpeg (metadata=mode=select), so
# only the handful of candidate frames is ever written out - parsing a per-frame dump of a feature
# in PowerShell is minutes of work for the same answer.

param(
  [Parameter(Mandatory)][string]$Path,
  [double]$Window   = 2.0,    # seconds before a black segment to inspect
  [double]$Sat      = 60.0,   # SATMAX above which a darkening frame is not a fade
  [double]$Chroma   = 12.0,   # how far UAVG/VAVG must sit from neutral 128
  [double]$MinBlack = 0.15    # blackdetect minimum duration
)

if (-not (Test-Path -LiteralPath $Path)) { Write-Host "not found: $Path"; exit 1 }

$paths  = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
$ffmpeg = $paths.ffmpeg

$tmp = Join-Path $env:TEMP ("seam-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  # signalstats' file= argument cannot carry a drive-letter colon, so run from the temp dir and
  # let it write a bare filename.
  Push-Location $tmp
  $chain = "blackdetect=d=$MinBlack`:pix_th=0.10," +
           "signalstats," +
           "metadata=mode=select:key=lavfi.signalstats.SATMAX:value=$Sat`:function=greater," +
           "metadata=mode=print:file=sel.txt"
  $log = & $ffmpeg -v info -i $Path -vf $chain -an -f null - 2>&1
  Pop-Location

  $seams = @()
  foreach ($line in $log) {
    if ("$line" -match 'black_start:([\d.]+) black_end:([\d.]+)') {
      $seams += [pscustomobject]@{ Start = [double]$Matches[1]; End = [double]$Matches[2] }
    }
  }
  Write-Host ("{0}" -f (Split-Path $Path -Leaf))
  Write-Host ("  black segments: {0}" -f $seams.Count)
  if (-not $seams.Count) { Write-Host "  no black segments - nothing to check"; exit 0 }

  # ---- candidate frames (already SATMAX-filtered by ffmpeg) -----------------------------------
  $cand = New-Object System.Collections.ArrayList
  $selFile = Join-Path $tmp 'sel.txt'
  if (Test-Path -LiteralPath $selFile) {
    $t = -1.0; $u = 128.0; $v = 128.0; $s = 0.0; $have = $false
    switch -File $selFile -Regex {
      '^frame:.*pts_time:([\d.]+)' {
        if ($have) { [void]$cand.Add([pscustomobject]@{ T = $t; U = $u; V = $v; S = $s }) }
        $t = [double]$Matches[1]; $u = 128.0; $v = 128.0; $s = 0.0; $have = $true
      }
      '^lavfi\.signalstats\.UAVG=([-\d.]+)'   { $u = [double]$Matches[1] }
      '^lavfi\.signalstats\.VAVG=([-\d.]+)'   { $v = [double]$Matches[1] }
      '^lavfi\.signalstats\.SATMAX=([-\d.]+)' { $s = [double]$Matches[1] }
    }
    if ($have) { [void]$cand.Add([pscustomobject]@{ T = $t; U = $u; V = $v; S = $s }) }
  }
  Write-Host ("  saturated candidate frames: {0}" -f $cand.Count)

  # ---- the window before each join --------------------------------------------------------------
  $totalBad = 0; $dirtySeams = 0
  foreach ($seam in $seams) {
    $lo = $seam.Start - $Window
    $bad = @($cand | Where-Object {
      $_.T -ge $lo -and $_.T -lt $seam.Start -and
      ([math]::Abs($_.U - 128) -ge $Chroma -or [math]::Abs($_.V - 128) -ge $Chroma)
    })
    if ($bad.Count) {
      $dirtySeams++; $totalBad += $bad.Count
      $worst = $bad | Sort-Object { [math]::Min($_.U, $_.V) } | Select-Object -First 1
      Write-Host ("  seam @ {0,9:F3} : *** {1,3} corrupt frames *** {2:F3}..{3:F3}  worst UAVG={4:F1} VAVG={5:F1} SATMAX={6:F1}" -f `
        $seam.Start, $bad.Count, $bad[0].T, $bad[-1].T, $worst.U, $worst.V, $worst.S)
    } else {
      Write-Host ("  seam @ {0,9:F3} : clean" -f $seam.Start)
    }
  }

  Write-Host ""
  if ($totalBad) {
    Write-Host ("*** SATURATED FILL AT {0} OF {1} SEAMS - {2} affected frames ***" -f $dirtySeams, $seams.Count, $totalBad)
    Write-Host "The item is COMPLETE but not INTACT - duration and frame count cannot see this."
    Write-Host ''
    Write-Host "FIRST establish WHERE it comes from, because two very different causes look identical:"
    Write-Host "  1. re-read the title with a CONTINUOUS read (no -pg, no chapter args) and stream-copy"
    Write-Host "     it losslessly, then run this check on THAT. No re-encode, no concat, no joins."
    Write-Host "  2. decode the whole stream at -v warning and count decoder messages."
    Write-Host ''
    Write-Host "If the continuous copy is CLEAN and messages are non-zero, the assembly introduced it -"
    Write-Host "rebuild from the continuous read. If the continuous copy shows the SAME frames at the"
    Write-Host "SAME timestamps and the decoder reports ZERO messages, the fill is ENCODED IN THE SOURCE"
    Write-Host "and NO re-read or re-encode can remove it - look at a frame full-size before assuming a"
    Write-Host "pipeline bug. Real case: The Saint S00E22, where a per-program build and a continuous"
    Write-Host "read produced byte-identical defect maps (17 seams, 269 frames) because the disc's own"
    Write-Host "master carries a horizontal picture slip with green fill at every trailer join."
    exit 2
  }
  Write-Host ("all {0} seams clean" -f $seams.Count)
  exit 0
}
finally {
  Pop-Location -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
