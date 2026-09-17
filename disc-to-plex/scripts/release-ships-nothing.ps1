<#
.SYNOPSIS
  Queue the staging release of every disc closed SHIPS NOTHING, under the user's standing authorisation.

.WHY
  A ships-nothing disc has no Plex item to confirm; what the user confirmed, disc after disc, was the
  verdict. On 2026-09-17 they granted it standing: "If there is nothing to do, you are authorized to
  release the work without my intervention". Until then each batch waited on a chat round-trip, and
  twelve West Wing discs (~85 GB) sat staged within 30 GB of the space floor waiting for one.

  The authorisation is DATA, not code: D:/video/_standing-authorisations.json key
  releaseShipsNothingStaging. No key -> this script reports and queues nothing. Deleting the key
  withdraws it.

.WHAT IT QUEUES
  For each <disc>.ships-nothing.json in the catalogue whose staging folder still exists, and only when:
    - the record is readable and its dispositionsSha256 matches the dispositions file NOW (a stale
      closure never releases anything);
    - no manifest in _manifests/_pending/_queue references the staged path (a disc that ships is not a
      ships-nothing disc);
    - no reclaim artefact (queued, done or failed) already names the unit;
  it writes one _reclaim-queue/confirmed-<date>-shipsnothing-<slug>.json with works: [] and the unit.
  The reclaim loop and every release gate still decide; this only replaces the chat round-trip.

.EXIT CODES
  0 = ran (queued zero or more)   3 = no standing authorisation (nothing queued)
#>
param(
  [string]$Disc,   # limit to one disc (close-ships-nothing.ps1 passes the one it just closed)
  [string]$CatalogueDir  = 'D:/video/_catalogue',
  [string]$Stage         = 'D:/video/_stage',
  [string]$ReclaimQueue  = 'D:/video/_reclaim-queue',
  [string]$Authorisations = 'D:/video/_standing-authorisations.json',
  [string[]]$ManifestGlobs = @('D:/video/_manifests/*.json', 'D:/video/_pending/*.json', 'D:/video/_queue/*.json',
                               'D:/video/_queue/running/*.json', 'D:/video/_queue/done/*.json', 'D:/video/_queue/failed/*.json'),
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

$auth = $null
try { $auth = (Get-Content -LiteralPath $Authorisations -Raw | ConvertFrom-Json).releaseShipsNothingStaging } catch { }
if (-not $auth -or -not "$($auth.userWords)".Trim()) {
  Write-Output "no standing authorisation (releaseShipsNothingStaging in $Authorisations) - nothing queued; ask the user to accept each verdict."
  exit 3
}

$records = @(Get-ChildItem -LiteralPath $CatalogueDir -Filter '*.ships-nothing.json' -File -ErrorAction SilentlyContinue)
if ($Disc) { $records = @($records | Where-Object { $_.Name -eq ((Split-Path $Disc -Leaf) + '.ships-nothing.json') }) }

$manifestText = $null
$artefactText = @(Get-ChildItem -LiteralPath $ReclaimQueue -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue |
                  ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw })
$queued = 0
foreach ($f in $records) {
  $name = $f.Name -replace '\.ships-nothing\.json$', ''
  if (-not (Test-Path -LiteralPath (Join-Path $Stage $name) -PathType Container)) { continue }   # already released

  $rec = $null
  try { $rec = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { }
  if (-not $rec) { Write-Output "SKIP  $name - record unreadable"; continue }
  $dispPath = Join-Path $CatalogueDir "$name.dispositions.txt"
  if (-not (Test-Path -LiteralPath $dispPath)) { Write-Output "SKIP  $name - dispositions missing"; continue }
  if ((Get-FileHash -LiteralPath $dispPath -Algorithm SHA256).Hash -ne "$($rec.dispositionsSha256)") {
    Write-Output "SKIP  $name - dispositions changed since the closure (stale record)"; continue
  }

  if ($null -eq $manifestText) { $manifestText = @(Get-ChildItem $ManifestGlobs -ErrorAction SilentlyContinue | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) }
  $pathRx = '_stage[\\/]+' + [regex]::Escape($name) + '(?=["\\/])'
  if ($manifestText | Where-Object { $_ -match $pathRx } | Select-Object -First 1) {
    Write-Output "SKIP  $name - a manifest references its staging; it is not a ships-nothing disc"; continue
  }

  $unitRx = '"' + [regex]::Escape(($name | ConvertTo-Json).Trim('"')) + '"'
  if ($artefactText | Where-Object { $_ -match $unitRx } | Select-Object -First 1) { continue }   # already queued/handled

  $slug = ($name.ToLower() -replace '[^a-z0-9]+', '-').Trim('-')
  $out = Join-Path $ReclaimQueue ("confirmed-{0}-shipsnothing-{1}.json" -f (Get-Date -Format 'yyyy-MM-dd-HHmm'), $slug)
  $doc = [ordered]@{
    confirmed = (Get-Date -Format 'yyyy-MM-dd')
    note      = ("STAGING-ONLY RELEASE of '{0}', closed SHIPS NOTHING at {1}: {2}. Queued by release-ships-nothing.ps1 under the user's standing authorisation of {3}: '{4}'. 'works' is deliberately empty. Every release gate still applies and is the authority." -f $name, $rec.closedAt, $rec.because, $auth.granted, $auth.userWords)
    works     = @()
    units     = @($name)
  }
  if ($WhatIf) { Write-Output "WOULD QUEUE  $name -> $out"; $queued++; continue }
  Set-Content -LiteralPath $out -Value (ConvertTo-Json -InputObject $doc -Depth 4) -Encoding UTF8
  Write-Output "QUEUED  $name -> $(Split-Path $out -Leaf)"
  $queued++
}
Write-Output ("{0} ships-nothing staging release(s) {1}" -f $queued, $(if ($WhatIf) { 'would be queued' } else { 'queued' }))
exit 0
