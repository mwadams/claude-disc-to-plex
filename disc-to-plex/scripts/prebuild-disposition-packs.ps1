<#
.SYNOPSIS
  Build the disposition EVIDENCE PACK for staged units that are queued behind the dispositions
  loop, BEFORE their agent is launched.

.DESCRIPTION
  when: 2026-09-07 04:0x. The GPU encode lanes sat empty while `_stage` held 15 staged discs.
  Nothing was stuck: the line is AUTHORING-BOUND. `_dispositions-loop.ps1` runs ONE agent at a
  time (deliberate, spend-capped, not to be changed), and measured cycle time was ~13 minutes a
  disc - dispositions ~11-13 min, manifest ~2 min. The encoder drains a gated disc in well under
  that, so it idles between gates.

  The avoidable part of those 13 minutes is that the agent runs `disposition-analysis.ps1`
  ITSELF, as step 1 of its brief (`_briefs/dispositions.md` line 35). That work is deterministic
  measurement - IFO parsing, packet counts, NAS probes, card OCR - with no judgement in it, and
  it is charged to the single serialised agent slot at agent token rates. All 15 queued discs had
  ZERO cached evidence.

  So take it out of band. The analysis is idempotent: it prints `CACHED:` and exits when the
  analysis file is newer than its evidence pack, so an agent that later runs the same command
  gets an instant cache hit instead of a ten-minute measurement pass. This changes no policy and
  touches no concurrency setting - it only moves deterministic work off the critical path.

.NOTES
  ORDER MATTERS. The loop consumes its backlog from the FRONT. This walks from the BACK, so the
  producer and the consumer move apart instead of colliding on the same unit. Belt and braces, a
  unit holding a live `.dispositioning`/`.authoring` marker is skipped and re-tested each pass:
  the marker is the loop's claim, and two processes measuring one disc is the collision this
  ordering exists to avoid.

  Honours the NAS hold (`D:\video\_nas-hold`) - the analysis does NAS probes, so it stands down
  with everything else rather than reading through a hold.

.EXAMPLE
  pwsh -NoProfile -File prebuild-disposition-packs.ps1 -WhatIf
.EXAMPLE
  pwsh -NoProfile -File prebuild-disposition-packs.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
  [string]$Stage     = 'D:/video/_stage',
  [string]$Pending   = 'D:/video/_pending',
  [string]$Catalogue = 'D:/video/_catalogue',
  [string]$LogDir    = 'D:/video/_logs',
  [string[]]$Unit,                      # explicit units; default = every staged unit with a pending brief
  [switch]$Force                        # rebuild even when a fresh pack exists
)

$ErrorActionPreference = 'Stop'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$analysis  = Join-Path $scriptDir 'disposition-analysis.ps1'
if (-not (Test-Path -LiteralPath $analysis)) { throw "disposition-analysis.ps1 not found beside this script ($analysis)" }

# SINGLE INSTANCE, and the guard lives HERE rather than in the caller. `_dispositions-loop.ps1`
# fires this off every pass (every ~2 min) without tracking it: that is only safe because a second
# copy exits immediately instead of racing the first over the same unit's evidence pack. Same
# convention as every track - a named mutex, never a CommandLine match, which matches your own shell.
$mutex = New-Object System.Threading.Mutex($false, 'Global\video-prebuild-packs')
try {
  $own = $mutex.WaitOne(0)
} catch [System.Threading.AbandonedMutexException] {
  # A previous prebuild was killed while holding it. An abandoned mutex is still GRANTED to us -
  # the exception is a warning that the last holder died mid-work, not a refusal. Swallowing it is
  # correct here (the analysis is idempotent, so a half-finished unit simply rebuilds); letting it
  # propagate would wedge the prebuild permanently after any single kill.
  $own = $true
}
if (-not $own) { Write-Host 'another prebuild is already running - exiting'; exit 0 }

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$log = Join-Path $LogDir '_prebuild-packs.log'
function Say([string]$m) {
  $line = "[{0:HH:mm:ss}] {1}" -f (Get-Date), $m
  Write-Host $line
  Add-Content -LiteralPath $log -Value $line
}

# ---------------------------------------------------------------- choose the units
# A unit qualifies when it is STAGED and the loop still has a dispositions brief pending for it.
# Anything already gated, closed or mid-manifest is none of our business.
function Get-Candidates {
  if ($Unit) { return @($Unit) }
  $staged = @{}
  Get-ChildItem -LiteralPath $Stage -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { $staged[$_.Name] = $true }
  Get-ChildItem -LiteralPath $Pending -Filter '*.dispositions-brief.md' -File -ErrorAction SilentlyContinue |
    ForEach-Object { $_.Name -replace '\.dispositions-brief\.md$','' } |
    Where-Object { $staged[$_] }
}

# The loop's claim on a unit. Never measure a disc an agent is holding.
function Test-Claimed([string]$u) {
  foreach ($ext in '.dispositioning', '.authoring', '.manifesting') {
    if (Test-Path -LiteralPath (Join-Path $Pending ($u + $ext))) { return $true }
  }
  return $false
}

function Test-Fresh([string]$u) {
  if ($Force) { return $false }
  $a = Join-Path $Catalogue "$u.analysis.json"
  $e = Join-Path $Catalogue "$u.evidence.json"
  if (-not (Test-Path -LiteralPath $a)) { return $false }
  if (-not (Test-Path -LiteralPath $e)) { return $true }   # analysis with no pack: leave it alone
  return (Get-Item -LiteralPath $a).LastWriteTime -ge (Get-Item -LiteralPath $e).LastWriteTime
}

function Wait-NasHold {
  while (Test-Path -LiteralPath 'D:/video/_nas-hold') {
    Say 'NAS hold is ON - standing down; will re-test in 60 s'
    Start-Sleep -Seconds 60
  }
}

# STOPPING THIS MUST NOT REQUIRE A KILL.
# 2026-09-07: the first version of this script had no stop route, so stopping it meant selecting a
# process and killing it - and the selection was made with `CommandLine -match 'prebuild-...'`,
# which matched the very shell issuing the command and killed that instead. The kill was both
# unnecessary (the pack it was reacting to was correct) and mis-aimed.
# A long-running process that can only be stopped by a kill INVITES that mistake. So: drop
# `D:\video\_prebuild-stop` and this exits at its next unit boundary, mid-analysis work intact
# (the analysis is idempotent - an interrupted unit simply rebuilds next pass).
$StopFile = 'D:/video/_prebuild-stop'
function Test-StopRequested {
  if (Test-Path -LiteralPath $StopFile) {
    Say 'stop sentinel present - exiting cleanly at unit boundary'
    Remove-Item -LiteralPath $StopFile -Force -ErrorAction SilentlyContinue
    return $true
  }
  return $false
}

# ---------------------------------------------------------------- run
# REVERSE order: the loop eats from the front, we build from the back.
$candidates = @(Get-Candidates) | Sort-Object
[array]::Reverse($candidates)

Say ("start: {0} candidate unit(s); building from the BACK of the queue (loop consumes the front)" -f $candidates.Count)
if (-not $candidates) { Say 'nothing to do'; exit 0 }

$built = 0; $cached = 0; $skipped = 0; $failed = @()

foreach ($u in $candidates) {
  if (Test-StopRequested) { break }
  # Re-tested per unit, not once up front: the loop advances while we work.
  if (Test-Claimed $u) { Say "SKIP  $u - claimed by a live agent (marker present)"; $skipped++; continue }
  if (Test-Fresh   $u) { Say "FRESH $u - pack already current"; $cached++; continue }

  Wait-NasHold
  if (-not $PSCmdlet.ShouldProcess($u, 'build disposition evidence pack')) { continue }

  $sw = [Diagnostics.Stopwatch]::StartNew()
  Say "BUILD $u ..."
  try {
    $out = & pwsh -NoProfile -File $analysis -Unit $u 2>&1
    $sw.Stop()
    if ($LASTEXITCODE -ne 0) {
      $failed += $u
      Say ("FAIL  {0} - exit {1} after {2:N0}s" -f $u, $LASTEXITCODE, $sw.Elapsed.TotalSeconds)
      $out | Select-Object -Last 12 | ForEach-Object { Say "        $_" }
    } elseif ($out -match '^CACHED:') {
      $cached++; Say ("CACHE {0} - already current ({1:N0}s)" -f $u, $sw.Elapsed.TotalSeconds)
    } else {
      # SAY WHAT IT ACTUALLY MEASURED, not merely that it exited 0.
      # "OK - pack built in 6s" was logged for a pack whose every title measurement was
      # UNAVAILABLE: the unit is a Blu-ray (BDMV, no VIDEO_TS) and this analysis measures DVDs, so
      # it correctly declined - but the log said success and read as a silent defect. A gate that
      # can only report the anticipated outcome cannot report the unanticipated one.
      $built++
      $note = ''
      try {
        $j = Get-Content -LiteralPath (Join-Path $Catalogue "$u.analysis.json") -Raw | ConvertFrom-Json
        $tot = [int]$j.findingCounts.total; $un = [int]$j.findingCounts.unavailable
        $note = " - $tot finding(s), $un unavailable"
        if ($un -ge $tot - 2) {
          $why = @($j.unavailable | Where-Object { $_.measurement -eq 'titles' } | ForEach-Object { $_.reason })
          $note += " *** LIMITED PACK: no per-title measurement" + $(if ($why) { " ($($why[0]))" })
        }
      } catch { $note = ' - (could not read back the pack to report what it measured)' }
      Say ("OK    {0} - built in {1:N0}s{2}" -f $u, $sw.Elapsed.TotalSeconds, $note)
    }
  } catch {
    $sw.Stop(); $failed += $u
    Say ("FAIL  {0} - {1}" -f $u, $_.Exception.Message)
  }
}

Say ("done: built {0}, already-fresh {1}, skipped-claimed {2}, failed {3}" -f $built, $cached, $skipped, $failed.Count)
if ($failed) { Say ("failed units: {0}" -f ($failed -join ', ')) }
$mutex.ReleaseMutex()
exit 0
