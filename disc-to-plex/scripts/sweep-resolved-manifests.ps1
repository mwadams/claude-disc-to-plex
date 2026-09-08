<#
.SYNOPSIS
  Archive the manifests in `_queue/failed` whose unit was LATER encoded successfully, so the board
  stops re-explaining them. Report by default; `-Apply` to move. Never deletes.

.WHY THIS EXISTS
  A failed manifest is kept deliberately - it is the evidence of what went wrong, and more than once
  it has been the thing that settled why. But nothing ever clears one once the failure is FIXED, and
  a fix is normal: on 2026-09-08 six manifests failed and were corrected and re-queued within hours
  (an SD extra marked `kind: BD`, an inverted commentary election, a duration window too tight for
  an honest overshoot...). Each leaves a file behind.

  `_stallwatch.ps1` handles them correctly - it works out that a LATER manifest for the same unit
  reached `done\` and prints "the failed/ copy is stale history; nothing to do". But it re-derives
  that on EVERY run, for ever, and prints one line per resolved failure.

  BE ACCURATE ABOUT THE SIZE OF THIS. My first count said "7 of 17 produce such a line", which was
  wrong: grepping for "stale history" also matches the RECLAIM queue's own five stale lines, which
  are a separate mechanism with its own reclaimFailedStale. Only TWO were manifests. The case for
  tidying is not today's volume - it is that the count only ever grows, one per fixed failure, and a
  board whose output is mostly explained noise is a board whose real lines get skimmed. That is the
  crowding-out failure this project has already had once, when error records drowned the OCR gate's
  own output.

.WHY IT READS THE BOARD'S ANSWER INSTEAD OF WORKING IT OUT AGAIN
  "Is this failure resolved?" is subtler than it looks: a retry is deliberately given a NEW name
  (`*.retry.json`, `*.named.json`, `*.playlist.json`) so it cannot collide with what it replaces, so
  comparing filenames finds nothing. The real test is whether any manifest for the same UNIT reached
  `done\` after the newest failed one. `_stallwatch.ps1` already asks exactly that, and now publishes
  the answer as `manifestFailedStale` in its state file - beside `reclaimFailedStale`, which has
  worked this way for the reclaim queue since 2026-09-07.

  So this script does not decide anything. A second implementation of that test would drift from the
  board's, and then either the board keeps reporting what this moved, or - far worse - this moves
  something the board still considers OPEN. Same discipline as the length rule living in one place.

.WHAT IT DOES
  Moves each resolved manifest to `_queue/failed/_resolved/`, which the board does NOT scan (it
  reads `failed/*.json`, not recursively), and writes a `.resolved.txt` beside it recording when it
  was archived and that the board judged it superseded. The file is never deleted: the evidence
  survives, it simply stops being reported as live.

  pwsh -File sweep-resolved-manifests.ps1              # report only
  pwsh -File sweep-resolved-manifests.ps1 -Apply       # archive them
#>
param(
  [string]$Queue     = 'D:/video/_queue',
  [string]$StateFile = 'D:/video/_stallwatch-state.json',
  [switch]$Apply
)
$ErrorActionPreference = 'Stop'
function Say([string]$m) { Write-Output $m }

if (-not (Test-Path -LiteralPath $StateFile)) {
  Say "no board state at $StateFile - run _stallwatch.ps1 first; this script does not judge resolution itself"
  exit 0
}
try { $state = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json }
catch { Say "board state is unreadable: $($_.Exception.Message)"; exit 1 }

# A state file written before the field existed has no property, and `@($null)` is a ONE-element
# array containing $null - the trap that raised a phantom alert when manifestFailed was added.
# Deduplicated: the board's $failed list can name one file twice, so the raw list over-counts.
$stale = @($state.manifestFailedStale | Where-Object { $_ } | Sort-Object -Unique)
# NEVER STRINGIFY A DateTime AND RE-PARSE IT. ConvertFrom-Json already returns `at` as a
# [DateTime]; "$($state.at)" renders it in the CURRENT CULTURE - here "08/09/2026 21:24:38" - and
# [DateTime]::Parse then reads that back as 9 AUGUST. A state file written 18 seconds earlier
# measured as 43,200 minutes old, and this script refused to run. Use the object as it is, and fall
# back to InvariantCulture only when it genuinely arrives as a string.
$age = $null
try {
  $at = if ($state.at -is [datetime]) { $state.at }
        else { [DateTime]::Parse("$($state.at)", [Globalization.CultureInfo]::InvariantCulture) }
  $age = ((Get-Date) - $at).TotalMinutes
} catch { }
if ($null -ne $age -and $age -gt 30) {
  Say ("board state is {0:N0} min old - re-run _stallwatch.ps1 so this acts on a CURRENT answer" -f $age)
  exit 0
}
if (-not $stale.Count) { Say 'no resolved failures to archive'; exit 0 }

$dest = Join-Path $Queue 'failed/_resolved'
Say ("{0} resolved failure(s) the board reports as stale history:" -f $stale.Count)
$moved = 0
foreach ($n in $stale) {
  $src = Join-Path $Queue ('failed/' + $n)
  if (-not (Test-Path -LiteralPath $src -PathType Leaf)) { Say "  (gone already) $n"; continue }
  if (-not $Apply) { Say "  would archive: $n"; continue }
  if (-not (Test-Path -LiteralPath $dest)) { New-Item -ItemType Directory -Path $dest -Force | Out-Null }
  $target = Join-Path $dest $n
  # Never overwrite a previous archive of the same name - two different failures can share one.
  if (Test-Path -LiteralPath $target) {
    $target = Join-Path $dest ([IO.Path]::GetFileNameWithoutExtension($n) + '.' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json')
  }
  Move-Item -LiteralPath $src -Destination $target -Force
  @("archived $(Get-Date -Format 's') by sweep-resolved-manifests.ps1",
    "_stallwatch.ps1 reported this unit's failure as superseded: a LATER manifest for the same unit reached _queue/done.",
    "The file is KEPT as evidence; it is out of _queue/failed so the board stops re-reporting it.") |
    Set-Content -LiteralPath ($target + '.resolved.txt') -Encoding UTF8
  Say "  archived: $n"
  $moved++
}
if (-not $Apply) { Say ''; Say 'report only - re-run with -Apply to archive them'; exit 0 }
Say ("sweep-resolved-manifests: {0} archived to {1}" -f $moved, $dest)
exit 0
