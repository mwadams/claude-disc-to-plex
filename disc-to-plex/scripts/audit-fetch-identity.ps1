<#
  Report-only pass of the fetch DISC IDENTITY GATE (D:/video/lib-disc-identity.ps1) over a real list
  and a real source drive, WITHOUT fetching, writing the ledger, or writing _fetch-collisions.json.

  WHY THIS EXISTS: to answer "what would the gate do right now" before the fetch loop is bounced onto
  it, and as a standing tool afterwards - point it at any listN.txt to see the same audit the loop
  runs every pass, without waiting for a poll.

  WHAT IT CHECKS, for every name in -List:
    - names already in _fetch-done.txt/_completed.txt whose folder ALSO exists on -SrcRoot right now
      (gate 3b - the silent-skip case: a same-named different disc looks "already done")
    - names still to fetch (in $left) that already have something sitting at _stage/<name> (gate 3a -
      the resume-into-a-different-disc case)
  Every other name is reported once, in the summary counts, as confirmed/unknown/not-present - see
  -Detailed for the per-name breakdown.

  Touches nothing on the NAS. Reads E: only for the per-disc dvdid.xml (or, absent that, a fingerprint
  of the one disc folder) - never a recursive scan of the drive.

  USAGE
    pwsh -File audit-fetch-identity.ps1 -List D:/video/list18.txt -SrcRoot E:\Movies
#>
param(
  [Parameter(Mandatory)][string]$List,
  [string]$SrcRoot   = 'E:\Movies',
  [string]$VideoRoot = 'D:/video',
  [string]$DoneFile  = (Join-Path $VideoRoot '_fetch-done.txt'),
  [string]$CompletedFile = (Join-Path $VideoRoot '_completed.txt'),
  [switch]$Detailed
)

. (Join-Path $VideoRoot 'lib-disc-identity.ps1')
if (-not (Get-Command Invoke-FetchIdentityAudit -ErrorAction SilentlyContinue)) {
  throw 'lib-disc-identity.ps1 failed to load'
}
if (-not (Test-Path -LiteralPath $List)) { throw "list not found: $List" }

$all = @(Get-Content -LiteralPath $List |
         Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') } |
         ForEach-Object { $_.Trim() })
$done = @(Get-Content -LiteralPath $DoneFile -ErrorAction SilentlyContinue | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
$complete = @(Get-Content -LiteralPath $CompletedFile -ErrorAction SilentlyContinue |
              Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') } | ForEach-Object { $_.Trim() })

Write-Output ("List: {0} ({1} disc name(s)) | SrcRoot: {2} | done={3} complete={4}" -f $List, $all.Count, $SrcRoot, $done.Count, $complete.Count)

# ---- gate 3b: EVERY name ever recorded done/complete (not just lines in -List - build-batch-list.ps1
# already drops a done/complete name from a freshly-proposed list by design, so a same-named DIFFERENT
# disc on the current drive never appears as a list LINE at all; see lib-disc-identity.ps1's header) --
$everCompletedNames = @($done + $complete | Sort-Object -Unique)
$cache = @{}
$audit = Invoke-FetchIdentityAudit -Names $everCompletedNames -SrcRoot $SrcRoot -VideoRoot $VideoRoot -Cache $cache -DryRun

Write-Output ''
Write-Output ("GATE 3b (every name EVER marked done/complete, vs {0} right now - not limited to {1}'s own lines):" -f $SrcRoot, (Split-Path -Leaf $List))
Write-Output ("  {0} name(s) have ever been marked done/complete" -f $everCompletedNames.Count)
Write-Output ("  {0} of those are NOT currently present on {1} (nothing to compare - the normal case, disc is on another/no drive)" -f $audit.NotPresent, $SrcRoot)
Write-Output ("  {0} CONFIRMED (present on {1} and identity matches the recorded one)" -f $audit.Confirmed.Count, $SrcRoot)
Write-Output ("  {0} UNKNOWN (present on {1} but no comparable recorded identity - not a collision)" -f $audit.Unknown.Count, $SrcRoot)
Write-Output ("  {0} REFUSED - DISC IDENTITY COLLISION:" -f $audit.Collisions.Count)
foreach ($c in $audit.Collisions) {
  Write-Output ("      '{0}' - source identity {1} ({2}) vs recorded {3}: {4}" -f `
                $c.Name, $c.SourceIdentity.Raw, $c.SourceIdentity.Kind, $c.Recorded.Source, $c.Recorded.Detail)
}
if ($Detailed) {
  if ($audit.Confirmed.Count) { Write-Output ("  confirmed: {0}" -f ($audit.Confirmed -join ', ')) }
  if ($audit.Unknown.Count)   { Write-Output ("  unknown:   {0}" -f ($audit.Unknown -join ', ')) }
}

# ---- gate 3a: names still to fetch that already have something staged ----------------------------
$left = @($all | Where-Object { $done -notcontains $_ -and $complete -notcontains $_ })
$stageRoot = Join-Path $VideoRoot '_stage'
$resumeChecked = 0; $resumeConfirmed = 0; $resumeUnknown = 0; $resumeCollisions = @()
foreach ($name in $left) {
  $dst = Join-Path $stageRoot $name
  if (-not (Test-Path -LiteralPath $dst -PathType Container)) { continue }
  $src = Join-Path $SrcRoot $name
  if (-not (Test-Path -LiteralPath $src -PathType Container)) { continue }
  $resumeChecked++
  $r = Test-StagedResumeIdentity -Src $src -Dst $dst -Name $name -VideoRoot $VideoRoot
  switch ($r.Verdict) {
    'confirmed' { $resumeConfirmed++ }
    'unknown'   { $resumeUnknown++ }
    'collision' { $resumeCollisions += [pscustomobject]@{ Name = $name; Detail = $r } }
  }
}
Write-Output ''
Write-Output ("GATE 3a (not-yet-fetched names that already have something at {0}\<name>):" -f $stageRoot)
Write-Output ("  {0} such name(s) checked" -f $resumeChecked)
Write-Output ("  {0} CONFIRMED same disc, {1} UNKNOWN (resume would proceed as today)" -f $resumeConfirmed, $resumeUnknown)
Write-Output ("  {0} REFUSED - resuming would MERGE two different discs:" -f $resumeCollisions.Count)
foreach ($c in $resumeCollisions) {
  Write-Output ("      '{0}' - source {1} vs staged {2} ({3})" -f $c.Name, $c.Detail.SourceIdentity.Raw, $c.Detail.StagedIdentity.Raw, $c.Detail.Recorded.Source)
}

Write-Output ''
$totalRefused = @($audit.Collisions | ForEach-Object { $_.Name }) + @($resumeCollisions | ForEach-Object { $_.Name }) | Sort-Object -Unique
Write-Output ("TOTAL REFUSED (either gate): {0} - {1}" -f $totalRefused.Count, ($(if ($totalRefused.Count) { $totalRefused -join ', ' } else { '(none)' })))
