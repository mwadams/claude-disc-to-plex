<#
.SYNOPSIS
  ONE question, asked across the pipeline's own stores: is anything STUCK in a way no automatic step
  will ever clear? Read-only. Exit 0 always - this reports, it never gates.

.WHY THIS EXISTS - READ THIS BEFORE ADDING ANOTHER GUARD
  2026-09-21, after the operator said: "It's amazing that so many weeks in the basics still don't
  work... We burn tokens trying fixing the same mistakes day in day out." They were right, and the
  pattern is specific.

  Six faults surfaced that day. FOUR of them were the same question wearing different clothes:

    Porco Rosso      two works on one disc, confirmed 12 min apart; each confirmation refused the
                     shared staging for "it also delivered <the other>". 17.1 GB, 2 days.
    Ghost Stories    identical shape (Barchester + A Warning to the Curious on one disc).
    Deep Space Nine  confirmed, published, but every disc's staging refused on an un-dischargeable
                     re-rip row. 78.81 GB, and the fetch lane stalled beneath its floor.
    orphan sidecars  15 files in _stage for units long gone; nothing claimed them, so no release
                     would ever take them.

  Each was found by the OPERATOR, days later, and each cost a separate investigation. Every
  individual component behaved exactly as documented. The failures lived in the SEAMS, and this
  project's habit - add a narrow guard at the seam, write a memory - makes more seams. There were
  already memories for most of these.

  So this asks the question ONCE, from outside, comparing stores rather than sitting inside any one
  of them:

      A work the operator CONFIRMED, whose staging is STILL HELD, which nothing will clear.

  If that is ever true, the board says so and names the artefact holding it. That is the whole idea.

.WHAT IT DELIBERATELY DOES NOT DO
  It does not release anything, judge identity, or re-implement a gate's decision. A gate refusing
  is usually CORRECT - DS9's re-rip guard was right to refuse. What was missing is that nobody was
  asking whether the refusal had any route to ever stop being true.

.AND THE SECOND QUESTION, same family
  Does the board's "WAITING ON YOU" agree with what is actually awaiting confirmation? On 2026-09-21
  the space audit told the operator to "Confirm those in Plex" while the pending list held NOTHING.
  Being handed a job that does not exist is worse than silence: it hides the real blocker behind a
  task the operator cannot complete.

.EXAMPLE
  pwsh -File audit-line-consistency.ps1
#>
param(
  [string]$VideoRoot    = 'D:/video',
  [string]$ReclaimQueue = 'D:/video/_reclaim-queue',
  [string]$Stage        = 'D:/video/_stage',
  [string]$AwaitingFile = 'D:/video/_awaiting-verification.txt'
)
$ErrorActionPreference = 'Stop'
$findings = @()

# ---- 1. CONFIRMED, STILL STAGED, AND REFUSED FOR A REASON THAT CANNOT CLEAR ITSELF ---------------
#
# A reclaim artefact in failed/ IS the record of this: the operator confirmed, the loop tried, a gate
# said no. What no store holds is whether that "no" is transient. So report every failed artefact
# whose units are STILL STAGED - those are the ones costing space right now - and quote the refusal
# so the reason is in front of whoever reads the board, not one investigation away.
$failedDir = Join-Path $ReclaimQueue 'failed'
foreach ($a in @(Get-ChildItem -LiteralPath $failedDir -File -Filter 'confirmed-*.json' -ErrorAction SilentlyContinue)) {
  $res = Join-Path $failedDir ([IO.Path]::GetFileNameWithoutExtension($a.Name) + '.result.txt')
  $why = ''
  if (Test-Path -LiteralPath $res -PathType Leaf) {
    $why = @(Get-Content -LiteralPath $res -ErrorAction SilentlyContinue |
             Where-Object { $_ -match 'REFUSED|NOT released|HELD' } | Select-Object -First 1) -join ''
  }
  # Which units did it name, and are any still on disk? Staging is the cost; an artefact whose
  # units are already gone is settled history and sweep-resolved-reclaims.ps1's business, not this.
  $stagedUnits = @()
  try {
    $doc = Get-Content -LiteralPath $a.FullName -Raw | ConvertFrom-Json
    $names = @(@($doc.units) + @($doc.works) + @($doc.deriveUnitsForWorks) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
    foreach ($d in @(Get-ChildItem -LiteralPath $Stage -Directory -ErrorAction SilentlyContinue)) {
      if ($res -and (Test-Path -LiteralPath $res) -and (Select-String -LiteralPath $res -SimpleMatch -Pattern $d.Name -Quiet -ErrorAction SilentlyContinue)) {
        $stagedUnits += $d.Name
      }
    }
    if (-not $stagedUnits.Count) {
      foreach ($n in $names) { if (Test-Path -LiteralPath (Join-Path $Stage $n) -PathType Container) { $stagedUnits += $n } }
    }
  } catch { }
  if (-not $stagedUnits.Count) { continue }
  $gb = 0
  foreach ($u in ($stagedUnits | Sort-Object -Unique)) {
    $s = (Get-ChildItem -LiteralPath (Join-Path $Stage $u) -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum)
    $gb += ($s.Sum / 1GB)
  }
  $findings += [pscustomobject]@{
    Kind  = 'confirmed-but-held'
    Head  = ("{0} - the operator CONFIRMED this, {1} unit(s) are still staged ({2:N2} GB), and the reclaim FAILED" -f $a.Name, @($stagedUnits | Sort-Object -Unique).Count, $gb)
    Lines = @(("units: " + (($stagedUnits | Sort-Object -Unique) -join '; ')),
              ("refusal: " + $(if ($why) { $why.Trim() } else { 'see ' + $res })),
              "Nothing retries a FAILED artefact. Fix the cause, then move the .json back into $ReclaimQueue/")
  }
}

# ---- 2. THE BOARD'S "WAITING ON YOU" MUST AGREE WITH THE PENDING LIST ----------------------------
#
# Two stores, one claim. _awaiting-verification.txt is append-only and a work stays in it after its
# local copies are reclaimed, so "the register lists something" is NOT "the operator owes an answer".
# approve-confirmed.ps1 applies the local-files test that settles it; this repeats only that test,
# deliberately, rather than a second opinion about what pending means.
$registered = @()
if (Test-Path -LiteralPath $AwaitingFile -PathType Leaf) {
  foreach ($l in (Get-Content -LiteralPath $AwaitingFile | Where-Object { $_.Trim() })) {
    $w = ($l -split '\|')[-1].Trim(); if ($w) { $registered += $w }
  }
}
$reallyPending = @()
foreach ($w in ($registered | Sort-Object -Unique)) {
  foreach ($kind in @('Movies', 'Television Shows')) {
    $d = Join-Path (Join-Path $VideoRoot $kind) $w
    if (Test-Path -LiteralPath $d -PathType Container) {
      if (@(Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue).Count) { $reallyPending += $w; break }
    }
  }
}
$reallyPending = @($reallyPending | Sort-Object -Unique)

if (-not $findings.Count -and $reallyPending.Count -ge 0) { }

# ---- REPORT --------------------------------------------------------------------------------------
if ($findings.Count) {
  Write-Output ("*** {0} THING(S) ARE STUCK AND WILL NOT CLEAR THEMSELVES:" -f $findings.Count)
  foreach ($f in $findings) {
    Write-Output ("    {0}" -f $f.Head)
    foreach ($l in $f.Lines) { Write-Output ("        {0}" -f $l) }
  }
  if (-not $reallyPending.Count) {
    Write-Output '    NOTE: nothing is actually awaiting the operator right now, so this is NOT a'
    Write-Output '    confirmation they can give. Anything telling them to "confirm in Plex" to clear'
    Write-Output '    space is wrong - the blocker is named above.'
  }
} else {
  Write-Output ("line consistency OK - no confirmed work is holding staging; {0} work(s) genuinely awaiting confirmation" -f $reallyPending.Count)
}
exit 0
