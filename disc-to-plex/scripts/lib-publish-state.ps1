# WHAT "PUBLISHED" MEANS FOR A MULTI-FILE WORK - one definition, used before AND after the copy.
#
# WHY THIS EXISTS
# ---------------
# 2026-09-04, Fight Club. The feature was still encoding while its 5 MB extra
# (`Other/Warning from Tyler Durden.mkv`) finished. publish-work.ps1 does the right thing with a
# partial file - it SKIPS it and publishes the rest, deliberately, so a show being encoded across
# hours still ships its finished episodes. It then printed its honest per-file summary:
#
#     verified 1/1
#
# and _publish-loop.ps1 read that one word `verified` as the WORK being published. It registered
# 'Fight Club' in _awaiting-verification.txt, printed
#
#     *** Fight Club IS PUBLISHED AND THE DISK IS BELOW THE FETCH FLOOR (104.5 GB).
#         Confirm it in Plex so its local copy can be reclaimed - the line is waiting on this.
#
# and audit-space-block.ps1 then asked the operator to confirm a 2.86 GB film of which the NAS held
# nothing but the July original. The claim was true of the FILES THE CHILD CHOSE TO COPY and false
# of the work; `verified N/N` is a ratio over a list the child had already narrowed, so it can never
# fall below 1.0 no matter how much was skipped. That is this project's recurring defect shape: a
# success-shaped message that the failure cannot disturb.
#
# THE DEFINITION. A work is published when EVERY file in its local folder that is ELIGIBLE TO
# TRAVEL has a NAS counterpart at the same relative path, with the same byte length and (within 2 s)
# the same last-write time. Nothing else counts - not a ratio, not an exit code, not a word in a
# child's output. Eligible to travel means exactly what publish-work.ps1 will actually ship:
#
#   - a known library artefact type (lib-artefact-types.ps1) - quarantine litter such as
#     `X.mkv.wrong-length` is never published, so its absence from the NAS is not work to do; and
#   - for a `.subtitles-only` work, ONLY the .srt sidecars - the local .mkv there is scaffolding
#     that exists to give OCR a source and differs from the published media permanently and by
#     design, so comparing it can only ever answer "stale".
#
# The mtime test is not decoration: `Michael J. Fox Interview` was re-encoded from DAR 4:3 to 16:9
# and came out byte-for-byte the SAME SIZE, so size alone would have left the stretched copy on the
# NAS forever. robocopy preserves the source mtime, so a difference means "local changed since it
# was published".
#
# A file still being encoded is OUTSTANDING here, even though publish-work.ps1 is right to skip it.
# The two are not in conflict: "publish what is ready" is a copy policy, "the work is published" is
# a claim about the NAS, and this function only answers the second.

$artefactLib = "$PSScriptRoot/lib-artefact-types.ps1"   # DOUBLE quotes: $PSScriptRoot must expand
if (-not (Test-Path -LiteralPath $artefactLib)) {
  throw "lib-artefact-types.ps1 missing beside lib-publish-state.ps1 ($artefactLib) - refusing to define a publish test that cannot tell an artefact from quarantine litter"
}
. $artefactLib
if (-not (Get-Command Test-LibraryArtefact -ErrorAction SilentlyContinue)) {
  # A dot-source failure is NON-TERMINATING, so without this the function would simply be
  # undefined, every call would write an error and continue, and the filter below would silently
  # pass everything. Same fail-closed discipline as publish-work.ps1's own loads.
  throw 'lib-artefact-types.ps1 failed to load - refusing to define Get-WorkOutstanding unguarded'
}

function Get-WorkOutstanding {
  <#
    .SYNOPSIS
      The files of a work that are NOT yet correctly on the NAS. Empty = the work is published.

    .OUTPUTS
      Zero or more objects: Name (relative path), Reason ('missing' | 'size' | 'timestamp'),
      LocalLength, NasLength.

      RETURNED PLAINLY - NOT as `,$array`. lib-disk.ps1's Get-UnitStageTargets uses the leading-comma
      convention so that a direct assignment keeps an empty result an ARRAY rather than $null, and
      the first version of this function copied it. That convention is WRONG for a function whose
      callers wrap the call in `@(...)`, which is what a count-then-branch caller naturally writes:
      `,$array` emits the array as a SINGLE object, so `@(Get-WorkOutstanding ...).Count` is 1 for
      every non-empty result no matter how many files are outstanding. Caught before the loop was
      bounced onto it, by a read-only simulation over the real library that reported "1 outstanding"
      while printing two outstanding files underneath (Fight Club, 2026-09-04) - a count that would
      have made $landed wrong on every multi-file publish. Emitted plainly, BOTH forms are right:
      `@(f).Count` and `(f).Count` agree at 0, 1 and N. Callers should still write `@(...)`.
  #>
  param(
    [Parameter(Mandatory)][string]$WorkDir,
    [Parameter(Mandatory)][string]$NasDir,
    [int]$TimestampToleranceSeconds = 2
  )

  $outstanding = @()
  if (-not (Test-Path -LiteralPath $WorkDir -PathType Container)) { return $outstanding }

  # Normalise the local root so the relative path arithmetic below is exact. Never .Replace() the
  # whole path: a work whose name happens to appear again deeper in the tree would be rewritten
  # twice.
  $root = (Get-Item -LiteralPath $WorkDir).FullName.TrimEnd([char]92, [char]47)
  $subsOnly = Test-Path -LiteralPath (Join-Path $root '.subtitles-only')

  foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -ErrorAction SilentlyContinue) {
    if ($subsOnly -and $f.Extension -ne '.srt') { continue }
    if (-not (Test-LibraryArtefact -Name $f.Name)) { continue }

    $rel = $f.FullName.Substring($root.Length).TrimStart([char]92, [char]47)
    $t   = Join-Path $NasDir $rel

    if (-not (Test-Path -LiteralPath $t)) {
      $outstanding += [pscustomobject]@{
        Name = $rel; Reason = 'missing'; LocalLength = $f.Length; NasLength = $null }
      continue
    }
    $ti = Get-Item -LiteralPath $t
    if ($ti.Length -ne $f.Length) {
      $outstanding += [pscustomobject]@{
        Name = $rel; Reason = 'size'; LocalLength = $f.Length; NasLength = $ti.Length }
    }
    elseif ([Math]::Abs(($ti.LastWriteTimeUtc - $f.LastWriteTimeUtc).TotalSeconds) -gt $TimestampToleranceSeconds) {
      $outstanding += [pscustomobject]@{
        Name = $rel; Reason = 'timestamp'; LocalLength = $f.Length; NasLength = $ti.Length }
    }
  }
  return $outstanding
}

# ---------------------------------------------------------------------------------------------
# THE CIRCUIT BREAKER - no work may be re-published indefinitely while nothing changes.
#
# WHY (2026-09-04). _publish-loop.ps1's log held 2,166 consecutive
#     Boston Legal   wrong-size copy on NAS -> republishing with -Overwrite
# lines from one morning (2026-09-02 07:21-10:47). The per-publish robocopy logs prove what each
# of those passes did: 1,479 robocopy runs, 1,441 of them copying ZERO bytes, at a median gap of
# 5 seconds - the loop never slept, because the old code took the child's word `verified` as
# "something published" and skipped its idle sleep. The re-publish itself could never succeed:
# the work carried a `.subtitles-only` marker, so the copy shipped only .srt files while the
# pre-check kept comparing the scaffolding .mkv against the NAS's legacy encode. Both halves have
# since been fixed (Get-WorkOutstanding above ignores the scaffolding; the loop now re-measures
# instead of reading the adjective) - but each of those fixes closed ONE way of looping, and the
# loop had already found five (Farscape 274, The Saint 162, Survivors 57, Danger Man, Hustle).
#
# This is the structural answer: a per-work counter of publish attempts that CHANGED NOTHING.
# The measure of "changed nothing" is the outstanding set itself - Get-WorkOutstanding before the
# attempt and after it, fingerprinted. A legitimate publish always changes that set (a file lands,
# or a new one appears), so a growing TV show never trips however many episodes it ships; only an
# attempt that leaves the NAS exactly as it found it counts. After MaxNoProgress such attempts in a
# row the breaker TRIPS and the loop stops invoking the publish for that work. It re-arms by itself
# when the outstanding set changes (a sidecar arrives, the operator replaces a file), because that
# is a new situation; but it also keeps a LIFETIME count of no-progress attempts, and past
# MaxNoProgressLifetime it trips HARD - no re-arm, only a deliberate bounce of the track clears it.
# So a loop that finds a way to churn the fingerprint still cannot attempt more than
# MaxNoProgressLifetime fruitless publishes per process, whatever the bug underneath.
#
# PURE FUNCTIONS OVER A HASHTABLE the caller owns, so the whole policy is testable without a NAS.
# ---------------------------------------------------------------------------------------------

function Get-OutstandingFingerprint {
  # One string that is equal iff two outstanding sets are the same files, reasons and sizes.
  # Sorted, so enumeration order cannot make two identical sets look different. Empty set = ''.
  param([object[]]$Outstanding)
  $items = @($Outstanding | Where-Object { $null -ne $_ })
  if ($items.Count -eq 0) { return '' }
  return ((@($items | ForEach-Object {
    '{0}|{1}|{2}|{3}' -f $_.Name, $_.Reason, $_.LocalLength, $_.NasLength }) | Sort-Object) -join "`n")
}

function New-PublishBreaker {
  param([int]$MaxNoProgress = 5, [int]$MaxNoProgressLifetime = 40)
  if ($MaxNoProgress -lt 1) { throw "MaxNoProgress must be >= 1 (got $MaxNoProgress)" }
  if ($MaxNoProgressLifetime -lt $MaxNoProgress) {
    throw "MaxNoProgressLifetime ($MaxNoProgressLifetime) must be >= MaxNoProgress ($MaxNoProgress)"
  }
  return @{ MaxNoProgress = $MaxNoProgress; MaxNoProgressLifetime = $MaxNoProgressLifetime; Works = @{} }
}

function Get-PublishBreakerWork {
  param($Breaker, [string]$Work)
  if (-not $Breaker.Works.ContainsKey($Work)) {
    $Breaker.Works[$Work] = @{
      Attempts = 0; NoProgress = 0; NoProgressLifetime = 0; LastFingerprint = $null
      Tripped = $false; HardTripped = $false; TrippedAt = $null; SkippedSinceTrip = 0
    }
  }
  return $Breaker.Works[$Work]
}

function Get-PublishBreakerVerdict {
  <#
    BEFORE an attempt. Returns { Allow, State, Skipped }:
      State 'armed'        - attempt away
            'rearmed'      - was tripped, but the outstanding set has changed since; one more go
            'tripped'      - refused: the set is exactly what it was after the last fruitless attempt
            'hard-tripped' - refused for the life of the process
      Skipped is how many passes have been refused since the trip (for throttled reminders).
  #>
  param([Parameter(Mandatory)]$Breaker, [Parameter(Mandatory)][string]$Work,
        [AllowEmptyString()][string]$Fingerprint)
  $w = Get-PublishBreakerWork $Breaker $Work
  if ($w.HardTripped) {
    $w.SkippedSinceTrip++
    return [pscustomobject]@{ Allow = $false; State = 'hard-tripped'; Skipped = $w.SkippedSinceTrip }
  }
  if ($w.Tripped) {
    if ($Fingerprint -ne $w.LastFingerprint) {
      $w.Tripped = $false; $w.NoProgress = 0; $w.SkippedSinceTrip = 0; $w.TrippedAt = $null
      return [pscustomobject]@{ Allow = $true; State = 'rearmed'; Skipped = 0 }
    }
    $w.SkippedSinceTrip++
    return [pscustomobject]@{ Allow = $false; State = 'tripped'; Skipped = $w.SkippedSinceTrip }
  }
  return [pscustomobject]@{ Allow = $true; State = 'armed'; Skipped = 0 }
}

function Register-PublishBreakerAttempt {
  <#
    AFTER an attempt: $Before and $After are the fingerprints around it. Returns
    'ok' | 'tripped' | 'hard-tripped' - the caller reports the latter two LOUDLY.
  #>
  param([Parameter(Mandatory)]$Breaker, [Parameter(Mandatory)][string]$Work,
        [AllowEmptyString()][string]$Before, [AllowEmptyString()][string]$After)
  $w = Get-PublishBreakerWork $Breaker $Work
  $w.Attempts++
  $w.LastFingerprint = $After
  if ($After -eq $Before) { $w.NoProgress++; $w.NoProgressLifetime++ }
  else { $w.NoProgress = 0 }
  if ($w.NoProgressLifetime -ge $Breaker.MaxNoProgressLifetime) {
    $w.HardTripped = $true; $w.Tripped = $true; $w.TrippedAt = Get-Date; $w.SkippedSinceTrip = 0
    return 'hard-tripped'
  }
  if ($w.NoProgress -ge $Breaker.MaxNoProgress) {
    $w.Tripped = $true; $w.TrippedAt = Get-Date; $w.SkippedSinceTrip = 0
    return 'tripped'
  }
  return 'ok'
}

function Write-PublishBreakerRegister {
  # The durable, operator-visible record: one line per tripped work (rewritten whole, so a re-arm
  # drops its line). Always written, header included, so "no file" and "nothing tripped" differ.
  param([Parameter(Mandatory)]$Breaker, [Parameter(Mandatory)][string]$Path)
  $lines = @('# publish circuit breaker - works the publish loop is REFUSING to re-publish (rewritten on every change)')
  $lines += ('# updated {0} | MaxNoProgress={1} MaxNoProgressLifetime={2} | columns: when|work|state|no-progress run|no-progress lifetime|attempts' -f `
    (Get-Date -Format s), $Breaker.MaxNoProgress, $Breaker.MaxNoProgressLifetime)
  foreach ($name in ($Breaker.Works.Keys | Sort-Object)) {
    $w = $Breaker.Works[$name]
    if (-not $w.Tripped) { continue }
    $state = if ($w.HardTripped) { 'HARD-TRIPPED (bounce the publish track to clear)' } else { 'tripped (re-arms when the outstanding set changes)' }
    $when = if ($w.TrippedAt) { $w.TrippedAt.ToString('s') } else { '' }
    $lines += ('{0}|{1}|{2}|{3}|{4}|{5}' -f $when, $name, $state, $w.NoProgress, $w.NoProgressLifetime, $w.Attempts)
  }
  Set-Content -LiteralPath $Path -Value $lines
}
