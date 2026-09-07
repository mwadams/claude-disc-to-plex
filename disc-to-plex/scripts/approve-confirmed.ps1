<#
.SYNOPSIS
  List the works awaiting the operator's Plex confirmation, and turn a "yes" into a correctly-scoped
  reclaim artefact with ONE command.

.WHY THIS EXISTS
  The conversation is the right approval channel - the operator nods through what they are happy
  with, which no tag or label captures as well. What was wrong was everything either side of the nod:
  the FLAGGING was incomplete and the FOLLOW-THROUGH was hand-authored.

  Measured over 2026-09-06/07. Six reclaim artefacts were written by hand that day, every one scoped
  to `works` only. That releases a work's local published copies - a few GB each - and never the
  staging behind them. Meanwhile `_stage` grew to 166.3 GB of which NOTHING was releasable, because
  a unit only enters `_completed.txt` through a UNIT-level release. Each confirmation the operator
  gave returned ~5 GB while 166 GB sat untouched, and the board kept reporting "space-blocked,
  awaiting confirmations" as though more nods were the answer. They were not: the four optically
  backed-up discs were held at the archive-to-stage handoff, the fetch was stopped for 160 discs, and
  the GPU lanes idled for hours.

  The schema ALREADY supported the right answer. `deriveUnits: true` makes _reclaim-loop.ps1 call
  Get-DeliveredUnitsForWorks, which returns exactly the staged units of the named works whose every
  output has been delivered and byte-verified. It was never set. This script sets it, always, so the
  scope stops being a judgement call made afresh six times.

.WHAT IT REFUSES
  * A work that is NOT currently on the pending list. A typo, a stale name from earlier in a
    conversation, or an invented one is refused rather than acted on - so the worst outcome of
    getting a name wrong is nothing happening.
  * Writing over an existing artefact filename. Names carry a timestamp AND a slug; on 2026-09-06 a
    hand-written name collided with an earlier one and a watcher read the OLD result as if it were
    the new run's, reporting a completed reclaim that had not happened.

.WHAT IT DOES NOT DO
  It does not decide what is safe. Every gate still runs inside _reclaim-loop.ps1 and
  _release-completed.ps1 - accounting, byte-verification, shipped-outside records, manifest
  consumers. This only removes the SCOPING decision, which is derivable, from the human path.

.EXAMPLE
  pwsh -File approve-confirmed.ps1
  pwsh -File approve-confirmed.ps1 -Work 'Spaced','Sleepy Hollow' -Note 'both confirmed'
  pwsh -File approve-confirmed.ps1 -All -Note 'all confirmed'
#>
param(
  [string[]]$Work = @(),
  [switch]$All,
  [string]$Note = '',
  [switch]$StagingOnly,          # units only: for a work whose local copies are already reclaimed
  [string]$VideoRoot = 'D:/video',
  [switch]$WhatIf,
  [switch]$SelfTest
)
$ErrorActionPreference = 'Stop'

function Get-ArtefactName {
  <# Unique by construction: date, time to the minute, and a slug of what is being approved. #>
  param([Parameter(Mandatory)][string[]]$Works, [datetime]$Now = (Get-Date))
  $slug = (($Works | ForEach-Object { ($_ -replace '[^A-Za-z0-9]', '').ToLowerInvariant() }) -join '-')
  if ($slug.Length -gt 30) { $slug = $slug.Substring(0, 30) }
  if (-not $slug) { $slug = 'none' }
  return ('confirmed-{0}-{1}.json' -f $Now.ToString('yyyy-MM-dd-HHmm'), $slug)
}

function Test-WorkIsPending {
  <# Returns $null when the name is on the pending list, else a refusal string naming the closest
     candidates. Approving something not pending is how a nod gets attached to the wrong work. #>
  param([Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Pending)
  if ($Pending -contains $Name) { return $null }
  $near = @($Pending | Where-Object { $_ -like "*$Name*" -or $Name -like "*$_*" })
  $hint = if ($near.Count) { " Did you mean: $($near -join ' | ')?" } else { " Pending right now: $(if ($Pending.Count) { $Pending -join ' | ' } else { '<nothing>' })" }
  return "'$Name' is not awaiting confirmation.$hint"
}

if ($SelfTest) {
  $fail = 0
  function T($n, $c) { if ($c) { "  ok   $n" } else { $script:fail++; "  FAIL $n" } }
  $now = [datetime]'2026-09-07T02:45:00'
  T 'name has date+time+slug'   ((Get-ArtefactName -Works @('Spaced') -Now $now) -eq 'confirmed-2026-09-07-0245-spaced.json')
  T 'name joins several works'  ((Get-ArtefactName -Works @('Spaced','Sleepy Hollow') -Now $now) -eq 'confirmed-2026-09-07-0245-spaced-sleepyhollow.json')
  T 'name strips punctuation'   ((Get-ArtefactName -Works @('Doctor Who (1963)') -Now $now) -eq 'confirmed-2026-09-07-0245-doctorwho1963.json')
  T 'name is capped'            ((Get-ArtefactName -Works @('A'*80) -Now $now).Length -lt 70)
  T 'two different minutes differ' ((Get-ArtefactName -Works @('X') -Now $now) -ne (Get-ArtefactName -Works @('X') -Now $now.AddMinutes(1)))
  T 'pending name accepted'     ($null -eq (Test-WorkIsPending -Name 'Spaced' -Pending @('Spaced','Porridge')))
  T 'unknown name refused'      ((Test-WorkIsPending -Name 'Spacd' -Pending @('Spaced')) -match 'not awaiting confirmation')
  T 'refusal offers the near miss' ((Test-WorkIsPending -Name 'Spac' -Pending @('Spaced')) -match 'Did you mean')
  T 'refusal lists pending when no near miss' ((Test-WorkIsPending -Name 'Zzz' -Pending @('Spaced')) -match 'Pending right now')
  T 'empty pending refuses'     ((Test-WorkIsPending -Name 'Spaced' -Pending @()) -match '<nothing>')
  if ($fail) { "SELFTEST FAILED - $fail case(s)"; exit 1 }
  'SELFTEST OK'; exit 0
}

# ---- the pending list, from the SAME register the board reads -------------------------------------
$reg = Join-Path $VideoRoot '_awaiting-verification.txt'
$pending = @()
if (Test-Path -LiteralPath $reg) {
  foreach ($l in (Get-Content -LiteralPath $reg | Where-Object { $_.Trim() })) {
    $parts = $l -split '\|'
    $pending += [pscustomobject]@{ When = $parts[0].Trim(); Work = $parts[-1].Trim() }
  }
}

# SELF-CLEARING, exactly as audit-space-block.ps1 does it. The register is append-only: the publish
# loop adds a work when it verifies it and never removes it. A work whose local copies have already
# been reclaimed has nothing left to confirm, and listing it is worse than useless - the first run of
# this script offered 67 works, nearly all of them done, which is the same wall of noise the operator
# is trying to get away from. A work is still PENDING only while local files remain under D:/video.
$localWorks = @{}
foreach ($area in 'Movies', 'Television Shows') {
  $root = Join-Path $VideoRoot $area
  if (-not (Test-Path -LiteralPath $root)) { continue }
  foreach ($d in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue)) {
    # KEEP THE FILES, NOT JUST THE COUNT. What is actually being confirmed is these files, and
    # naming only the WORK invites the operator to confirm the wrong thing - see the listing below.
    $files = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.Extension -in '.mkv', '.mp4', '.m4v', '.avi' })
    if ($files.Count -gt 0) { $localWorks[$d.Name] = $files }
  }
}
$pending = @($pending | Where-Object { $localWorks.ContainsKey($_.Work) })

# NEVER ASK TWICE FOR A NOD ALREADY GIVEN.
# "Local files remain" is not the same question as "does the operator still owe a confirmation".
# A work whose artefact is already in _reclaim-queue has been confirmed; its files remain only
# because a RELEASE GATE is refusing - and that refusal is ours to clear, not theirs to re-answer.
# 2026-09-07: Harry Potter and the Prisoner of Azkaban was confirmed at 02:55, and the reclaim has
# been returning RETRY ever since ("2 file(s) still held by the per-file gate") because two Deleted
# Scenes carry a dvd_subtitle stream and never got their .eng.srt. This script went on listing it as
# awaiting confirmation, so the operator confirmed it FOUR times - the exact wall of noise the
# self-clearing above exists to prevent, just from the other end.
# So: partition. Still-owed goes in the list; already-confirmed-but-stuck is reported separately,
# WITH the reason, because that is a work item for us.
$confirmedWorks = @{}
$rq = Join-Path $VideoRoot '_reclaim-queue'
foreach ($a in (Get-ChildItem -LiteralPath $rq -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
  try { $art = Get-Content -LiteralPath $a.FullName -Raw | ConvertFrom-Json } catch { continue }
  $status = [IO.Path]::ChangeExtension($a.FullName, $null) + 'status.txt'
  $why = ''
  if (Test-Path -LiteralPath $status) {
    $line = @(Get-Content -LiteralPath $status -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*(pending|refused|blocked)\s*:' })
    if ($line.Count) { $why = ($line[-1] -replace '^\s*\w+\s*:\s*', '').Trim() }
  }
  foreach ($w in @($art.works)) { if ($w) { $confirmedWorks["$w"] = @{ When = $a.LastWriteTime; Why = $why } } }
}

$stuck   = @($pending | Where-Object { $confirmedWorks.ContainsKey($_.Work) })
$pending = @($pending | Where-Object { -not $confirmedWorks.ContainsKey($_.Work) })
$pendingNames = @($pending | ForEach-Object { $_.Work } | Sort-Object -Unique)

# ---- staging currently held, so the LIST shows the real prize -------------------------------------
$stage = Join-Path $VideoRoot '_stage'
$stagedGB = 0.0
if (Test-Path -LiteralPath $stage) {
  $stagedGB = [math]::Round(((Get-ChildItem -LiteralPath $stage -Recurse -File -ErrorAction SilentlyContinue |
                Measure-Object Length -Sum).Sum / 1GB), 1)
}

if (-not $Work.Count -and -not $All) {
  Write-Output "AWAITING YOUR CONFIRMATION - $($pendingNames.Count) work(s):"
  if (-not $pendingNames.Count) { Write-Output '   (none)' }
  # NAME THE FILES. A work name alone is not the question being asked.
  #
  # 2026-09-07, in the operator's own words: "my confirmation was also incorrect. Because you just
  # gave me a film title, I assumed you were asking for the feature. In fact, you were asking to
  # confirm a specific set of extras which you did not list."
  #
  # Exactly so. The reclaim releases the LOCAL FILES that remain, and for a work published in
  # stages those are usually a handful of late extras, not the feature - Azkaban's feature went to
  # the NAS days before the two Deleted Scenes this gate was actually holding. Asked "is Harry
  # Potter and the Prisoner of Azkaban in Plex?", anyone reasonably checks the film, sees it, and
  # says yes. The confirmation then attaches to evidence nobody looked at, which is precisely the
  # failure a human gate exists to prevent. So print what will be released, and check THOSE.
  foreach ($p in ($pending | Sort-Object When)) {
    Write-Output ("   {0,-42} published {1}" -f $p.Work, $p.When)
    $fl = @($localWorks[$p.Work])
    foreach ($f in ($fl | Sort-Object FullName)) {
      $rel = $f.FullName -replace [regex]::Escape((Join-Path $VideoRoot '')), ''
      $rel = ($rel -split '\\', 3)[-1]      # drop "Movies\<work>\" / "Television Shows\<work>\"
      Write-Output ("        {0,8:N1} MB  {1}" -f ($f.Length / 1MB), $rel)
    }
    Write-Output ("        ^ CONFIRM THESE {0} file(s) in Plex - not the work as a whole. They are what the reclaim releases." -f $fl.Count)
  }
  Write-Output ''
  if ($stuck.Count) {
    Write-Output "ALREADY CONFIRMED BY YOU - blocked downstream, do NOT confirm again ($($stuck.Count)):"
    foreach ($s in ($stuck | Sort-Object Work)) {
      $c = $confirmedWorks[$s.Work]
      Write-Output ("   {0,-42} confirmed {1:MM-dd HH:mm}" -f $s.Work, $c.When)
      if ($c.Why) { Write-Output ("        blocked: {0}" -f $c.Why) }
    }
    Write-Output '   These are OURS to clear, not yours to re-answer.'
    Write-Output ''
  }
  Write-Output ("_stage currently holds {0} GB. Approving a work releases its local published copies AND -" -f $stagedGB)
  Write-Output '   because this writes deriveUnits:true - the staging of every unit of that work whose outputs'
  Write-Output '   are all delivered and byte-verified. That second part is what hand-written artefacts missed.'
  Write-Output ''
  Write-Output '   pwsh -File approve-confirmed.ps1 -Work ''<name>'' -Note ''<their words>'''
  Write-Output '   pwsh -File approve-confirmed.ps1 -All -Note ''<their words>'''
  exit 0
}

$chosen = if ($All) { $pendingNames } else { $Work }
$problems = @()
foreach ($w in $chosen) { $p = Test-WorkIsPending -Name $w -Pending $pendingNames; if ($p) { $problems += $p } }
if ($problems.Count) {
  Write-Output "REFUSE - $($problems.Count) name(s) not on the pending list:"
  $problems | ForEach-Object { Write-Output "    $_" }
  exit 2
}
if (-not $chosen.Count) { Write-Output 'nothing to approve'; exit 0 }

$doc = [ordered]@{
  confirmed = (Get-Date -Format 'yyyy-MM-dd')
  note      = ("OPERATOR CONFIRMATION via approve-confirmed.ps1 at $(Get-Date -Format 'yyyy-MM-dd HH:mm'). " +
               $(if ($Note) { "Their words: '$Note'. " } else { '' }) +
               "Scope was COMPUTED, not chosen: works as named, plus deriveUnits:true so " +
               "Get-DeliveredUnitsForWorks returns the staged units of these works whose every output is " +
               "delivered and byte-verified. Hand-written artefacts on 2026-09-06 omitted that and left " +
               "166.3 GB of staging unreleasable; this script exists so that scope is never decided by hand again. " +
               "Every release gate still applies and a refusal is the correct outcome.")
  works       = @($chosen)
  units       = @()
  deriveUnits = $true
}
if ($StagingOnly) { $doc.works = @(); $doc.units = @(); $doc.deriveUnitsForWorks = @($chosen) }

$outDir = Join-Path $VideoRoot '_reclaim-queue'
$name = Get-ArtefactName -Works $chosen
$out  = Join-Path $outDir $name
if (Test-Path -LiteralPath $out) { Write-Output "REFUSE - $name already exists; not overwriting an artefact"; exit 2 }

Write-Output ("approving {0} work(s): {1}" -f $chosen.Count, ($chosen -join ', '))
Write-Output ("  -> {0}   (works + deriveUnits:true)" -f $name)
if ($WhatIf) { Write-Output '  WhatIf: nothing written'; exit 0 }
($doc | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $out -Encoding UTF8
Write-Output '  queued - _reclaim-loop.ps1 will pick it up and apply every gate.'
exit 0
