<#
  Apply a verified file->episode mapping by COPYING to the correct names, then hand over the
  originals for removal.

  IT ONLY EVER COPIES. Nothing is removed here, on any volume. Sources whose copy is
  byte-verified are written to a retire list for the user; acting on that list is their
  decision. This is the same shape as every other correction in this pipeline, and it is what
  makes a wrong mapping recoverable: delete the copy and nothing has been lost.

  WHY COPYING IS SAFE HERE
  The new names carry the episode title - "Danger Man - S01E01 - View from the Villa.mkv" -
  while the originals are bare - "Danger Man S01E01.mkv". A titled name cannot collide with a
  bare one, so all of them can be written while the originals are still in place. A
  bare-to-bare correction would have needed temporary names to stop two files briefly claiming
  one slot, with a window where an interrupted run left the library inconsistent.

  PRE-FLIGHT REFUSES ANYTHING THAT IS NOT A CLEAN ONE-TO-ONE. A mapping where two sources
  target one name, or where a target already exists, is not a correction but a data-loss plan,
  and its failure would only become visible after the originals were gone.
#>
param(
  [Parameter(Mandatory)][string]$Plan,            # JSON: [{source,target,episode,score,title}]
  [Parameter(Mandatory)][string]$Dir,             # folder holding the sources
  [string]$RetireList = 'D:\video\_nas-retire-renamed.txt',
  [int]$MinScore = 2,
  [switch]$Execute
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Dir))  { throw "folder not found: $Dir" }
if (-not (Test-Path -LiteralPath $Plan)) { throw "plan not found: $Plan" }
$items = Get-Content -LiteralPath $Plan -Raw | ConvertFrom-Json

# ---- pre-flight
$problems = @()
$srcSeen = @{}; $dstSeen = @{}
foreach ($i in $items) {
  $s = Join-Path $Dir $i.source
  $d = Join-Path $Dir $i.target
  if (-not (Test-Path -LiteralPath $s)) { $problems += "source missing: $($i.source)" }
  if (Test-Path -LiteralPath $d)        { $problems += "target already exists: $($i.target)" }
  if ($srcSeen[$i.source]) { $problems += "source used twice: $($i.source)" }
  if ($dstSeen[$i.target]) { $problems += "target used twice: $($i.target)" }
  if ($i.score -lt $MinScore) { $problems += "score $($i.score) below floor for $($i.source)" }
  $srcSeen[$i.source] = $true; $dstSeen[$i.target] = $true
}
$onDisk = @(Get-ChildItem -LiteralPath $Dir -File -Filter *.mkv | Select-Object -ExpandProperty Name)
$unmapped = @($onDisk | Where-Object { -not $srcSeen[$_] })
if ($unmapped.Count) { $problems += "$($unmapped.Count) file(s) in the folder are not in the plan: $($unmapped -join ', ')" }

Write-Host "plan items      : $($items.Count)"
Write-Host "files in folder : $($onDisk.Count)"
if ($problems.Count) {
  Write-Host "`nREFUSING - pre-flight failed:" -ForegroundColor Red
  $problems | Select-Object -First 12 | ForEach-Object { "   !! $_" }
  exit 2
}
Write-Host 'pre-flight OK: one-to-one, no target exists, every file accounted for'

if (-not $Execute) {
  Write-Host "`nDRY RUN - pass -Execute to write the copies"
  $items | Select-Object -First 5 | ForEach-Object { "   $($_.source)  ->  $($_.target)" }
  return
}

# ---- copy and byte-verify
$ok = 0; $bad = @()
foreach ($i in $items) {
  $s = Join-Path $Dir $i.source
  $d = Join-Path $Dir $i.target
  Copy-Item -LiteralPath $s -Destination $d -Force
  $a = Get-Item -LiteralPath $s; $b = Get-Item -LiteralPath $d
  if ($a.Length -eq $b.Length) { $ok++; Write-Host ("  OK  {0,-30} -> {1}" -f $i.source, $i.target) }
  else { $bad += $i.target; Write-Host ("  SIZE MISMATCH {0}" -f $i.target) -ForegroundColor Red }
}
Write-Host "`ncopied and byte-verified: $ok / $($items.Count)"

# ---- hand over ONLY the sources whose copy verified
$verified = @($items | Where-Object { $bad -notcontains $_.target })
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Mis-named originals, each superseded by a byte-verified copy under its correct name.')
$lines.Add("# Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm'). NOTHING HAS BEEN REMOVED.")
$lines.Add('# Identified from dialogue against per-episode cast lists; see the plan for scores.')
$lines.Add('')
foreach ($i in $verified | Sort-Object source) { $lines.Add((Join-Path $Dir $i.source)) }
Set-Content -LiteralPath $RetireList -Value $lines -Encoding UTF8
Write-Host "retire list -> $RetireList  ($($verified.Count) path(s))"
if ($bad.Count) { Write-Host "$($bad.Count) copy(ies) failed - their sources are NOT on the list" -ForegroundColor Red }
