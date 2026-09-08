<#
.SYNOPSIS
  Clear a unit's NEEDS-VALIDATION escalation so `_dispositions-loop.ps1` picks it up again - BOTH
  artefacts, in both places, after showing you what you are clearing.

.WHY THIS EXISTS
  An escalation writes TWO files in TWO different directories:

    D:/video/_pending/<unit>.NEEDS-VALIDATION.txt     the reason, for a human
    D:/video/_stage/<unit>/.HOLD                      the marker the loop skips on

  and the instruction inside the first says only "delete this file AND the unit's .HOLD (if this
  loop wrote it)" - without saying where the .HOLD lives. 2026-09-08: I deleted the
  NEEDS-VALIDATION file for two West Wing discs, checked `_pending` for a .HOLD, found none, and
  reported both units cleared. The .HOLD is in the STAGING folder. Both units stayed held, the
  encode queue drained to empty, and the loop sat idle through four passes with two valid manifests
  waiting in _pending - while I had already said the line would resume.

  A remedy that is two deletions in two directories, described in prose, in a file you read once
  under pressure, is a manual step. This is that step.

.WHAT IT DOES NOT DO
  It does not decide whether the escalation was ADDRESSED - only a human or an agent that read the
  detail can know that, which is why the reason is printed and -Unit is mandatory. There is no
  -All: clearing every held unit without reading why each was held is precisely the mistake the
  hold exists to prevent (and the operator's standing rule, 2026-09-08: "`-All` should never be
  used. You should be required to explicitly state what is being recovered").

  It does not touch `_dispositions-state.json`. The loop skips on the FILE (see its line ~995), not
  on the `escalated` flag, and that state file is owned and rewritten by the running loop - editing
  it underneath would be clobbered at best. The flag is stale bookkeeping once the files are gone
  and is reset when the unit next completes a step.

  pwsh -File clear-escalation.ps1 -List
  pwsh -File clear-escalation.ps1 -Unit 'The West Wing Season 1 Disk 4'
  pwsh -File clear-escalation.ps1 -Unit 'The West Wing Season 1 Disk 4' -WhatIf
#>
param(
  [string]$Unit = '',
  [string]$Pending = 'D:/video/_pending',
  [string]$Stage   = 'D:/video/_stage',
  [switch]$List,
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'
function Say([string]$m) { Write-Output $m }

# EVERY unit currently held, from either artefact - a unit with only one of the two is exactly the
# half-cleared state this script exists to end, so both sources are scanned and merged.
function Get-Escalations {
  $found = @{}
  foreach ($f in @(Get-ChildItem -LiteralPath $Pending -File -Filter '*.NEEDS-VALIDATION.txt' -ErrorAction SilentlyContinue)) {
    $u = $f.Name -replace '\.NEEDS-VALIDATION\.txt$', ''
    if (-not $found.ContainsKey($u)) { $found[$u] = @{ Unit = $u; Nv = ''; Hold = '' } }
    $found[$u].Nv = $f.FullName
  }
  foreach ($d in @(Get-ChildItem -LiteralPath $Stage -Directory -ErrorAction SilentlyContinue)) {
    $h = Join-Path $d.FullName '.HOLD'
    if (-not (Test-Path -LiteralPath $h -PathType Leaf)) { continue }
    $u = $d.Name
    if (-not $found.ContainsKey($u)) { $found[$u] = @{ Unit = $u; Nv = ''; Hold = '' } }
    $found[$u].Hold = $h
  }
  return @($found.Values | Sort-Object { $_.Unit })
}

$all = @(Get-Escalations)

if ($List -or -not $Unit) {
  if (-not $all.Count) { Say 'no escalations - nothing is held'; exit 0 }
  Say ("{0} unit(s) held:" -f $all.Count)
  foreach ($e in $all) {
    $why = ''
    if ($e.Nv) { $why = (Get-Content -LiteralPath $e.Nv -TotalCount 1 -ErrorAction SilentlyContinue) }
    elseif ($e.Hold) { $why = (Get-Content -LiteralPath $e.Hold -TotalCount 1 -ErrorAction SilentlyContinue) }
    Say ("  {0}" -f $e.Unit)
    Say ("     {0}" -f "$why".Trim())
    # A unit missing one of the two is worth calling out: it will keep being skipped for the one
    # that remains, which is the failure mode that produced this script.
    if (-not $e.Nv)   { Say '     (no NEEDS-VALIDATION.txt - only the staging .HOLD remains; still held)' }
    if (-not $e.Hold) { Say '     (no staging .HOLD - only the NEEDS-VALIDATION.txt remains; still held)' }
  }
  if (-not $Unit) { Say ''; Say 'clear one with:  pwsh -File clear-escalation.ps1 -Unit ''<unit>''' }
  exit 0
}

$e = @($all | Where-Object { $_.Unit -eq $Unit })[0]
if ($null -eq $e) { Say "no escalation for '$Unit' - nothing held (run with -List to see what is)"; exit 0 }

# SHOW THE REASON BEFORE REMOVING IT. The whole detail, not a summary: this is the last moment
# anyone sees why the unit was held, and the file is about to go.
if ($e.Nv) {
  Say "--- $Unit : why it was held ---"
  Get-Content -LiteralPath $e.Nv -ErrorAction SilentlyContinue | ForEach-Object { Say ("  " + $_) }
  Say ''
}

$removed = @()
foreach ($p in @($e.Nv, $e.Hold)) {
  if (-not $p) { continue }
  if ($WhatIf) { Say "WhatIf: would remove $p"; continue }
  # Both paths are constructed from -Pending / -Stage above, never from the file's own content.
  Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
  if (Test-Path -LiteralPath $p) { Say "!! could not remove $p" } else { $removed += $p }
}
if ($WhatIf) { exit 0 }

# VERIFY, do not assume. The reason this script exists is a report of "cleared" that was not true.
$still = @(Get-Escalations | Where-Object { $_.Unit -eq $Unit })
if ($still.Count) {
  Say "!! '$Unit' is STILL HELD - remaining: $(@($still[0].Nv, $still[0].Hold | Where-Object { $_ }) -join ', ')"
  exit 1
}
foreach ($r in $removed) { Say "removed: $r" }
Say "'$Unit' is no longer held - _dispositions-loop.ps1 will pick it up on its next pass (within ~2 min)."
exit 0
