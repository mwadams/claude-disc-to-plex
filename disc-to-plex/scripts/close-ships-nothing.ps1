<#
.SYNOPSIS
  Close out a disc that LEGITIMATELY SHIPS NOTHING, as a positive, evidenced assertion.

.WHY THIS EXISTS
  Re-rip batches produce discs whose correct answer is "nothing to recover": every title is
  accounted for, and none of it is worth shipping (already published from the same edition, no
  subtitles to OCR, no second audio, no hidden cells, no quality gain). The Champions Disk 3
  (2026-09-03) was the first: fully dispositioned, assert-accounted -RequireEvidence exit 0, and
  nothing to manifest - so _stallwatch.ps1 reported "needs MANIFEST" forever, a permanent false
  positive on the one board whose whole value is that it can be acted on without checking.

  The gap could not be papered over with "no manifest exists, so nothing ships": absence is how a
  disc whose manifest was simply never written gets quietly dropped, and this project has lost a
  disc exactly that way (_fetch-done.txt's header records the shape). So the outcome is a WRITTEN
  RECORD that can only be produced when the evidence supports it.

.WHAT IT REFUSES - each is a real way a disc could be wrongly closed
  1. No dispositions file            -> nobody has looked; closure would be a default.
  2. The dispositions never reach the verdict. The file must itself contain the line
     "NOTHING IS WORTH SHIPPING" (case-insensitive; "NOTHING WORTH SHIPPING" also accepted):
     the verdict belongs to the analysis that examined the disc, written where the per-title
     evidence lives - not to whoever happens to invoke this script. A -Because argument alone
     is an operator's say-so; the dispositions carrying the verdict is the analyst's finding.
  3. A .authoring / .dispositioning marker is live in _pending -> an agent is mid-work on this
     disc; closing it now races that work.
  4. ANY manifest (in _manifests, _pending, _queue, running/, done/, failed/) references the
     disc's staged path or a rip slug of it -> the disc ships, shipped, or is about to ship
     something. "Ships nothing" would be a contradiction. A disc that shipped output closes
     through the normal route (publish -> user confirms in Plex -> reclaim), never through this.
  5. assert-accounted.ps1 -RequireEvidence does not exit 0 -> the accounting itself is not done,
     so "nothing worth shipping" cannot be known yet. This also inherits every check that gate
     performs (catalogue floor, sourceVerified, evidence citations, mapping proofs).

.THE RECORD
  <CatalogueDir>/<disc>.ships-nothing.json - carries WHY nothing ships (-Because, required), the
  verdict line quoted from the dispositions, a per-title kind/note table, and the SHA256 of the
  dispositions file it was judged from. _stallwatch.ps1 re-hashes the dispositions on every pass:
  a record whose dispositions have since changed reads as STALE and stalls loudly, so the closure
  can never outlive its evidence. The record lives in _catalogue, not in the staging folder,
  because it must SURVIVE the staging release - it is the durable answer to "what happened to
  this disc?".

.WHAT THIS DOES NOT DO
  It deletes nothing and confirms nothing. Releasing the staging still goes through the existing
  reclaim track: a person authors a _reclaim-queue artefact naming the unit AFTER the user
  confirms - and for a ships-nothing disc what the user confirms is THE VERDICT ITSELF ("I accept
  nothing from this disc will be added to the library"), since there is no Plex item to look at.
  Deletion stays gated on the user, never derived from this record.

.EXAMPLE
  pwsh -NoProfile -File close-ships-nothing.ps1 -Disc 'The Champions Disk 3' `
    -Because 'zero subpicture packets on every title set (no subtitles), single AC3 stream per title (no commentary), single-PGC cell layout identical to the published S01E09-E12 (no tail cells), same retail edition (no quality gain)'

.EXIT CODES
  0 = closed (or already closed against identical dispositions)   2 = refused
#>
param(
  [Parameter(Mandatory)][string]$Disc,
  [Parameter(Mandatory)][string]$Because,
  [string]$CatalogueDir = 'D:/video/_catalogue',
  [string]$Stage        = 'D:/video/_stage',
  [string]$Manifests    = 'D:/video/_manifests',
  [string]$Pending      = 'D:/video/_pending',
  [string]$Queue        = 'D:/video/_queue',
  # Rewrite an existing record after the dispositions legitimately changed. Never the default:
  # a record silently rewritten is a record nobody can trust.
  [switch]$Force
)
$ErrorActionPreference = 'Stop'

# Accept a bare name or a path, same as assert-accounted.ps1.
$discName = Split-Path $Disc -Leaf
$dispPath = Join-Path $CatalogueDir "$discName.dispositions.txt"
$recPath  = Join-Path $CatalogueDir "$discName.ships-nothing.json"

# ---- 1. the dispositions must EXIST - closure is never a default -----------------------------
if (-not (Test-Path -LiteralPath $dispPath)) {
  Write-Output "REFUSE  $discName - no dispositions file at $dispPath"
  Write-Output 'A ships-nothing closure is a POSITIVE assertion; with no dispositions, nobody has looked.'
  exit 2
}

# ---- 2. the WHY must be substantive ----------------------------------------------------------
if ("$Because".Trim().Length -lt 30) {
  Write-Output 'REFUSE  -Because must actually say why nothing ships (>= 30 chars).'
  Write-Output 'Name the categories checked: subtitles, second audio, structure/tail cells, quality, extras.'
  exit 2
}

# ---- 3. the dispositions must themselves carry the verdict -----------------------------------
$dispRaw = Get-Content -LiteralPath $dispPath -Raw
$verdictRx = '(?im)^.*NOTHING\s+(IS\s+)?WORTH\s+SHIPPING.*$'
$verdictLines = @([regex]::Matches($dispRaw, $verdictRx) | ForEach-Object { $_.Value.Trim() })
if ($verdictLines.Count -eq 0) {
  Write-Output "REFUSE  $discName - the dispositions never state the verdict."
  Write-Output 'The analysis that examined the disc must write "NOTHING IS WORTH SHIPPING" (with its'
  Write-Output 'reasoning) into the dispositions file. This script records that finding; it does not'
  Write-Output 'substitute for it.'
  exit 2
}

# ---- 4. nobody is mid-work on this disc ------------------------------------------------------
foreach ($marker in @('.authoring', '.dispositioning')) {
  $m = Join-Path $Pending ($discName + $marker)
  if (Test-Path -LiteralPath $m) {
    Write-Output "REFUSE  $discName - $($discName + $marker) is live in _pending: an agent is working this disc right now."
    exit 2
  }
}

# ---- 5. NO manifest may reference the disc, anywhere in the manifest lifecycle ---------------
#
# Same path-anchored regex family as _stallwatch.ps1 and _release-completed.ps1: match the staged
# path, never the bare name (a disc called 'M' must not match every manifest containing an 'm'),
# and include the rip-slug forms _rip-loop.ps1 produces.
$manifestDirs = @("$Manifests/*.json", "$Pending/*.json", "$Queue/*.json", "$Queue/running/*.json",
                  "$Queue/done/*.json", "$Queue/failed/*.json")
$slug = ($discName -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
$rxes = @('_stage[\\/]' + [regex]::Escape($discName) + '(?=["\\/])')
foreach ($sfx in @('-rip', '-x', '-main', '-mkv')) {
  $rxes += ('_stage[\\/]' + [regex]::Escape($slug + $sfx) + '(?=["\\/])')
}
$referencing = @(Get-ChildItem $manifestDirs -ErrorAction SilentlyContinue | Where-Object {
  $raw = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
  foreach ($rx in $rxes) { if ($raw -match $rx) { return $true } }
  $false
})
if ($referencing.Count -gt 0) {
  Write-Output ("REFUSE  {0} - {1} manifest(s) reference this disc: {2}" -f `
                $discName, $referencing.Count, (($referencing | ForEach-Object { $_.FullName }) -join ', '))
  Write-Output 'A disc that ships, shipped, or is about to ship output is NOT a ships-nothing disc.'
  Write-Output 'It closes through the normal route: publish, user confirms in Plex, reclaim.'
  exit 2
}

# ---- 6. the accounting gate must pass, with evidence required --------------------------------
#
# Invoke directly and read $LASTEXITCODE in the next statement - NEVER through a pipe, which
# reports the downstream command's status (that exact mistake hid a dead guard on 2026-08-23).
$assert = Join-Path $PSScriptRoot 'assert-accounted.ps1'
if (-not (Test-Path -LiteralPath $assert)) {
  Write-Output 'REFUSE  assert-accounted.ps1 is missing beside this script - cannot verify the accounting.'
  exit 2
}
$assertOut = @(& pwsh -NoProfile -File $assert -Disc $Disc -RequireEvidence 2>&1 | ForEach-Object { "$_" })
$assertExit = $LASTEXITCODE
if ($assertExit -ne 0) {
  Write-Output "REFUSE  $discName - assert-accounted.ps1 -RequireEvidence exited $assertExit; the disc is not accounted for."
  $assertOut | Select-Object -Last 12 | ForEach-Object { Write-Output "        | $_" }
  exit 2
}

# ---- existing record: idempotent when nothing changed, refuse-by-default when it has ---------
$dispSha = (Get-FileHash -LiteralPath $dispPath -Algorithm SHA256).Hash
if ((Test-Path -LiteralPath $recPath) -and -not $Force) {
  $old = $null
  try { $old = Get-Content -LiteralPath $recPath -Raw | ConvertFrom-Json } catch { }
  if ($old -and $old.dispositionsSha256 -eq $dispSha) {
    Write-Output "already closed: $discName ships nothing (record of $($old.closedAt) matches the current dispositions)"
    exit 0
  }
  Write-Output "REFUSE  $discName - a ships-nothing record exists but the dispositions have CHANGED since it was written."
  Write-Output 'Re-read the dispositions, and re-close with -Force only if the verdict still holds.'
  exit 2
}

# ---- parse the per-title decisions into the record -------------------------------------------
$titles = @()
$kindCounts = @{}
foreach ($line in ($dispRaw -split "`n")) {
  $l = $line.Trim()
  if (-not $l -or $l.StartsWith('#')) { continue }
  $p = $l -split '\|', 4
  if ($p.Count -lt 2 -or $p[0] -notmatch '^t(\d+)$') { continue }
  $id   = [int]$Matches[1]
  $kind = $p[1].Trim().ToLower()
  $note = if ($p.Count -ge 3) { $p[2].Trim() } else { '' }
  if ($note.Length -gt 220) { $note = $note.Substring(0, 220) + '...' }
  $titles += [ordered]@{ id = $id; kind = $kind; note = $note }
  $kindCounts[$kind] = 1 + $(if ($kindCounts.ContainsKey($kind)) { $kindCounts[$kind] } else { 0 })
}

$record = [ordered]@{
  disc                = $discName
  verdict             = 'SHIPS NOTHING'
  closedAt            = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
  because             = "$Because".Trim()
  verdictLines        = $verdictLines
  dispositionsFile    = "$dispPath"
  dispositionsSha256  = $dispSha
  kindCounts          = $kindCounts
  titles              = $titles
  manifestDirsSearched = $manifestDirs
  manifestsReferencing = 0
  assertAccounted     = [ordered]@{
    invocation = 'assert-accounted.ps1 -RequireEvidence'
    exitCode   = 0
    tail       = @($assertOut | Select-Object -Last 4)
  }
  closedBy            = 'close-ships-nothing.ps1'
}
Set-Content -LiteralPath $recPath -Value ($record | ConvertTo-Json -Depth 6) -Encoding UTF8

Write-Output "CLOSED - $discName SHIPS NOTHING."
Write-Output ("  record : {0}" -f $recPath)
Write-Output ("  titles : {0}" -f (($kindCounts.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Value) $($_.Name)" }) -join ', '))
Write-Output ("  why    : {0}" -f $record.because)
Write-Output ''
Write-Output 'The staging is NOT released by this. To release it: tell the user WHY nothing ships and'
Write-Output 'ask them to confirm the verdict; after they confirm, author a _reclaim-queue artefact'
Write-Output 'naming this unit (works: []), with a note citing this record. The reclaim loop and the'
Write-Output 'existing release gates do the rest.'
exit 0
