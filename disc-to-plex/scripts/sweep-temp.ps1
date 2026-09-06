<#
.SYNOPSIS
  Sweep dead working files out of D:\temp. Age-gated, scoped to directories this project creates,
  and deliberately blind to everything else living there.

.WHY
  D:\temp reached 62.4 GB on 2026-09-06 while D: was under its 120 GB fetch floor and the optical
  lane could not hand two finished discs across. None of it was needed; all of it was ours.

  Two sources, and neither is a leak so much as cleanup that only ran on the happy path:

    * `disposition-evidence-*`  - 11.2 GB across 18 directories, every one dated 09-04/09-05, the
      night a batch of runaway agents was killed. disposition-evidence.ps1 removes its scratch at
      the END of a normal run, and a killed run never reaches that line. It now sweeps its own
      stale predecessors at START instead, so this script is the backstop rather than the fix.
    * session scratchpads       - 28.4 GB in one session alone: whole VOB and MKV segments pulled
      out during diagnostic work on 09-02 to 09-04 (a 2.0 GB e01-cells1-13.vob, a 1.5 GB
      withvideo.mkv, and 39,000 smaller files). Every one had served its purpose within the hour.

.WHAT IT WILL NOT TOUCH - this matters more than what it will
  * Anything outside D:\temp.
  * `tasks\` directories. Those hold background-command output and subagent transcripts that the
    harness reads back by path; removing one turns a readable result into a silent absence.
  * Anything modified inside -Days. The current session is still writing, and an age gate is the
    only thing standing between "dead scratch" and "the file an agent is using right now".
  * Directories this project did not create. D:\temp also holds a Visual Studio installer cache
    (2.75 GB), VS Code and telemetry directories. They are not ours, they are not swept, and their
    size is not evidence that they should be.

  pwsh -NoProfile -File sweep-temp.ps1 -WhatIf      # say what would go
  pwsh -NoProfile -File sweep-temp.ps1              # sweep
  pwsh -NoProfile -File sweep-temp.ps1 -Days 7      # be more conservative
#>
param(
  [string]$Temp    = 'D:/temp',
  [int]$Days       = 2,
  # Evidence scratch is aged in HOURS, not days, and deliberately not with the same dial.
  # A scratchpad file may plausibly be wanted tomorrow; a disposition-evidence directory is dead the
  # moment its run ends, and its owner (disposition-evidence.ps1) sweeps its own predecessors on a
  # 2-hour rule. A backstop that is slower than the thing it backs up leaves exactly the orphans it
  # exists to catch: sized at 2 DAYS, this script listed none of the 18 orphans (11.2 GB) sitting in
  # D:\temp, because the newest were only hours old at the time. Same number as the owner, so the
  # two cannot disagree about what counts as abandoned.
  [int]$EvidenceHours = 2,
  # Ad-hoc agent working directories are aged in HOURS too, and for the same reason as evidence
  # scratch: the directory is dead the moment the agent that made it finishes. The longest agent run
  # observed on this project is about 70 minutes (a 4,178 s Blake's 7 dispositions run), so 12 hours
  # is an order of magnitude of headroom. Under the -Days rule these sat untouched at 1.73 GB -
  # `ghostwatch`, `prize-of-arms-dispositions`, `bod-check` and friends, full of carved VOB cells -
  # simply because "2 days" is the right dial for a scratchpad a human might revisit and the wrong
  # one for a directory nothing will ever open again.
  [int]$AdHocHours = 12,
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path -LiteralPath $Temp).Path
if (-not $root.EndsWith('\')) { $root += '\' }
if (-not $root.StartsWith('D:\temp')) { throw "refusing to operate outside D:\temp: $root" }
$cutoff = (Get-Date).AddDays(-$Days)

$freed = 0
function Sweep-Path([string]$path, [string]$why) {
  if (-not $path.StartsWith($root)) { return }          # belt and braces: never outside the root
  $b = (Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
  if ($script:WhatIfMode) {
    Write-Output ("  WOULD  {0,-52} {1,8:N2} GB  {2}" -f (Split-Path -Leaf $path), ($b/1GB), $why)
    $script:freed += $b; return
  }
  Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
  if (-not (Test-Path -LiteralPath $path)) {
    Write-Output ("  swept  {0,-52} {1,8:N2} GB  {2}" -f (Split-Path -Leaf $path), ($b/1GB), $why)
    $script:freed += $b
  }
}
$script:WhatIfMode = [bool]$WhatIf
$script:freed = 0

# ---- 1. orphaned disposition evidence scratch -----------------------------------------------------
# THE ALLOWLIST IS EVIDENCE-BASED, NOT GUESSED. Each prefix below was traced to the script that
# creates it, because D:\temp is shared with tooling this project must not touch:
#
#   disposition-evidence-*  disposition-evidence.ps1   (also sweeps its own, at start)
#   capture-evidence-*      capture-evidence.py, assert-accounted.ps1, apply-proof.py
#   cards-*                 verify-title-cards.ps1
#   card-*                  read-card.ps1, disc-identity.ps1, disposition-analysis.ps1
#   seconv_ocr*             the OCR track's subtitle conversion
#
# NOT swept, and named here so the omission reads as a decision rather than an oversight:
#   scoped_dir*, TCD*, chrome_drag*   the browser tooling
#   tmp<random>                       Python's tempfile.mkdtemp - used by our scripts AND others,
#                                     and indistinguishable between them by name. A script that
#                                     leaks one of these should be fixed at the source, the way
#                                     disposition-evidence.ps1 was; guessing from an 8-character
#                                     random suffix is how something else's data gets deleted.
#   bp2w1glh (2.75 GB)                a Visual Studio installer cache. Size is not ownership.
#
# THIS SWEEP IS A BACKSTOP, NOT THE FIX. 490 capture-evidence-* directories going back to 08-29 is
# not a disk-space problem (1.18 GB) so much as a signal that capture-evidence.py does not remove
# its own scratch. The durable answer is per-script cleanup at START, as disposition-evidence.ps1
# now does; this catches what escapes, including from runs that were killed.
$evPrefixes = @('disposition-evidence-', 'capture-evidence-', 'cards-', 'card-', 'seconv_ocr')
$evCutoff = (Get-Date).AddHours(-$EvidenceHours)
foreach ($d in @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                 Where-Object { $n = $_.Name; ($evPrefixes | Where-Object { $n.StartsWith($_, 'OrdinalIgnoreCase') }) } |
                 Where-Object { $_.LastWriteTime -lt $evCutoff })) {
  Sweep-Path $d.FullName ('orphaned evidence scratch, last written ' + $d.LastWriteTime.ToString('MM-dd HH:mm'))
}

# ---- 2. session scratchpads --------------------------------------------------------------------
# Swept FILE BY FILE, not directory by directory: a session that is still live (this one) holds dead
# 4-day-old media beside files written minutes ago, so taking the whole directory on its aggregate
# timestamp would destroy work in progress. `tasks\` is skipped entirely - see the header.
$claude = Join-Path $root 'claude'
if (Test-Path -LiteralPath $claude -PathType Container) {
  # ---- 2a. AD-HOC AGENT WORKING DIRECTORIES ------------------------------------------------------
  # Not every directory under `claude` is a session. Agents also create NAMED working directories
  # here - `ghostwatch`, `prize-of-arms-dispositions`, `bod-check`, `rumpole-s2d2-menu-vts01`,
  # `b7s3d4-menu-vts02b` - and fill them with carved VOB cells and raw audio. 1.73 GB of them
  # survived the first version of this sweep untouched, because it only ever descended into
  # <project>/<session>/scratchpad and these sit a level higher.
  #
  # Told apart from a PROJECT directory by shape, not by a name list: a project directory's children
  # are session ids (32+ hex characters with dashes). Anything else is ad-hoc scratch and is aged by
  # its own last-write time. Getting this wrong in the permissive direction would delete a live
  # session's tasks\, so the test is for the SESSION shape and the default is to leave it alone.
  $rxSession = '^[0-9a-fA-F]{8}-[0-9a-fA-F-]{20,}$'
  foreach ($d in @(Get-ChildItem -LiteralPath $claude -Directory -ErrorAction SilentlyContinue)) {
    $looksLikeProject = @(Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue |
                          Where-Object { $_.Name -match $rxSession }).Count -gt 0
    if ($looksLikeProject) { continue }
    $newest = @(Get-ChildItem -LiteralPath $d.FullName -Recurse -File -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    $stamp = if ($newest.Count) { $newest[0].LastWriteTime } else { $d.LastWriteTime }
    if ($stamp -ge (Get-Date).AddHours(-$AdHocHours)) { continue }
    Sweep-Path $d.FullName ('ad-hoc agent working dir, last written ' + $stamp.ToString('MM-dd HH:mm'))
  }

  foreach ($proj in @(Get-ChildItem -LiteralPath $claude -Directory -ErrorAction SilentlyContinue)) {
    foreach ($sess in @(Get-ChildItem -LiteralPath $proj.FullName -Directory -ErrorAction SilentlyContinue)) {
      $pad = Join-Path $sess.FullName 'scratchpad'
      if (-not (Test-Path -LiteralPath $pad -PathType Container)) { continue }
      $old = @(Get-ChildItem -LiteralPath $pad -Recurse -File -ErrorAction SilentlyContinue |
               Where-Object { $_.LastWriteTime -lt $cutoff -and $_.FullName.StartsWith($root) })
      if ($old.Count -eq 0) { continue }
      $b = ($old | Measure-Object Length -Sum).Sum
      if ($WhatIf) {
        Write-Output ("  WOULD  {0,-52} {1,8:N2} GB  {2} scratchpad file(s) older than {3}d" -f $sess.Name.Substring(0, [Math]::Min(8, $sess.Name.Length)), ($b/1GB), $old.Count, $Days)
        $script:freed += $b
        continue
      }
      $n = 0
      foreach ($f in $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; if (-not (Test-Path -LiteralPath $f.FullName)) { $n++ } }
      # Empty directories left behind are noise, not data.
      foreach ($sub in @(Get-ChildItem -LiteralPath $pad -Recurse -Directory -ErrorAction SilentlyContinue | Sort-Object { $_.FullName.Length } -Descending)) {
        if (@(Get-ChildItem -LiteralPath $sub.FullName -Recurse -File -ErrorAction SilentlyContinue).Count -eq 0) {
          Remove-Item -LiteralPath $sub.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }
      }
      Write-Output ("  swept  {0,-52} {1,8:N2} GB  {2} scratchpad file(s) older than {3}d" -f $sess.Name.Substring(0, [Math]::Min(8, $sess.Name.Length)), ($b/1GB), $n, $Days)
      $script:freed += $b
    }
  }
}

Write-Output ("sweep-temp: {0} {1:N2} GB (files older than {2} day(s); tasks\ and non-project directories untouched)" -f `
              $(if ($WhatIf) { 'would free' } else { 'freed' }), ($script:freed/1GB), $Days)
exit 0
