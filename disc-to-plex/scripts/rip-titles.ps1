<#
.SYNOPSIS
  Rip selected titles from a staged disc with MakeMKV — space-gated up front, verified after.

.WHY THIS EXISTS
  The FETCH is gated (`_fetch-one.ps1`, 80 GB floor) and the ENCODE is gated (transcode.ps1's
  preflights). The RIP in between was the one step with no tooling at all: invoked by hand, no space
  check, no verification, flags retyped each run. So the operator ends up doing arithmetic about
  free space in their head mid-session — which is exactly the thing a script should own.

  Three failures this covers, all of which have actually happened:

  1. **No space gate.** A 33 GB feature rip started with 51 GB free while a 42 GB disc was still
     copying in. It happened to fit; it very nearly did not, and filling the disk mid-write
     corrupts a staging folder.
  2. **Free space reads STALE after a large delete.** Releasing 44.85 GB and checking two seconds
     later reported 66 GB when the truth was 108 GB. `_fetch-one.ps1` already solves this with a
     re-read loop; hand-rolled checks do not, and I twice reported a false low figure today.
  3. **"It said it worked" is not verification.** MakeMKV exits 0 having written NOTHING when it
     cannot read the source (it reports "can't find any usable optical drives"). A grep of its
     output for anticipated strings cannot report an unanticipated failure. So this COUNTS THE
     OUTPUT FILES and checks each duration against the enumeration.

.PARAMETER Titles
  Title ids to rip. Omit to rip every title the disc enumerates.

.PARAMETER Reserve
  GB to leave free ON TOP of the rip's own size, so the encoder still has room afterwards. 20 GB is
  about one feature-length H.264 output.

.EXAMPLE
  pwsh -File rip-titles.ps1 -Disc D:\video\_stage\MAN_GOLDEN_GUN_F1 -Titles 0
  pwsh -File rip-titles.ps1 -Disc D:\video\_stage\MOONRAKER_F1 -Dest D:\video\_stage\moonraker-mkv
#>
param(
  [Parameter(Mandatory)][string]$Disc,
  [int[]]$Titles,
  [string]$Dest,
  [int]$Reserve = 20,
  [string]$MakeMkv = 'C:\Program Files (x86)\MakeMKV\makemkvcon64.exe',
  [string]$ToolsDir = 'D:\video\.transcode-tools'
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Disc))    { throw "disc folder not found: $Disc" }
if (-not (Test-Path -LiteralPath $MakeMkv)) { throw "MakeMKV not found: $MakeMkv" }
$discName = Split-Path $Disc -Leaf
if (-not $Dest) { $Dest = Join-Path (Split-Path $Disc -Parent) ($discName.ToLower() + '-mkv') }

$tp = Get-Content (Join-Path $ToolsDir 'tool-paths.json') | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $tp.ffmpeg) 'ffprobe.exe'

# ---- 1. ENUMERATE (MakeMKV is the authority on what the disc contains) ---------------------
Write-Output "enumerating $discName ..."
$info = & $MakeMkv -r --cache=1 --minlength=10 info "file:$Disc" 2>&1
$dur = @{}; $size = @{}
foreach ($line in $info) {
  if ($line -match '^TINFO:(\d+),9,0,"([^"]+)"')  { $p = $Matches[2] -split ':'; $dur[[int]$Matches[1]]  = [int]$p[0]*3600 + [int]$p[1]*60 + [int]$p[2] }
  if ($line -match '^TINFO:(\d+),10,0,"([^"]+)"') { $size[[int]$Matches[1]] = $Matches[2] }
}
if ($dur.Count -eq 0) { throw "enumeration returned NO titles - is the disc still copying? (see assert-staged-complete.ps1)" }
# NOT `if (-not $Titles)`. A single-element array unwraps to its element, so `-not @(0)` is TRUE —
# meaning `-Titles 0`, the feature and by far the commonest case, read as "no titles given" and
# ripped the ENTIRE DISC. Caught 2026-08-21 on Moonraker: asked for title 0, got "ripping 0..10".
if ($null -eq $Titles -or @($Titles).Count -eq 0) { $Titles = @($dur.Keys | Sort-Object) }
Write-Output ("disc has {0} title(s); ripping {1}" -f $dur.Count, ($Titles -join ','))

# ---- 2. SPACE GATE, with the stale-read retry ---------------------------------------------
# MakeMKV's declared sizes are close enough to budget from; +10% covers container overhead.
$needGB = 0.0
foreach ($t in $Titles) {
  $s = "$($size[$t])"
  if ($s -match '([\d.]+)\s*GB') { $needGB += [double]$Matches[1] }
  elseif ($s -match '([\d.]+)\s*MB') { $needGB += [double]$Matches[1] / 1024 }
}
$needGB = [math]::Round($needGB * 1.1, 1)
$wantGB = $needGB + $Reserve

# Free space reads LOW for several seconds after a large delete. One retry is not enough - a real
# case read 79 GB twice when the truth was 158 GB - so re-read a few times before refusing.
$freeGB = 0.0
for ($i = 1; $i -le 5; $i++) {
  $freeGB = [math]::Round((Get-Volume -DriveLetter D).SizeRemaining / 1GB, 1)
  if ($freeGB -ge $wantGB) { break }
  if ($i -lt 5) { Start-Sleep -Seconds 4 }
}
Write-Output ("space: need {0} GB for the rip + {1} GB reserve = {2} GB; free {3} GB" -f $needGB, $Reserve, $wantGB, $freeGB)
if ($freeGB -lt $wantGB) {
  Write-Output "*** REFUSING: not enough free space ***"
  Write-Output "Reclaim something first, or lower -Reserve if no encode follows this rip."
  exit 2
}

# ---- 3. RIP -------------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $Dest | Out-Null

# RECORD WHICH UNIT THIS DIRECTORY BELONGS TO, HERE, WHERE IT IS KNOWN FOR CERTAIN.
#
# The reclaim path (Get-UnitStageTargets, lib-disk.ps1) finds artefact directories by DERIVING their
# names from the unit name - `<slug>-rip|-x|-main|-mkv|-reel|-audio`. That works only while -Dest
# follows the convention on line 48. Pass a -Dest that does not, and nothing on disk records which
# disc the folder came from: the link lives solely in the head of whoever typed the command, and the
# folder becomes unreachable by every reclaim artefact.
#
# `_stage/mumins1-mkv` (7.6 GB) is the case that proved it - ripped from DIE_MUMINS_1 into a -Dest
# named after its MANIFEST (`mumins1`), so the slug `die_mumins_1-mkv` never existed and both
# _release-completed.ps1 and _reclaim-loop.ps1 reported "not staged" for a folder plainly sitting
# there. No matcher can bridge `mumins1` to `DIE_MUMINS_1` without also reaching names it must not
# touch, and a mis-targeted release is this pipeline's one irreversible step. So write the fact down
# instead of re-deriving it: one line, at the moment the directory is created.
$unitMarker = Join-Path $Dest '.unit'
if (-not (Test-Path -LiteralPath $unitMarker)) {
  Set-Content -LiteralPath $unitMarker -Encoding UTF8 -Value @(
    $discName
    '# Written by rip-titles.ps1 at rip time. First non-comment line is the STAGED UNIT this'
    '# directory was ripped from, as _completed.txt and the catalogue spell it.'
    '# Get-UnitStageTargets (lib-disk.ps1) reads it so a -Dest that does not follow the slug'
    '# convention is still reachable by a reclaim artefact naming the unit. Do not edit it to'
    '# make a release pass: it is a record of where these files came from.'
    ("# source disc: {0}" -f $Disc)
    ("# ripped     : {0}" -f (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'))
  )
}

$before = @(Get-ChildItem $Dest -Filter *.mkv -ErrorAction SilentlyContinue).Count
foreach ($t in $Titles) {
  Write-Output ("  ripping t{0:D2} ({1}) ..." -f $t, $size[$t])
  & $MakeMkv -r --cache=1 --minlength=10 --noscan mkv "file:$Disc" $t $Dest 2>&1 | Out-Null
}

# ---- 4. VERIFY BY COUNTING FILES AND CHECKING DURATIONS -----------------------------------
# NEVER conclude success from MakeMKV's own output: it exits 0 having written nothing.
$files = @(Get-ChildItem $Dest -Filter *.mkv)
$made  = $files.Count - $before
Write-Output ("FILES PRODUCED: {0} (expected {1})" -f $made, $Titles.Count)

$bad = 0
foreach ($t in $Titles) {
  $f = $files | Where-Object { $_.BaseName -match ("_t{0:D2}$" -f $t) } | Select-Object -First 1
  if (-not $f) { Write-Output ("  t{0:D2}  ** NO FILE **" -f $t); $bad++; continue }
  $d = & $ffprobe -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null
  $secs = if ($d) { [math]::Round([double]$d) } else { 0 }
  $want = $dur[$t]
  # A LOW-BITRATE PLAYLIST CAN LEGITIMATELY RIP SHORT. MakeMKV reports a playlist's duration
  # including repeats, so a looping menu/gallery title enumerates far longer than its unique
  # content (Live and Let Die t01: 120 s declared, 1 s of actual content; t05: 460 s vs 211 s).
  # Flag it for a look rather than calling it a failure.
  $delta = [math]::Abs($secs - $want)
  if ($delta -le 3) { Write-Output ("  t{0:D2}  {1,6}s  ok" -f $t, $secs) }
  elseif ($secs -gt $want) {
    # LONGER THAN DECLARED CANNOT BE TRUNCATION. Saying "truncated rip" here sends the reader
    # hunting for missing content that is provably not missing, and trains them to skim the
    # warning - which matters, because the SHORT direction below is real.
    #
    # The two enumerators genuinely disagree about long titles: libdvdnav counts the full cell
    # chain, MakeMKV trims. `catalogue-dvd.ps1` already allows 0.5% of runtime for this when
    # matching titles. Out of the Clouds ripped 4576s against 4570s declared - 6s over, 0.13% -
    # and ffprobe put the true duration at 4576.480, so the RIP was right and the DECLARATION was
    # short.
    #
    # Still reported, never silently passed: an over-length rip can also be a looping playlist
    # whose declared duration counts repeats (Live and Let Die t01: 120s declared, 1s of content).
    # But it is a different question from truncation, so it gets a different sentence.
    $pct = if ($want -gt 0) { 100.0 * $delta / $want } else { 0 }
    Write-Output ("  t{0:D2}  {1,6}s  vs {2,6}s declared  <-- LONGER by {3}s ({4:N2}%) - NOT truncation. Usually MakeMKV trimming a long title; check for a looping playlist if the gap is large" -f $t, $secs, $want, $delta, $pct)
    $bad++
  }
  else {
    Write-Output ("  t{0:D2}  {1,6}s  vs {2,6}s declared  <-- SHORT by {3}s - CHECK: truncated rip, or a looping playlist whose declared duration counts repeats" -f $t, $secs, $want, $delta)
    $bad++
  }
}
# The exit code must agree with the verification above. 'RIP DONE' printed over a nonzero $bad
# with exit 0 is the "unconditional success message" defect: anything scripted on top of this
# (a waiter grepping for RIP DONE, a && chain) read a short rip as a finished one. The literal
# 'RIP DONE' stays in both branches for existing greps; the exit code carries the verdict.
if ($bad -gt 0) {
  Write-Output "*** $bad title(s) need a look - see the notes above ***"
  Write-Output "RIP DONE - $bad title(s) UNVERIFIED"
  exit 1
}
Write-Output 'RIP DONE'
