# Report which PIPELINE STAGE is waiting on the OPERATOR, per staged unit.
#
# WHY THIS EXISTS
# ---------------
# `_lanewatch` and `_idlewatch` say that something is idle. They do not say WHICH STEP is blocked,
# and every stall on 2026-08-23 was a specific missing step that only the operator could take:
#
#   - the GPU sat idle 07:57-10:30 because no MANIFEST had been authored
#   - batch 7 made zero progress because no FETCH had been started, twice announced as started
#   - a staged disc sat un-CATALOGUED while its lane was free
#   - a disc had a catalogue but no DISPOSITIONS, so nothing could be manifested
#
# "LANE FREE" was firing throughout and was true but useless: it names a symptom several steps
# downstream of the cause. This names the cause.
#
# The self-draining tracks (encode / OCR / publish) need no prompting - they are loops. The chain
# BEFORE them is all manual:
#
#     fetch -> catalogue -> dispositions -> rip -> analyse -> manifest -> queue
#
# Each staged unit sits at exactly one point in that chain. Print it.
#
# HOLDS: a unit with a `.HOLD` file in its staging folder is deliberately parked (e.g. Mumins,
# awaiting a missing disc) and is reported separately, never as a stall. Put the reason in the file.

param(
  [string]$Stage     = 'D:/video/_stage',
  [string]$Catalogue = 'D:/video/_catalogue',
  [string]$Manifests = 'D:/video/_manifests',
  [string]$Queue     = 'D:/video/_queue',
  [switch]$Quiet          # print nothing when every unit is either busy or held
)

function Test-AnythingRunning {
  $names = 'ffmpeg', 'makemkvcon64', 'robocopy', 'tesseract', 'seconv', 'mkvextract'
  foreach ($n in $names) { if (@(Get-Process $n -ErrorAction SilentlyContinue).Count -gt 0) { return $true } }
  # a catalogue or analysis launched with -File (NOT a shell command that merely mentions the name -
  # that false positive has bitten this project repeatedly; classify by HOW it was launched)
  $procs = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
             Where-Object { $_.CommandLine -and $_.CommandLine -notmatch '\s-Command\s' -and
                            ($_.CommandLine -match 'catalogue-d|analyze-tracks|_fetch-one\.ps1') })
  return ($procs.Count -gt 0)
}

$busy       = Test-AnythingRunning
$queued     = @(Get-ChildItem "$Queue/*.json" -ErrorAction SilentlyContinue).Count
$running    = @(Get-ChildItem "$Queue/running/*.json" -ErrorAction SilentlyContinue).Count
$units      = @(Get-ChildItem $Stage -Directory -ErrorAction SilentlyContinue)
# Only VERIFIED copies appear here - _fetch-one.ps1 writes a line after matching count and bytes.
$fetchDone  = @(Get-Content 'D:/video/_fetch-done.txt' -ErrorAction SilentlyContinue |
                Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })

$stalls = @()
$held   = @()
$moving = @()

foreach ($u in $units) {
  $name = $u.Name

  $hold = Join-Path $u.FullName '.HOLD'
  if (Test-Path -LiteralPath $hold) {
    $why = (Get-Content -LiteralPath $hold -Raw -ErrorAction SilentlyContinue).Trim()
    $held += "{0,-28} HELD - {1}" -f $name, $(if ($why) { $why } else { 'no reason recorded' })
    continue
  }

  # A rip folder (…-x, …-main) is an INTERMEDIATE, not a disc: judge it by whether its analysis and
  # manifest exist, not by whether it has a catalogue.
  $isRip = $name -match '-(x|main|mkv|rip)$'   # mumins1-mkv is a rip folder too - the -x|-main pair did not match reality

  $cat  = Join-Path $Catalogue "$name.catalogue.json"
  $disp = Join-Path $Catalogue "$name.dispositions.txt"

  if (-not $isRip) {
    # STILL COPYING is not a stall - but do NOT prove that by scanning the source drive.
    #
    # The first version compared this unit against E:/Movies recursively, per unit, per tick. E: is
    # a slow USB spindle and this project forbids broad recursive scans of it; the check took so
    # long the monitor never printed. The right signal is already local and free:
    #
    #   _fetch-one.ps1 appends a unit to _fetch-done.txt ONLY after verifying file count AND bytes
    #   against the source. So "is it complete?" is exactly "is it recorded there?".
    #
    # A staged unit absent from that file is either mid-copy or was copied by hand and never
    # verified. Both mean "do not catalogue it yet", and both are reported the same way.
    if ($fetchDone -notcontains $name) {
      $moving += "{0,-28} still COPYING (or never verified) - not yet in _fetch-done.txt" -f $name
      continue
    }

    if (-not (Test-Path -LiteralPath $cat)) {
      # If _catalogue-loop is alive it will sweep this within ~2 minutes, so it is NOT waiting on
      # the operator. Reporting it as a stall would train the reader to ignore this tool, which is
      # exactly how the older monitors lost their value.
      $catLoopAlive = $false
      try {
        $tmp = $null
        $mutexName = 'Global' + [char]92 + 'video-catalogue-loop'
        $catLoopAlive = [System.Threading.Mutex]::TryOpenExisting($mutexName, [ref]$tmp)
        if ($tmp) { $tmp.Dispose() }
      } catch { $catLoopAlive = $false }
      if ($catLoopAlive) {
        $moving += "{0,-28} queued for _catalogue-loop" -f $name
      } else {
        $stalls += "{0,-28} needs CATALOGUE   -> start _catalogue-loop.ps1 (or sweep by hand)" -f $name
      }
      continue
    }
    if (-not (Test-Path -LiteralPath $disp)) {
      $stalls += "{0,-28} needs DISPOSITIONS -> write {1}" -f $name, (Split-Path $disp -Leaf)
      continue
    }
    $unresolved = @(Get-Content -LiteralPath $disp -ErrorAction SilentlyContinue |
                    Where-Object { $_ -match '^t\d\d\|\?\|' })
    if ($unresolved.Count -gt 0) {
      $stalls += "{0,-28} needs IDENTIFICATION - {1} title(s) still '?'" -f $name, $unresolved.Count
      continue
    }
  }

  # Is there a manifest that mentions this unit, and has it been queued or completed?
  #
  # SEARCH THE QUEUE TOO, NOT JUST _manifests. `_gate-queue.ps1` MOVES a manifest out of
  # `_manifests` and into `_queue` - so a unit whose manifest was queued has NO file left in
  # `_manifests`, and searching there alone reported it as "needs MANIFEST". Observed on Julius
  # Caesar and King Lear, both already encoded, with Julius Caesar's sidecar already written.
  #
  # That is the worst kind of false positive for this tool: it names finished work as waiting on
  # the operator, and this monitor's whole value is that its output can be acted on without
  # checking it first. The queue-state reporting below already knew how to describe a queued or
  # completed manifest - it simply never ran, because the search returned nothing.
  # MATCH THE STAGED PATH, NOT THE BARE NAME. A unit can be named `M` (Fritz Lang, 1931), and a
  # bare substring match on one letter hits EVERY manifest containing an "m" - which reported M as
  # having failed four unrelated manifests. Require the name to sit where a staged path puts it:
  # after `_stage/` and followed by a separator or the closing quote.
  $manifestDirs = @("$Manifests/*.json", "$Queue/*.json", "$Queue/running/*.json",
                    "$Queue/done/*.json", "$Queue/failed/*.json")
  $pathRx = '_stage[\\/]' + [regex]::Escape($name) + '(?=["\\/])'
  $mentioned = @(Get-ChildItem $manifestDirs -ErrorAction SilentlyContinue |
                 Where-Object { (Get-Content -LiteralPath $_.FullName -Raw) -match $pathRx })
  if ($mentioned.Count -eq 0) {
    $stalls += "{0,-28} needs MANIFEST     -> author one and drop it in _queue" -f $name
    continue
  }
  # A MANIFEST FILE EXISTING IS NOT THE SAME AS IT BEING QUEUED.
  #
  # This used to report "manifest exists, in the queue" whenever a manifest merely MENTIONED the
  # unit. METROPOLIS sat like that for an hour: its manifest was authored, REFUSED by the evidence
  # gate, and never re-queued - while this tool called it queued. A trigger that misreports a
  # blocked unit as moving is worse than no trigger, because the operator then decides by feel
  # instead of by signal. Report where the manifest ACTUALLY is.
  $inQueue  = @(Get-ChildItem "$Queue/*.json" -ErrorAction SilentlyContinue).Name
  $inRun    = @(Get-ChildItem "$Queue/running/*.json" -ErrorAction SilentlyContinue).Name
  $inDone   = @(Get-ChildItem "$Queue/done/*.json" -ErrorAction SilentlyContinue).Name
  $inFailed = @(Get-ChildItem "$Queue/failed/*.json" -ErrorAction SilentlyContinue).Name
  $mNames   = @($mentioned.Name)
  $failed   = @($mNames | Where-Object { $inFailed -contains $_ })
  $done     = @($mNames | Where-Object { $inDone   -contains $_ })
  $live     = @($mNames | Where-Object { $inQueue -contains $_ -or $inRun -contains $_ })
  $orphan   = @($mNames | Where-Object { $inQueue -notcontains $_ -and $inRun -notcontains $_ -and
                                          $inDone -notcontains $_ -and $inFailed -notcontains $_ })
  if ($failed.Count -gt 0) {
    $stalls += "{0,-28} manifest FAILED the gate or the encode -> {1}" -f $name, ($failed -join ", ")
  } elseif ($orphan.Count -gt 0) {
    $stalls += "{0,-28} manifest AUTHORED BUT NEVER QUEUED -> _gate-queue.ps1 ({1})" -f $name, ($orphan -join ", ")
  } elseif ($live.Count -gt 0) {
    $moving += "{0,-28} in the queue / encoding" -f $name
  } elseif ($done.Count -eq $mNames.Count) {
    $moving += "{0,-28} encoded - awaiting OCR/publish/confirmation" -f $name
  } else {
    $moving += "{0,-28} manifest state unclear - check _queue by hand" -f $name
  }
}

if ($stalls.Count -eq 0 -and $Quiet) { return }

$stamp = Get-Date -Format 'HH:mm:ss'
if ($stalls.Count -gt 0) {
  Write-Output "[$stamp] PIPELINE WAITING ON THE OPERATOR - $($stalls.Count) unit(s):"
  $stalls | ForEach-Object { Write-Output "   $_" }
  # The distinction that matters: is the machine busy anyway, or is EVERYTHING stopped?
  if (-not $busy -and $queued -eq 0 -and $running -eq 0) {
    Write-Output "   *** nothing is encoding, ripping, cataloguing or copying - the line is FULLY STOPPED ***"
  } else {
    Write-Output "   (other work is in flight; these are queued behind it)"
  }
} elseif (-not $Quiet) {
  Write-Output "[$stamp] no unit is waiting on the operator."
}

if ($moving.Count -gt 0 -and -not $Quiet) { $moving | ForEach-Object { Write-Output "   $_" } }
if ($held.Count   -gt 0 -and -not $Quiet) { $held   | ForEach-Object { Write-Output "   $_" } }

# Nothing staged at all, and nothing running, is its own stall: the SOURCE track needs kicking.
if ($units.Count -eq 0 -and -not $busy) {
  Write-Output "[$stamp] NOTHING STAGED and nothing running - start a fetch (_fetch-one.ps1 -Discs <list>)"
}
