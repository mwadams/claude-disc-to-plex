<#
.SYNOPSIS
  For staged Blu-ray units, measure any CANDIDATE TWIN PLAYLISTS before their dispositions agent is
  launched, and leave the answer in `_catalogue/<unit>.branch-comparison.txt`.

.WHY
  Same principle as prebuild-disposition-packs.ps1: deterministic measurement does not belong on the
  single serialised agent slot, at agent token rates. This one also fixes a QUALITY problem, not
  just a cost one.

  Blake's 7 Series 1 Disc 1, 2026-09-21: both episodes were delivered as two playlists, and the
  dispositions excluded one of each as `exclude|duplicate` - reasoning from identical runtime and
  identical audioMd5 per clip pair. They were the modernized-VFX branches. On a seamless-branching
  remaster those two figures match BY CONSTRUCTION, because re-rendering an effects shot does not
  touch the soundtrack, so the evidence the agent was given could not answer the question it was
  asked. Half the disc was about to be discarded, and the same reasoning would have run over 26
  episodes across two series.

  The agent was not careless. It was handed clip-list arithmetic and asked for a judgement about
  PICTURES. This hands it a measurement of the pictures instead.

.THE CHEAP PRE-FILTER
  Full per-frame SSIM over two playlists is minutes of decoding, so it must not run on every disc.
  A candidate pair is narrow and costs nothing to find: two playlists whose TOTAL RUNTIME matches
  within a second, that SHARE at least one clip, and that each carry at least one clip the other
  does not. A disc with no branching has no such pair and this does nothing.

.WHAT IT WILL NOT DO
  It does not disposition anything, and it does not decide which branch is the original - see the
  tool's own header for why that is left to eyes. It measures, writes, and stops.

.EXAMPLE
  pwsh -NoProfile -File prebuild-branch-comparison.ps1 -WhatIf
  pwsh -NoProfile -File prebuild-branch-comparison.ps1 -Unit 'Blakes 7 - Series 1 - Disc 1-53e0015f'
#>
param(
  [string]$Stage     = 'D:/video/_stage',
  [string]$Catalogue = 'D:/video/_catalogue',
  [string]$Unit      = '',
  [string]$NasHold   = 'D:/video/_nas-hold',
  [int]$MaxPairs     = 4,          # per unit, cheapest insurance against a pathological disc
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mpls = Join-Path $here 'mpls-clips.py'
$cmp  = Join-Path $here 'compare-branch-clips.py'

function Say([string]$m) { Write-Output $m }

# SINGLE-INSTANCE, MACHINE-WIDE. _dispositions-loop.ps1 fire-and-forgets this every pass (~2 min), and
# its comment promised "single-instance on its own mutex" - true of prebuild-disposition-packs.ps1,
# never of this one. One Blu-ray's comparison takes far longer than a pass (Blake's 7 S1 Disc 6,
# 2026-09-23: ~1 h 45 min for 4 pairs), and until its report is written every new launch sees no report
# and starts the SAME comparison: TEN copies ran 11:55-14:00, each decoding the same clips, starving
# the catalogue track that the whole line was waiting on. A second copy now leaves at once.
$script:Mutex = New-Object System.Threading.Mutex($false, 'Global\video-prebuild-branch-comparison')
$got = $false
try { $got = $script:Mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
if (-not $got) { Say 'another prebuild-branch-comparison is already running - leaving it to finish'; exit 0 }

$units = if ($Unit) { @($Unit) } else {
  @(Get-ChildItem -LiteralPath $Stage -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'BDMV/PLAYLIST') } |
    ForEach-Object { $_.Name })
}
if (-not $units.Count) { Say 'no staged Blu-ray unit with a PLAYLIST folder - nothing to do'; exit 0 }

foreach ($u in $units) {
  $dir = Join-Path $Stage $u
  $pl  = Join-Path $dir 'BDMV/PLAYLIST'
  $sd  = Join-Path $dir 'BDMV/STREAM'
  if (-not (Test-Path -LiteralPath $pl)) { continue }
  $out = Join-Path $Catalogue ($u + '.branch-comparison.txt')

  # Idempotent, like the analysis cache: an existing report newer than the staging folder stands.
  if ((Test-Path -LiteralPath $out) -and
      ((Get-Item -LiteralPath $out).LastWriteTime -gt (Get-Item -LiteralPath $dir).LastWriteTime)) {
    Say "CACHED: $u"
    continue
  }
  # The comparison decodes from the staging drive only, but the --published lookup reads the NAS.
  if (Test-Path -LiteralPath $NasHold) { Say "NAS HOLD set - skipping $u"; continue }

  # ---- read every playlist once ----
  $info = @{}
  foreach ($f in @(Get-ChildItem -LiteralPath $pl -Filter '*.mpls' -File -ErrorAction SilentlyContinue)) {
    try {
      $j = & python $mpls $f.FullName --json --stream-dir $sd 2>$null | ConvertFrom-Json
      if (-not $j -or -not $j.clips) { continue }
      $info[$f.FullName] = [pscustomobject]@{
        Total = [double]$j.totalSec
        Clips = @($j.clips | ForEach-Object { "$($_.clip)" })
      }
    } catch { }
  }
  if ($info.Count -lt 2) { Say "$u : fewer than 2 readable playlists - nothing to pair"; continue }

  # ---- the cheap pre-filter ----
  $keys = @($info.Keys | Sort-Object)
  $pairs = @()
  for ($i = 0; $i -lt $keys.Count; $i++) {
    for ($k = $i + 1; $k -lt $keys.Count; $k++) {
      $a = $info[$keys[$i]]; $b = $info[$keys[$k]]
      if ([math]::Abs($a.Total - $b.Total) -gt 1.0) { continue }
      $shared = @($a.Clips | Where-Object { $b.Clips -contains $_ })
      $aOnly  = @($a.Clips | Where-Object { $b.Clips -notcontains $_ })
      $bOnly  = @($b.Clips | Where-Object { $a.Clips -notcontains $_ })
      # Shares something AND differs in something. All-shared is the same playlist twice (a second
      # door); all-different is two unrelated titles that happen to run the same length.
      if ($shared.Count -ge 1 -and $aOnly.Count -ge 1 -and $bOnly.Count -ge 1) {
        $pairs += [pscustomobject]@{ A = $keys[$i]; B = $keys[$k]; Shared = $shared.Count; Swapped = $aOnly.Count }
      }
    }
  }
  if (-not $pairs.Count) { Say "$u : no candidate twin playlists (nothing shares-and-differs)"; continue }

  Say ("{0} : {1} candidate twin pair(s)" -f $u, $pairs.Count)
  foreach ($p in ($pairs | Select-Object -First $MaxPairs)) {
    Say ("    {0} <-> {1}   {2} shared, {3} swapped" -f (Split-Path $p.A -Leaf), (Split-Path $p.B -Leaf), $p.Shared, $p.Swapped)
  }
  if ($WhatIf) { Say '    WhatIf: measured nothing'; continue }

  $frames = Join-Path $Catalogue ($u + '-branch-frames')
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("branch comparison for $u   generated $(Get-Date -Format 's')")
  $lines.Add("Candidate twins are playlists that SHARE some clips and SWAP others at equal runtime.")
  $lines.Add("Sustained divergence below means they are DIFFERENT VERSIONS, not duplicates - see")
  $lines.Add("_briefs/dispositions.md. Which branch is the ORIGINAL is not scored: look at the frames.")
  $lines.Add('')
  foreach ($p in ($pairs | Select-Object -First $MaxPairs)) {
    $args = @($cmp, $sd, '--a', $p.A, '--b', $p.B, '--frames', $frames)
    $res = & python @args 2>&1 | ForEach-Object { "$_" }
    $lines.AddRange([string[]]$res)
    $lines.Add('')
  }
  if (-not (Test-Path -LiteralPath $Catalogue)) { New-Item -ItemType Directory -Path $Catalogue -Force | Out-Null }
  Set-Content -LiteralPath $out -Value $lines -Encoding UTF8
  Say "    -> $out"
}
exit 0
