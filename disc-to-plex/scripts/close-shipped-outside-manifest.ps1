<#
.SYNOPSIS
  Close out a disc whose one shippable item reached the library by a route OTHER than a manifest,
  as a positive, evidenced assertion - never as a licence to release the raw staging.

.WHY THIS EXISTS
  close-ships-nothing.ps1 closes discs where the correct answer is "nothing here is worth
  shipping". Survivors Series 2 Disk 4 (2026-09-03) is a different shape entirely: fully
  dispositioned, assert-accounted -RequireEvidence exit 0, all 8 MakeMKV/dvdvideo titles either
  already published or identified boilerplate - AND its one genuinely new item, a photo gallery,
  is authored as 20 STILL MENUS in the MENU domain (VTS_01 menu PGCs, not a title). transcode.ps1
  encodes from `-f dvdvideo -title N`, and a menu PGC has no such N, so NO MANIFEST COULD EVER
  PRODUCE IT. The gallery was carved by dvd-still-cells.py --menu and published by
  _publish-loop.ps1, which is filesystem-driven, not manifest-driven. So _stallwatch.ps1 reported
  "needs MANIFEST" forever - a permanent false positive, same family as the ships-nothing gap, but
  the WRONG record: ships-nothing.json asserts nothing on the disc was worth shipping, and this
  disc shipped something. Writing a false ships-nothing here would be exactly the laundering that
  record's own required-verdict check exists to prevent.

.THE CRITICAL DIFFERENCE FROM close-ships-nothing.ps1 - READ BEFORE CHANGING EITHER SCRIPT
  A ships-nothing disc can be released with zero information cost: by definition nothing on it was
  worth keeping, so close-ships-nothing.ps1 can afford to stay neutral about release ("deletes
  nothing and confirms nothing... releasing still goes through the existing reclaim track").
  A shipped-outside-manifest disc is NOT that: its raw staging may be the ONLY place the shipped
  item could ever be re-derived from, because it shipped by a route the normal gates (assert-
  accounted, _release-completed.ps1) know nothing about. assert-accounted.ps1 has no concept of a
  menu PGC - it only ever validates MakeMKV/dvdvideo TITLES - so it will happily exit 0 and print
  "Raw staging may be released" for a disc holding an unrebuildable menu-domain item. That generic
  line is a FALSE ASSURANCE for exactly this class of disc, and it is the danger this script exists
  to close off, not merely document:

    - the RECORD never says the staging is releasable (contrast close-ships-nothing.ps1's silence,
      which is safe there and would NOT be safe here);
    - _stallwatch.ps1's board line for this record type never uses ships-nothing's "staging
      releases via a user-confirmed reclaim artefact" wording - that phrase is only true when
      nothing came from the disc;
    - _release-completed.ps1 REFUSES BY DEFAULT when a *.shipped-outside-manifest.json record exists
      beside the unit's dispositions - never as a side effect of confirming Plex.

.TWO CLAIMS, ONLY ONE OF WHICH JUSTIFIES REFUSING RELEASE (2026-09-03)
  The refusal above was originally unconditional, and that conflated two separate claims:

    "NO MANIFEST CAN PRODUCE IT"  - a statement about the MANIFEST FORMAT. Permanently true for a
                                    menu-domain PGC (no `-f dvdvideo -title N` reaches it) and for
                                    a set whose reading order is a permutation of its sector order
                                    (no manifest field reorders cells within a carve).
    "THE SOURCE IS UNAVAILABLE"   - a statement about the DRIVE. Contingent, and checkable.

  Only the SECOND justifies an unconditional refusal. Edge of Darkness Disk 1 and Survivors Series
  2 Disk 4 both hold permanently true findings of the first kind - and both source discs were still
  sitting on E: byte-for-byte, so a re-fetch plus the same carve commands reproduces the shipped
  items exactly. There, the staging was buying CONVENIENCE, not content, at the price of ~18 GB of
  NVMe against a fetch floor. The right test at release time is whether the source disc is
  REACHABLE, which is a question about the drive, not about the manifest.

  So the record carries an OPTIONAL, per-record opt-out:

    stagingReleaseAuthorised = { authorisedBy, authorisedAt, because,
                                 sourceDisc = { path, files, bytes, measuredAt,
                                                stagedFiles, stagedBytes, matchedStaging },
                                 recheckAtRelease, scopeNote }

  written ONLY by scripts/authorise-staging-release.ps1, which refuses unless the named source
  exists AND matches the staging on file count and total bytes. _release-completed.ps1 honours it
  for that unit alone and RE-MEASURES the source itself, so a detached drive or an altered copy
  turns the refusal back on by itself. A record WITHOUT the field refuses exactly as before, and
  there is no flag on the release script that changes that: the default is refuse.

  THE RECORD IS NEVER DELETED TO UNBLOCK A RELEASE. Its other function is permanent - without it
  _stallwatch.ps1 reports "needs MANIFEST" for the disc forever, a false positive no manifest can
  ever clear - and deleting it would also destroy the finding. That is why the opt-out is a field.

.WHAT IT REFUSES
  1. No dispositions file                    -> nobody has looked; closure would be a default.
  2. -Because too short (<30 chars)           -> must actually say why no manifest could ship it.
  3. The dispositions never carry the marker. Must contain the literal phrase (case-insensitive)
     "SHIPPED VIA NON-MANIFEST ROUTE" - the analyst's finding, not the closer's say-so, same
     discipline as close-ships-nothing.ps1's "NOTHING (IS) WORTH SHIPPING" requirement.
  4. A .authoring / .dispositioning marker is live in _pending -> an agent is mid-work; racing it.
  5. ANY manifest (in _manifests, _pending, _queue, running/, done/, failed/) references the disc's
     staged path or a rip slug of it -> contradiction; a disc with a manifest ships through the
     normal route (publish -> confirm -> reclaim), never through this.
  6. assert-accounted.ps1 -RequireEvidence does not exit 0 -> the accounting itself is not done.
  7. -NasPath does not exist on disk, or -NasBytes does not match the file actually found there ->
     the "where it now lives" claim must be checkable, not merely asserted.

.THE RECORD
  <CatalogueDir>/<disc>.shipped-outside-manifest.json - names the ShippedItem, the Route it took
  (free text: which tool, which PGCs/domain, which loop published it), the verified NasPath/bytes/
  sha256, the -Because rationale, the verdict line quoted from the dispositions, and the SHA256 of
  the dispositions file it was judged from (re-hashed by _stallwatch.ps1 on every pass, same
  staleness detection as ships-nothing.json). It carries an explicit `releaseNotice` field stating
  plainly that this record is not a release licence - so a reader of the JSON alone, not just this
  script's prose, sees the caveat.

.EXAMPLE
  pwsh -NoProfile -File close-shipped-outside-manifest.ps1 -Disc 'Survivors Series 2 Disk 4' `
    -ShippedItem 'Survivors - S00E17 - Publicity Stills - Series 2.mkv' `
    -Route 'dvd-still-cells.py --menu carved 20 still-menu I-frames (VTS_01 menu PGCs 12-31) directly from the staged VIDEO_TS; built into a slideshow; published by _publish-loop.ps1 (filesystem-driven)' `
    -NasPath '\\NASTEAMV\Multimedia\Television Shows\Survivors\Season 00\Survivors - S00E17 - Publicity Stills - Series 2.mkv' `
    -Because 'the gallery is authored as 20 still MENUS in the menu domain (VTS_01 PGCs 12-31), absent from TT_SRPT and invisible to MakeMKV at any --minlength, so -f dvdvideo -title N can never reach it and no manifest could ever be authored for it'

.EXIT CODES
  0 = closed (or already closed against identical dispositions)   2 = refused
#>
param(
  [Parameter(Mandatory)][string]$Disc,
  [Parameter(Mandatory)][string]$ShippedItem,
  [Parameter(Mandatory)][string]$Route,
  [Parameter(Mandatory)][string]$NasPath,
  [Parameter(Mandatory)][string]$Because,
  [string]$CatalogueDir = 'D:/video/_catalogue',
  [string]$Stage        = 'D:/video/_stage',
  [string]$Manifests    = 'D:/video/_manifests',
  [string]$Pending      = 'D:/video/_pending',
  [string]$Queue        = 'D:/video/_queue',
  # Optional Plex cross-check - never required (Plex being unreachable must not block a closure
  # whose primary evidence is the NAS file itself), but when given and Plex IS reachable, a title
  # that does NOT match is a real contradiction and refuses the same as false disc evidence does.
  [string]$PlexShow,
  [int]$PlexSeason = -1,
  [string]$PlexEpisodeTitle,
  [string]$PlexBaseUrl = $env:PLEX_BASEURL,
  [string]$PlexToken   = $env:PLEX_TOKEN,
  # Rewrite an existing record after the dispositions legitimately changed. Never the default.
  [switch]$Force
)
$ErrorActionPreference = 'Stop'

$discName = Split-Path $Disc -Leaf
$dispPath = Join-Path $CatalogueDir "$discName.dispositions.txt"
$recPath  = Join-Path $CatalogueDir "$discName.shipped-outside-manifest.json"

# ---- 1. dispositions must exist ---------------------------------------------------------------
if (-not (Test-Path -LiteralPath $dispPath)) {
  Write-Output "REFUSE  $discName - no dispositions file at $dispPath"
  Write-Output 'A closure is a POSITIVE assertion; with no dispositions, nobody has looked.'
  exit 2
}

# ---- 2. the WHY must be substantive -------------------------------------------------------------
if ("$Because".Trim().Length -lt 30) {
  Write-Output 'REFUSE  -Because must actually say why no manifest could ship this (>= 30 chars).'
  exit 2
}

# ---- 3. the ANALYSIS must carry the verdict - in the dispositions, or in a hash-pinned sidecar ----
# Same rule and same sidecar as close-ships-nothing.ps1 (see its check 3): the dispositions may be
# written before the item shipped by its other route (Quatermass Disks 1-2, 2026-09-04: the
# dispositions proposed the production notes; they were built and published hours later), and a
# closed, hashed dispositions file is never edited after the fact. The manifest agent that judged
# them writes <disc>.closure-verdict.txt with the verdict line and the dispositionsSha256 it judged;
# a sidecar whose hash no longer matches the file is STALE and refused.
$dispRaw = Get-Content -LiteralPath $dispPath -Raw
$dispSha = (Get-FileHash -LiteralPath $dispPath -Algorithm SHA256).Hash
# 🔴 ANCHORED - see the same note in close-ships-nothing.ps1 and _dispositions-loop.ps1. As a
# free-floating substring match this fired on the DISPOSITION BRIEF TEMPLATE'S OWN prose -
#     "#    ...Once shipped by whatever non-manifest route the orchestrator uses, this becomes
#      SHIPPED VIA NON-MANIFEST ROUTE."
# - which every disc built from that template carries, so every such disc escalated for validation
# and stopped the line. Two were stalled that way on 2026-09-04/05. Keep all three identical.
$verdictRx = '(?im)^[ \t]*#?[ \t]*SHIPPED\s+VIA\s+NON-MANIFEST\s+ROUTE\s*([:.].*)?$'
$verdictLines = @([regex]::Matches($dispRaw, $verdictRx) | ForEach-Object { $_.Value.Trim() })
$verdictSource = 'dispositions'
$sidecarPath = Join-Path $CatalogueDir "$discName.closure-verdict.txt"
if ($verdictLines.Count -eq 0 -and (Test-Path -LiteralPath $sidecarPath)) {
  $scRaw = Get-Content -LiteralPath $sidecarPath -Raw
  $scLines = @([regex]::Matches($scRaw, $verdictRx) | ForEach-Object { $_.Value.Trim() })
  $scShaM = [regex]::Match($scRaw, '(?im)^\s*dispositionsSha256:\s*([0-9A-Fa-f]{64})\s*$')
  $scSha = if ($scShaM.Success) { $scShaM.Groups[1].Value.ToUpperInvariant() } else { '' }
  if ($scLines.Count -eq 0) {
    Write-Output "REFUSE  $discName - a closure-verdict sidecar exists but does not state SHIPPED VIA NON-MANIFEST ROUTE: $sidecarPath"
    Write-Output '(If it states NOTHING IS WORTH SHIPPING, the disc closes through close-ships-nothing.ps1 instead.)'
    exit 2
  }
  if ($scSha -ne $dispSha.ToUpperInvariant()) {
    Write-Output "REFUSE  $discName - the closure-verdict sidecar is STALE: it judged dispositions $(if ($scSha) { $scSha.Substring(0, 12) } else { '<no dispositionsSha256 line>' }) but the file is now $($dispSha.Substring(0, 12))."
    Write-Output 'Re-read the dispositions and write the verdict again against the current file, or delete the sidecar.'
    exit 2
  }
  $verdictLines = $scLines
  $verdictSource = "closure-verdict sidecar ($sidecarPath)"
}
if ($verdictLines.Count -eq 0) {
  Write-Output "REFUSE  $discName - the dispositions never state the verdict."
  Write-Output 'The analysis that examined the disc must write "SHIPPED VIA NON-MANIFEST ROUTE"'
  Write-Output '(with its reasoning) into the dispositions file, or the manifest agent that judged'
  Write-Output "them must write it into $discName.closure-verdict.txt beside them with the"
  Write-Output 'dispositionsSha256 it judged. This script records that finding; it does not substitute for it.'
  exit 2
}

# ---- 4. nobody is mid-work on this disc ----------------------------------------------------------
foreach ($marker in @('.authoring', '.dispositioning')) {
  $m = Join-Path $Pending ($discName + $marker)
  if (Test-Path -LiteralPath $m) {
    Write-Output "REFUSE  $discName - $($discName + $marker) is live in _pending: an agent is working this disc right now."
    exit 2
  }
}

# ---- 5. NO manifest may reference the disc, anywhere in the manifest lifecycle -------------------
# Same path-anchored regex family as _stallwatch.ps1 / close-ships-nothing.ps1 / _release-completed.ps1.
$manifestDirs = @("$Manifests/*.json", "$Pending/*.json", "$Queue/*.json", "$Queue/running/*.json",
                  "$Queue/done/*.json", "$Queue/failed/*.json")
$slug = ($discName -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
$rxes = @('_stage[\\/]' + [regex]::Escape($discName) + '(?=["\\/])')
foreach ($sfx in @('-rip', '-x', '-main', '-mkv')) {
  $rxes += ('_stage[\\/]' + [regex]::Escape($slug + $sfx) + '(?=["\\/])')
}
$referencing = @(Get-ChildItem $manifestDirs -ErrorAction SilentlyContinue | Where-Object {
  $raw = Get-Content -LiteralPath $_.FullName -Raw -ErrorAction SilentlyContinue
  foreach ($rx in $rxes) { if ($raw -match $rx) { return $true } }
  $false
})
if ($referencing.Count -gt 0) {
  Write-Output ("REFUSE  {0} - {1} manifest(s) reference this disc: {2}" -f `
                $discName, $referencing.Count, (($referencing | ForEach-Object { $_.FullName }) -join ', '))
  Write-Output 'A disc with a manifest ships through the normal route: publish, user confirms, reclaim.'
  exit 2
}

# ---- 6. the accounting gate must pass, with evidence required ------------------------------------
# Invoke directly and read $LASTEXITCODE in the next statement - NEVER through a pipe.
$assert = Join-Path $PSScriptRoot 'assert-accounted.ps1'
if (-not (Test-Path -LiteralPath $assert)) {
  Write-Output 'REFUSE  assert-accounted.ps1 is missing beside this script - cannot verify the accounting.'
  exit 2
}
$assertOut = @(& pwsh -NoProfile -File $assert -Disc $Disc -RequireEvidence 2>&1 | ForEach-Object { "$_" })
$assertExit = $LASTEXITCODE
if ($assertExit -ne 0) {
  Write-Output "REFUSE  $discName - assert-accounted.ps1 -RequireEvidence exited $assertExit; the disc is not accounted for."
  $assertOut | Select-Object -Last 12 | ForEach-Object { Write-Output "        | $_" }
  exit 2
}

# ---- 7. the shipped item's location must be CHECKABLE, not merely asserted -----------------------
if (-not (Test-Path -LiteralPath $NasPath)) {
  Write-Output "REFUSE  $discName - -NasPath does not exist: $NasPath"
  Write-Output 'Name where the item ACTUALLY lives, not where it is meant to end up.'
  exit 2
}
$nasItem  = Get-Item -LiteralPath $NasPath
$nasBytes = $nasItem.Length
$nasSha   = (Get-FileHash -LiteralPath $NasPath -Algorithm SHA256).Hash

# ---- optional: cross-check Plex, never a hard requirement for reachability -----------------------
$plexCheck = [ordered]@{ checked = $false }
if ($PlexShow -and $PlexEpisodeTitle) {
  if (-not $PlexToken -or -not $PlexBaseUrl) {
    Write-Output "NOTE    Plex cross-check requested but PLEX_TOKEN/PLEX_BASEURL not available - skipping (not required)."
    $plexCheck.checked = $false
    $plexCheck.skippedReason = 'no token/baseurl'
  } else {
    try {
      $h = @{ 'X-Plex-Token' = $PlexToken; 'Accept' = 'application/json' }
      function Get-MCLocal($path) { (Invoke-RestMethod ($PlexBaseUrl.TrimEnd('/') + $path) -Headers $h).MediaContainer }
      $secs = (Get-MCLocal '/library/sections').Directory | Where-Object { $_.type -eq 'show' }
      $showObj = $null
      foreach ($s in $secs) {
        $hit = (Get-MCLocal "/library/sections/$($s.key)/all?type=2").Metadata | Where-Object { $_.title -match [regex]::Escape($PlexShow) }
        if ($hit) { $showObj = $hit | Select-Object -First 1; break }
      }
      if (-not $showObj) { throw "show matching '$PlexShow' not found" }
      $seasons = (Get-MCLocal "/library/metadata/$($showObj.ratingKey)/children").Metadata
      $season = if ($PlexSeason -ge 0) { $seasons | Where-Object { $_.index -eq $PlexSeason } } else { $null }
      if (-not $season) { throw "season $PlexSeason not found under '$($showObj.title)'" }
      $eps = (Get-MCLocal "/library/metadata/$($season.ratingKey)/children").Metadata
      $ep = $eps | Where-Object { $_.title -eq $PlexEpisodeTitle } | Select-Object -First 1
      if (-not $ep) { throw "episode '$PlexEpisodeTitle' not found in Season $PlexSeason of '$($showObj.title)'" }
      $full = (Invoke-RestMethod ("$($PlexBaseUrl.TrimEnd('/'))/library/metadata/$($ep.ratingKey)") -Headers $h).MediaContainer.Metadata
      $titleLocked = @($full.Field | Where-Object { $_.name -eq 'title' -and $_.locked }).Count -gt 0
      $plexCheck.checked        = $true
      $plexCheck.show           = $showObj.title
      $plexCheck.season         = $season.index
      $plexCheck.ratingKey      = $ep.ratingKey
      $plexCheck.episodeTitle   = $full.title
      $plexCheck.titleLocked    = $titleLocked
      $plexCheck.partFile       = $full.Media.Part.file
      $plexCheck.partSize       = $full.Media.Part.size
      $plexCheck.durationMs     = $full.duration
      if ([long]$full.Media.Part.size -ne [long]$nasBytes) {
        Write-Output ("REFUSE  {0} - Plex's Media.Part.size ({1}) does not match the NAS file's actual size ({2})" -f $discName, $full.Media.Part.size, $nasBytes)
        exit 2
      }
      Write-Output ("Plex check OK - {0} S{1:D2}E{2} '{3}' (ratingKey={4}), title.locked={5}" -f `
                    $showObj.title, $season.index, $ep.index, $full.title, $ep.ratingKey, $titleLocked)
    } catch {
      Write-Output "REFUSE  $discName - Plex cross-check was attempted and FAILED: $($_.Exception.Message)"
      Write-Output 'A requested check that fails is a contradiction, not an absence - fix the claim or drop -PlexShow/-PlexEpisodeTitle to skip it.'
      exit 2
    }
  }
} else {
  Write-Output "NOTE    no -PlexShow/-PlexEpisodeTitle given - closing on NAS file evidence alone."
}

# ---- existing record: idempotent when nothing changed, refuse-by-default when it has -------------
if ((Test-Path -LiteralPath $recPath) -and -not $Force) {
  $old = $null
  try { $old = Get-Content -LiteralPath $recPath -Raw | ConvertFrom-Json } catch { }
  if ($old -and $old.dispositionsSha256 -eq $dispSha -and $old.nasSha256 -eq $nasSha) {
    Write-Output "already closed: $discName shipped outside the manifest (record of $($old.closedAt) matches the current dispositions and NAS file)"
    exit 0
  }
  Write-Output "REFUSE  $discName - a shipped-outside-manifest record exists but the dispositions or the NAS file have CHANGED since it was written."
  Write-Output 'Re-read both, and re-close with -Force only if the finding still holds.'
  exit 2
}

# A -Force RE-CLOSE DELIBERATELY DROPS ANY stagingReleaseAuthorised FIELD, AND SAYS SO.
# -Force means the finding itself was re-made, so an authorisation resting on the OLD finding must
# not be carried forward silently - the record would then read as authorised on evidence nobody
# re-checked. Dropping it restores the default (refuse), which is the safe direction; re-authorising
# is one command. This is announced rather than done quietly, because a permission that disappears
# without a word is how the next operator concludes the guard is broken.
if ($Force -and (Test-Path -LiteralPath $recPath)) {
  $prev = $null
  try { $prev = Get-Content -LiteralPath $recPath -Raw | ConvertFrom-Json } catch { }
  if ($prev -and $prev.stagingReleaseAuthorised) {
    Write-Output ("NOTE    the previous record carried a stagingReleaseAuthorised field (by {0}, {1}, source {2})." -f `
                  "$($prev.stagingReleaseAuthorised.authorisedBy)", "$($prev.stagingReleaseAuthorised.authorisedAt)",
                  "$($prev.stagingReleaseAuthorised.sourceDisc.path)")
    Write-Output '        It is NOT carried into this re-close: it rested on the finding you have just re-made.'
    Write-Output '        _release-completed.ps1 will refuse this unit again until authorise-staging-release.ps1 is re-run.'
  }
}

$record = [ordered]@{
  disc                = $discName
  verdict             = 'SHIPPED VIA NON-MANIFEST ROUTE'
  closedAt            = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
  shippedItem         = $ShippedItem
  route               = $Route
  because             = "$Because".Trim()
  verdictLines        = $verdictLines
  verdictSource       = $verdictSource
  nasPath             = $NasPath
  nasBytes            = $nasBytes
  nasSha256           = $nasSha
  plexCheck           = $plexCheck
  dispositionsFile    = "$dispPath"
  dispositionsSha256  = $dispSha
  manifestDirsSearched = $manifestDirs
  manifestsReferencing = 0
  assertAccounted     = [ordered]@{
    invocation = 'assert-accounted.ps1 -RequireEvidence'
    exitCode   = 0
    tail       = @($assertOut | Select-Object -Last 4)
  }
  releaseNotice = 'THIS RECORD DOES NOT LICENSE RELEASING THE RAW STAGING. Unlike ships-nothing.json, ' + `
    'this disc shipped something that no manifest could have produced - assert-accounted.ps1 has ' + `
    'no concept of a non-title (e.g. menu-domain) item and its "may be released" line does not ' + `
    'account for this. _release-completed.ps1 therefore REFUSES BY DEFAULT any unit carrying this ' + `
    'record. THE WAY TO LIFT THAT IS NEVER TO DELETE THIS FILE: deleting it destroys the finding ' + `
    'and makes _stallwatch.ps1 report "needs MANIFEST" for this disc forever, which no manifest ' + `
    'can ever clear. Instead, note that "no manifest can produce it" (about the manifest format) ' + `
    'and "the source is unavailable" (about the drive) are DIFFERENT CLAIMS, and only the second ' + `
    'justifies refusing release. If the source disc is still reachable and byte-identical to the ' + `
    'staging, a re-fetch plus the same commands reproduces the item, and ' + `
    'scripts/authorise-staging-release.ps1 stamps an evidenced stagingReleaseAuthorised field onto ' + `
    'this record for THIS unit only; _release-completed.ps1 re-measures that source before ' + `
    'honouring it. Without that field, this record refuses.'
  closedBy            = 'close-shipped-outside-manifest.ps1'
}
Set-Content -LiteralPath $recPath -Value ($record | ConvertTo-Json -Depth 8) -Encoding UTF8

Write-Output "CLOSED - $discName SHIPPED VIA NON-MANIFEST ROUTE."
Write-Output ("  record  : {0}" -f $recPath)
Write-Output ("  shipped : {0}" -f $ShippedItem)
Write-Output ("  nas     : {0} ({1:N2} MB, sha256 {2})" -f $NasPath, ($nasBytes/1MB), $nasSha)
Write-Output ("  route   : {0}" -f $Route)
Write-Output ("  why     : {0}" -f $record.because)
Write-Output ''
Write-Output 'This does NOT release the staging, and _release-completed.ps1 will actively refuse this'
Write-Output 'unit while this record exists. If the staging is ever confirmed genuinely dispensable'
Write-Output '(e.g. the gallery is proven reproducible some other way), that judgement and the'
Write-Output 'removal of this record are a separate, deliberate, human step - never automatic.'
exit 0
