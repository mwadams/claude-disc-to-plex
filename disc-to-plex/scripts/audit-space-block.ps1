# Is the line stopped for DISK SPACE that only the operator can release?
#
# WHY THIS EXISTS
# ---------------
# On 2026-09-01 the fetch loop sat below its floor for over an hour with 16 discs still to stage,
# and `_stallwatch.ps1` reported "no unit is waiting on the operator" the whole time. It was wrong:
# the line was blocked on exactly one thing - the user confirming four published episodes in Plex so
# their local copies could be reclaimed. The user asked "why did you not notify me?", and the honest
# answer was that nothing did. The monitor watches stallwatch's output for operator-blocked units,
# so a condition stallwatch does not name is a condition nobody is ever told about.
#
# This is the cries-wolf failure inverted. A monitor that fires on nothing gets ignored; a monitor
# that stays silent through a real stop is worse, because it actively reassures.
#
# THE CONDITION IS A CONJUNCTION, deliberately - all three must hold, or this is not a block:
#   1. free space is below the fetch floor, so `_fetch-loop.ps1` will not start a disc
#   2. discs remain to stage in the current listN.txt, so there IS work being held up
#   3. local files exist that are already byte-verified on the NAS, so there is something to
#      reclaim. Without this the operator can do nothing and saying so would just be noise.
#
# It NEVER deletes anything and never asks for a deletion directly: reclaiming a published unit is
# gated on the user confirming it in Plex, and that gate is the point. This only makes the wait
# visible, and says exactly how much space is on the other side of it.
#
#   pwsh -File audit-space-block.ps1              # report
#   pwsh -File audit-space-block.ps1 -Quiet       # exit only: 0 not blocked, 2 blocked
param(
  [string]$VideoRoot = 'D:/video',
  [int]$FloorGB      = 120,          # must match _fetch-loop.ps1's -FloorGB
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'

$freeGB = [math]::Round([IO.DriveInfo]::new('D').AvailableFreeSpace / 1GB, 1)
if ($freeGB -ge $FloorGB) { if (-not $Quiet) { Write-Output "space OK - $freeGB GB free, floor $FloorGB" }; exit 0 }

# (2) is any work actually being held up?
$listFile = Get-ChildItem (Join-Path $VideoRoot 'list*.txt') -ErrorAction SilentlyContinue |
            Sort-Object { $m = [regex]::Match($_.BaseName, '\d+'); if ($m.Success) { [int]$m.Value } else { 0 } } |
            Select-Object -Last 1
if (-not $listFile) { exit 0 }
$fetched = @{}; foreach ($l in (Get-Content (Join-Path $VideoRoot '_fetch-done.txt') -EA SilentlyContinue)) { if ($l.Trim()) { $fetched[$l.Trim()] = $true } }
$done    = @{}; foreach ($l in (Get-Content (Join-Path $VideoRoot '_completed.txt')  -EA SilentlyContinue)) { if ($l.Trim()) { $done[$l.Trim()] = $true } }
$left = @(Get-Content -LiteralPath $listFile.FullName |
          ForEach-Object { $_.Trim() } |
          Where-Object { $_ -and -not $_.StartsWith('#') -and -not $fetched.ContainsKey($_) -and -not $done.ContainsKey($_) })
if ($left.Count -eq 0) { if (-not $Quiet) { Write-Output "below the floor, but nothing left to stage in $($listFile.Name)" }; exit 0 }

# (3) what could actually be reclaimed? A local file counts ONLY when the NAS holds the same
# relative path at the SAME BYTE LENGTH - the identical test _release-published.ps1 applies. Size,
# not timestamp: robocopy carries the source mtime across, so timestamps prove nothing here.
#
# ffprobe mirrors the reclaim gate's SECOND condition: a byte-matched .mkv that still carries an
# un-OCR'd bitmap subtitle stream with no sidecar on the NAS will be HELD by _release-published.ps1
# (the mkv is the only source its sidecar can be made from). Counting such a file here promises
# space the reclaim will refuse - Harry Potter's two extras (24 MB) headed this list as
# "reclaimable" on 2026-09-02 while confirming them would have freed nothing. If ffprobe is
# unavailable, keep the old over-counting behaviour rather than dying: a monitor that stops
# reporting is the exact failure this script exists to prevent.
$ffprobe = $null
try {
  $tp = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
  $cand = Join-Path (Split-Path $tp.ffmpeg) 'ffprobe.exe'
  if (Test-Path -LiteralPath $cand) { $ffprobe = $cand }
} catch { }
$pairs = @(
  @{ Local = "$VideoRoot/Television Shows"; Nas = '\\NASTEAMV\Multimedia\Television Shows' }
  @{ Local = "$VideoRoot/Movies";           Nas = '\\NASTEAMV\Multimedia\Movies' }
)
$bytes = 0L; $files = 0; $works = @{}
# Per-work byte totals, so the report can say WHICH confirmation is worth HOW MUCH. The aggregate
# alone let the list lead with a 0.02 GB film while ~7 GB of Boston Legal scaffolding sat behind
# the same gate, unattributed (2026-09-02) - the operator was asked to confirm the wrong unit.
$workBytes = @{}
foreach ($p in $pairs) {
  if (-not (Test-Path -LiteralPath $p.Local)) { continue }
  foreach ($f in Get-ChildItem -LiteralPath $p.Local -Recurse -File -EA SilentlyContinue) {
    $rel = $f.FullName.Substring((Resolve-Path $p.Local).Path.Length).TrimStart('\', '/')
    $nas = Join-Path $p.Nas $rel
    $workTop = ($rel -split '[\\/]')[0]
    # SUBTITLES-ONLY WORK: the .mkv never byte-matches the NAS copy BY DESIGN (fresh local encode,
    # legacy NAS encode, same name), so the test below would exclude it from "reclaimable" forever
    # while ~12 GB of scaffolding sat behind the operator's confirmation. Mirror the gate
    # _release-published.ps1 applies to such a file: it is reclaimable once its sidecar is ON THE
    # NAS - that is the purpose the mkv exists to serve.
    if ($f.Extension -eq '.mkv' -and
        (Test-Path -LiteralPath (Join-Path (Join-Path $p.Local $workTop) '.subtitles-only'))) {
      # Both conditions mirror _release-published.ps1: the NAS must hold media at this path (any
      # bytes - it is the legacy encode) AND the sidecar. A path with no NAS media at all is an
      # unpublished picture, not scaffolding, and is not reclaimable.
      $srtNas = [IO.Path]::ChangeExtension($nas, $null) + 'eng.srt'
      if ((Test-Path -LiteralPath $nas) -and (Test-Path -LiteralPath $srtNas)) {
        $bytes += $f.Length; $files++; $works[$workTop] = $true
        $workBytes[$workTop] = [long]$workBytes[$workTop] + $f.Length
      }
      continue
    }
    if (-not (Test-Path -LiteralPath $nas)) { continue }
    if ((Get-Item -LiteralPath $nas).Length -ne $f.Length) { continue }
    # Byte-matched is NOT sufficient for an .mkv the OCR track still needs - see the ffprobe note
    # above. Only probe when the NAS lacks the sidecar, so the cost stays a handful of files.
    if ($f.Extension -eq '.mkv' -and $ffprobe) {
      $srtNas = [IO.Path]::ChangeExtension($nas, $null) + 'eng.srt'
      if (-not (Test-Path -LiteralPath $srtNas)) {
        $codecs = @(& $ffprobe -v error -select_streams s -show_entries stream=codec_name `
                      -of csv=p=0 $f.FullName 2>$null)
        if ($codecs -match 'dvd_subtitle|hdmv_pgs_subtitle|dvb_subtitle') { continue }
      }
    }
    $bytes += $f.Length; $files++
    $works[$workTop] = $true
    $workBytes[$workTop] = [long]$workBytes[$workTop] + $f.Length
  }
}
$stageGB = 0.0
foreach ($d in (Get-ChildItem (Join-Path $VideoRoot '_stage') -Directory -EA SilentlyContinue)) {
  if (Test-Path -LiteralPath (Join-Path $d.FullName '.HOLD')) { continue }
  if ($done.ContainsKey(($d.Name -replace '-rip$', ''))) {
    $stageGB += ((Get-ChildItem -LiteralPath $d.FullName -Recurse -File -EA SilentlyContinue |
                  Measure-Object Length -Sum).Sum / 1GB)
  }
}
$reclaimGB = [math]::Round($bytes / 1GB + $stageGB, 2)

if ($files -eq 0 -and $stageGB -eq 0) {
  if (-not $Quiet) {
    Write-Output "*** SPACE-BLOCKED and NOTHING IS RECLAIMABLE - $freeGB GB free, floor $FloorGB, $($left.Count) disc(s) waiting."
    Write-Output '    No local file is byte-verified on the NAS, so publishing must finish first.'
  }
  exit 2
}

if (-not $Quiet) {
  Write-Output ''
  Write-Output ("*** THE LINE IS SPACE-BLOCKED AND WAITING ON YOU - {0} GB free, floor {1}." -f $freeGB, $FloorGB)
  Write-Output ("    {0} disc(s) in {1} cannot start until space is freed." -f $left.Count, $listFile.Name)
  Write-Output ("    {0} GB is reclaimable: {1} local file(s) already byte-verified on the NAS{2}." -f `
                $reclaimGB, $files, $(if ($stageGB -gt 0) { ", plus $([math]::Round($stageGB,2)) GB of confirmed staging" } else { '' }))
  # PREFER THE REGISTER OVER THE FOLDER NAMES. _publish-loop.ps1 records each work as it verifies,
  # so the register says what was published AND WHEN - which is the actual request. The show
  # folders below are only a fallback for anything published before the register existed; they name
  # a programme, not a unit, and cannot say whether it has already been seen.
  # AN ENTRY CLEARS WHEN THE WORK HAS BEEN RECLAIMED, NOT WHEN _completed.txt NAMES IT.
  # The register holds WORK names ("Babylon 5"); _completed.txt holds DISC names ("Babylon 5
  # Season 4 Disk 5"). Testing one against the other never matches - the same mismatch
  # _release-published.ps1's header documents - so an entry would have stayed for ever and the
  # report would have kept naming works that were long gone.
  # $works is the set that still has local files byte-verified on the NAS, i.e. still reclaimable.
  # Intersecting with it makes the register self-clearing: reclaim the work and it drops out.
  $reg = Join-Path $VideoRoot '_awaiting-verification.txt'
  $pending = @()
  if (Test-Path -LiteralPath $reg) {
    foreach ($l in (Get-Content -LiteralPath $reg | Where-Object { $_.Trim() })) {
      $parts = $l -split '\|'
      $name  = $parts[-1].Trim()
      if (-not $works.ContainsKey($name)) { continue }   # nothing left of it locally: reclaimed
      $pending += [pscustomobject]@{ When = $parts[0]; Work = $name }
    }
  }
  if ($pending.Count -gt 0) {
    # PER-UNIT FIGURES, BIGGEST FIRST. The aggregate figure above cannot answer the operator's
    # actual question - "which confirmation clears the floor?". On 2026-09-02 this list led with
    # Harry Potter (0.02 GB) while ~7 GB of Boston Legal subtitles-only scaffolding sat behind the
    # same confirmation gate with no figure against its name, so the operator was effectively asked
    # to confirm the wrong unit. Attribute the space to the unit that returns it.
    Write-Output '    PUBLISHED AND AWAITING YOUR PLEX CONFIRMATION (biggest reclaim first):'
    foreach ($p in ($pending | Sort-Object { [long]$workBytes[$_.Work] } -Descending)) {
      Write-Output ("       {0}   published {1}   confirming returns ~{2:N2} GB" -f `
                    $p.Work, $p.When, ([long]$workBytes[$p.Work] / 1GB))
    }
  } elseif ($works.Keys.Count -gt 0) {
    $legacy = ($works.Keys | Sort-Object { [long]$workBytes[$_] } -Descending |
               ForEach-Object { '{0} (~{1:N2} GB)' -f $_, ([long]$workBytes[$_] / 1GB) }) -join ', '
    Write-Output ("    Local copies belong to: {0} (published before the register existed - confirm by unit)" -f $legacy)
  }
  Write-Output '    Confirm those in Plex and the reclaim clears the floor; the fetch resumes by itself.'
}
exit 2
