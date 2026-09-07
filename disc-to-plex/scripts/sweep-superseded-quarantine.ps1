<#
.SYNOPSIS
  Report - and with -Apply, remove - quarantine artefacts (`.wrong-length`, `.seam-gap`) whose
  replacement has since encoded correctly. Local `D:` only, and only where the replacement is
  PROVEN good.

.WHY THIS EXISTS
  transcode.ps1 moves a bad output aside rather than deleting it, which is right: the artefact is
  the evidence, and more than once it has been the thing that settled what actually went wrong.
  But nothing ever clears them. When a TOLERANCE or a MANIFEST bug quarantines a CORRECT encode -
  which is exactly what happened on 2026-09-07, twice in one morning - the re-encode succeeds and
  the artefact stays behind holding gigabytes.

  The reclaim loop will not touch them, and says so plainly:

      1 quarantine artefact(s), 1650.5 MB, NOT counted as held: never published, so never
      byte-matchable on the NAS. Local-only on D:, yours to drop

  That is correct - a reclaim releases what the NAS has verified, and these were never published,
  so there is nothing to verify against. Which leaves the judgement here: is the file that REPLACED
  this one actually good? That is a real check, and it was being made by hand each time.

  WHAT MAKES IT SAFE. Four conditions, all required, any one of them failing means the artefact
  stays:

    1. The replacement EXISTS at the same path without the suffix.
    2. The NEWEST manifest naming that output is in `_queue\done\`. A manifest still queued, still
       running, or in `failed\` means the encode that would justify dropping the artefact has not
       succeeded - and the artefact is the only copy of what went wrong.
    3. The replacement has been QUIET for -StableMinutes. A file still being written is not a
       replacement yet: on 2026-09-07 two of five artefacts belonged to a disc that was still
       encoding, and its 624 MB output was mid-write.
    4. The replacement's length matches the manifest, judged by lib-length-tolerance.ps1 - the same
       rule transcode.ps1 itself applies, not a second copy of it.

.NOTES
  DRY RUN BY DEFAULT. Nothing is removed without -Apply. Refuses to act on any path outside the
  library roots or not ending in a known quarantine suffix, so a malformed root cannot widen it.

.EXAMPLE
  pwsh -NoProfile -File sweep-superseded-quarantine.ps1
  pwsh -NoProfile -File sweep-superseded-quarantine.ps1 -Apply
#>
param(
  # Local library roots only. Quarantine artefacts never reach the NAS - transcode.ps1 writes them
  # beside the output it was building, which is always under D:.
  [string[]]$Root = @('D:/video/Movies', 'D:/video/Television Shows'),
  [string]$Queue = 'D:/video/_queue',
  [string[]]$Suffix = @('.wrong-length', '.seam-gap'),
  # How long the replacement must have been untouched before it counts as finished.
  [int]$StableMinutes = 5,
  [switch]$Apply
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/lib-length-tolerance.ps1"

$toolPaths = 'D:/video/.transcode-tools/tool-paths.json'
$ffprobe = $null
if (Test-Path -LiteralPath $toolPaths) {
  try {
    $ffprobe = Join-Path (Split-Path ((Get-Content -LiteralPath $toolPaths -Raw | ConvertFrom-Json).ffmpeg)) 'ffprobe.exe'
    if (-not (Test-Path -LiteralPath $ffprobe)) { $ffprobe = $null }
  } catch { $ffprobe = $null }
}
if (-not $ffprobe) {
  Write-Output 'sweep-superseded-quarantine: ffprobe not found - cannot verify a replacement, so nothing is eligible.'
  exit 0
}

function Get-Norm([string]$p) { return ("$p" -replace '/', '\').TrimEnd('\').ToLowerInvariant() }

# ---- Index every manifest row by its output path, keeping the NEWEST manifest per output. -------
# The newest is what matters: an output usually appears in an original AND its retries, and the
# question is whether the LAST attempt succeeded, not whether any attempt ever did.
$byOut = @{}
foreach ($state in @('','running','done','failed')) {
  $dir = if ($state) { Join-Path $Queue $state } else { $Queue }
  if (-not (Test-Path -LiteralPath $dir)) { continue }
  foreach ($m in (Get-ChildItem -LiteralPath $dir -Filter *.json -File -ErrorAction SilentlyContinue)) {
    $rows = $null
    try { $rows = @(Get-Content -LiteralPath $m.FullName -Raw | ConvertFrom-Json) } catch { continue }
    foreach ($r in $rows) {
      if (-not $r.out) { continue }
      $k = Get-Norm $r.out
      $prev = $byOut[$k]
      if ($null -eq $prev -or $m.LastWriteTime -gt $prev.When) {
        $byOut[$k] = [pscustomobject]@{
          When = $m.LastWriteTime; State = $(if ($state) { $state } else { 'queued' })
          Manifest = $m.Name; Row = $r
        }
      }
    }
  }
}

$roots = @($Root | Where-Object { Test-Path -LiteralPath $_ })
$arts = @()
foreach ($rt in $roots) {
  foreach ($sfx in $Suffix) {
    $arts += @(Get-ChildItem -LiteralPath $rt -Filter "*$sfx" -File -Recurse -ErrorAction SilentlyContinue)
  }
}
if (-not $arts.Count) { Write-Output 'sweep-superseded-quarantine: no quarantine artefacts found.'; exit 0 }

Write-Output ("sweep-superseded-quarantine: {0} artefact(s) under {1} root(s)" -f $arts.Count, $roots.Count)
Write-Output ''

$now = Get-Date
$safe = @(); $held = @()
foreach ($a in $arts) {
  # NO @() HERE, AND THAT IS THE WHOLE POINT. Wrapping this in @() makes $sfx a one-element ARRAY,
  # and [array].Length is its COUNT - so `$a.FullName.Length - $sfx.Length` stripped ONE character
  # instead of ten, $repl became "...mkv.wrong-lengt", Test-Path found nothing, and the script
  # reported "no replacement has been encoded yet" for two files that were sitting right there.
  # It failed SAFE (everything held) which is why it looked plausible - the same @()-around-a-
  # single-item trap that made Sub-IdxByLang index a string and return a character.
  [string]$sfx = $Suffix | Where-Object { $a.Name.EndsWith($_) } | Select-Object -First 1
  if (-not $sfx) { continue }        # cannot happen via the -Filter above, but never guess a suffix
  $repl = $a.FullName.Substring(0, $a.FullName.Length - $sfx.Length)
  $why = @()

  if (-not (Test-Path -LiteralPath $repl)) { $why += 'no replacement has been encoded yet' }
  else {
    $ri = Get-Item -LiteralPath $repl
    $quiet = ($now - $ri.LastWriteTime).TotalMinutes
    if ($quiet -lt $StableMinutes) { $why += ('replacement written {0:N1} min ago - may still be encoding' -f $quiet) }

    $rec = $byOut[(Get-Norm $repl)]
    if ($null -eq $rec) { $why += 'no manifest names this output - cannot tell which encode produced it' }
    elseif ($rec.State -ne 'done') { $why += ("its manifest {0} is in '{1}', not done" -f $rec.Manifest, $rec.State) }
    else {
      $row = $rec.Row
      if ($null -ne $row.expectSeconds -and [double]$row.expectSeconds -gt 0) {
        $gd = 0.0
        [void][double]::TryParse("$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $repl 2>$null)".Trim().TrimEnd(','), [ref]$gd)
        $v = Test-OutputDuration -GotSeconds $gd -ExpectSeconds ([double]$row.expectSeconds)
        if (-not $v.Ok) {
          $why += ('replacement is {0:N2}s against an expected {1:N2}s ({2:+0.00;-0.00}) - it is not good either' -f $gd, [double]$row.expectSeconds, $v.Delta)
        }
      } else { $why += 'manifest row declares no expectSeconds - nothing to verify the replacement against' }
    }
  }

  if ($why.Count) { $held += [pscustomobject]@{ Art = $a; Why = ($why -join '; ') } }
  else            { $safe += $a }
}

if ($held.Count) {
  Write-Output ("HELD - {0} artefact(s) stay, the replacement is not proven:" -f $held.Count)
  foreach ($h in $held) {
    Write-Output ("   {0:N2} GB  {1}" -f ($h.Art.Length/1GB), $h.Art.Name)
    Write-Output ("            {0}" -f $h.Why)
  }
  Write-Output ''
}

if (-not $safe.Count) { Write-Output 'nothing is eligible.'; exit 0 }

$tot = ($safe | Measure-Object Length -Sum).Sum
Write-Output ("SUPERSEDED - {0} artefact(s), {1:N2} GB, replacement verified against the manifest:" -f $safe.Count, ($tot/1GB))
foreach ($s in $safe) { Write-Output ("   {0:N2} GB  {1}" -f ($s.Length/1GB), $s.FullName) }
Write-Output ''

if (-not $Apply) {
  Write-Output '   DRY RUN - re-run with -Apply to remove them. Each replacement above exists, its'
  Write-Output '   manifest completed, it has been quiet, and its length matches what the manifest'
  Write-Output '   declared under the same rule transcode.ps1 applies.'
  exit 0
}

$freed = 0
foreach ($s in $safe) {
  # Belt and braces: never act on anything that is not a quarantine artefact under a library root.
  $ok = ($Suffix | Where-Object { $s.Name.EndsWith($_) }).Count -gt 0
  $inRoot = ($roots | Where-Object { (Get-Norm $s.FullName).StartsWith((Get-Norm $_) + '\') }).Count -gt 0
  if (-not ($ok -and $inRoot)) { Write-Output ("   SKIPPED (failed the final path check): {0}" -f $s.FullName); continue }
  $sz = $s.Length
  Remove-Item -LiteralPath $s.FullName -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $s.FullName) { Write-Output ("   STILL PRESENT: {0}" -f $s.FullName) }
  else { $freed += $sz; Write-Output ("   removed {0:N2} GB  {1}" -f ($sz/1GB), $s.Name) }
}
Write-Output ''
Write-Output ("freed {0:N2} GB" -f ($freed/1GB))
exit 0
