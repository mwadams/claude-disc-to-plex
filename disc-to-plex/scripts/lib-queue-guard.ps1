<#
  Shared duplicate-insertion guard for any path-keyed pipeline queue CSV.

  WHY THIS EXISTS (2026-09-03): _transcribe-queue.csv held two independent enqueue routes -
  subtitle-coverage.ps1 (per-row Export-Csv -Append, checking a hashtable it built from the
  file ONCE at startup) and queue-transcribable.ps1 (a bulk rebuild that accumulates an in-memory
  $rows list across TWO loops - register outputs, then an optional -AuditSet - and only checked
  membership against the list as it stood BEFORE the second loop started, never updating that
  check as the second loop added its own rows). Danger Man S00E03 and S00E12 each ended up
  enqueued twice: once by each route, independently, because neither route's identity table knew
  about the other's insertions, and queue-transcribable.ps1's OWN table did not even stay current
  within its own single run.

  THE FIX: one shared identity table, keyed on the row's Path (trimmed, case-insensitive - NAS
  paths are not case sensitive in practice here and a script-cased vs literal-cased duplicate is
  still a duplicate), that every insertion point consults and updates through the SAME functions
  below. A route that seeds its table from the CSV once, then keeps using ad-hoc code to update it
  per insertion, is exactly the shape that drifted out of sync - centralising the update makes
  that impossible.

  THIS GUARDS PATH-IDENTITY DUPLICATES ONLY. It does NOT know that a renamed file is "the same"
  row under a different path - that is revalidate-queue.ps1's job (resolve the row to its CURRENT
  path first). Run revalidation before relying on this guard to catch a rename-shaped duplicate;
  this guard only ever sees the path strings it is given.
#>

# Normalise a path for identity comparison: trim, lowercase. NOT full canonicalisation (no
# GetFullPath/UNC-vs-mapped-drive folding) - every writer here already deals exclusively in
# \\NASTEAMV\Multimedia\... UNC paths, so string equality after trim+lower is the identity that
# actually matters and is cheap enough to run per row with no I/O.
function Get-QueueRowKey {
  param([Parameter(Mandatory)][string]$Path)
  return $Path.Trim().ToLowerInvariant()
}

# Read a queue CSV's Path column into a hashtable of key -> $true, for seeding $SeenInRun. Missing
# file returns an empty table (nothing queued yet), not an error - the normal state before a
# queue's first write.
function Get-QueueSeenTable {
  param([Parameter(Mandatory)][string]$Csv)
  $seen = @{}
  if (Test-Path -LiteralPath $Csv) {
    foreach ($r in Import-Csv -LiteralPath $Csv -ErrorAction SilentlyContinue) {
      if ("$($r.Path)") { $seen[(Get-QueueRowKey "$($r.Path)")] = $true }
    }
  }
  return $seen
}

# Append $Row to $Csv unless its Path is already present - either on disk when $SeenInRun was
# seeded, or added earlier IN THIS SAME RUN. $SeenInRun is the caller's table (from
# Get-QueueSeenTable), passed BY REFERENCE (hashtables are reference types in PowerShell) and
# updated in place on every successful add, so every subsequent call - even from a different loop
# in the same script - sees prior insertions. Returns $true if the row was added, $false if a
# duplicate was refused.
function Add-UniqueQueueRow {
  param(
    [Parameter(Mandatory)][string]$Csv,
    [Parameter(Mandatory)]$Row,
    [Parameter(Mandatory)][hashtable]$SeenInRun
  )
  $path = "$($Row.Path)"
  if (-not $path) { throw 'Add-UniqueQueueRow: row has no Path' }
  $key = Get-QueueRowKey $path
  if ($SeenInRun.ContainsKey($key)) { return $false }
  $SeenInRun[$key] = $true
  [pscustomobject]$Row | Export-Csv -LiteralPath $Csv -Append -NoTypeInformation
  return $true
}

# Same contract as Add-UniqueQueueRow, for a script (queue-transcribable.ps1) that accumulates an
# in-memory list and writes the whole file once at the end, rather than appending per row.
function Add-UniqueQueueRowToList {
  param(
    # [AllowEmptyCollection()] is LOAD-BEARING: PowerShell's Mandatory validation on a collection
    # parameter rejects an empty one by default, and the very first call in a run always passes an
    # empty List[object] (nothing queued yet) - without this attribute every first-of-run call
    # throws "Cannot bind argument to parameter 'List' because it is an empty collection."
    [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$List,
    [Parameter(Mandatory)]$Row,
    [Parameter(Mandatory)][hashtable]$SeenInRun
  )
  $path = "$($Row.Path)"
  if (-not $path) { throw 'Add-UniqueQueueRowToList: row has no Path' }
  $key = Get-QueueRowKey $path
  if ($SeenInRun.ContainsKey($key)) { return $false }
  $SeenInRun[$key] = $true
  $List.Add([pscustomobject]$Row)
  return $true
}
