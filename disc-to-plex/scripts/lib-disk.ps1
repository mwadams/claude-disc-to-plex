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

<#
.SYNOPSIS
  The ONE authority for "what on-disk paths under _stage belong to this unit" - the raw disc
  folder AND every derived artefact (tracks.json sidecars, per-title evidence, and the
  -rip/-x/-main/-mkv/-reel/-audio slug intermediates).

.WHY THIS EXISTS
  _release-completed.ps1 originally computed this list inline, and _reclaim-loop.ps1 separately
  decided "is this unit already released" by testing ONLY the raw disc folder
  (Test-Path (Join-Path $Stage $unit)) - a second, narrower reimplementation of the same question.
  The two agree whenever a unit's raw folder and its derived artefacts are released together, which
  is most of the time, so the gap went unnoticed until the 13 "Danger Man Series 1964-1968" units:
  their raw `_stage/<unit>` folders were released first (an earlier pass), but each still had a
  `<slug>-rip` intermediate sitting in _stage (~15 GB total). _reclaim-loop.ps1 saw the raw folder
  gone, the unit registered in _completed.txt, and reported "already released" without ever calling
  _release-completed.ps1 - so the -rip folders were never looked at, let alone removed, and the
  artefact still moved to done/ with verdict DONE. This is the exact class of drift ConvertTo-RipSlug
  above already fixed once for slug computation; the fix here is the same shape applied to target
  ENUMERATION: one function, used by both the actual deletion and any "is there anything left"
  pre-check, so there is nothing left to drift.

.THE SLUG IS A CONVENTION, NOT A RECORD - SO A DIRECTORY MAY DECLARE ITS OWN UNIT
  Everything above derives the artefact directory name FROM THE UNIT NAME. That is a convention,
  and rip-titles.ps1 lets the caller override it: `-Dest` names the folder outright, and its
  default (`<disc>.ToLower() + '-mkv'`) only applies when -Dest is absent. Pass a -Dest that does
  not follow the convention and NOTHING on disk records which unit the folder belongs to - the link
  exists only in the head of whoever typed the command.

  That is not hypothetical. `_stage/mumins1-mkv` (7.6 GB) was ripped from `DIE_MUMINS_1` with a
  -Dest named after its MANIFEST (`mumins1`, see _queue/done/mumins1.json). The unit slug is
  `die_mumins_1-mkv`, which never existed, so every enumeration above returned nothing and the
  folder was invisible to `_release-completed.ps1` and `_reclaim-loop.ps1` alike - the Danger Man
  `-rip` class recurring at one remove. It could only be released by inventing a unit called
  "Mumins 1", which the reclaim gate correctly refused as a name the pipeline has never seen.

  NO MATCHER CAN CLOSE THIS. `mumins1` is not derivable from `DIE_MUMINS_1` by any rule that would
  not also reach some other work's staging from a similar name, and a mis-targeted release is the
  one irreversible step in this pipeline. The fix is therefore to RECORD the link at rip time
  rather than re-derive it: rip-titles.ps1 writes a `.unit` marker into every -Dest it creates,
  naming the disc the rip came from. This function honours that marker, under three constraints
  that keep it exact rather than fuzzy:

    1. EXACT NAME MATCH, never substring or prefix - `DIE_MUMINS_1` must not claim
       `DIE_MUMINS_11`'s artefacts. Case-insensitive only, because Windows paths are.
    2. ONLY DIRECT CHILDREN OF $Stage whose name carries one of the known intermediate suffixes
       (-rip/-x/-main/-mkv/-reel/-audio). A marker can therefore only ever redirect WITHIN the
       intermediate namespace; it can never aim a deletion at another unit's RAW disc folder,
       however the -Dest was written.
    3. A DIRECTORY WITH NO MARKER IS NEVER CLAIMED. The default is still the slug convention, so
       nothing that works today changes behaviour.

  The marker is written by the step that creates the directory, so it is a record of what actually
  happened rather than a judgement made later. A marker retro-fitted to a pre-existing folder is a
  CLAIM like any other and must be evidenced the same way (for mumins1-mkv: its 23 rips match
  DIE_MUMINS_1's catalogue titles t01-t23 duration-for-duration in order, and one-to-one onto the
  23 published outputs of mumins1.json) - the marker file carries that reasoning in `#` comments.

.PARAMETER Unit
  The unit/disc name exactly as _completed.txt or the catalogue spells it.

.PARAMETER Stage
  The staging root (normally D:/video/_stage).

.OUTPUTS
  string[] of full paths (directories and/or files) that exist right now for this unit. An empty
  array is the ONLY honest basis for "there is nothing left to release" - it means every location
  this function knows to check was tested and found empty, not merely that the raw folder is gone.
#>
function Get-UnitStageTargets {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)][string]$Unit,
    [Parameter(Mandatory)][string]$Stage
  )
  $unit = $Unit.Trim()
  $dir  = Join-Path $Stage $unit
  $slug = ConvertTo-RipSlug $unit

  $targets = @()
  if (Test-Path -LiteralPath $dir -PathType Container) { $targets += $dir }

  $sidecar = Join-Path $Stage "$unit.tracks.json"
  if (Test-Path -LiteralPath $sidecar) { $targets += $sidecar }

  # Per-title evidence files: assert-tracks-analysed.ps1 keys DVD audio evidence to
  # `<unit>.title<N>.tracks.json` whenever one disc folder is the src of several gated items.
  Get-ChildItem -LiteralPath $Stage -Filter "$unit.title*.tracks.json" -File -ErrorAction SilentlyContinue |
    ForEach-Object { $targets += $_.FullName }

  # '-rip' is the raw rip intermediate; '-x'/'-main'/'-mkv' are transcode-stage intermediates;
  # '-reel' is the per-PROGRAM extraction used to recover a first-cell-truncated title; '-audio' is
  # a per-title audio extraction for analysis. All are named with the slug convention.
  foreach ($suffix in @('-rip', '-x', '-main', '-mkv', '-reel', '-audio')) {
    $ripDir = Join-Path $Stage "$slug$suffix"
    if (Test-Path -LiteralPath $ripDir -PathType Container) { $targets += $ripDir }
  }

  # ARTEFACT DIRECTORIES THAT DECLARE THEIR OWN UNIT - see the header section on the slug being a
  # convention rather than a record. Deliberately narrow: an intermediate-suffixed direct child of
  # $Stage, carrying a `.unit` marker whose named unit EQUALS this one. Anything looser could aim a
  # deletion at work this unit has nothing to do with.
  foreach ($cand in @(Get-ChildItem -LiteralPath $Stage -Directory -ErrorAction SilentlyContinue |
                      Where-Object { $_.Name -match '-(rip|x|main|mkv|reel|audio)$' })) {
    if ($targets -contains $cand.FullName) { continue }   # already found by the slug convention
    $marker = Join-Path $cand.FullName '.unit'
    if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { continue }
    # First non-empty, non-'#' line is the unit name; the rest of the file is free-text provenance,
    # the same shape as a dispositions file. A marker naming nothing claims nothing.
    $claim = @(Get-Content -LiteralPath $marker -ErrorAction SilentlyContinue |
               ForEach-Object { $_.Trim() } |
               Where-Object { $_ -and -not $_.StartsWith('#') }) | Select-Object -First 1
    if ($claim -and [string]::Equals("$claim", $unit, [System.StringComparison]::OrdinalIgnoreCase)) {
      $targets += $cand.FullName
    }
  }

  return ,$targets
}
