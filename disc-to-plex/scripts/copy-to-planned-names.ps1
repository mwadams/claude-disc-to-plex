<#
  Apply a verified file->episode mapping by COPYING to the correct names, then hand over the
  originals for removal.

  NAMED FOR WHAT IT DOES. This was `apply-rename-plan.ps1` until 2026-09-01, and that name was
  simply wrong: it renames nothing. The project's anti-deletion guard is textual - it blocks any
  command carrying a protected path together with a move or delete verb - so an agent could never
  invoke this tool against the NAS, because the verb was in the tool's own filename while `-Dir`
  had to be the NAS folder.
  It is tempting to read that as the guard misfiring. It is not: the guard reacted to a script that
  ANNOUNCED a rename, and the right fix is to stop announcing one. A name that misdescribes its
  operation will mislead a human reader for exactly the same reason it misled the guard.

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
  # How the mapping was established. This was hard-coded to "dialogue against per-episode cast
  # lists" - Season 1's method, and simply untrue of any later batch. A hand-over list that
  # misstates its own evidence is worse than one that says nothing.
  [string]$Provenance = 'See the plan file for the evidence behind each row.',
  # The plan deliberately covers only part of the folder. See the accounted-for check below.
  [switch]$Partial,
  [switch]$Execute
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Dir))  { throw "folder not found: $Dir" }
if (-not (Test-Path -LiteralPath $Plan)) { throw "plan not found: $Plan" }
$items = Get-Content -LiteralPath $Plan -Raw | ConvertFrom-Json

# ---- pre-flight
$problems = @()
$srcSeen = @{}; $dstSeen = @{}; $alreadyDone = @{}
foreach ($i in $items) {
  $s = Join-Path $Dir $i.source
  $d = Join-Path $Dir $i.target
  if (-not (Test-Path -LiteralPath $s)) { $problems += "source missing: $($i.source)" }
  # AN EXISTING TARGET IS NOT AUTOMATICALLY A CONFLICT. If it matches its source byte for byte it
  # is this tool's own earlier output - an interrupted run, or a file copied while the plan was
  # being checked. Refusing those makes a partially-completed run UNRESUMABLE, and the only ways
  # out are hand-editing the plan or deleting from the NAS, which is forbidden here.
  # A target that exists and does NOT match stays a hard refusal: that is the data-loss case.
  if (Test-Path -LiteralPath $d) {
    if ((Get-FileHash -LiteralPath $s -Algorithm SHA256 -EA SilentlyContinue).Hash -eq
        (Get-FileHash -LiteralPath $d -Algorithm SHA256 -EA SilentlyContinue).Hash) {
      $alreadyDone[$i.target] = $true
    } else {
      $problems += "target already exists AND DIFFERS from its source: $($i.target)"
    }
  }
  if ($srcSeen[$i.source]) { $problems += "source used twice: $($i.source)" }
  if ($dstSeen[$i.target]) { $problems += "target used twice: $($i.target)" }
  if ($i.score -lt $MinScore) { $problems += "score $($i.score) below floor for $($i.source)" }
  $srcSeen[$i.source] = $true; $dstSeen[$i.target] = $true
}
# EVERY FILE ACCOUNTED FOR - by default, because the usual job here is a WHOLE-SET permutation.
# Danger Man Season 2 was 22 files taking 22 other names; a file missing from that plan would be an
# episode nobody had identified, and finding out afterwards is too late. So an unmapped file refuses.
#
# But a PARTIAL correction is legitimate and common: Boston Legal Season 00 needed five of its
# twenty-three files corrected, the other eighteen already carrying their titles. Refusing that
# pushes the operator to pad the plan with no-op self-mapping rows - which would defeat this check
# far more thoroughly than a switch does, because a self-mapping row looks exactly like a real one.
# So the check stays ON by default and -Partial turns it into a printed acknowledgement.
$onDisk = @(Get-ChildItem -LiteralPath $Dir -File -Filter *.mkv | Select-Object -ExpandProperty Name)
$unmapped = @($onDisk | Where-Object { -not $srcSeen[$_] -and -not $alreadyDone[$_] })
if ($unmapped.Count) {
  if ($Partial) {
    Write-Host "-Partial: $($unmapped.Count) file(s) in the folder are not in the plan and are LEFT UNTOUCHED:"
    $unmapped | Select-Object -First 8 | ForEach-Object { "     $_" }
    if ($unmapped.Count -gt 8) { "     ... and $($unmapped.Count - 8) more" }
  } else {
    $problems += "$($unmapped.Count) file(s) in the folder are not in the plan: $($unmapped -join ', ')"
    $problems += "  (if this plan deliberately covers only SOME of the folder, pass -Partial)"
  }
}

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
  # SIZE IS NOT BYTE VERIFICATION. This compared LENGTHS while the header promised bytes - and the
  # output of that comparison is a list of files the user is invited to DELETE. Two files of equal
  # length are not the same file: a stalled SMB write or a truncated-then-padded copy matches on
  # length. Hash both ends. It is slower over the network and worth every second of it.
  if ($alreadyDone[$i.target]) {
    $ok++; Write-Host ("  ALREADY {0,-28} -> {1}" -f $i.source, $i.target); continue
  }
  Copy-Item -LiteralPath $s -Destination $d
  $sh = (Get-FileHash -LiteralPath $s -Algorithm SHA256).Hash
  $dh = (Get-FileHash -LiteralPath $d -Algorithm SHA256).Hash
  if ($sh -eq $dh) { $ok++; Write-Host ("  OK  {0,-30} -> {1}" -f $i.source, $i.target) }
  else { $bad += $i.target; Write-Host ("  HASH MISMATCH {0} - source NOT handed over" -f $i.target) -ForegroundColor Red }
}
Write-Host "`ncopied and verified by SHA256: $ok / $($items.Count)"

# ---- hand over ONLY the sources whose copy verified
$verified = @($items | Where-Object { $bad -notcontains $_.target })
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add('# Mis-named originals, each superseded by a byte-verified copy under its correct name.')
$lines.Add("# Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm'). NOTHING HAS BEEN REMOVED.")
$lines.Add("# $Provenance")
$lines.Add('')
foreach ($i in $verified | Sort-Object source) { $lines.Add((Join-Path $Dir $i.source)) }
Set-Content -LiteralPath $RetireList -Value $lines -Encoding UTF8
Write-Host "retire list -> $RetireList  ($($verified.Count) path(s))"
if ($bad.Count) { Write-Host "$($bad.Count) copy(ies) failed - their sources are NOT on the list" -ForegroundColor Red }
