<#
.SYNOPSIS
  Report every published show whose Season 00 (Specials) still carries AGENT titles instead of
  our filename titles — i.e. every show where `fix-plex-extras.ps1` has not been run.

.WHY THIS EXISTS
  This is step 6 of the per-unit gate and it is the step that keeps getting skipped, because it
  falls due LATE — after the encode, after the OCR, after the publish, after attention has moved
  to the next disc. The user has had to ask for it by name repeatedly (Gangsters 2026-08-20, and
  again for Pulling). Writing "always run fix-plex-extras.ps1" into the batch notes did not work;
  it was written there twice and skipped anyway. So it becomes a CHECK instead of a reminder.

  What it catches: the Plex TV agent relabels Season 00 by INDEX against its own specials list,
  so it confidently renames our extras to whatever its list holds, or to a bare "Episode N".
  Gangsters S00E02 sat as "Episode 2" instead of "Popular Culture" until the user noticed —
  and S00E01 happened to match by luck, which is precisely what makes the gap easy to miss.

  A title is considered UNFIXED when either:
    - it is not LOCKED (the agent can and will overwrite it on the next refresh), or
    - it reads as a placeholder ("Episode 7"), or
    - it disagrees with the title token in its own filename.

.EXAMPLE
  pwsh -File audit-season00-titles.ps1
  pwsh -File audit-season00-titles.ps1 -Show Pulling
  pwsh -File audit-season00-titles.ps1 -Quiet     # one line per offending show, for a monitor
#>
param(
  [string]$Show,                 # optional substring filter
  [int]$Section = 5,
  [switch]$Quiet,                # print only the summary lines (for _idlewatch)
  # Only examine shows Plex has touched in the last N days. A full-library pass costs one HTTP
  # round-trip PER SEASON-00 ITEM (the locked-field list exists nowhere else), which is far too
  # slow to run on a monitor tick. Recently-updated is exactly the set that matters: a show whose
  # extras were fixed months ago does not silently un-fix itself. 0 = no filter (full audit).
  [int]$SinceDays = 0
)
$ErrorActionPreference = 'Stop'

function Env-Fallback($name){
  $v = [Environment]::GetEnvironmentVariable($name,'Process')
  if (-not $v) { $v = [Environment]::GetEnvironmentVariable($name,'User') }
  $v
}
$tok  = Env-Fallback 'PLEX_TOKEN'
$base = Env-Fallback 'PLEX_BASEURL'
if (-not $tok -or -not $base) { throw "PLEX_TOKEN / PLEX_BASEURL not set (User or Process env)." }

# Deliberately NO `Accept: application/json` header. With it, the single-item endpoint
# (/library/metadata/<rk>) returns a container this client parses to $null, so the per-item
# read - which is the only place the LOCKED-field list lives - silently yields nothing. The
# default XML shape works for every endpoint used here: .Directory for shows/seasons,
# .Video for episodes, and .Video.Field for the locked fields.
function Plex-Get([string]$path){
  (Invoke-RestMethod -Uri ("{0}{1}{2}X-Plex-Token={3}" -f $base, $path, $(if($path -match '\?'){'&'}else{'?'}), $tok)).MediaContainer
}

# Title token as WE write it: "<Show> (<year>) - S00E04 - Secrets of Quark's Bar.mkv" -> the tail.
# A file with no title token cannot be judged, so it is reported separately rather than as a fault.
function Title-FromFile([string]$name){
  $stem = [IO.Path]::GetFileNameWithoutExtension($name)
  if ($stem -match '\sS\d{2}E\d{2}\s-\s(.+)$') { return $Matches[1].Trim() }
  return $null
}
function Norm([string]$s){
  if (-not $s) { return '' }
  ($s -replace '[^\w]', '').ToLowerInvariant()
}

$shows = @((Plex-Get "/library/sections/$Section/all").Directory)
if ($Show) { $shows = @($shows | Where-Object { $_.title -like "*$Show*" }) }
if ($SinceDays -gt 0) {
  $cutoff = [DateTimeOffset]::UtcNow.AddDays(-$SinceDays).ToUnixTimeSeconds()
  $shows = @($shows | Where-Object { $_.updatedAt -and [long]$_.updatedAt -ge $cutoff })
}

$offenders = 0
foreach ($s in $shows) {
  $seasons = @((Plex-Get "/library/metadata/$($s.ratingKey)/children").Directory)
  $s00 = $seasons | Where-Object { $_.index -ne $null -and [int]$_.index -eq 0 }
  if (-not $s00) { continue }

  $eps = @((Plex-Get "/library/metadata/$($s00.ratingKey)/children").Video)
  $bad = @(); $notes = @(); $unver = @()
  foreach ($e in $eps) {
    # per-item fetch: the bulk listing omits the Field[] that says which fields are LOCKED
    $full = (Plex-Get "/library/metadata/$($e.ratingKey)").Video
    $locked = @($full.Field | Where-Object { $_.name -eq 'title' }).Count -gt 0
    $file   = @($full.Media.Part | ForEach-Object { Split-Path $_.file -Leaf })[0]
    $want   = Title-FromFile $file
    # 🔴 "NOT LOCKED" IS NOT A FAULT ON ITS OWN — and treating it as one is dangerous.
    # A Season 00 does not always hold extras. In the tvdbAiring tree Spartacus's season 0 is
    # *Gods of the Arena*, six REAL episodes with correct agent titles and summaries, simply not
    # locked because nothing needed to override them. This audit's first version reported all six
    # as "run fix-plex-extras.ps1", which would have cleared six real episodes' summaries and
    # replaced their artwork with random frames. fix-plex-extras.ps1 carries the same warning.
    #
    # So only two things count as faults, and both mean "Plex disagrees with the file we shipped":
    #   - a placeholder title ("Episode 7"), which the agent invents for slots it cannot name
    #   - a title that contradicts the title token in its own filename
    # An unlocked-but-correct title is reported only as a NOTE, and never triggers the alarm.
    $reason = $null
    if ($full.title -match '^Episode\s+\d+$')               { $reason = "placeholder '$($full.title)'" }
    elseif ($want -and (Norm $want) -ne (Norm $full.title))  { $reason = "'$($full.title)' != file '$want'" }
    if ($reason) { $bad += "S00E{0:D2} {1}" -f [int]$full.index, $reason }
    # 🔴 A CONFIDENTLY-WRONG AGENT TITLE IS INVISIBLE TO BOTH TESTS ABOVE.
    # When the filename carries no title token there is nothing to contradict, and a name the agent
    # invented is not a placeholder — so it passes silently. The West Wing shipped 14 extras of
    # 31 s–9 min; the agent had labelled the first four after canonical specials that run 45–64 min
    # (*Isaac and Ishmael*, *Documentary Special*, *The Debate*, …). The audit called them OK.
    # Duration is what exposes it, so report these separately WITH the runtime rather than as a
    # fault — a hard fault here would re-create the Spartacus false positive, where season 0 holds
    # six REAL episodes whose agent titles are correct.
    elseif (-not $want) {
      $mins = if ($full.duration) { [math]::Round([double]$full.duration / 60000, 1) } else { $null }
      $unver += "S00E{0:D2} '{1}'{2}" -f [int]$full.index, $full.title,
                $(if ($null -ne $mins) { " [{0} min]" -f $mins } else { '' })
    }
    elseif (-not $locked) { $notes += "S00E{0:D2} '{1}' not locked (title agrees with the file)" -f [int]$full.index, $full.title }
  }

  if ($bad.Count) {
    $offenders++
    "{0}: {1} of {2} Season 00 item(s) need fix-plex-extras.ps1" -f $s.title, $bad.Count, $eps.Count
    if (-not $Quiet) { $bad | ForEach-Object { "    $_" } }
  }
  if ($unver.Count -and -not $Quiet) {
    "{0}: {1} of {2} item(s) UNVERIFIED - agent title, filename carries none. Check the runtime is credible for that title." -f $s.title, $unver.Count, $eps.Count
    $unver | ForEach-Object { "    $_" }
  }
  if (-not $bad.Count -and $notes.Count -and -not $Quiet) {
    "{0}: OK ({1} unlocked but matching - no action; may be REAL episodes at season 0)" -f $s.title, $notes.Count
  }
}

if ($offenders -eq 0) { if (-not $Quiet) { 'All Season 00 titles are set and locked.' } }
else { "$offenders show(s) need fix-plex-extras.ps1" }
