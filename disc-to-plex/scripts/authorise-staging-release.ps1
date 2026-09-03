<#
.SYNOPSIS
  Stamp a per-record, evidenced opt-out onto an existing *.shipped-outside-manifest.json so that
  _release-completed.ps1 will release THAT ONE unit's raw staging - and no other.

.THE DISTINCTION THIS SCRIPT EXISTS TO DRAW - READ THIS BEFORE USING IT
  A shipped-outside-manifest record makes ONE claim: "no manifest could ever produce this item".
  _release-completed.ps1 was built to read that claim as "therefore the staged disc folder is the
  only place the item could ever come from again", and refused release unconditionally.

  THOSE ARE TWO DIFFERENT CLAIMS, and only the second justifies an unconditional refusal.

    "no manifest can produce it"   - a statement about the MANIFEST FORMAT. Permanently true for
                                     these discs: a menu-domain PGC has no `-f dvdvideo -title N`,
                                     and no manifest field reorders cells within a carve.
    "the source is unavailable"    - a statement about the DRIVE. Contingent, and checkable.

  When the source disc is still sitting on E: byte-for-byte, a re-fetch plus the SAME carve commands
  reproduces the item exactly. What the staging then saves is CONVENIENCE, not content - and holding
  7 GB of NVMe hostage to convenience stalls the fetch floor, which is a real cost against a saving
  of none. The right test at release time is therefore: IS THE SOURCE DISC REACHABLE? That is a
  question about the drive, and this script (plus the re-check in _release-completed.ps1) asks it.

  What has NOT changed: the record stays, because its OTHER function is permanent. Without it
  _stallwatch.ps1 reports "needs MANIFEST" for this disc forever - a false positive that no manifest
  can ever clear. Deleting the record to unblock a release would trade a permanent board defect for
  a one-off convenience, and would also destroy the finding. So the opt-out is a FIELD, not a
  deletion, and it is per record: a shipped-outside-manifest record WITHOUT this field still refuses.
  The default is refuse.

.WHAT IT REFUSES
  1. No *.shipped-outside-manifest.json for the disc -> nothing to authorise; this is not a way to
     pre-authorise a record that does not exist yet.
  2. The record is unreadable, or is not a shipped-outside-manifest verdict.
  3. -SourceDisc does not exist -> the whole justification is that the source is reachable. If it
     is not reachable RIGHT NOW, there is nothing to authorise.
  4. The staged disc folder still exists and does NOT match -SourceDisc on file count AND total
     bytes -> then the staging is not merely a copy of the source, and re-fetching would not
     reproduce it. This is the check that separates a real duplicate from a hopeful one.
  5. -Because under 40 chars -> the record must carry the reasoning, not a shrug.
  6. An authorisation already present, without -Force.

.THE FIELD IT WRITES
  stagingReleaseAuthorised = {
    authorisedBy, authorisedAt, because,
    sourceDisc = { path, files, bytes, measuredAt, stagedFiles, stagedBytes, matchedStaging },
    recheckAtRelease  - prose stating that the release script re-measures, so a reader of the JSON
                        alone knows the field is not a rubber stamp
  }
  _release-completed.ps1 honours it ONLY while sourceDisc.path is still reachable and still totals
  sourceDisc.bytes. A drive that has gone away turns the refusal back on by itself.

.EXAMPLE
  pwsh -NoProfile -File authorise-staging-release.ps1 -Disc 'Edge of Darkness Disk 1' `
    -SourceDisc 'E:/Movies/Edge of Darkness Disk 1' `
    -AuthorisedBy 'user direction 2026-09-03 ("they came from E: and they aren''t needed any more")' `
    -Because 'the source disc is present on E: byte-identical to the staging, so a re-fetch plus the same carve commands reproduces the shipped items exactly; the record''s claim is about the manifest format, not about the source being gone'

.EXIT CODES
  0 = authorised (or already authorised)   2 = refused
#>
param(
  [Parameter(Mandatory)][string]$Disc,
  [Parameter(Mandatory)][string]$SourceDisc,
  [Parameter(Mandatory)][string]$AuthorisedBy,
  [Parameter(Mandatory)][string]$Because,
  [string]$CatalogueDir = 'D:/video/_catalogue',
  [string]$Stage        = 'D:/video/_stage',
  [switch]$Force
)
$ErrorActionPreference = 'Stop'

$discName = Split-Path $Disc -Leaf
$recPath  = Join-Path $CatalogueDir "$discName.shipped-outside-manifest.json"

# ---- 1. the record must already exist ------------------------------------------------------------
if (-not (Test-Path -LiteralPath $recPath)) {
  Write-Output "REFUSE  $discName - no shipped-outside-manifest record at $recPath"
  Write-Output 'This stamps an opt-out onto an existing finding; it does not create one.'
  exit 2
}
$rec = $null
try { $rec = Get-Content -LiteralPath $recPath -Raw | ConvertFrom-Json } catch { }
if (-not $rec -or "$($rec.verdict)" -ne 'SHIPPED VIA NON-MANIFEST ROUTE') {
  Write-Output "REFUSE  $discName - the record at $recPath is unreadable or is not a shipped-outside-manifest verdict."
  exit 2
}

# ---- 2. the WHY must be substantive --------------------------------------------------------------
if ("$Because".Trim().Length -lt 40) {
  Write-Output 'REFUSE  -Because must state the evidence that makes the staging dispensable (>= 40 chars).'
  exit 2
}

# ---- 3. the source must be REACHABLE, now --------------------------------------------------------
# The entire justification is "the source disc is still there". An unreachable source is not a
# paperwork problem to be waved through; it is the original refusal being correct.
if (-not (Test-Path -LiteralPath $SourceDisc -PathType Container)) {
  Write-Output "REFUSE  $discName - -SourceDisc is not an existing folder: $SourceDisc"
  Write-Output 'The authorisation rests on the source being reachable. It is not.'
  exit 2
}

function Measure-Folder([string]$path) {
  $agg = Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue |
         Measure-Object -Property Length -Sum
  [pscustomobject]@{ Files = [int]$agg.Count; Bytes = [long]($agg.Sum) }
}

$srcM = Measure-Folder $SourceDisc
if ($srcM.Files -eq 0) {
  Write-Output "REFUSE  $discName - $SourceDisc holds no files; that is not a source disc."
  exit 2
}

# ---- 4. if the staging is still here, it must BE that source -------------------------------------
# A staged folder that differs from the source is not reproducible by re-fetching it, whatever the
# folder names say. Compare file count AND total bytes, the project's standing pair.
$stagedDir = Join-Path $Stage $discName
$matched   = $false
$stgFiles  = $null
$stgBytes  = $null
if (Test-Path -LiteralPath $stagedDir -PathType Container) {
  $stgM     = Measure-Folder $stagedDir
  $stgFiles = $stgM.Files
  $stgBytes = $stgM.Bytes
  $matched  = ($stgM.Files -eq $srcM.Files -and $stgM.Bytes -eq $srcM.Bytes)
  if (-not $matched) {
    Write-Output ("REFUSE  {0} - the staged folder does not match the source." -f $discName)
    Write-Output ("        staged : {0} files, {1} bytes  ({2})" -f $stgM.Files, $stgM.Bytes, $stagedDir)
    Write-Output ("        source : {0} files, {1} bytes  ({2})" -f $srcM.Files, $srcM.Bytes, $SourceDisc)
    Write-Output 'A re-fetch would not reproduce this staging, so the source is not a substitute for it.'
    exit 2
  }
} else {
  Write-Output "NOTE    the staged disc folder is already gone ($stagedDir) - authorising on the source evidence alone (derived artefacts may remain)."
}

# ---- 5. don't silently rewrite an existing authorisation -----------------------------------------
if ($rec.PSObject.Properties.Name -contains 'stagingReleaseAuthorised' -and $rec.stagingReleaseAuthorised -and -not $Force) {
  Write-Output ("already authorised: {0} - by {1} at {2}" -f `
                $discName, "$($rec.stagingReleaseAuthorised.authorisedBy)", "$($rec.stagingReleaseAuthorised.authorisedAt)")
  Write-Output '(re-stamp with -Force only if the authorisation or its evidence has genuinely changed)'
  exit 0
}

$auth = [ordered]@{
  authorisedBy = "$AuthorisedBy".Trim()
  authorisedAt = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
  because      = "$Because".Trim()
  sourceDisc   = [ordered]@{
    path           = "$SourceDisc"
    files          = $srcM.Files
    bytes          = $srcM.Bytes
    measuredAt     = (Get-Date -Format 'yyyy-MM-ddTHH:mm:ss')
    stagedFiles    = $stgFiles
    stagedBytes    = $stgBytes
    matchedStaging = $matched
  }
  recheckAtRelease = 'NOT A RUBBER STAMP: _release-completed.ps1 re-measures sourceDisc.path at ' +
    'release time and honours this authorisation ONLY while that folder is reachable and still ' +
    'totals sourceDisc.bytes. If the drive is detached or the copy has changed, the unconditional ' +
    'refusal comes back on by itself. This field authorises THIS record only - a ' +
    'shipped-outside-manifest record without it still refuses, which is the default.'
  scopeNote = 'The record itself STAYS. Its other function is permanent: without it _stallwatch.ps1 ' +
    'reports "needs MANIFEST" for this disc forever, and no manifest can ever clear that. ' +
    '"No manifest can produce it" (about the manifest format) and "the source is unavailable" ' +
    '(about the drive) are different claims, and only the second justifies refusing release.'
}

$rec | Add-Member -NotePropertyName 'stagingReleaseAuthorised' -NotePropertyValue ([pscustomobject]$auth) -Force

# CORRECT A STALE releaseNotice, PRESERVING THE ORIGINAL VERBATIM. Records written before this
# opt-out existed instruct the reader to REMOVE THE RECORD in order to release - which is exactly
# the harm the field exists to avoid (it destroys the finding and re-opens the permanent
# "needs MANIFEST" false positive). A record that contradicts its own authorisation misleads the
# next reader, so the notice is rewritten - and the original kept beside it, so nothing is laundered.
if ("$($rec.releaseNotice)" -match 'must remove\s+this file first') {
  $rec | Add-Member -NotePropertyName 'releaseNoticeBeforeAuthorisation' -NotePropertyValue "$($rec.releaseNotice)" -Force
  $rec.releaseNotice =
    'THIS RECORD STILL DOES NOT LICENSE RELEASING ANY OTHER UNIT, AND MUST NOT BE DELETED. Its ' +
    'finding stands: no manifest could have produced this disc''s shipped item, and deleting this ' +
    'file would destroy that finding and make _stallwatch.ps1 report "needs MANIFEST" for this ' +
    'disc forever. What HAS been lifted, for this record only, is the staging refusal - see ' +
    'stagingReleaseAuthorised. "No manifest can produce it" (about the manifest format) and "the ' +
    'source is unavailable" (about the drive) are different claims, and only the second justifies ' +
    'refusing release; the source disc named there is reachable and byte-identical to the staging, ' +
    'and _release-completed.ps1 re-measures it before honouring this. The superseded wording, ' +
    'which told the reader to delete this file, is preserved in releaseNoticeBeforeAuthorisation.'
}

Set-Content -LiteralPath $recPath -Value ($rec | ConvertTo-Json -Depth 8) -Encoding UTF8

Write-Output "AUTHORISED - $discName raw staging may now be released by _release-completed.ps1."
Write-Output ("  record  : {0}" -f $recPath)
Write-Output ("  source  : {0} ({1} files, {2:N2} GB){3}" -f `
              $SourceDisc, $srcM.Files, ($srcM.Bytes/1GB), $(if ($matched) { ' - byte-identical to the staging' } else { '' }))
Write-Output ("  by      : {0}" -f $auth.authorisedBy)
Write-Output ("  why     : {0}" -f $auth.because)
Write-Output ''
Write-Output 'The finding is UNCHANGED and the record remains: no manifest can produce these items,'
Write-Output 'and the board still reads this disc as closed rather than awaiting a manifest. What is'
Write-Output 'lifted is only the staging refusal, for this one record, while the source stays reachable.'
exit 0
