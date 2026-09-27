<#
.SYNOPSIS
  REFUSE a manifest that declares an episode slot (SxxEyy - Season 00 above all) which another IN-FLIGHT
  claim already holds under a different name: another manifest in _queue (root, running, done) or
  _pending, a file already in the local work folder, or a row of _pending/SEASON00-ALLOCATION.md
  recorded for a different title. Exit 0 = no competing claim. Exit 2 = refuse; do not queue.

.WHY THIS EXISTS
  2026-09-27, Doctor Who (1963). The Robot and The Androids of Tara manifests were authored minutes
  apart. Both agents read "Next free Doctor Who (1963) number: S00E320" from the register; only Robot
  wrote its rows back. So S00E320..E324 were each declared twice under different titles ("A New
  Frontier" / "Now and Then - The Androids of Tara", ...). Every gate passed: the leaves differ, so no
  path clashed, and assert-episode-slot-free.ps1 only compares against the PUBLISHED library, where
  neither existed yet. Both encoded; publish-work.ps1's own slot-collision refusal then held the whole
  Season 00 folder, and the five Androids extras had to be renumbered by hand after the encode.

  The register is a claim ledger that agents write by hand, so it will race again. The fix is not a
  warning in the brief - it is checking, at the ONE door into the queue, every place a claim can
  already be written down.

.WHAT IT CHECKS
  For every row whose `out` is under Television Shows\<show>\<season>\ with an SxxEyy slot:
    1. THIS manifest: two rows claiming one slot under different names (Plex stack parts - "- pt1",
       "- pt2" - are one item and pass).
    2. OTHER MANIFESTS in _queue\, _queue\running\, _queue\done\ and _pending\ claiming the same show +
       slot under a different name. A manifest's own family ("x.json", "x.retry.json") is itself - a
       re-gated retry REPLACES its earlier declaration and is never refused against it. A clash with a
       manifest still in _pending (not yet gated) is waived when the register records the slot for
       THIS row's title: the register breaks the tie, the other one is the interloper and will be
       refused when it is gated.
    3. THE LOCAL WORK FOLDER: a .mkv already there claiming the slot under a different name.
    4. THE REGISTER: rows recorded for this show + slot, none of which is this row's title.
  Declaring the other leaf in the row's `supersedes` satisfies 1-3 (a deliberate replacement).

.WHAT IT DOES NOT DO
  It renames nothing and never decides who is right beyond the register's tie-break. It does not look
  at the published library - that is assert-episode-slot-free.ps1, the sibling on the same chain.

.EXAMPLE
  pwsh -NoProfile -File assert-slot-not-claimed.ps1 -Manifest D:/video/_pending/the-androids-of-tara.json
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [string]$QueueRoot  = 'D:/video/_queue',
  [string]$PendingDir = 'D:/video/_pending',
  [string]$Register   = 'D:/video/_pending/SEASON00-ALLOCATION.md',
  [string]$LocalRoot  = 'D:/video',
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib-slot-claims.ps1')
function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Say "assert-slot-not-claimed: no manifest at $Manifest"; exit 0 }
$mine = @(Get-ManifestSlotClaims -Path $Manifest)
if (-not $mine.Count) { Say 'assert-slot-not-claimed: no TV episode slot declared - nothing to check'; exit 0 }

$selfFull   = [IO.Path]::GetFullPath($Manifest)
$selfFamily = Get-ManifestFamily -Path $Manifest
$shows = @($mine.Show | Sort-Object -Unique)
$conflicts = [System.Collections.Generic.List[object]]::new()
function Add-Conflict($claim, [string]$other, [string]$where) {
  $conflicts.Add([pscustomobject]@{ Slot = $claim.Slot; Show = $claim.Show; Mine = $claim.Leaf; Other = $other; Where = $where })
}
function Test-Superseded($claim, [string]$leaf) { return ($claim.Supersedes -contains $leaf.ToLowerInvariant()) }
$key = { param($c) ('{0}|{1}' -f $c.Show, $c.Slot).ToLowerInvariant() }

# ---- the register: rows for these shows only ------------------------------------------------------
$regRows = @(Read-SlotRegister -Path $Register | Where-Object { $r = $_; @($shows | Where-Object { Test-SlotShowMatch $r.Show $_ }).Count })
function Get-RegisterRows($claim) { @($regRows | Where-Object { $_.Slot -eq $claim.Slot -and (Test-SlotShowMatch $_.Show $claim.Show) }) }
function Test-RegisterBacksMe($claim) {
  foreach ($r in (Get-RegisterRows $claim)) { if (Test-SlotRegisterTitleMatch $r.Title @($claim.Title, $claim.PlexTitle) $claim.Show) { return $true } }
  return $false
}

# ---- 1. within this manifest ----------------------------------------------------------------------
foreach ($g in ($mine | Group-Object { & $key $_ })) {
  $bases = @($g.Group.Base | Sort-Object -Unique)
  if ($bases.Count -gt 1) {
    $first = $g.Group[0]
    foreach ($c in @($g.Group | Where-Object { $_.Base -ne $first.Base })) { Add-Conflict $c $first.Leaf 'this same manifest' }
  }
}

# ---- 2. every other manifest that could still own the slot ----------------------------------------
$files = [System.Collections.Generic.List[object]]::new()
foreach ($d in @($QueueRoot, (Join-Path $QueueRoot 'running'), (Join-Path $QueueRoot 'done'), $PendingDir)) {
  if (-not (Test-Path -LiteralPath $d -PathType Container)) { continue }
  foreach ($f in @(Get-ChildItem -LiteralPath $d -File -Filter *.json -ErrorAction SilentlyContinue)) {
    if ($f.Extension -ne '.json') { continue }                                   # *.json also matches .json.bak-x on some hosts
    if ([string]::Equals($f.FullName, $selfFull, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if ((Get-ManifestFamily -Path $f.FullName) -eq $selfFamily) { continue }
    $files.Add([pscustomobject]@{ File = $f; Pending = [string]::Equals($d, $PendingDir, [StringComparison]::OrdinalIgnoreCase) })
  }
}
$myKeys = @{}
foreach ($c in $mine) { $myKeys[(& $key $c)] = $true }
$scanned = 0
foreach ($e in $files) {
  # Cheap pre-filter: a manifest that never names one of these shows cannot claim one of its slots.
  try { $text = [IO.File]::ReadAllText($e.File.FullName) } catch { continue }
  if (-not @($shows | Where-Object { $text.IndexOf($_, [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count) { continue }
  $scanned++
  foreach ($o in @(Get-ManifestSlotClaims -Path $e.File.FullName)) {
    if (-not $myKeys.ContainsKey((& $key $o))) { continue }
    foreach ($c in @($mine | Where-Object { (& $key $_) -eq (& $key $o) })) {
      if ($c.Base -eq $o.Base) { continue }                 # the same output: a replacement, not a rival
      if (Test-Superseded $c $o.Leaf) { continue }          # declared replacement
      $rel = $e.File.FullName
      if ($e.Pending -and (Test-RegisterBacksMe $c)) {
        Say ("  waived     {0} {1}: {2} (still in _pending, ungated) also claims it, but the register records it for THIS title" -f $c.Slot, $c.Title, (Split-Path $rel -Leaf))
        continue
      }
      Add-Conflict $c $o.Leaf ("manifest {0}" -f $rel)
    }
  }
}

# ---- 3. the local work folder ---------------------------------------------------------------------
$dirCache = @{}
foreach ($c in $mine) {
  $dir = [IO.Path]::Combine($LocalRoot, 'Television Shows', $c.Show, $c.SeasonDir)
  if (-not $dirCache.ContainsKey($dir)) { $dirCache[$dir] = @(Get-ChildItem -LiteralPath $dir -File -Filter *.mkv -ErrorAction SilentlyContinue) }
  foreach ($f in $dirCache[$dir]) {
    if ((Get-EpisodeSlots -Name $f.Name) -notcontains $c.Slot) { continue }
    if ((Get-SlotStackBase $f.Name) -eq $c.Base) { continue }
    if (Test-Superseded $c $f.Name) { continue }
    Add-Conflict $c $f.Name ("local file in {0}" -f $dir)
  }
}

# ---- 4. the register --------------------------------------------------------------------------------
foreach ($c in $mine) {
  $rows = @(Get-RegisterRows $c)
  if (-not $rows.Count) { continue }
  if (Test-RegisterBacksMe $c) { continue }
  foreach ($r in $rows) {
    $t = if ($r.Title.Length -gt 110) { $r.Title.Substring(0, 110) + '...' } else { $r.Title }
    Add-Conflict $c $t ("{0} line {1} (section '{2}')" -f (Split-Path $Register -Leaf), $r.Line, $r.Show)
  }
}

if (-not $conflicts.Count) {
  Say ("assert-slot-not-claimed: OK - {0} slot claim(s); {1} other manifest(s) name this show, local folder and register agree" -f $mine.Count, $scanned)
  exit 0
}

Say ("REFUSE - {0} slot claim(s) collide with a claim already written down elsewhere:" -f $conflicts.Count)
foreach ($c in ($conflicts | Sort-Object Show, Slot, Where)) {
  Say ("    {0}  {1}" -f $c.Slot, $c.Show)
  Say ("        this manifest : {0}" -f $c.Mine)
  Say ("        already       : {0}" -f $c.Other)
  Say ("        recorded in   : {0}" -f $c.Where)
}
Say '  Plex files an episode by its SxxEyy, so two items in one slot show as ONE and the other is lost;'
Say '  publish-work.ps1 then holds the whole season folder. Fix it HERE, before anything encodes:'
Say '    - a NEW item: read the register''s CURRENT "Next free" line, WRITE your rows into'
Say '      _pending/SEASON00-ALLOCATION.md first, then renumber this manifest''s rows to match;'
Say '    - a REPLACEMENT of that other item: name its leaf in the row''s `supersedes`;'
Say '    - the register row IS this item under other wording: make the row''s title start with this'
Say '      manifest''s title (or set `plexTitle` to the register''s wording).'
exit 2
