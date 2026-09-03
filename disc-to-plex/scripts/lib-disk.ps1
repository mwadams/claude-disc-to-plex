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

    # STABILITY IS NOT ENOUGH WHEN WE KNOW WHAT WAS REMOVED.
    #
    # This first required only that the figure had MOVED before accepting a plateau. That is too
    # weak, and it shipped a wrong number on the very first real use: reclaiming 83.22 GB of library
    # files, the volume ticked up a few MB, held flat for the three reads, and the caller reported
    # "free on D: 116.4 GB" as settled fact. The true figure once accounting finished was 199.7 GB.
    #
    # A large delete does not free space smoothly - it climbs in bursts with PLATEAUS between them,
    # and an early plateau is indistinguishable from the end state by shape alone. So when
    # ExpectedGain is known, only reaching it counts; a plateau short of it keeps waiting and, if
    # the wait runs out, the caller is told the figure is provisional. Stability remains the only
    # available signal when the caller cannot say how much it removed.
    if ($target -le 0 -and $gain -gt 0 -and $stable -ge $StableReads) { $reason = 'stable'; break }
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

<#
.SYNOPSIS
  The ONE authority for turning a unit name (as _completed.txt / the catalogue spell it) into the
  slug _rip-loop.ps1 actually uses for its rip-intermediate folder name.

.WHY THIS EXISTS
  _rip-loop.ps1 builds its rip-folder name with exactly:

      $disc.ToLower().Replace(' ', '') + '-rip'

  - lowercase, and remove SPACES ONLY. Every other character in the name (hyphens, colons,
  apostrophes, ...) survives unchanged. At least four consumers had independently re-derived that
  same slug using `($unit -replace '[^A-Za-z0-9]', '').ToLowerInvariant()` instead - strip ALL
  punctuation, not just spaces - on the belief, stated in their own comments, that this was "how
  _rip-loop.ps1 names it". The two transformations agree whenever a name has no punctuation besides
  spaces, which is most of the time, so the divergence went unnoticed for months.

  It surfaced on 2026-09-02: "Danger Man Series 1964-1968 Disk 1" ... "Disk 13" are all confirmed in
  _completed.txt, but their `-rip` intermediates kept the hyphen in "1964-1968"
  (dangermanseries1964-1968disk1-rip) while _release-completed.ps1's guessed slug stripped it
  (dangermanseries19641968disk1-rip) - a path that never existed, so the derived-artefact cleanup
  silently matched nothing. 13 folders, ~15 GB, stranded with no error from any run.

  ONE function, used everywhere a rip-slug is computed, makes that class of drift structurally
  impossible instead of merely documented. If _rip-loop.ps1's own naming ever changes, this is the
  only other place that needs to change with it.

.PARAMETER Name
  The unit/disc name exactly as _completed.txt or the catalogue spells it.
#>
function ConvertTo-RipSlug {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$Name)
  $Name.ToLowerInvariant().Replace(' ', '')
}
