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
#>
param(
  [string[]]$Work = @(),
  [switch]$All,
  # Vestigial: -All is REFUSED (see below), so this no longer guards anything. Kept so an old
  # habit gets the explanation rather than a binding error.
  #
  # NAMED ONLY. `pwsh -File script.ps1 -Work 'a','b','c'` passes arguments as COMMAND-LINE STRINGS
  # and FLATTENS the array - 'a' binds to -Work and the rest bind POSITIONALLY to whatever comes
  # next. Adding this int parameter therefore made a latent trap fire on 2026-09-07: a work name
  # landed on -Expect and the call died with "cannot convert ... to type System.Int32". Loud, but
  # only because the types differed; a numeric work name would have bound silently. The same trap
  # is documented in _fetch-one.ps1's header. Call this script IN-PROCESS with `&` for arrays.
  [Parameter(ValueFromPipeline = $false, ValueFromPipelineByPropertyName = $false)]
  [ValidateRange(0, 1000)]
  [int]$Expect,
  [string]$Note = '',
  [switch]$StagingOnly,          # units only: for a work whose local copies are already reclaimed
  [string]$VideoRoot = 'D:/video',
  # Needed to ask whether a file is REALLY published before asking the operator to confirm it.
  # Read-only here: this script never writes to the NAS, it only tests for presence.
  [string]$NasRoot = '\\NASTEAMV\Multimedia',
  # Verdicts written by verify-title-cards.ps1. Read-only, and its ABSENCE is reported as
  # "not checked" rather than quietly treated as clean.
  [string]$IdentityCsv = 'D:/video/_episode-identity.csv',
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
# WHICH OF A WORK'S LOCAL FILES ARE ALREADY ON THE NAS - ONE implementation, two callers.
#
# The listing (list mode) prints these as "CONFIRM THESE n file(s)", and the -Work path writes the
# same set into the artefact's coversOutputs. Those two MUST agree: the artefact's whole purpose is
# to authorise exactly what the operator was shown, and a second copy of this path arithmetic is
# how they would quietly diverge. The library mirrors under both roots, so the NAS path is the local
# one with the root swapped.
function Get-FilesOnNas {
  param([object[]]$Files, [string]$VideoRoot, [string]$NasRoot)
  $prefix = (Join-Path $VideoRoot '')
  return @($Files | Where-Object {
    Test-Path -LiteralPath (Join-Path $NasRoot ($_.FullName.Substring($prefix.Length)))
  })
}

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
    # ASK ONLY ABOUT FILES THAT ARE ACTUALLY ON THE NAS.
    #
    # This listed every local file of a "published" work, taking the word from a WORK-level
    # register. A work stays in that register while any of its files remain local - which is also
    # true when publish has FAILED for some of them. So the two can disagree, and on 2026-09-08
    # they did: Tales of the Unexpected's six Season 05 episodes were printed under "PUBLISHED AND
    # AWAITING YOUR PLEX CONFIRMATION" when the NAS had no Season 05 folder at all. The operator was
    # asked to confirm, in Plex, six files that had never left this machine - and said so.
    #
    # That is the same defect as `verified N/N` describing only the files publish CHOSE to copy: a
    # work-level claim outrunning file-level reality. The reclaim's own gate would have refused to
    # release them, so nothing was at risk of deletion - but asking a false question wastes the one
    # gate a human holds, and teaches the operator that the list cannot be trusted.
    #
    # So measure. A file that is not on the NAS is NOT awaiting confirmation; it is awaiting
    # PUBLISH, and saying so points at the real blocker instead of hiding it behind a nod.
    # NOT $all - PowerShell variable names are CASE-INSENSITIVE, so `$all` IS the `-All` switch
    # parameter. Assigning an array to it replaced the switch and the next binding of -All died
    # with "Cannot convert System.Object[] to SwitchParameter" - from a line that never mentions it.
    $localFiles = @($localWorks[$p.Work])
    $fl = @(); $unpub = @()
    foreach ($f in $localFiles) {
      $rel = $f.FullName -replace [regex]::Escape((Join-Path $VideoRoot '')), ''
      $rel = ($rel -split '\\', 3)[-1]
      # The library mirrors under both roots - D:\video\<Kind>\<Work>\... and
      # \\NASTEAMV\Multimedia\<Kind>\<Work>\... - so the NAS path is the local one with the root
      # swapped. Built from the SAME string that produced $rel, so the two cannot drift apart.
      $onNas = @(Get-FilesOnNas -Files @($f) -VideoRoot $VideoRoot -NasRoot $NasRoot).Count -gt 0
      if ($onNas) { $fl += [pscustomobject]@{ F = $f; Rel = $rel } }
      else { $unpub += [pscustomobject]@{ F = $f; Rel = $rel } }
    }
    foreach ($x in ($fl | Sort-Object Rel)) { Write-Output ("        {0,8:N1} MB  {1}" -f ($x.F.Length / 1MB), $x.Rel) }
    if ($fl.Count) {
      Write-Output ("        ^ CONFIRM THESE {0} file(s) in Plex - not the work as a whole. They are what the reclaim releases." -f $fl.Count)
    }
    if ($unpub.Count) {
      Write-Output ("        !! {0} further local file(s) of this work are NOT ON THE NAS - do NOT confirm them; they are waiting on PUBLISH, not on you:" -f $unpub.Count)
      foreach ($x in ($unpub | Sort-Object Rel)) { Write-Output ("           {0,8:N1} MB  {1}" -f ($x.F.Length / 1MB), $x.Rel) }
      Write-Output  '           Check the publish loop for this work - a plan gate holding it, or a tripped breaker.'
    }

    # ---- WHAT THE DISC ITSELF SAYS THESE EPISODES ARE ------------------------------------------
    # The user is being asked "is this right in Plex?", and the honest thing to hand them alongside
    # that question is anything WE already know to be wrong. Plex shows a filename's slot filled
    # with the agent's title for that slot; it cannot tell you the file holds a different episode.
    # The West Wing Season 3, 2026-09-09: eighteen episodes published one slot too high, every one
    # displaying a plausible title beside a plausible runtime, and only the user's eye caught it.
    #
    # verify-title-cards.ps1 reads each episode's on-screen card and leaves its verdicts in
    # _episode-identity.csv. This only READS that file - OCR takes minutes per season and must
    # never run inside a listing someone is waiting on. "not checked" is reported as exactly that,
    # never as a pass: an absent verdict is an absent check.
    $idRows = @()
    if (Test-Path -LiteralPath $IdentityCsv) {
      try {
        # Match on the CSV's own Work column, NOT on a path prefix built from $VideoRoot: the real
        # paths carry a Kind segment ('Television Shows') between the root and the work, and the
        # roots differ in slash direction too. A prefix built without both matched nothing and the
        # listing said "NOT CHECKED" while 21 verdicts sat in the file - a check reporting itself
        # absent is indistinguishable from one that never ran.
        $idRows = @(Import-Csv -LiteralPath $IdentityCsv | Where-Object { "$($_.Work)" -eq "$($p.Work)" })
      } catch { }
    }
    if ($idRows.Count) {
      $mm = @($idRows | Where-Object { $_.Verdict -eq 'MISMATCH' })
      $okc = @($idRows | Where-Object { $_.Verdict -eq 'OK' }).Count
      $unr = @($idRows | Where-Object { $_.Verdict -eq 'UNREAD' }).Count
      if ($mm.Count) {
        Write-Output ("        !! IDENTITY: {0} file(s) contain a DIFFERENT episode than their name claims - do NOT confirm these:" -f $mm.Count)
        foreach ($m in $mm) { Write-Output ("           {0}  claims '{1}'  but {2}" -f (Split-Path -Leaf $m.Path), $m.Expected, $m.Read) }
      } else {
        Write-Output ("        identity: {0} verified against their on-screen title card, {1} unreadable, 0 wrong." -f $okc, $unr)
      }
    } else {
      Write-Output '        identity: NOT CHECKED against the discs'' title cards (verify-title-cards.ps1 -Show ''<show>'').'
    }
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
  exit 0
}

# `-All` MEANS "EVERYTHING ON THE LIST I WAS SHOWN", AND THE LIST MOVES.
#
# The pipeline publishes continuously, so between printing the pending list and the operator saying
# "yes" - a minute, or ten - other works finish and join it. `-All` then approves things the
# operator has never seen, and a confirmation is the ONE gate they hold: everything downstream,
# including deleting local copies and releasing staging, runs on their word.
#
# 2026-09-07, twice in two hours. At 09:56 they were shown 4 works and said "All are confirmed in
# Plex"; -All approved 6, having swept in Private Schulz and Reach For The Sky. At 12:01 they were
# shown 3 and said "I can confirm those 3 works on Plex"; -All approved 6 again, adding three
# Sherlock Holmes titles. Both were caught and narrowed by hand, which is not a control.
#
# `-Expect <n>` is the control: state how many works the list showed, and this refuses if the list
# has changed underneath. Cheap for the caller, and it converts a silent over-approval into a stop.
# `-All` IS FORBIDDEN. Operator direction, 2026-09-08: "-All should never be used. You should be
# required to explicitly state what is being recovered."
#
# It had already gone wrong three times, and the count guard added after the first two did not stop
# the third. 2026-09-08 09:23 the operator was shown six works and said "I can confirm all 6 works";
# by 09:28 Pride and Prejudice had finished its reclaim and dropped off while Tales of the
# Unexpected had joined - the COUNT was still six, so `-Expect 6` passed, and -All approved a work
# the operator had never been shown. (Worse, its six Season 05 episodes were not even on the NAS.)
#
# The count can never carry this. A set of six is not the same six, and only the NAMES say which.
# So there is no blanket approval any more: name every work, and the approval below states exactly
# what it releases.
if ($All) {
  Write-Output 'REFUSED: -All is not available. Approving "everything on the list" cannot be safe,'
  Write-Output '   because the list MOVES - the pipeline publishes continuously, so between printing'
  Write-Output '   it and the operator answering, works join and leave. On 2026-09-08 the set changed'
  Write-Output '   identity while keeping its count, and -Expect passed a work nobody had been shown.'
  Write-Output ''
  Write-Output '   Name each work explicitly instead - one -Work per confirmation:'
  foreach ($n in $pendingNames) { Write-Output ("      pwsh -File approve-confirmed.ps1 -Work '{0}' -Note '<their words>'" -f $n) }
  exit 2
}
$chosen = $Work
$problems = @()
# -StagingOnly IS EXEMPT FROM THE PENDING CHECK, and without this exemption the switch is dead code.
#
# The pending list SELF-CLEARS: "a work is still PENDING only while local files remain under
# D:/video". -StagingOnly is documented as "units only: for a work whose local copies are already
# reclaimed". Those two conditions are mutually exclusive, so every work the switch exists to serve
# is guaranteed to be absent from the list it was being checked against. Discovered 2026-09-08
# trying to use it on Taxi Driver: confirmed by the operator on 09-06, its local copies released by
# one of the six works-only artefacts of that day, and 7.5 GB of staging stranded ever since with
# no sanctioned way to free it.
#
# Safe, because the pending list is not what makes a release safe. Every gate still runs inside
# _reclaim-loop.ps1: deriveUnitsForWorks returns only units whose every output is DELIVERED AND
# BYTE-VERIFIED on the NAS, and a unit that fails is refused. What is checked here instead is that
# the switch is being used for what it says: a work with nothing left locally.
if ($StagingOnly) {
  foreach ($w in $chosen) {
    if ($localWorks.ContainsKey($w) -and @($localWorks[$w]).Count) {
      $problems += ("'$w' still has $(@($localWorks[$w]).Count) local file(s) - use the normal path, not -StagingOnly (which exists for works whose local copies are already gone).")
    }
  }
} else {
  foreach ($w in $chosen) { $p = Test-WorkIsPending -Name $w -Pending $pendingNames; if ($p) { $problems += $p } }
}
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

# SCOPE THE CONFIRMATION TO THE FILES THAT WERE ACTUALLY SHOWN.
#
# `deriveUnits: true` authorises releasing the staging of any unit of these works whose every
# output is delivered - evaluated WHEN THE ARTEFACT RUNS, not when it was written. An artefact that
# returns RETRY stays queued and is re-evaluated every pass, so files that publish AFTERWARDS fall
# inside a confirmation given before they existed.
#
# 2026-09-09, Out of the Unknown: the listing showed 11 files as confirmable and explicitly warned
# "do NOT confirm" the other 11, which were not yet on the NAS. The operator confirmed the 11. The
# artefact named the WORK with no scope, returned RETRY at 04:29, sat queued while publish delivered
# the other 11, and completed at 06:56 - releasing all of it, staging included. The operator found
# it in Plex and asked whether it had been cleaned up without their confirmation. It had.
#
# This script ALREADY knows the answer: Get-FilesOnNas returns the same list it prints under "CONFIRM
# THESE n file(s)". Writing it into coversOutputs means the artefact can never authorise more than
# was put in front of the operator, however long it sits in the queue. _reclaim-loop.ps1 requires
# EVERY output of a unit to match, so a disc that delivered one confirmed episode and three
# unconfirmed ones is not a confirmed disc - which is the property that was missing.
#
# Leafs are REGEX-ESCAPED and anchored: coversOutputs entries are matched with -match against the
# output's leaf filename, so an unescaped "Come Buttercup, Come Daisy, Come...?.mkv" would match far
# more than itself.
if (-not $StagingOnly) {
  $covers = @()
  foreach ($w in $chosen) {
    foreach ($f in @(Get-FilesOnNas -Files @($localWorks[$w]) -VideoRoot $VideoRoot -NasRoot $NasRoot)) {
      $covers += ('^' + [regex]::Escape($f.Name) + '$')
    }
  }
  if ($covers.Count) {
    $doc.coversOutputs = @($covers | Sort-Object -Unique)
    $doc.note = $doc.note + (" SCOPE: coversOutputs names the {0} file(s) shown as confirmable at that moment, " -f @($doc.coversOutputs).Count) +
                "so staging is released only for units whose EVERY output is one of them - a later publish cannot widen this."
  }
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


