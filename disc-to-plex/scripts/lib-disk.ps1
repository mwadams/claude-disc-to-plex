<#
.SYNOPSIS
  Wait for a volume's free-space figure to catch up with a large delete, then report it.

.WHY
  Releasing staging prints how many bytes it freed and then what the disk reports. Those two
  disagreed twice on 2026-08-27:

    release Sunrise           freed 86.42 GB   ->  "free on D: 63 GB"    (true value 149.1 GB)
    release 10 Sword/Bill     freed 54.33 GB   ->  "free on D: 99.6 GB"  (true value 147.6 GB)

  My first diagnosis was that Get-PSDrive serves a session-cached value, so I switched to CIM. The
  second release DISPROVED that - CIM was already in place and still reported the pre-release
  figure. Both APIs report the volume honestly; the VOLUME has not finished accounting for tens of
  thousands of just-deleted files at the instant it is asked.

  It matters because "54 GB freed" beside an unchanged disk reads as a FAILED reclaim, and the
  obvious response is to release more staging - the one irreversible step in this pipeline.

  The first fix was an inline loop that broke on the FIRST increase, which is barely better: a
  partially-updated figure is still wrong, just less obviously. So this waits for the number to
  either reach what was expected or STOP MOVING, and reports which of those happened - a caller
  can then say plainly that a figure is provisional instead of presenting it as fact.

  Reader/Sleeper are injectable so the settling logic can be tested without deleting anything;
  see lib-disk.tests.ps1.

.OUTPUTS
  [pscustomobject] Free, Gain, Reason ('expected'|'stable'|'timeout'), Settled ([bool])
#>

function Wait-FreeSpaceSettled {
  [CmdletBinding()]
  param(
    # Free bytes sampled BEFORE the deletions.
    [Parameter(Mandatory)][long]$Before,
    # Bytes we believe were freed. 0 = unknown, in which case only stability can end the wait.
    [long]$ExpectedGain = 0,
    [string]$Drive = 'D',
    [int]$TimeoutSec = 60,
    [int]$StableReads = 3,
    [int]$PollMs = 500,
    [int]$MaxPolls = 0,
    [scriptblock]$Reader,
    [scriptblock]$Sleeper
  )

  if (-not $Reader)  { $Reader  = { [System.IO.DriveInfo]::new($Drive).AvailableFreeSpace }.GetNewClosure() }
  if (-not $Sleeper) { $Sleeper = { param($ms) Start-Sleep -Milliseconds $ms } }
  if ($MaxPolls -le 0) { $MaxPolls = [int](($TimeoutSec * 1000) / [Math]::Max($PollMs, 1)) + 1 }

  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  # 90%, not 100%: other things on the box are also writing, so demanding the exact figure would
  # always time out on a busy machine and report every good reclaim as provisional.
  $target   = if ($ExpectedGain -gt 0) { [long]($ExpectedGain * 0.9) } else { 0 }
  $last     = $null
  $stable   = 0
  $now      = $Before
  $reason   = 'timeout'

  for ($i = 0; $i -lt $MaxPolls; $i++) {
    $now = [long](& $Reader)
    if ($null -ne $last -and $now -eq $last) { $stable++ } else { $stable = 0 }
    $last = $now
    $gain = $now - $Before

    if ($target -gt 0 -and $gain -ge $target) { $reason = 'expected'; break }
    # Stability only counts once the figure has actually MOVED - otherwise a volume that has not
    # begun accounting yet looks "stable" at its pre-delete value and we report the stale number
    # with confidence, which is the whole bug.
    if ($gain -gt 0 -and $stable -ge $StableReads) { $reason = 'stable'; break }
    if ((Get-Date) -ge $deadline) { $reason = 'timeout'; break }

    & $Sleeper $PollMs
  }

  [pscustomobject]@{
    Free    = $now
    Gain    = $now - $Before
    Reason  = $reason
    Settled = ($reason -ne 'timeout')
  }
}
