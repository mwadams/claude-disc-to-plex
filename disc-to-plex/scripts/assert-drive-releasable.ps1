<#
.SYNOPSIS
  Answer, before a source drive is unplugged: DOES ANYTHING STILL NEED IT?

.WHY THIS EXISTS
  Swapping a drive out is the one routine action in this project that can turn a recoverable
  situation into a stuck one, and nothing checked it. The user named the root cause on 2026-09-06:
  "I was allowed to swap a drive out, despite a pending verification requiring it."

  The Quatermass Experiment is what that costs. Its 62-page gallery was carved from the disc's MENU
  domain, which no manifest can express, so releasing its 7.72 GB of staging requires proving the
  source is reachable. media2 was swapped out while that proof was still outstanding, so the proof
  became impossible, and the staging sat on a volume already below its 120 GB fetch floor - blocking
  the optical lane from handing two finished discs across. It took an explicit, weaker,
  physical-disc authorisation to clear, hours later. Every part of that was avoidable by asking one
  question before the drive came out.

  The check is cheap and the failure is expensive and delayed, which is exactly the shape that
  belongs in a script rather than in someone's memory.

.WHAT COUNTS AS A DEPENDENCY  (each is evidence that already exists; none is a fresh judgement)
  1. A shipped-outside-manifest record with NO stagingReleaseAuthorised, for a disc on this drive.
     Its staging is refused until the source is re-measured, and unplugging the drive makes that
     re-measure impossible. THE QUATERMASS CASE.
  2. A _rerip-worklist.tsv row still OPEN or IN-FLIGHT for a disc on this drive - the obligation
     names work that may still need the source.
  3. A disc named in the newest list*.txt that is not yet in _fetch-done.txt: unfetched work.

  Reported but NOT blocking: staged-but-unreleased units whose source is this drive. The staging is
  already a byte-verified copy, so the drive is not needed to use it - only to rebuild it if the
  staging were lost. Worth knowing, not worth refusing over.

.THE JOIN
  Disc -> drive comes from the disc-identity register's `sourceDrive` field (the NAS _disc-identity
  store), which sweep-drive.ps1 writes for every disc it enumerates. A disc with NO identity record
  cannot be attributed to a drive at all; those are listed separately as UNATTRIBUTABLE rather than
  silently treated as "not on this drive", because absence of evidence is the thing that made the
  original mistake possible.

  pwsh -NoProfile -File assert-drive-releasable.ps1 -Label media2
  pwsh -NoProfile -File assert-drive-releasable.ps1 -Label media3 -Quiet

.EXIT CODES
  0 = nothing outstanding needs this drive   2 = something does, and is named
#>
param(
  [Parameter(Mandatory)][string]$Label,
  [string]$Store      = '\\NASTEAMV\Multimedia\_disc-identity',
  [string]$Catalogue  = 'D:/video/_catalogue',
  [string]$Register   = 'D:/video/_rerip-worklist.tsv',
  [string]$FetchDone  = 'D:/video/_fetch-done.txt',
  [string]$Stage      = 'D:/video/_stage',
  [string]$VideoRoot  = 'D:/video',
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

# ---- disc -> drive, from the identity register ---------------------------------------------------
$driveOf = @{}
$known   = 0
if (Test-Path -LiteralPath $Store -PathType Container) {
  foreach ($f in @(Get-ChildItem -LiteralPath $Store -File -Filter *.json -ErrorAction SilentlyContinue)) {
    try { $j = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    $folder = "$($j.discFolder)".Trim()
    $drive  = "$($j.sourceDrive)".Trim()
    if ($folder -and $drive) { $driveOf[$folder.ToLowerInvariant()] = $drive; $known++ }
  }
} else {
  Say "assert-drive-releasable: identity store not reachable at $Store - cannot attribute any disc to a drive."
  Say 'Refusing rather than reporting a clean bill of health from no evidence.'
  exit 2
}
Say ("identity records with a source drive: {0}" -f $known)

function Test-OnDrive([string]$disc) {
  $k = "$disc".Trim().ToLowerInvariant()
  return ($driveOf.ContainsKey($k) -and $driveOf[$k] -eq $Label)
}
function Test-Unattributed([string]$disc) {
  return -not $driveOf.ContainsKey("$disc".Trim().ToLowerInvariant())
}

$blockers = @()
$notes    = @()
$unknown  = @()

# ---- 1. shipped-outside-manifest records still awaiting a source-backed authorisation ------------
foreach ($r in @(Get-ChildItem -LiteralPath $Catalogue -File -Filter '*.shipped-outside-manifest.json' -ErrorAction SilentlyContinue)) {
  $disc = $r.Name -replace '\.shipped-outside-manifest\.json$', ''
  try { $j = Get-Content -LiteralPath $r.FullName -Raw | ConvertFrom-Json } catch { continue }
  $auth = $j.stagingReleaseAuthorised
  if ($auth -and "$($auth.authorisedBy)".Trim()) { continue }        # already settled, drive not needed
  $stagedDir = Join-Path $Stage $disc
  if (-not (Test-Path -LiteralPath $stagedDir -PathType Container)) { continue }  # nothing left to release
  if (Test-Unattributed $disc) { $unknown += "$disc (shipped-outside-manifest, staging present)"; continue }
  if (Test-OnDrive $disc) {
    $blockers += ("{0} - its staging is REFUSED until the source is re-measured, and this drive is the source. Unplug it and that proof becomes impossible: the only way out is the weaker physical-disc authorisation. Settle it first (scripts/authorise-staging-release.ps1) or leave the drive in." -f $disc)
  }
}

# ---- 2. open re-rip obligations ------------------------------------------------------------------
if (Test-Path -LiteralPath $Register -PathType Leaf) {
  $lines = @(Get-Content -LiteralPath $Register)
  $hdr = $null
  foreach ($l in $lines) {
    if (-not $l -or $l.TrimStart().StartsWith('#')) { continue }
    $f = $l -split "`t"
    if ($null -eq $hdr) { $hdr = @{}; for ($i=0; $i -lt $f.Count; $i++) { $hdr[$f[$i]] = $i }; continue }
    $disc   = "$($f[$hdr['Disc']])".Trim()
    $status = "$($f[$hdr['Status']])".Trim().ToUpperInvariant()
    if ($status -notin @('OPEN','IN-FLIGHT')) { continue }
    if (Test-Unattributed $disc) { $unknown += "$disc (re-rip row $status)"; continue }
    if (Test-OnDrive $disc) {
      $blockers += ("{0} - re-rip register row is {1}; the obligation is not discharged and its source is this drive." -f $disc, $status)
    }
  }
}

# ---- 3. batch work not yet fetched ---------------------------------------------------------------
$list = @(Get-ChildItem -LiteralPath $VideoRoot -File -Filter 'list*.txt' -ErrorAction SilentlyContinue |
          Sort-Object { [int](($_.BaseName -replace '\D','') + '0') } | Select-Object -Last 1)
if ($list.Count) {
  $done = @()
  if (Test-Path -LiteralPath $FetchDone) { $done = @(Get-Content -LiteralPath $FetchDone | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
  $pending = @()
  foreach ($l in @(Get-Content -LiteralPath $list[0].FullName)) {
    $d = "$l".Trim()
    if (-not $d -or $d.StartsWith('#')) { continue }
    if ($done -contains $d) { continue }
    if (Test-OnDrive $d) { $pending += $d }
  }
  if ($pending.Count) {
    $blockers += ("{0} disc(s) in {1} are on this drive and NOT YET FETCHED - e.g. {2}" -f `
                  $pending.Count, $list[0].Name, (($pending | Select-Object -First 4) -join '; '))
  }
}

# ---- reported, not blocking ----------------------------------------------------------------------
foreach ($d in @(Get-ChildItem -LiteralPath $Stage -Directory -ErrorAction SilentlyContinue)) {
  if (Test-OnDrive $d.Name) { $notes += $d.Name }
}

# ---- verdict -------------------------------------------------------------------------------------
Say ''
if ($unknown.Count) {
  Say ("*** {0} item(s) CANNOT BE ATTRIBUTED to any drive (no identity record). They may or may not be on '{1}':" -f $unknown.Count, $Label)
  foreach ($u in ($unknown | Select-Object -Unique)) { Say "      $u" }
  Say '    An unswept disc has no sourceDrive, so this check cannot clear it. Sweep the drive'
  Say '    (sweep-drive.ps1) or settle these by hand before relying on the answer below.'
  Say ''
}
if ($notes.Count) {
  Say ("note: {0} staged unit(s) came from '{1}'. Their staging is already a byte-verified copy, so the drive is not needed to USE them - only to rebuild them if that staging were lost. Not blocking: {2}" -f `
       $notes.Count, $Label, (($notes | Select-Object -First 5) -join '; '))
  Say ''
}
if ($blockers.Count -eq 0) {
  Say ("DRIVE '{0}' IS RELEASABLE - nothing outstanding needs it." -f $Label)
  if ($unknown.Count) { Say '(subject to the unattributable items above)' }
  exit 0
}
Say ("*** DO NOT SWAP OUT '{0}' YET - {1} thing(s) still need it:" -f $Label, $blockers.Count)
foreach ($b in $blockers) { Say "      $b" }
Say ''
Say 'Each of these is cheap to settle while the drive is attached and expensive or impossible once it'
Say 'is gone. That asymmetry is the whole reason this check exists.'
exit 2
