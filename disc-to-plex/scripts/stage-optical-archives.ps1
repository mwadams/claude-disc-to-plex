<#
.SYNOPSIS
  Hand a VERIFIED optical-lane archive over to the D: staging pipeline, and record it in
  _fetch-done.txt so the catalogue loop will sweep it.

.WHY THIS EXISTS
  The optical track backs discs up to a local archive (C:) and stops there. Everything downstream -
  catalogue, dispositions, manifest, encode - watches D:\video\_stage and gates on _fetch-done.txt.
  Nothing joined the two, so every disc was carried across BY HAND: on 2026-09-05 that was eight
  Jeeves and Wooster discs plus Staggered, one Move-Item at a time, and C: ran down to 0.25 GB free
  before anyone noticed. The user, twice: "this needs to be built into the scripts so it ceases to
  be a manual step."

.WHY WRITING _fetch-done.txt HERE IS LEGITIMATE
  That file means "this copy was verified complete against its source". Fetch writes it after a
  count-and-bytes match against E:. These discs never came from E: - so the assertion has to come
  from somewhere, and the optical lane's own _disc-backup.json is a STRONGER proof than fetch's:
  byte total equal to the volume size, every IFO/BUP pair compared and identical, zero read errors,
  and a decode probe of every title. This script re-checks that sidecar AFTER the move (the bytes
  must still match where they now live) and only then writes the line. A disc that fails any part
  is moved but NOT recorded, so the catalogue loop leaves it alone and it is visible as staged-but-
  ungated rather than silently half-done.

.SAFETY
  * .partial-* folders are NEVER touched. A rip in progress owns its folder.
  * An existing destination is never overwritten - that disc is reported and skipped.
  * Refuses to move when D: would drop below -MinFreeGB, because filling the encode disk to rescue
    the archive disk just moves the outage.
  * Local D:-to-D: is out of scope; this only moves ACROSS volumes, which is a copy+delete, so the
    source is removed only after the destination verifies.

  pwsh -File stage-optical-archives.ps1                      # move everything eligible
  pwsh -File stage-optical-archives.ps1 -WhatIf              # say what it would do
  pwsh -File stage-optical-archives.ps1 -Only 'Clayhanger*'  # one show
#>
param(
  [string]$ArchiveRoot = 'C:/Users/matth/Videos/DVD',
  [string]$Stage       = 'D:/video/_stage',
  [string]$FetchDone   = 'D:/video/_fetch-done.txt',
  [string]$Only        = '*',
  # THE SAME FLOOR FETCH USES, DELIBERATELY. Both this and _fetch-loop.ps1 do the same thing to the
  # same volume - add a staged disc that will sit there until a reclaim releases it - so they must
  # obey the same limit. A lower floor here would let the optical lane starve the encode lanes by a
  # route fetch is explicitly forbidden to take, and the encode preflight would then start refusing
  # manifests ("do NOT encode into the last few GB") while the archive drained happily.
  # (Set to 40 when first written on 2026-09-06; the user caught the inconsistency immediately.)
  #
  # If C: fills while D: is under this floor, that is NOT something to solve by lowering it: it
  # means discs are being fed faster than the line drains, and the answer is to confirm published
  # works in Plex so reclaims can run. The optical lane has its own 15 GB floor on C: as a backstop
  # and will refuse the next disc rather than fill the archive volume.
  [int]$MinFreeGB      = 120,
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
function Say([string]$m) { Write-Output $m }

if (-not (Test-Path -LiteralPath $ArchiveRoot)) { Say "no archive root at $ArchiveRoot"; exit 0 }

$done = @()
if (Test-Path -LiteralPath $FetchDone) {
  $done = @(Get-Content -LiteralPath $FetchDone | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

$moved = 0; $skipped = 0; $failed = 0
foreach ($d in @(Get-ChildItem -LiteralPath $ArchiveRoot -Directory -Force -ErrorAction SilentlyContinue | Sort-Object Name)) {
  if ($d.Name -like '*.partial-*') { continue }               # a rip in progress owns this
  if ($d.Name -eq '_failed') { continue }
  if ($d.Name -notlike $Only) { continue }

  $sidecar = Join-Path $d.FullName '_disc-backup.json'
  if (-not (Test-Path -LiteralPath $sidecar)) { Say ("  SKIP {0} - no _disc-backup.json, so nothing vouches for it" -f $d.Name); $skipped++; continue }
  try { $j = Get-Content -LiteralPath $sidecar -Raw | ConvertFrom-Json } catch { Say ("  SKIP {0} - unreadable sidecar" -f $d.Name); $skipped++; continue }
  if (-not $j.verified) { Say ("  SKIP {0} - sidecar says verified=false" -f $d.Name); $skipped++; continue }

  # ---- NAME COLLISION ACROSS THE HANDOFF -------------------------------------------------------
  # backup-dvd-folder.ps1 dedups a label ONLY against folders still sitting in the archive root, by
  # fingerprint. The moment a disc is staged it stops being an occupant, so the SAME label is free
  # again - and box sets stamp every disc with the same label ("DVDVolume" on all seven Clayhanger
  # discs). Two failure modes follow, and the second is silent:
  #   1. the first disc is still in _stage      -> this one skips for ever and the archive fills;
  #   2. the first disc has been RECLAIMED      -> _stage/<name> is gone, so this one moves in, and
  #      <name> is ALREADY in _fetch-done.txt from the first disc, so the gate passes it as
  #      "already verified" and it is catalogued under the FIRST disc's identity.
  # The sidecar's fingerprint is the identity, so use it. A ledger records what was staged under
  # which name, because once staging is reclaimed the evidence is otherwise gone from this machine.
  $fp = "$($j.fingerprint)"
  $ledger = Join-Path (Split-Path $FetchDone) '_optical-staged.tsv'
  if (-not (Test-Path -LiteralPath $ledger)) { "Name`tFingerprint`tWhen`tBytes" | Set-Content -LiteralPath $ledger }
  $seen = @{}
  foreach ($row in @(Import-Csv -LiteralPath $ledger -Delimiter "`t" -ErrorAction SilentlyContinue)) { $seen["$($row.Name)"] = "$($row.Fingerprint)" }

  $target = $d.Name
  $why = ''
  for ($n = 2; $n -le 40; $n++) {
    $dest = Join-Path $Stage $target
    $clash = $false
    if (Test-Path -LiteralPath $dest) {
      # A staged unit carries its own sidecar - compare fingerprints, never names.
      $other = Join-Path $dest '_disc-backup.json'
      $ofp = ''
      if (Test-Path -LiteralPath $other) { try { $ofp = "$((Get-Content -LiteralPath $other -Raw | ConvertFrom-Json).fingerprint)" } catch { } }
      if ($ofp -and $ofp -eq $fp) { $why = 'SAME'; break }      # genuinely the same disc, already staged
      $clash = $true
    }
    elseif ($seen.ContainsKey($target)) {
      # Not staged now, but this name HAS been used. Same disc = nothing to do; different disc =
      # the dangerous case, because _fetch-done.txt already vouches for that name.
      if ($seen[$target] -eq $fp) { $why = 'SAME'; break }
      $clash = $true
    }
    if (-not $clash) { break }
    $target = ('{0} ({1})' -f $d.Name, $n)
    $why = 'RENAMED'
  }
  if ($why -eq 'SAME') { Say ("  SKIP {0} - this exact disc (fingerprint {1}) is already staged or recorded" -f $d.Name, $fp.Substring(0, [Math]::Min(12, $fp.Length))); $skipped++; continue }
  if ($why -eq 'RENAMED') {
    Say ("  *** NAME COLLISION: '{0}' has already been used by a DIFFERENT disc (fingerprints differ). Staging this one as '{1}' instead." -f $d.Name, $target)
    Say ("      Box sets stamp every disc with the same volume label, so this is expected - but '{0}' is not a useful unit name." -f $target)
    Say ("      Rename the ARCHIVE folder to something meaningful (e.g. 'Clayhanger D3') BEFORE it is staged, and this will not arise.")
  }
  $dest = Join-Path $Stage $target

  $need = [long]$j.bytes
  $free = [IO.DriveInfo]::new([IO.Path]::GetPathRoot((Resolve-Path $Stage).Path)).AvailableFreeSpace
  if (($free - $need) -lt ([long]$MinFreeGB * 1GB)) {
    Say ("  HOLD {0} - {1:N2} GB needed, {2:N1} GB free on the stage volume, floor {3} GB" -f $d.Name, ($need/1GB), ($free/1GB), $MinFreeGB)
    $skipped++; continue
  }

  if ($WhatIf) { Say ("  WhatIf: would stage {0} ({1:N2} GB) -> {2}" -f $d.Name, ($need/1GB), $dest); continue }

  Say ("  staging {0} ({1:N2} GB)..." -f $d.Name, ($need/1GB))
  # robocopy /MOVE across volumes: restartable, and it removes the source only after the copy.
  # Exit codes 0-7 are success (1 = files copied); 8+ is a real failure.
  $rc = (Start-Process robocopy -ArgumentList @("`"$($d.FullName)`"", "`"$dest`"", '/E', '/MOVE', '/R:2', '/W:5', '/NFL', '/NDL', '/NP', '/NJH', '/NJS') -Wait -PassThru -WindowStyle Hidden).ExitCode
  if ($rc -ge 8) { Say ("  !! FAILED {0} - robocopy exit {1}; left where it was" -f $d.Name, $rc); $failed++; continue }

  # RE-VERIFY WHERE IT NOW LIVES. The sidecar's byte total must still hold after the move; anything
  # else means a short copy, and recording it in _fetch-done.txt would assert a completeness that
  # was never re-established.
  $vts = Join-Path $dest 'VIDEO_TS'
  $now = 0L
  if (Test-Path -LiteralPath $vts) { $now = [long](@(Get-ChildItem -LiteralPath $vts -File -ErrorAction SilentlyContinue) | Measure-Object Length -Sum).Sum }
  if ($now -ne $need) {
    Say ("  !! {0} STAGED BUT NOT GATED - VIDEO_TS is {1:N0} B, the sidecar says {2:N0} B. Not written to _fetch-done.txt." -f $d.Name, $now, $need)
    $failed++; continue
  }
  $ifoDiff = @($j.ifoBup.different).Count
  if ($ifoDiff -ne 0 -or [int]$j.readErrors -ne 0) {
    Say ("  !! {0} STAGED BUT NOT GATED - sidecar reports {1} IFO/BUP difference(s), {2} read error(s)." -f $d.Name, $ifoDiff, $j.readErrors)
    $failed++; continue
  }

  if ($done -notcontains $target) {
    Add-Content -LiteralPath $FetchDone -Value $target
    $done += $target
  }
  # The ledger is what makes the collision check survive a reclaim: once staging is released the
  # fingerprint is gone from this machine, and _fetch-done.txt records only a NAME.
  "{0}`t{1}`t{2}`t{3}" -f $target, $fp, (Get-Date -Format 'o'), $need | Add-Content -LiteralPath $ledger
  Say ("  OK {0}{1} - staged and recorded (bytes match the sidecar, IFO/BUP identical, 0 read errors)" -f $target, $(if ($target -ne $d.Name) { " (from archive folder '$($d.Name)')" } else { '' }))
  $moved++
}

Say ("stage-optical-archives: {0} staged, {1} skipped, {2} failed" -f $moved, $skipped, $failed)
if ($failed) { exit 1 }
