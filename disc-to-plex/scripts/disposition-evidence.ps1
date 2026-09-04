<#
.SYNOPSIS
  Pre-flight ONE disc into a single evidence pack - every per-disc MEASUREMENT a disposition agent
  needs, taken once, so the agent reads one file and does only judgement.

.REACH FOR THIS WHEN
  A staged DVD is about to be dispositioned (or re-dispositioned), or an agent is about to run
  ffprobe / an IFO parse / a NAS listing by hand to answer "what is on this disc and what does the
  library already hold". Run it first; measure by hand only what the pack marks UNAVAILABLE.

.WHY THIS EXISTS
  Disposition agents were making 77-112 tool calls and spending 160k-280k tokens per disc, and
  roughly 70% of that was MEASUREMENT discovered one round-trip at a time - packet counts, IFO
  attribute tables, menu-domain sector arithmetic, NAS listings and probes, the worklist row, the
  MakeMKV log. Every one of those is deterministic and most already had a script. This is a thin
  ORCHESTRATOR over those scripts (prove-dvd-mapping.py, dvd-ifo-facts.py, lib-nas-governor.ps1,
  lib-disk.ps1, audio-envelope-correlate.py) plus ffprobe, writing ONE cached pack.

.RULES IT KEEPS
  - FACTS ONLY. No verdicts. Classifications carry their threshold beside the number.
  - ANY MEASUREMENT NOT TAKEN IS RECORDED AS UNAVAILABLE WITH A REASON - never omitted - so a reader
    can tell "measured false" from "not measured". The list is printed at the top of the .txt.
  - NAS reads go through lib-nas-governor.ps1 (slot, ceiling, kill switch). NAS files are never
    walked - header probes only; -Correlate reads short audio windows, governed.
  - Writes ONLY to _catalogue/<unit>.evidence.{json,txt,log} and _catalogue/<unit>-evidence/ (PNGs).
    Nothing to _stage, _queue or the NAS. Scratch is a temp dir, removed.
  - Idempotent: cached unless -Force, or the catalogue / MakeMKV log is newer than the pack.

.EXAMPLE
  pwsh -NoProfile -File disposition-evidence.ps1 -Unit "Don't Look Now"
  pwsh -NoProfile -File disposition-evidence.ps1 -Unit "The Sandbaggers Series 2 Disk 2" -Correlate
  pwsh -NoProfile -File disposition-evidence.ps1 -Unit "X" -Work "The League of Gentlemen" -Kind 'Television Shows'
#>
param(
  [Parameter(Mandatory)][string]$Unit,
  [string]$Stage      = 'D:/video/_stage',
  [string]$Catalogue  = 'D:/video/_catalogue',
  [string]$DiscInfo   = 'D:/video/_disc-info',
  [string]$VideoRoot  = 'D:/video',
  [string]$NasRoot    = '\\NASTEAMV\Multimedia',
  # Override the library work this disc maps to (when the automatic resolution is ambiguous).
  [string]$Work = '',
  [ValidateSet('', 'Movies', 'Television Shows')][string]$Kind = '',
  [switch]$Force,
  [switch]$Correlate,          # envelope correlation disc title <-> NAS duration candidates (costly)
  [switch]$NoNas,              # skip every NAS read (recorded as UNAVAILABLE)
  [switch]$NoPlex,             # skip Plex (recorded as UNAVAILABLE)
  [int]$NasProbeMax = 40,      # ffprobe at most this many NAS files (header reads)
  [double]$CandidateWindowSec = 120,   # a NAS file within this of a disc title is a duration candidate
  [double]$ExactMatchSec = 2.0,
  [int]$CorrelateOffsets = 3,
  [int]$CorrelateWindowSec = 20
)

$ErrorActionPreference = 'Continue'
$script:Sw = [Diagnostics.Stopwatch]::StartNew()
$script:Version = 'disposition-evidence/1'

# ---------------------------------------------------------------------------------- libraries
$scriptsDir = $PSScriptRoot
foreach ($lib in @('lib-nas-governor.ps1', 'lib-disk.ps1')) {
  $p = Join-Path $scriptsDir $lib
  if (-not (Test-Path -LiteralPath $p)) { Write-Output "FATAL: $lib missing beside this script"; exit 1 }
  . $p
}
foreach ($fn in @('Invoke-NasRead', 'Test-NasPath', 'Get-UnitStageTargets', 'ConvertTo-RipSlug')) {
  if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { Write-Output "FATAL: $fn not defined after dot-sourcing"; exit 1 }
}
$prover     = Join-Path $scriptsDir 'prove-dvd-mapping.py'
$ifoFacts   = Join-Path $scriptsDir 'dvd-ifo-facts.py'
$correlator = Join-Path $scriptsDir 'audio-envelope-correlate.py'
$toolPathsFile = Join-Path $VideoRoot '.transcode-tools/tool-paths.json'
$ffmpeg = $null; $ffprobe = $null
if (Test-Path -LiteralPath $toolPathsFile) {
  $tp = Get-Content -LiteralPath $toolPathsFile -Raw | ConvertFrom-Json
  $ffmpeg = $tp.ffmpeg
  $ffprobe = Join-Path (Split-Path $ffmpeg) 'ffprobe.exe'
}

# ---------------------------------------------------------------------------------- paths
$unit = $Unit.Trim()
$stagePath   = (Join-Path $Stage $unit)
$videoTs     = Join-Path $stagePath 'VIDEO_TS'
$catPath     = Join-Path $Catalogue ($unit + '.catalogue.json')
$discInfoLog = Join-Path $DiscInfo ($unit + '.txt')
$outJson     = Join-Path $Catalogue ($unit + '.evidence.json')
$outTxt      = Join-Path $Catalogue ($unit + '.evidence.txt')
$outLog      = Join-Path $Catalogue ($unit + '.evidence.log')
$evDir       = Join-Path $Catalogue ($unit + '-evidence')
$dispPath    = Join-Path $Catalogue ($unit + '.dispositions.txt')

# ---------------------------------------------------------------------------------- cache
if (-not $Force -and (Test-Path -LiteralPath $outJson) -and (Test-Path -LiteralPath $outTxt)) {
  $packTime = (Get-Item -LiteralPath $outJson).LastWriteTimeUtc
  $newer = @()
  foreach ($dep in @($catPath, $discInfoLog)) {
    if ((Test-Path -LiteralPath $dep) -and (Get-Item -LiteralPath $dep).LastWriteTimeUtc -gt $packTime) { $newer += $dep }
  }
  if ($newer.Count -eq 0) {
    Write-Output ("CACHED: {0} (written {1}); -Force to regenerate. Read: {2}" -f $outJson, $packTime.ToLocalTime().ToString('s'), $outTxt)
    exit 0
  }
  Write-Output ("cache is older than: {0} - regenerating" -f ($newer -join ', '))
}

New-Item -ItemType Directory -Force -Path $Catalogue, $evDir | Out-Null
Set-Content -LiteralPath $outLog -Value ("disposition-evidence {0} for '{1}' started {2}" -f $script:Version, $unit, (Get-Date -Format 's')) -Encoding UTF8

# ---------------------------------------------------------------------------------- state
$pack = [ordered]@{}
$unavailable = [System.Collections.Generic.List[object]]::new()
$timings = [ordered]@{}
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('disposition-evidence-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $scratch | Out-Null

function Log([string]$m) {
  $line = ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m)
  Add-Content -LiteralPath $outLog -Value $line -Encoding UTF8
  Write-Host $line
}
function Add-Unavailable([string]$Measurement, [string]$Reason) {
  $unavailable.Add([pscustomobject]@{ measurement = $Measurement; reason = $Reason })
  Log ("UNAVAILABLE {0}: {1}" -f $Measurement, $Reason)
}
$say = { param($m) Log ("[governor] " + $m) }

function Invoke-Section([string]$Name, [scriptblock]$Body) {
  $sw = [Diagnostics.Stopwatch]::StartNew()
  Log ("section {0} ..." -f $Name)
  try { & $Body }
  catch {
    Add-Unavailable $Name ("section threw: " + $_.Exception.Message + " at " + $_.InvocationInfo.PositionMessage.Split("`n")[0])
  }
  $timings[$Name] = [math]::Round($sw.Elapsed.TotalSeconds, 1)
  Log ("section {0} done in {1} s" -f $Name, $timings[$Name])
}

function Invoke-Native([string]$Exe, [string[]]$Args, [string]$Label, [int]$TimeoutSec = 300) {
  # stdout as lines, stderr as lines, exit code - read DIRECTLY, never through a pipe.
  #
  # 🔴 WHY THIS IS NOT `& $Exe @Args`. The call operator has NO TIMEOUT and blocks for ever.
  # On 2026-09-04 this function was called for the byte proof, `prove-dvd-mapping.py` left the
  # process table, and the whole evidence run sat in `section byteProof` producing nothing -
  # twice, on 'Don't Look Now', with nothing else contending. There was no way to tell a slow
  # proof from a dead one, and the brief had every disposition agent running this first.
  # A PRE-FLIGHT THAT CAN HANG IS WORSE THAN NO PRE-FLIGHT: it takes its caller down with it.
  #
  # So: every child gets a deadline, and a breach is a MEASUREMENT THAT DID NOT HAPPEN
  # (Code = -1, TimedOut = true) which callers already turn into an UNAVAILABLE line - never a
  # silent omission, and never a wait.
  #
  # ArgumentList (not a single string) so nothing re-quotes a path; this project has discs whose
  # names carry apostrophes and spaces - "Don't Look Now" is the one that found this.
  # 🔴 IT MUST BE THE CALL OPERATOR. Do not "improve" this into [Diagnostics.Process] with
  # UseShellExecute=$false. That was tried on 2026-09-05 and REGRESSED: `python` on this machine
  # resolves to the Windows Store App Execution Alias
  # (C:\Users\matth\AppData\Local\Microsoft\WindowsApps\python.exe), which the call operator execs
  # correctly but ProcessStartInfo does NOT - the stub starts, never runs the script and never
  # exits, leaving argument-less WindowsApps\python.exe processes behind. Bisected: the prover
  # returns in 0.4-0.5 s under `&`, and timed out at 45 s under ProcessStartInfo with identical
  # arguments. If a timeout is ever genuinely needed here, add it with Start-Job/a runspace around
  # this call - never by changing how the child is launched.
  $errFile = Join-Path $scratch ('err-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.txt')
  $out = @(& $Exe @Args 2>$errFile)
  $code = $LASTEXITCODE
  $err = @()
  if (Test-Path -LiteralPath $errFile) { $err = @(Get-Content -LiteralPath $errFile -ErrorAction SilentlyContinue); Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
  return [pscustomobject]@{ Out = $out; Err = $err; Code = $code; Label = $Label; TimedOut = $false }
}

function Get-Slug([string]$name) { (($name.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')) }
function Get-ShowKey([string]$name) {
  # Same heuristic _dispositions-loop.ps1 uses to find SISTER files. Never identity.
  $k = $name
  $k = $k -replace '\s+(Disk|Disc|D)\s*\d+\s*$', ''
  $k = $k -replace '\s+(Series|Season|S)\s*\d+.*$', ''
  $k = $k -replace '\s+(Disk|Disc|D)\s*\d+\s*$', ''
  return $k.Trim()
}
function Get-NasPathFromPlexFile([string]$plexFile) {
  # Plex reports /share/CACHEDEV1_DATA/Multimedia/<Kind>/<Work>/... ; the SMB share is \\NASTEAMV\Multimedia
  $m = [regex]::Match($plexFile, '^/share/[^/]+/Multimedia/(.*)$')
  if (-not $m.Success) { return $null }
  return ($NasRoot.TrimEnd('\') + '\' + ($m.Groups[1].Value -replace '/', '\'))
}
function Convert-FpsString([string]$s) {
  if ($s -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -ne 0) { return [math]::Round([double]$Matches[1] / [double]$Matches[2], 3) }
  return $null
}
function Read-JsonFile([string]$path) {
  try { return (Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop) } catch { return $null }
}
function Get-AudioSecondsFromPackets([string]$codec, [int]$packets, [string]$sampleRate) {
  $frameSize = @{ ac3 = 1536; eac3 = 1536; aac = 1024; mp2 = 1152; mp3 = 1152; dts = 512; vorbis = 1024; opus = 960; pcm_dvd = 0 }
  if ($frameSize.ContainsKey($codec) -and $frameSize[$codec] -gt 0 -and $sampleRate -match '^\d+$' -and [int]$sampleRate -gt 0) {
    return [math]::Round($packets * $frameSize[$codec] / [double]$sampleRate, 2)
  }
  return $null
}

# ================================================================================== 1. INPUTS
$pack.meta = [ordered]@{
  schema = $script:Version; unit = $unit; generated = (Get-Date -Format 's'); host = $env:COMPUTERNAME
  args = [ordered]@{ Work = $Work; Kind = $Kind; Force = [bool]$Force; Correlate = [bool]$Correlate; NoNas = [bool]$NoNas; NoPlex = [bool]$NoPlex; NasProbeMax = $NasProbeMax; CandidateWindowSec = $CandidateWindowSec }
  ffprobe = $ffprobe
  outputs = [ordered]@{ json = $outJson; txt = $outTxt; log = $outLog; evidenceDir = $evDir }
}

Invoke-Section 'inputs' {
  $stagePresent = Test-Path -LiteralPath $stagePath -PathType Container
  $vtsPresent = Test-Path -LiteralPath $videoTs -PathType Container
  $files = @()
  if ($vtsPresent) {
    $files = @(Get-ChildItem -LiteralPath $videoTs -File -Force | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; bytes = $_.Length; mtime = $_.LastWriteTime.ToString('s') } })
  }
  $stageTop = @()
  if ($stagePresent) {
    $stageTop = @(Get-ChildItem -LiteralPath $stagePath -Force | Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; bytes = $(if ($_.PSIsContainer) { $null } else { $_.Length }); dir = [bool]$_.PSIsContainer; hidden = [bool]($_.Attributes -band [IO.FileAttributes]::Hidden) } })
  }
  $targets = @()
  foreach ($t in @(Get-UnitStageTargets -Unit $unit -Stage $Stage)) { foreach ($x in @($t)) { if ($x) { $targets += "$x" } } }   # the function returns a NESTED array
  $tracks = @()
  foreach ($t in $targets) { if ($t -like '*.tracks.json') { $tracks += $t } }
  foreach ($d in $targets) { if (Test-Path -LiteralPath $d -PathType Container) { $tracks += @(Get-ChildItem -LiteralPath $d -Filter '*.tracks.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) } }
  $ripFiles = @()
  foreach ($d in $targets) {
    if ((Test-Path -LiteralPath $d -PathType Container) -and $d -ne $stagePath) {
      $ripFiles += @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ path = $_.FullName; bytes = $_.Length; mtime = $_.LastWriteTime.ToString('s') } })
    }
  }
  $fetchDone = $false; $completed = $false
  $fd = Join-Path $VideoRoot '_fetch-done.txt'; $cp = Join-Path $VideoRoot '_completed.txt'
  if (Test-Path -LiteralPath $fd) { $fetchDone = @(Get-Content -LiteralPath $fd | Where-Object { $_.Trim() -eq $unit }).Count -gt 0 }
  if (Test-Path -LiteralPath $cp) { $completed = @(Get-Content -LiteralPath $cp | Where-Object { ($_ -split '\|')[0].Trim() -eq $unit -or $_.Trim() -eq $unit }).Count -gt 0 }
  $showKey = Get-ShowKey $unit
  $showSlug = Get-Slug $showKey
  $pending = Join-Path $VideoRoot '_pending'
  $alloc = @()
  if (Test-Path -LiteralPath $pending) {
    foreach ($f in Get-ChildItem -LiteralPath $pending -Filter 'SEASON00-ALLOCATION*.md' -File) {
      $fs = ($f.BaseName -replace '^SEASON00-ALLOCATION-?', '').ToLowerInvariant()
      $core = $showSlug -replace '^the-', ''
      if ($fs -eq '' -or ($fs -and $core -and ($core -like "*$fs*" -or $fs -like "*$core*"))) { $alloc += $f.FullName }
    }
  }
  $sisters = @()
  foreach ($f in Get-ChildItem -LiteralPath $Catalogue -Filter '*.dispositions.txt' -File) {
    $n = $f.Name -replace '\.dispositions\.txt$', ''
    if ($n -ne $unit -and (Get-ShowKey $n) -eq $showKey) { $sisters += $f.FullName }
  }
  $briefs = @(Get-ChildItem -LiteralPath $pending -Filter ($unit + '.*brief.md') -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
  $markers = @(Get-ChildItem -LiteralPath $pending -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -in @("$unit.dispositioning", "$unit.authoring", "$unit.NEEDS-VALIDATION.txt") } | ForEach-Object { $_.FullName })
  $pack.inputs = [ordered]@{
    stagePath = $stagePath; stagePresent = $stagePresent; videoTsPresent = $vtsPresent
    stageTopLevel = $stageTop; videoTsFiles = $files
    videoTsBytes = ($files | ForEach-Object { [long]$_.bytes } | Measure-Object -Sum).Sum
    unitStageTargets = $targets; tracksJson = @($tracks | Sort-Object -Unique); ripFiles = $ripFiles
    catalogueJson = $catPath; cataloguePresent = (Test-Path -LiteralPath $catPath)
    catalogueMtime = $(if (Test-Path -LiteralPath $catPath) { (Get-Item -LiteralPath $catPath).LastWriteTime.ToString('s') } else { $null })
    makemkvLog = $discInfoLog; makemkvLogPresent = (Test-Path -LiteralPath $discInfoLog)
    makemkvLogMtime = $(if (Test-Path -LiteralPath $discInfoLog) { (Get-Item -LiteralPath $discInfoLog).LastWriteTime.ToString('s') } else { $null })
    inFetchDone = $fetchDone; inCompleted = $completed
    showKeyHeuristic = $showKey; showSlug = $showSlug
    season00AllocationFiles = $alloc; sisterDispositions = $sisters
    dispositionsFile = $dispPath; dispositionsPresent = (Test-Path -LiteralPath $dispPath)
    briefs = $briefs; markers = $markers
  }
  if (-not $stagePresent) { Add-Unavailable 'staging' "no folder at $stagePath - every disc-side measurement below is unavailable" }
  elseif (-not $vtsPresent) { Add-Unavailable 'VIDEO_TS' "$stagePath has no VIDEO_TS - this pack measures DVDs; Blu-ray discs need the MakeMKV/playlist sweep" }
}

# ================================================================================== 2. CLAIMS
Invoke-Section 'claims' {
  $claims = [ordered]@{ note = 'CLAIMS from metadata files, never evidence. Identity is settled from content.' }
  $dvdid = $null
  if (Test-Path -LiteralPath $stagePath) {
    $x = Get-ChildItem -LiteralPath $stagePath -Filter '*.dvdid.xml' -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($x) {
      $m = [regex]::Match((Get-Content -LiteralPath $x.FullName -Raw), '<ID>(.*?)</ID>')
      if ($m.Success) { $dvdid = $m.Groups[1].Value.Trim() }
      $claims.dvdidFile = $x.FullName
    }
  }
  $claims.discId = $dvdid
  if (-not $dvdid) { Add-Unavailable 'discId' 'no *.dvdid.xml in the staging folder (the identity register is keyed on it)' }
  # mymovies.xml
  $mym = $null
  if (Test-Path -LiteralPath $stagePath) { $mym = Get-ChildItem -LiteralPath $stagePath -Filter 'mymovies.xml' -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1 }
  if ($mym) {
    try {
      [xml]$doc = Get-Content -LiteralPath $mym.FullName -Raw -Encoding UTF8
      $t = $doc.Title
      $mm = [ordered]@{ file = $mym.FullName }
      foreach ($k in @('LocalTitle', 'LocalTitleDisplay', 'OriginalTitle', 'SortTitleDisplay', 'ProductionYear', 'RunningTime', 'Type', 'Studio', 'Country', 'Description', 'Barcode')) {
        $v = $t.$k; if ($v -is [System.Xml.XmlElement]) { $v = $v.InnerText }; if ($v) { $mm[$k] = "$v".Trim() }
      }
      if ($t.IMDB) { $mm.IMDB = "$($t.IMDB)".Trim() }
      if ($t.WebServices) { $mm.WebServiceID = "$($t.WebServices.WebService.ID)".Trim() }
      $discs = @()
      $bracket = $null
      if ($mm.LocalTitleDisplay -match '\[(.+?)\]\s*$') { $bracket = $Matches[1].Trim() }
      foreach ($d in @($t.Discs.Disc)) {
        if (-not $d) { continue }
        $titles = @()
        foreach ($ti in @($d.TitlesSideA.Title)) {
          if (-not $ti -or -not $ti.Number) { continue }
          $chapters = @($ti.Chapter)
          $sec = [int]$ti.Hours * 3600 + [int]$ti.Minutes * 60 + [int]$ti.Seconds + $(if ([int]$ti.FPS -gt 0) { [int]$ti.Frames / [double]$ti.FPS } else { 0 })
          $titles += [ordered]@{
            number = [int]$ti.Number; seconds = [math]::Round($sec, 2)
            hms = ('{0}:{1}:{2}.{3}' -f $ti.Hours, $ti.Minutes, $ti.Seconds, $ti.Frames)
            chapters = $chapters.Count; containsEpisode = "$($ti.ContainsEpisode)"; mainMovie = "$($ti.MainMovie)"
            tvSeason = "$($ti.TVSeason)"; tvEpisode = "$($ti.TVEpisode)"
            titleText = $(if ($ti.Title -is [System.Xml.XmlElement]) { "$($ti.Title.InnerText)".Trim() } else { "$($ti.Title)".Trim() })
            chapterSeconds = @($chapters | ForEach-Object { if ($_.Hours) { [math]::Round([int]$_.Hours * 3600 + [int]$_.Minutes * 60 + [int]$_.Seconds + $(if ([int]$_.FPS -gt 0) { [int]$_.Frames / [double]$_.FPS } else { 0 }), 2) } })
          }
        }
        $name = "$($d.Name)".Trim()
        $discs += [ordered]@{ name = $name; discIdSideA = "$($d.DiscIdSideA)".Trim(); thisDiscByLocalTitleDisplay = ($bracket -and $name -eq $bracket); titles = $titles }
      }
      $mm.discs = $discs
      $claims.mymovies = $mm
    } catch { Add-Unavailable 'mymovies.xml' ("could not parse " + $mym.FullName + ": " + $_.Exception.Message) }
  } else { Add-Unavailable 'mymovies.xml' 'not present in the staging folder' }
  # movie.nfo
  $nfo = $null
  if (Test-Path -LiteralPath $videoTs) { $nfo = Get-ChildItem -LiteralPath $videoTs -Filter '*.nfo' -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1 }
  if (-not $nfo -and (Test-Path -LiteralPath $stagePath)) { $nfo = Get-ChildItem -LiteralPath $stagePath -Filter '*.nfo' -File -Force -ErrorAction SilentlyContinue | Select-Object -First 1 }
  if ($nfo) {
    $raw = Get-Content -LiteralPath $nfo.FullName -Raw
    $n = [ordered]@{ file = $nfo.FullName }
    foreach ($k in @('title', 'originaltitle', 'year', 'runtime', 'id', 'studio', 'director', 'mpaa', 'premiered', 'plot')) {
      $m = [regex]::Match($raw, "<$k>(.*?)</$k>", 'Singleline')
      if ($m.Success) { $n[$k] = ($m.Groups[1].Value -replace '\s+', ' ').Trim() }
    }
    $claims.nfo = $n
  }
  $pack.claims = $claims
}

# ================================================================================== 3. CATALOGUE
$cat = $null
Invoke-Section 'catalogue' {
  if (-not (Test-Path -LiteralPath $catPath)) { Add-Unavailable 'catalogue' "no $catPath - the catalogue track has not swept this disc"; return }
  $script:cat = Read-JsonFile $catPath
  $cat = $script:cat
  if (-not $cat) { Add-Unavailable 'catalogue' "$catPath did not parse as JSON"; return }
  $rows = @()
  foreach ($t in @($cat.titles)) {
    $rows += [ordered]@{
      title = $t.title; makemkvId = ('t{0:D2}' -f [int]$t.title); duration = $t.duration; dvdvideoTitle = $t.dvdvideoTitle
      mappingAmbiguous = $t.mappingAmbiguous; mappingTieSize = $t.mappingTieSize; mappingDeltaSec = $t.mappingDeltaSec
      mappingProvenBy = $t.mappingProvenBy; sizeBytes = $t.sizeBytes; width = $t.width; height = $t.height
      frames = @($t.frames); headStrip = $t.headStrip; speechStatus = $t.speechStatus; speechFrom = $t.speechFrom
      speechSample = $t.speechSample; speechSamplesExtra = @($t.speechSamplesExtra); evidenceNote = $t.evidenceNote
      disposition = $t.disposition
    }
  }
  $pack.catalogue = [ordered]@{
    path = $catPath; disc = $cat.disc; discPath = $cat.discPath; discType = $cat.discType; minLength = $cat.minLength
    sourceVerified = $cat.sourceVerified; titleNumbering = $cat.titleNumbering; titleCount = $cat.titleCount
    rows = $rows
    frameDir = (Join-Path $Catalogue ($unit + '-frames'))
    frameFiles = @(Get-ChildItem -LiteralPath (Join-Path $Catalogue ($unit + '-frames')) -File -ErrorAction SilentlyContinue | ForEach-Object { [ordered]@{ name = $_.Name; bytes = $_.Length } })
  }
  if ($cat.discType -and "$($cat.discType)" -ne 'DVD') { Add-Unavailable 'DVD measurements' ("catalogue says discType={0}; the IFO/menu/packet sections apply to DVDs only" -f $cat.discType) }
}

# ================================================================================== 4. MAKEMKV LOG
Invoke-Section 'makemkvLog' {
  if (-not (Test-Path -LiteralPath $discInfoLog)) { Add-Unavailable 'makemkvLog' "no $discInfoLog (the enumeration log the catalogue was built from); cell-removal and decode-failure warnings cannot be scanned"; return }
  $lines = @(Get-Content -LiteralPath $discInfoLog -Encoding UTF8)
  $titles = [ordered]@{}
  $msgs = @(); $cellsRemoved = @(); $failed = @(); $skipped = @(); $identicalSubs = @(); $added = @()
  $boiler = @('1005', '5042', '5010', '5011', '3007', '3306', '3341', '1011')
  foreach ($l in $lines) {
    if ($l -match '^MSG:(\d+),\d+,\d+,"((?:[^"\\]|\\.)*)"') {
      $code = $Matches[1]; $text = $Matches[2]
      switch ($code) {
        '3028' { if ($text -match 'Title #(\d+) was added \((\d+) cell\(s\), ([\d:]+)\)') { $added += [ordered]@{ makemkvTitleNumber = [int]$Matches[1]; cells = [int]$Matches[2]; duration = $Matches[3]; text = $text } } }
        '3038' { $cellsRemoved += [ordered]@{ text = $text; afterTitleAdded = $(if ($added.Count) { $added[-1].makemkvTitleNumber } else { $null }) } }
        '5043' { $failed += $text }
        '3025' { $skipped += $text }
        '3030' { $identicalSubs += $text }
      }
      if ($boiler -notcontains $code -and $code -ne '3028') { $msgs += [ordered]@{ code = [int]$code; text = $text } }
    }
    elseif ($l -match '^TINFO:(\d+),(\d+),\d+,"(.*)"$') {
      # STRING keys, not int: an [ordered]@{} indexed with an Int32 binds to OrderedDictionary's
      # this[int index] overload (positional) instead of this[object key] (lookup) - PowerShell
      # picks the exact-type match. That throws "index out of range" the moment the numeric key
      # isn't also a valid position, which happened on THIS disc's very first title. String keys
      # never collide with the int-index overload.
      $id = [int]$Matches[1]; $f = [int]$Matches[2]; $v = $Matches[3]; $idKey = "$id"
      if (-not $titles.Contains($idKey)) { $titles[$idKey] = [ordered]@{ makemkvTitle = $id; streams = [ordered]@{} } }
      switch ($f) { 9 { $titles[$idKey].duration = $v } 10 { $titles[$idKey].sizeText = $v } 11 { $titles[$idKey].sizeBytes = [long]$v } 24 { $titles[$idKey].sourceTitleClaim = $v } 25 { $titles[$idKey].segmentCount = $v } 26 { $titles[$idKey].segmentMap = $v } 27 { $titles[$idKey].fileName = $v } 8 { $titles[$idKey].chapters = $v } 30 { $titles[$idKey].summary = $v } }
    }
    elseif ($l -match '^SINFO:(\d+),(\d+),(\d+),\d+,"(.*)"$') {
      $id = [int]$Matches[1]; $s = [int]$Matches[2]; $f = [int]$Matches[3]; $v = $Matches[4]; $idKey = "$id"; $sKey = "$s"
      if (-not $titles.Contains($idKey)) { $titles[$idKey] = [ordered]@{ makemkvTitle = $id; streams = [ordered]@{} } }
      if (-not $titles[$idKey].streams.Contains($sKey)) { $titles[$idKey].streams[$sKey] = [ordered]@{ stream = $s } }
      switch ($f) { 1 { $titles[$idKey].streams[$sKey].type = $v } 5 { $titles[$idKey].streams[$sKey].codecId = $v } 6 { $titles[$idKey].streams[$sKey].codecShort = $v } 7 { $titles[$idKey].streams[$sKey].codecLong = $v } 3 { $titles[$idKey].streams[$sKey].lang = $v } 4 { $titles[$idKey].streams[$sKey].langName = $v } 13 { $titles[$idKey].streams[$sKey].bitrate = $v } 14 { $titles[$idKey].streams[$sKey].channels = $v } 17 { $titles[$idKey].streams[$sKey].sampleRate = $v } 19 { $titles[$idKey].streams[$sKey].resolution = $v } 20 { $titles[$idKey].streams[$sKey].aspect = $v } 21 { $titles[$idKey].streams[$sKey].fps = $v } 30 { $titles[$idKey].streams[$sKey].description = $v } 39 { $titles[$idKey].streams[$sKey].flags = $v } }
    }
  }
  $tl = @()
  foreach ($k in $titles.Keys) {
    $t = $titles[$k]
    $t.streams = @($t.streams.Values)
    $t.subtitleStreamsDeclared = @($t.streams | Where-Object { "$($_.type)" -eq 'Subtitles' }).Count
    $t.audioStreamsDeclared = @($t.streams | Where-Object { "$($_.type)" -eq 'Audio' }).Count
    $tl += $t
  }
  $pack.makemkvLog = [ordered]@{
    path = $discInfoLog; lines = $lines.Count; source = (@($lines | Where-Object { $_ -match '^MSG:1005' }) | Select-Object -First 1)
    titlesEnumerated = $tl.Count; titles = $tl; titlesAdded = $added
    cellsRemovedWarnings = $cellsRemoved; decodeFailures = $failed; skippedShortTitles = $skipped; identicalSubtitleSkips = $identicalSubs
    otherMessages = $msgs
  }
  if ($script:cat -and $script:cat.titleCount -ne $tl.Count) { $pack.makemkvLog.note = ("log enumerates {0} titles, catalogue has {1} - check they are the same enumeration" -f $tl.Count, $script:cat.titleCount) }
}

# ================================================================================== 5. BYTE PROOF
Invoke-Section 'byteProof' {
  if (-not (Test-Path -LiteralPath $videoTs)) { Add-Unavailable 'byteProof' 'no VIDEO_TS on disk'; return }
  if (-not (Test-Path -LiteralPath $prover)) { Add-Unavailable 'byteProof' "prove-dvd-mapping.py missing beside this script"; return }
  $bp = [ordered]@{ script = $prover }
  $infoArgs = @()
  if (Test-Path -LiteralPath $discInfoLog) { $infoArgs = @('--info-file', $discInfoLog); $bp.infoFile = $discInfoLog }
  else { $bp.infoFile = $null; $bp.note = 'no saved MakeMKV log - the prover ran MakeMKV itself (--minlength 10)' }
  $r = Invoke-Native 'python' (@($prover, $stagePath, '--minlength', '10') + $infoArgs) 'prove text'
  $bp.textExit = $r.Code
  $bp.textVerbatim = @($r.Out)
  if ($r.Err.Count) { $bp.textStderr = @($r.Err | Select-Object -Last 5) }
  $j = Invoke-Native 'python' (@($prover, $stagePath, '--minlength', '10', '--json') + $infoArgs) 'prove json'
  $bp.jsonExit = $j.Code
  try { $bp.json = (($j.Out -join "`n") | ConvertFrom-Json) } catch { $bp.json = $null; Add-Unavailable 'byteProof.json' ("--json output did not parse: " + ($j.Out | Select-Object -Last 2)) }
  if (Test-Path -LiteralPath $catPath) {
    $v = Invoke-Native 'python' @($prover, $stagePath, '--verify-claims', $catPath) 'verify claims'
    $bp.verifyClaimsExit = $v.Code
    $bp.verifyClaimsVerbatim = @($v.Out)
    $bp.verifyClaimsRan = @($v.Out | Where-Object { "$_" -match '^\s*\d+ verified, \d+ unverifiable, \d+ FAILED\s*$' }).Count -gt 0
  } else { $bp.verifyClaimsExit = $null; Add-Unavailable 'byteProof.verifyClaims' 'no catalogue to verify claims against' }
  $pack.byteProof = $bp
}

# ================================================================================== 6. IFO FACTS + MENU DOMAIN
$ifo = $null
Invoke-Section 'ifo' {
  if (-not (Test-Path -LiteralPath $videoTs)) { Add-Unavailable 'ifo' 'no VIDEO_TS on disk'; return }
  if (-not (Test-Path -LiteralPath $ifoFacts)) { Add-Unavailable 'ifo' 'dvd-ifo-facts.py missing beside this script'; return }
  # Title-domain PGCs worth carving and classifying: entry PGCs of declared titles MakeMKV never
  # enumerated, plus any declared title of 30 s or under (idents, stills, black stubs).
  $extraPgcs = @()
  $enumeratedDv = @()
  if ($script:cat) { $enumeratedDv = @($script:cat.titles | ForEach-Object { $_.dvdvideoTitle } | Where-Object { $null -ne $_ }) }
  $pre = Invoke-Native 'python' @($ifoFacts, $stagePath) 'ifo pre'
  $preDoc = $null
  try { $preDoc = (($pre.Out -join "`n") | ConvertFrom-Json) } catch { }
  if ($preDoc) {
    foreach ($t in @($preDoc.titles)) {
      if (-not $t.entryPgc) { continue }
      $isEnum = $enumeratedDv -contains [int]$t.title
      $short = ($t.pgc -and [double]$t.pgc.playbackSec -le 30)
      if (-not $isEnum -or $short) { $extraPgcs += ('{0}:{1}' -f $t.vtsn, $t.entryPgc) }
    }
  }
  $ifoJson = Join-Path $scratch 'ifo.json'
  $args = @($ifoFacts, $stagePath, '--classify', '--out-dir', $evDir, '--json-out', $ifoJson)
  if ($extraPgcs.Count) { $args += @('--title-pgcs', ($extraPgcs -join ',')) }
  $r = Invoke-Native 'python' $args 'ifo facts'
  if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $ifoJson)) { Add-Unavailable 'ifo' ("dvd-ifo-facts.py exit {0}: {1}" -f $r.Code, (($r.Err | Select-Object -Last 3) -join ' / ')); return }
  $script:ifo = Read-JsonFile $ifoJson
  $ifo = $script:ifo
  if (-not $ifo) { Add-Unavailable 'ifo' 'dvd-ifo-facts.py output did not parse'; return }
  $pack.ifo = $ifo
  $pack.ifoTitlePgcsClassified = $extraPgcs
}

# ================================================================================== 7. PER-TITLE PACKET PROBES
Invoke-Section 'titles' {
  if (-not (Test-Path -LiteralPath $videoTs)) { Add-Unavailable 'titles' 'no VIDEO_TS on disk'; return }
  if (-not $ffprobe -or -not (Test-Path -LiteralPath $ffprobe)) { Add-Unavailable 'titles' 'ffprobe not found via tool-paths.json'; return }
  $declared = @()
  if ($script:ifo) { $declared = @($script:ifo.vmg.ttSrpt | ForEach-Object { [int]$_.title }) }
  if (-not $declared.Count) {
    # no IFO parse - fall back to the catalogue's dvdvideo titles
    if ($script:cat) { $declared = @($script:cat.titles | ForEach-Object { $_.dvdvideoTitle } | Where-Object { $null -ne $_ } | ForEach-Object { [int]$_ }) }
  }
  if (-not $declared.Count) { Add-Unavailable 'titles' 'no title list from the IFO or the catalogue to probe'; return }
  $catByDv = @{}
  if ($script:cat) { foreach ($t in @($script:cat.titles)) { if ($null -ne $t.dvdvideoTitle) { $catByDv[[int]$t.dvdvideoTitle] = $t } } }
  $out = @()
  foreach ($dv in ($declared | Sort-Object -Unique)) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $rec = [ordered]@{ dvdvideoTitle = $dv }
    $tt = $null
    if ($script:ifo) { $tt = @($script:ifo.titles | Where-Object { [int]$_.title -eq $dv })[0] }
    if ($tt) {
      $rec.vtsn = $tt.vtsn; $rec.vtsTtn = $tt.vtsTtn; $rec.nrOfPtts = $tt.nrOfPtts; $rec.nrOfAngles = $tt.nrOfAngles; $rec.entryPgc = $tt.entryPgc
      if ($tt.pgc) { $rec.declaredSec = $tt.pgc.playbackSec; $rec.declared = $tt.pgc.playback; $rec.cells = $tt.pgc.nrCells; $rec.programs = $tt.pgc.nrPrograms; $rec.audioControlEnabled = @($tt.pgc.audioStreamsEnabled); $rec.subpControlEnabled = @($tt.pgc.subpStreamsEnabled); $rec.hasAngleBlock = $tt.pgc.hasAngleBlock; $rec.cellSectorRange = $tt.pgc.sectorRange; $rec.cellBytes = $tt.pgc.totalBytes }
      $rec.ifoVideoAttr = $tt.videoAttr; $rec.ifoAudioDeclared = $tt.audioDeclared; $rec.ifoSubpDeclared = $tt.subpDeclared
    }
    if ($catByDv.ContainsKey($dv)) { $rec.makemkvTitle = ('t{0:D2}' -f [int]$catByDv[$dv].title); $rec.makemkvDuration = $catByDv[$dv].duration; $rec.mappingProvenBy = $catByDv[$dv].mappingProvenBy } else { $rec.makemkvTitle = $null }
    $a = @('-v', 'error', '-f', 'dvdvideo', '-title', "$dv", '-i', $stagePath, '-count_packets',
           '-show_entries', 'stream=index,codec_type,codec_name,profile,nb_read_packets,avg_frame_rate,r_frame_rate,sample_rate,channels,channel_layout,width,height,sample_aspect_ratio,display_aspect_ratio,field_order,pix_fmt,bit_rate:stream_tags=language:format=duration,bit_rate',
           '-of', 'json')
    $r = Invoke-Native $ffprobe $a "ffprobe title $dv"
    $rec.ffprobeExit = $r.Code
    $errLines = @($r.Err | Where-Object { "$_" -notmatch 'libdvdcss|CSS authentication|Can''t open|Could not open|Unable to open device' })
    if ($errLines.Count) { $rec.ffprobeStderr = @($errLines | Select-Object -Last 4) }
    $js = $null
    try { $js = (($r.Out -join "`n") | ConvertFrom-Json) } catch { }
    if ($r.Code -ne 0 -or -not $js -or -not $js.streams) {
      $rec.measured = $false
      $rec.unavailable = ("ffprobe -f dvdvideo -title {0} exit {1}: {2}" -f $dv, $r.Code, (($errLines | Select-Object -Last 2) -join ' / '))
      Add-Unavailable ("title dv{0} packets" -f $dv) $rec.unavailable
    } else {
      $rec.measured = $true
      $rec.formatDurationDeclared = $(if ($js.format -and $js.format.duration) { [double]$js.format.duration } else { $null })
      $streams = @()
      $videoSec = $null; $videoPkts = $null; $fps = $null
      foreach ($s in @($js.streams)) {
        $nbRaw = "$($s.nb_read_packets)"
        $nb = $(if ($nbRaw -match '^\d+$') { [int]$nbRaw } else { 0 })
        $st = [ordered]@{ index = $s.index; type = $s.codec_type; codec = $s.codec_name; packets = $nb; packetsKeyPresent = ($nbRaw -match '^\d+$') }
        if ("$($s.codec_type)" -eq 'video') {
          $fps = Convert-FpsString "$($s.avg_frame_rate)"
          $st.width = $s.width; $st.height = $s.height; $st.sar = $s.sample_aspect_ratio; $st.dar = $s.display_aspect_ratio; $st.fps = $fps; $st.rFrameRate = $s.r_frame_rate; $st.fieldOrder = $s.field_order; $st.pixFmt = $s.pix_fmt; $st.profile = $s.profile
          if ($fps -and $nb -gt 0) { $videoSec = [math]::Round($nb / $fps, 2); $videoPkts = $nb }
          $st.emittedSec = $videoSec
        } elseif ("$($s.codec_type)" -eq 'audio') {
          $st.sampleRate = $s.sample_rate; $st.channels = $s.channels; $st.layout = $s.channel_layout; $st.bitRate = $s.bit_rate; $st.lang = $(if ($s.tags) { $s.tags.language } else { $null })
          $st.derivedSec = Get-AudioSecondsFromPackets "$($s.codec_name)" $nb "$($s.sample_rate)"
        } elseif ("$($s.codec_type)" -eq 'subtitle') {
          $st.lang = $(if ($s.tags) { $s.tags.language } else { $null })
          $st.note = $(if ($nb -eq 0) { 'DECLARED BUT EMPTY: 0 packets after a full walk of the title (nb_read_packets absent)' } else { $null })
        }
        $streams += $st
      }
      $rec.streams = $streams
      $rec.videoPackets = $videoPkts; $rec.fps = $fps; $rec.emittedSec = $videoSec
      $rec.expectFrames = $videoPkts; $rec.expectSeconds = $videoSec
      $rec.audioPackets = @($streams | Where-Object { $_.type -eq 'audio' } | ForEach-Object { $_.packets })
      $rec.subtitlePackets = @($streams | Where-Object { $_.type -eq 'subtitle' } | ForEach-Object { $_.packets })
      $rec.subtitleStreamsSeen = @($streams | Where-Object { $_.type -eq 'subtitle' }).Count
      $rec.subtitleStreamsWithPackets = @($streams | Where-Object { $_.type -eq 'subtitle' -and $_.packets -gt 0 }).Count
      $rec.audioStreamsSeen = @($streams | Where-Object { $_.type -eq 'audio' }).Count
      if ($rec.declaredSec -and $videoSec) { $rec.deltaDeclaredMinusEmittedSec = [math]::Round([double]$rec.declaredSec - $videoSec, 2) }
    }
    $rec.probeSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
    $out += $rec
  }
  $pack.titles = $out
}

# ================================================================================== 8. RE-RIP WORKLIST ROW
Invoke-Section 'worklist' {
  $tsv = Join-Path $VideoRoot '_rerip-worklist.tsv'
  if (-not (Test-Path -LiteralPath $tsv)) { Add-Unavailable 'worklist' "no $tsv"; return }
  $lines = @(Get-Content -LiteralPath $tsv -Encoding UTF8)
  $header = @($lines | Where-Object { $_ -match '^Disc\t' } | Select-Object -First 1)
  $row = @($lines | Where-Object { $_ -notmatch '^#' -and ($_ -split "`t")[0].Trim() -eq $unit })
  $wl = [ordered]@{ path = $tsv; header = $(if ($header.Count) { $header[0] } else { $null }); rowVerbatim = @($row) }
  if ($row.Count -and $header.Count) {
    $cols = $header[0] -split "`t"; $vals = $row[0] -split "`t"
    $parsed = [ordered]@{}
    for ($i = 0; $i -lt $cols.Count; $i++) { $parsed[$cols[$i].Trim()] = $(if ($i -lt $vals.Count) { $vals[$i] } else { '' }) }
    $wl.parsed = $parsed
  } elseif (-not $row.Count) { $wl.note = 'this unit has NO row in the re-rip worklist' }
  $md = Join-Path $VideoRoot '_rerip-worklist.md'
  if (Test-Path -LiteralPath $md) {
    $wl.markdownMentions = @(Get-Content -LiteralPath $md -Encoding UTF8 | Select-String -SimpleMatch $unit | ForEach-Object { ('{0}: {1}' -f $_.LineNumber, $_.Line.Trim()) })
  }
  $um = Join-Path $VideoRoot 'updates_media2.txt'
  if (Test-Path -LiteralPath $um) {
    $wl.updatesMedia2Mentions = @(Get-Content -LiteralPath $um -Encoding UTF8 | Select-String -SimpleMatch $unit | ForEach-Object { ('{0}: {1}' -f $_.LineNumber, $_.Line.Trim()) })
    $wl.updatesMedia2Warning = 'updates_media2.txt is a FROZEN report; its supersedes: pairings are duration-derived and its own header says never to copy them'
  }
  $pack.worklist = $wl
}

# ================================================================================== 9. LIBRARY (Plex + NAS)
function Env-Fallback($n) { $v = [Environment]::GetEnvironmentVariable($n, 'Process'); if (-not $v) { $v = [Environment]::GetEnvironmentVariable($n, 'User') }; $v }

Invoke-Section 'library' {
  $lib = [ordered]@{}
  # ---- attribution rows (a prior audit's disc -> file attributions; CLAIMS) --------------------
  $attr = @()
  $auditFile = Join-Path $VideoRoot '_audit-transcribable-media2.json'
  if (Test-Path -LiteralPath $auditFile) {
    $aud = Read-JsonFile $auditFile
    foreach ($r in @($aud)) { if ("$($r.disc)" -eq $unit) { $attr += [ordered]@{ kind = $r.kind; work = $r.work; rel = $r.rel; tid = $r.tid; minutes = $r.minutes; note = $r.note; nasPath = ($NasRoot.TrimEnd('\') + '\' + $r.kind + '\' + $r.rel) } } }
  }
  $lib.attributions = [ordered]@{ source = $auditFile; note = 'a prior audit attributed these published files to this disc (by title id + runtime) - a claim to check, not a proof'; rows = $attr }

  # ---- identity register (NAS, governed) ------------------------------------------------------
  $reg = [ordered]@{}
  $discId = $pack.claims.discId
  if (-not $discId) { $reg.unavailable = 'no disc id'; Add-Unavailable 'identityRegister' 'no dvdid.xml to key the record' }
  elseif ($NoNas) { $reg.unavailable = '-NoNas'; Add-Unavailable 'identityRegister' '-NoNas' }
  else {
    $safe = ($discId -replace '[^A-Za-z0-9._-]', '_')
    $regFile = ($NasRoot.TrimEnd('\') + '\_disc-identity\' + $safe + '.json')
    $reg.path = $regFile
    $txt = Invoke-NasRead -Path $regFile -Label 'identity register' -Say $say -MaxWaitMinutes 2 -Do { if (Test-Path -LiteralPath $regFile) { Get-Content -LiteralPath $regFile -Raw } else { $null } }
    if ($txt) { try { $reg.record = ($txt | ConvertFrom-Json) } catch { $reg.unavailable = 'record did not parse'; Add-Unavailable 'identityRegister' 'record did not parse as JSON' } }
    else { $reg.record = $null; $reg.note = 'NO RECORD for this disc id' }
  }
  $lib.identityRegister = $reg

  # ---- resolve the work ------------------------------------------------------------------------
  $cands = @()
  if ($Work) { $cands += [ordered]@{ source = '-Work argument'; work = $Work; kind = $Kind } }
  foreach ($a in $attr) { $cands += [ordered]@{ source = 'attribution audit'; work = $a.work; kind = $a.kind } }
  if ($reg.record) {
    foreach ($t in @($reg.record.titles)) { if ($t.work) { $cands += [ordered]@{ source = 'identity register'; work = $t.work; kind = $t.kind } } }
    foreach ($o in @($reg.record.outputs)) { if ($o.path -and "$($o.path)" -match '\\Multimedia\\(Movies|Television Shows)\\([^\\]+)\\') { $cands += [ordered]@{ source = 'identity register outputs'; work = $Matches[2]; kind = $Matches[1] } } }
  }
  $mymTitle = $null
  if ($pack.claims.mymovies) { $mymTitle = $pack.claims.mymovies.LocalTitle }
  $nfoTitle = $null
  if ($pack.claims.nfo) { $nfoTitle = $pack.claims.nfo.title }
  $searchTerms = @()
  foreach ($s in @($mymTitle, $nfoTitle, $pack.inputs.showKeyHeuristic)) { if ($s) { $searchTerms += ($s -split '\s[:\-–]\s')[0].Trim() } }
  $searchTerms = @($searchTerms | Where-Object { $_ } | Sort-Object -Unique)
  $lib.workCandidatesFromRecords = $cands
  $lib.plexSearchTerms = $searchTerms

  # ---- Plex --------------------------------------------------------------------------------------
  $plex = [ordered]@{}
  $tok = Env-Fallback 'PLEX_TOKEN'; $base = Env-Fallback 'PLEX_BASEURL'
  $plexOk = (-not $NoPlex) -and $tok -and $base
  if ($NoPlex) { Add-Unavailable 'plex' '-NoPlex' } elseif (-not $plexOk) { Add-Unavailable 'plex' 'PLEX_TOKEN / PLEX_BASEURL not set (User scope)' }
  $h = @{ 'X-Plex-Token' = $tok }
  $base = "$base".TrimEnd('/')
  $found = @()      # [{kind, ratingKey, title, year, guid, items[]}]
  function Get-PlexXml([string]$path) { try { return [xml](Invoke-WebRequest ($base + $path) -Headers $h -UseBasicParsing -TimeoutSec 60).Content } catch { return $null } }
  function Convert-PlexItem($v, [string]$kind) {
    $files = @()
    foreach ($m in @($v.Media)) {
      if (-not $m) { continue }
      foreach ($p in @($m.Part)) {
        if (-not $p) { continue }
        $files += [ordered]@{ plexFile = $p.file; nasPath = (Get-NasPathFromPlexFile "$($p.file)"); bytes = $(if ($p.size) { [long]$p.size } else { $null }); durationSec = $(if ($p.duration) { [math]::Round([double]$p.duration / 1000, 3) } else { $null }); container = $p.container
                             mediaId = $m.id; width = $m.width; height = $m.height; bitrateKbps = $m.bitrate; aspectRatio = $m.aspectRatio; videoCodec = $m.videoCodec; audioCodec = $m.audioCodec; audioChannels = $m.audioChannels; videoResolution = $m.videoResolution; videoFrameRate = $m.videoFrameRate }
      }
    }
    return [ordered]@{ ratingKey = $v.ratingKey; type = $v.type; title = $v.title; year = $v.year; season = $v.parentIndex; episode = $v.index; durationSec = $(if ($v.duration) { [math]::Round([double]$v.duration / 1000, 3) } else { $null }); guid = $v.guid; addedAt = $v.addedAt; files = $files }
  }
  if ($plexOk) {
    foreach ($term in $searchTerms) {
      $q = [uri]::EscapeDataString($term)
      $x = Get-PlexXml "/library/sections/6/all?title=$q"
      if ($x) { foreach ($v in @($x.MediaContainer.Video)) { if ($v) { $found += [ordered]@{ kind = 'Movies'; searchTerm = $term; ratingKey = $v.ratingKey; title = $v.title; year = $v.year; guid = $v.guid; item = (Convert-PlexItem $v 'Movies') } } } }
      $z = Get-PlexXml "/library/sections/5/all?type=2&title=$q"
      if ($z) { foreach ($d in @($z.MediaContainer.Directory)) { if ($d) { $found += [ordered]@{ kind = 'Television Shows'; searchTerm = $term; ratingKey = $d.ratingKey; title = $d.title; year = $d.year; guid = $d.guid; leafCount = $d.leafCount; childCount = $d.childCount } } } }
    }
    # de-duplicate by ratingKey
    $seen = @{}; $uniq = @()
    foreach ($f in $found) { if (-not $seen.ContainsKey("$($f.ratingKey)")) { $seen["$($f.ratingKey)"] = $true; $uniq += $f } }
    $found = $uniq
    $plex.matches = @($found | ForEach-Object { [ordered]@{ kind = $_.kind; ratingKey = $_.ratingKey; title = $_.title; year = $_.year; guid = $_.guid; searchTerm = $_.searchTerm; leafCount = $_.leafCount } })
  }

  # choose the work: explicit -Work/-Kind; else a single Plex match; else a single record candidate; else ambiguous
  $chosen = $null; $how = $null
  if ($Work -and $Kind) {
    $chosen = [ordered]@{ work = $Work; kind = $Kind }; $how = '-Work/-Kind arguments'
    $pm = @($found | Where-Object { $_.kind -eq $Kind -and ($_.title -eq $Work -or $_.title -eq ($Work -replace '\s\(\d{4}\)$', '')) })
    if ($pm.Count) { $chosen.plex = $pm[0] }
  } elseif ($found.Count -eq 1) {
    $chosen = [ordered]@{ work = $found[0].title; kind = $found[0].kind; plex = $found[0] }; $how = 'single Plex match on the search terms'
  } elseif ($found.Count -gt 1) {
    # prefer a Plex match whose kind+title agrees with a record candidate
    $agree = @()
    foreach ($f in $found) { foreach ($c in $cands) { if ($c.kind -eq $f.kind -and (("$($c.work)" -replace '\s\(\d{4}\)$', '').ToLowerInvariant() -eq ("$($f.title)").ToLowerInvariant())) { $agree += $f } } }
    $agree = @($agree | Sort-Object { $_.ratingKey } -Unique)
    if ($agree.Count -eq 1) { $chosen = [ordered]@{ work = $agree[0].title; kind = $agree[0].kind; plex = $agree[0] }; $how = 'Plex match agreeing with a record candidate' }
  } elseif ($cands.Count) {
    $distinct = @($cands | ForEach-Object { "$($_.kind)|$($_.work)" } | Sort-Object -Unique)
    if ($distinct.Count -eq 1) { $chosen = [ordered]@{ work = $cands[0].work; kind = $cands[0].kind }; $how = 'single record candidate (no Plex match)' }
  }
  $lib.workResolution = [ordered]@{ chosen = $(if ($chosen) { [ordered]@{ work = $chosen.work; kind = $chosen.kind; plexRatingKey = $(if ($chosen.plex) { $chosen.plex.ratingKey } else { $null }) } } else { $null }); how = $how }
  if (-not $chosen) {
    Add-Unavailable 'library.work' ("could not resolve ONE library work: {0} Plex match(es) [{1}], {2} record candidate(s) [{3}]. Re-run with -Work '<name>' -Kind 'Movies|Television Shows'" -f $found.Count, (($found | ForEach-Object { "$($_.kind): $($_.title)" }) -join '; '), $cands.Count, (($cands | ForEach-Object { "$($_.kind): $($_.work)" }) -join '; '))
  }

  # ---- Plex items of the chosen work -------------------------------------------------------------
  $items = @()
  if ($chosen -and $chosen.plex -and $plexOk) {
    $rk = $chosen.plex.ratingKey
    if ($chosen.kind -eq 'Movies') {
      $items += $chosen.plex.item
      $x = Get-PlexXml "/library/metadata/$rk"
      if ($x -and $x.MediaContainer.Video) {
        $items[0].streams = @($x.MediaContainer.Video.Media | ForEach-Object { $mid = $_.id; foreach ($p in @($_.Part)) { foreach ($s in @($p.Stream)) { if ($s) { [ordered]@{ mediaId = $mid; streamType = $s.streamType; codec = $s.codec; language = $s.language; languageTag = $s.languageTag; title = $s.title; channels = $s.channels; width = $s.width; height = $s.height; frameRate = $s.frameRate; bitrate = $s.bitrate; profile = $s.profile; default = $s.default; displayTitle = $s.displayTitle; key = $s.key } } } } })
        # local extras subfolders show up as Extras on the item
        $ex = Get-PlexXml "/library/metadata/$rk/extras"
        if ($ex) { $items[0].extras = @($ex.MediaContainer.Video | Where-Object { $_ } | ForEach-Object { [ordered]@{ title = $_.title; subtype = $_.subtype; durationSec = $(if ($_.duration) { [math]::Round([double]$_.duration / 1000, 3) } else { $null }); files = @(Convert-PlexItem $_ 'Movies').files } }) }
      }
      $lib.plexLocations = @()
    } else {
      $L = Get-PlexXml "/library/metadata/$rk/allLeaves"
      if ($L) { foreach ($v in @($L.MediaContainer.Video)) { if ($v) { $items += (Convert-PlexItem $v 'Television Shows') } } }
      $S = Get-PlexXml "/library/metadata/$rk"
      if ($S) { $lib.plexLocations = @($S.MediaContainer.Directory.Location | ForEach-Object { $_.path }) }
    }
  }
  $plex.items = $items
  $plex.itemCount = $items.Count
  $lib.plex = $plex

  # ---- NAS: folder listing (governed) ------------------------------------------------------------
  $nas = [ordered]@{}
  $workFolder = $null
  if ($chosen) {
    if ($items.Count) {
      $first = @($items | ForEach-Object { $_.files } | Where-Object { $_.nasPath })[0]
      if ($first) {
        $rel = $first.nasPath.Substring($NasRoot.TrimEnd('\').Length + 1)
        $parts = $rel -split '\\'
        if ($parts.Count -ge 2) { $workFolder = $NasRoot.TrimEnd('\') + '\' + $parts[0] + '\' + $parts[1] }
      }
    }
    if (-not $workFolder) { $workFolder = $NasRoot.TrimEnd('\') + '\' + $chosen.kind + '\' + $chosen.work }
  }
  $nas.workFolder = $workFolder
  $listing = @()
  if (-not $chosen) { $nas.unavailable = 'work not resolved' }
  elseif ($NoNas) { $nas.unavailable = '-NoNas'; Add-Unavailable 'nas.listing' '-NoNas' }
  else {
    $exists = Invoke-NasRead -Path $workFolder -Label 'work folder exists' -Say $say -MaxWaitMinutes 2 -Do { Test-Path -LiteralPath $workFolder -PathType Container }
    $nas.workFolderExists = [bool]$exists
    if ($exists) {
      $listing = Invoke-NasRead -Path $workFolder -Label 'work folder listing' -Say $say -MaxWaitMinutes 2 -Do {
        @(Get-ChildItem -LiteralPath $workFolder -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
          $ext = $_.Extension.ToLowerInvariant()
          [ordered]@{ path = $_.FullName; rel = $_.FullName.Substring($workFolder.Length + 1); bytes = $_.Length; mtime = $_.LastWriteTime.ToString('s'); ctime = $_.CreationTime.ToString('s')
                      kind = $(if ($ext -in @('.mkv', '.mp4', '.m4v', '.avi', '.ts', '.mov')) { 'media' } elseif ($ext -eq '.srt') { 'srt' } elseif ($ext -eq '.json') { 'json' } elseif ($ext -in @('.jpg', '.png', '.jpeg')) { 'art' } else { 'other' }) } })
      }
      $listing = @($listing)
    } else { Add-Unavailable 'nas.listing' ("work folder does not exist on the NAS: {0}" -f $workFolder) }
    # sister folders that differ only by a (year) suffix or capitalisation - the split-work trap
    if ($chosen) {
      $kindRoot = $NasRoot.TrimEnd('\') + '\' + $chosen.kind
      $stem = (($chosen.work -replace '\s\(\d{4}\)$', '') -replace '[^A-Za-z0-9]', '').ToLowerInvariant()
      $sibs = Invoke-NasRead -Path $kindRoot -Label 'sibling folders' -Say $say -MaxWaitMinutes 2 -Do {
        @(Get-ChildItem -LiteralPath $kindRoot -Directory -ErrorAction SilentlyContinue | Where-Object { (($_.Name -replace '\s\(\d{4}\)$', '') -replace '[^A-Za-z0-9]', '').ToLowerInvariant() -eq $stem } | ForEach-Object { $_.FullName })
      }
      $nas.foldersWithSameStem = @($sibs)
    }
  }
  $media = @($listing | Where-Object { $_.kind -eq 'media' })
  foreach ($m in $media) {
    $stemPath = [IO.Path]::Combine([IO.Path]::GetDirectoryName($m.path), [IO.Path]::GetFileNameWithoutExtension($m.path))
    $m.sidecars = @($listing | Where-Object { $_.kind -ne 'media' -and $_.path.StartsWith($stemPath + '.', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { $_.rel })
  }
  $nas.listing = $listing
  $nas.mediaCount = $media.Count
  $nas.listingBytes = ($listing | ForEach-Object { [long]$_.bytes } | Measure-Object -Sum).Sum

  # ---- NAS: header probes (governed, bounded) ------------------------------------------------------
  $probes = @()
  $discSecs = @()
  if ($pack.titles) { $discSecs = @($pack.titles | ForEach-Object { if ($_.emittedSec) { [double]$_.emittedSec } elseif ($_.declaredSec) { [double]$_.declaredSec } }) }
  $plexDur = @{}
  foreach ($it in $items) { foreach ($f in $it.files) { if ($f.nasPath -and $f.durationSec) { $plexDur[$f.nasPath.ToLowerInvariant()] = [double]$f.durationSec } } }
  $attrPaths = @($attr | ForEach-Object { $_.nasPath.ToLowerInvariant() })
  $toProbe = @()
  if ($media.Count -le $NasProbeMax) { $toProbe = $media; $nas.probeSelection = ("all {0} media files (<= NasProbeMax {1})" -f $media.Count, $NasProbeMax) }
  else {
    foreach ($m in $media) {
      $lp = $m.path.ToLowerInvariant()
      $why = @()
      if ($attrPaths -contains $lp) { $why += 'attributed to this disc' }
      if ($plexDur.ContainsKey($lp)) { foreach ($d in $discSecs) { if ([math]::Abs($plexDur[$lp] - $d) -le $CandidateWindowSec) { $why += ('duration within {0} s of a disc title' -f $CandidateWindowSec); break } } }
      elseif ($discSecs.Count) { $why += 'no Plex duration known' }
      if ($why.Count) { $m.probeWhy = ($why -join '; '); $toProbe += $m }
    }
    $nas.probeSelection = ("{0} of {1} media files: attributed to this disc, or Plex duration within {2} s of a disc title, or unknown to Plex; capped at {3}" -f $toProbe.Count, $media.Count, $CandidateWindowSec, $NasProbeMax)
    if ($toProbe.Count -gt $NasProbeMax) { $toProbe = @($toProbe | Select-Object -First $NasProbeMax); $nas.probeSelection += ' (CAP HIT)' }
  }
  if ($NoNas -or -not $ffprobe) { if ($media.Count) { Add-Unavailable 'nas.probes' $(if ($NoNas) { '-NoNas' } else { 'ffprobe not found' }) } }
  else {
    foreach ($m in $toProbe) {
      $path = $m.path
      $pr = [ordered]@{ path = $path; rel = $m.rel }
      $r = Invoke-NasRead -Path $path -Label ('probe ' + $m.rel) -Say $say -MaxWaitMinutes 2 -Do {
        Invoke-Native $ffprobe @('-v', 'error', '-i', $path, '-show_entries', 'format=duration,bit_rate,size,format_name:stream=index,codec_type,codec_name,profile,width,height,sample_aspect_ratio,display_aspect_ratio,avg_frame_rate,field_order,channels,channel_layout,sample_rate,bit_rate:stream_tags=language,title:stream_disposition=default', '-of', 'json') ('probe ' + $m.rel)
      }
      $js = $null
      try { $js = (($r.Out -join "`n") | ConvertFrom-Json) } catch { }
      if ($r.Code -ne 0 -or -not $js) { $pr.unavailable = ("ffprobe exit {0}: {1}" -f $r.Code, (($r.Err | Select-Object -Last 2) -join ' / ')); Add-Unavailable ('nas.probe ' + $m.rel) $pr.unavailable }
      else {
        $pr.durationSec = $(if ($js.format.duration) { [double]$js.format.duration } else { $null })
        $pr.bitRate = $js.format.bit_rate; $pr.formatName = $js.format.format_name
        $pr.streams = @($js.streams | ForEach-Object {
          $s = $_
          $o = [ordered]@{ index = $s.index; type = $s.codec_type; codec = $s.codec_name; lang = $(if ($s.tags) { $s.tags.language } else { $null }); title = $(if ($s.tags) { $s.tags.title } else { $null }); default = $(if ($s.disposition) { $s.disposition.default } else { $null }) }
          if ("$($s.codec_type)" -eq 'video') { $o.width = $s.width; $o.height = $s.height; $o.sar = $s.sample_aspect_ratio; $o.dar = $s.display_aspect_ratio; $o.fps = (Convert-FpsString "$($s.avg_frame_rate)"); $o.fieldOrder = $s.field_order; $o.profile = $s.profile; $o.bitRate = $s.bit_rate }
          if ("$($s.codec_type)" -eq 'audio') { $o.channels = $s.channels; $o.layout = $s.channel_layout; $o.sampleRate = $s.sample_rate; $o.bitRate = $s.bit_rate }
          $o })
        $pr.subtitleStreams = @($pr.streams | Where-Object { $_.type -eq 'subtitle' } | ForEach-Object { ('{0}/{1}' -f $_.codec, $_.lang) })
        $pr.audioStreams = @($pr.streams | Where-Object { $_.type -eq 'audio' } | ForEach-Object { ('{0} {1}ch {2}' -f $_.codec, $_.channels, $_.lang) })
      }
      $probes += $pr
    }
  }
  $nas.probes = $probes
  $notProbed = @($media | Where-Object { $p = $_.path; -not ($toProbe | Where-Object { $_.path -eq $p }) })
  if ($notProbed.Count) { Add-Unavailable 'nas.probes(unselected)' ("{0} media file(s) in the work folder were not ffprobed (over the selection rule); their Plex durations are in library.plex.items" -f $notProbed.Count) }
  $lib.nas = $nas

  # ---- duration candidates: disc title <-> library file --------------------------------------------
  $dc = @()
  $known = @{}   # nasPath(lower) -> [ordered]{path, durationSec, source}
  foreach ($it in $items) { foreach ($f in $it.files) { if ($f.nasPath -and $f.durationSec) { $known[$f.nasPath.ToLowerInvariant()] = [ordered]@{ path = $f.nasPath; durationSec = [double]$f.durationSec; source = 'plex'; plexTitle = $it.title; season = $it.season; episode = $it.episode } } } }
  foreach ($p in $probes) { if ($p.durationSec) { $known[$p.path.ToLowerInvariant()] = [ordered]@{ path = $p.path; durationSec = [double]$p.durationSec; source = 'ffprobe'; plexTitle = $(if ($known.ContainsKey($p.path.ToLowerInvariant())) { $known[$p.path.ToLowerInvariant()].plexTitle } else { $null }) } } }
  foreach ($t in @($pack.titles)) {
    $sec = $(if ($t.emittedSec) { [double]$t.emittedSec } elseif ($t.declaredSec) { [double]$t.declaredSec } else { $null })
    if ($null -eq $sec) { continue }
    $hits = @()
    foreach ($k in $known.Values) {
      $delta = [math]::Round($k.durationSec - $sec, 3)
      if ([math]::Abs($delta) -le $CandidateWindowSec) { $hits += [ordered]@{ path = $k.path; durationSec = $k.durationSec; deltaSec = $delta; withinExact = ([math]::Abs($delta) -le $ExactMatchSec); source = $k.source; plexTitle = $k.plexTitle } }
    }
    $dc += [ordered]@{ dvdvideoTitle = $t.dvdvideoTitle; makemkvTitle = $t.makemkvTitle; discSec = $sec; basis = $(if ($t.emittedSec) { 'emitted (packets/fps)' } else { 'declared (IFO)' }); candidates = @($hits | Sort-Object { [math]::Abs($_.deltaSec) }) }
  }
  $lib.durationCandidates = [ordered]@{ windowSec = $CandidateWindowSec; exactSec = $ExactMatchSec; note = 'DURATION SAYS HOW MANY ITEMS FIT, NEVER WHICH. Corroboration only.'; rows = $dc }

  # ---- subtitle-coverage rows for the work (local CSV) ---------------------------------------------
  $cov = Join-Path $VideoRoot '_subtitle-coverage.csv'
  if ((Test-Path -LiteralPath $cov) -and $chosen) {
    $rows = @()
    try {
      $all = Import-Csv -LiteralPath $cov
      $wf = $(if ($workFolder) { $workFolder.ToLowerInvariant() } else { '' })
      foreach ($r in $all) { if (($wf -and "$($r.MkvPath)".ToLowerInvariant().StartsWith($wf)) -or ("$($r.Work)" -eq $chosen.work)) { $rows += [ordered]@{ file = $r.File; category = $r.Category; evidence = $r.Evidence; bitmapProbe = $r.BitmapProbe; audioProbe = $r.AudioProbe; probedAt = $r.ProbedAt; mkvPath = $r.MkvPath } } }
    } catch { Add-Unavailable 'subtitleCoverage' ("could not read " + $cov + ": " + $_.Exception.Message) }
    $lib.subtitleCoverage = [ordered]@{ source = $cov; rows = $rows }
  } elseif ($chosen) { Add-Unavailable 'subtitleCoverage' "no $cov" }
  $pack.library = $lib
}

# ================================================================================== 10. SUPERSEDES CANDIDATES
Invoke-Section 'supersedes' {
  $cands = @()
  $lib = $pack.library
  if ($pack.worklist -and $pack.worklist.parsed) {
    $sc = "$($pack.worklist.parsed.SupersedesCandidate)"
    $cands += [ordered]@{ source = '_rerip-worklist.tsv SupersedesCandidate'; text = $sc; path = $(if ($sc -match '^\\\\') { $sc } else { $null }) }
  }
  if ($lib -and $lib.attributions) { foreach ($a in $lib.attributions.rows) { $cands += [ordered]@{ source = 'attribution audit row'; text = $a.rel; path = $a.nasPath } } }
  if ($lib -and $lib.identityRegister -and $lib.identityRegister.record) { foreach ($o in @($lib.identityRegister.record.outputs)) { if ($o -and $o.path) { $cands += [ordered]@{ source = 'identity register outputs[]'; text = "$($o.source) -> $($o.path)"; path = "$($o.path)" } } } }
  if ($pack.worklist -and $pack.worklist.updatesMedia2Mentions) {
    foreach ($l in $pack.worklist.updatesMedia2Mentions) { if ($l -match 'supersedes:\s*(\\\\\S.*?)\s*$') { $cands += [ordered]@{ source = 'updates_media2.txt (UNSAFE, duration-derived)'; text = $l; path = $Matches[1] } } }
  }
  # legacy non-mkv media in the work folder are supersede-shaped by definition
  if ($lib -and $lib.nas -and $lib.nas.listing) { foreach ($m in @($lib.nas.listing | Where-Object { $_.kind -eq 'media' -and $_.path -notmatch '\.mkv$' })) { $cands += [ordered]@{ source = 'legacy non-.mkv media in the work folder'; text = $m.rel; path = $m.path } } }
  foreach ($c in $cands) {
    if ($c.path) {
      if ($NoNas) { $c.exists = $null; $c.note = '-NoNas' }
      else {
        $p = $c.path
        $r = Invoke-NasRead -Path $p -Label ('exists? ' + (Split-Path $p -Leaf)) -Say $say -MaxWaitMinutes 2 -Do { if (Test-Path -LiteralPath $p -PathType Leaf) { $i = Get-Item -LiteralPath $p; [ordered]@{ exists = $true; bytes = $i.Length; mtime = $i.LastWriteTime.ToString('s') } } else { [ordered]@{ exists = $false } } }
        $c.exists = $r.exists; if ($r.exists) { $c.bytes = $r.bytes; $c.mtime = $r.mtime }
      }
    } else { $c.exists = $null }
  }
  if ($NoNas -and $cands.Count) { Add-Unavailable 'supersedes.exists' '-NoNas: candidate paths were not Test-Path-ed' }
  $pack.supersedes = [ordered]@{ note = 'CANDIDATES only, each resolved exists/not on the NAS. A supersedes claim is established from CONTENT.'; candidates = $cands }
}

# ================================================================================== 11. CORRELATE (optional)
Invoke-Section 'correlate' {
  if (-not $Correlate) { Add-Unavailable 'correlate' 'not requested (-Correlate): envelope correlation disc title <-> NAS candidates was not measured'; return }
  if ($NoNas) { Add-Unavailable 'correlate' '-NoNas'; return }
  if (-not (Test-Path -LiteralPath $correlator)) { Add-Unavailable 'correlate' 'audio-envelope-correlate.py missing'; return }
  if (-not $pack.library -or -not $pack.library.durationCandidates) { Add-Unavailable 'correlate' 'no duration candidates to correlate against'; return }
  $results = @()
  foreach ($row in @($pack.library.durationCandidates.rows)) {
    if (-not $row.candidates.Count) { continue }
    $dv = [int]$row.dvdvideoTitle; $sec = [double]$row.discSec
    if ($sec -lt 90) { continue }
    $offsets = @()
    for ($i = 1; $i -le $CorrelateOffsets; $i++) { $offsets += [int]($sec * $i / ($CorrelateOffsets + 1)) }
    foreach ($cand in @($row.candidates | Select-Object -First 3)) {
      foreach ($off in $offsets) {
        $discWav = Join-Path $scratch ('disc-dv{0}-{1}.wav' -f $dv, $off)
        $nasWav = Join-Path $scratch ('nas-dv{0}-{1}-{2}.wav' -f $dv, $off, [IO.Path]::GetFileNameWithoutExtension($cand.path) -replace '[^A-Za-z0-9]', '')
        $d = Invoke-Native $ffmpeg @('-v', 'error', '-y', '-f', 'dvdvideo', '-title', "$dv", '-i', $stagePath, '-ss', "$off", '-t', "$CorrelateWindowSec", '-vn', '-ac', '1', '-ar', '8000', '-c:a', 'pcm_s16le', $discWav) 'disc window'
        $nasPath = $cand.path
        $nasOff = [math]::Max(0, $off - 10)
        $n = Invoke-NasRead -Path $nasPath -Label ('audio window ' + (Split-Path $nasPath -Leaf) + " @$off") -Say $say -MaxWaitMinutes 2 -Do {
          Invoke-Native $ffmpeg @('-v', 'error', '-y', '-ss', "$nasOff", '-i', $nasPath, '-t', "$($CorrelateWindowSec + 20)", '-vn', '-ac', '1', '-ar', '8000', '-c:a', 'pcm_s16le', $nasWav) 'nas window'
        }
        $rec = [ordered]@{ dvdvideoTitle = $dv; offsetSec = $off; nasPath = $nasPath; nasWindowStart = $nasOff }
        if (-not (Test-Path -LiteralPath $discWav) -or -not (Test-Path -LiteralPath $nasWav)) { $rec.unavailable = 'a window could not be extracted'; $results += $rec; continue }
        $c = Invoke-Native 'python' @($correlator, $discWav, $nasWav, '--max-lag', '12', '--json') 'correlate'
        try { $cj = (($c.Out -join "`n") | ConvertFrom-Json); $rec.r = $cj.r; $rec.lagMs = $(if ($null -ne $cj.lagMs) { [int]$cj.lagMs - 10000 } else { $null }); $rec.rAtZeroLag = $cj.rAtZeroLag; $rec.method = $cj.method; $rec.note = 'lagMs is disc-relative: NAS window starts 10 s before the disc offset, so 0 = aligned' } catch { $rec.unavailable = 'correlator output did not parse' }
        $results += $rec
      }
    }
  }
  $pack.correlate = [ordered]@{ windowSec = $CorrelateWindowSec; offsetsPerTitle = $CorrelateOffsets; rows = $results }
}

# ================================================================================== FINISH
$pack.unavailable = @($unavailable)
$pack.timings = $timings
$pack.runtimeSeconds = [math]::Round($script:Sw.Elapsed.TotalSeconds, 1)
$pack.meta.runtimeSeconds = $pack.runtimeSeconds

# ---------------------------------------------------------------------------------- text render
function Fmt($v) { if ($null -eq $v) { return '-' } ; return "$v" }
function Bytes($b) { if ($null -eq $b) { return '-' }; return ('{0:N0}' -f [long]$b) }
$L = [System.Collections.Generic.List[string]]::new()
function Add([string]$s) { $L.Add($s) }
function H1([string]$s) { Add ''; Add ('=' * 100); Add ('  ' + $s); Add ('=' * 100) }
function H2([string]$s) { Add ''; Add ('---- ' + $s + ' ' + ('-' * [math]::Max(0, 92 - $s.Length))) }

Add ("EVIDENCE PACK  {0}   generated {1}   runtime {2} s   {3}" -f $unit, $pack.meta.generated, $pack.runtimeSeconds, $script:Version)
Add ("FACTS ONLY - no verdicts. JSON with every field: {0}" -f $outJson)
Add ("Evidence images (menu/still frames, contact sheets): {0}" -f $evDir)
H1 'UNAVAILABLE - measurements NOT taken (measure these yourself; everything else below was measured)'
if ($unavailable.Count -eq 0) { Add '  none' } else { foreach ($u in $unavailable) { Add ("  {0,-34} {1}" -f $u.measurement, $u.reason) } }

H1 'INPUTS'
$in = $pack.inputs
Add ("  staging      {0}   present={1}   VIDEO_TS={2}   bytes={3}" -f $in.stagePath, $in.stagePresent, $in.videoTsPresent, (Bytes $in.videoTsBytes))
Add ("  catalogue    {0}   present={1}   mtime={2}" -f $in.catalogueJson, $in.cataloguePresent, (Fmt $in.catalogueMtime))
Add ("  makemkv log  {0}   present={1}   mtime={2}" -f $in.makemkvLog, $in.makemkvLogPresent, (Fmt $in.makemkvLogMtime))
Add ("  in _fetch-done.txt={0}   in _completed.txt={1}   dispositions file present={2}" -f $in.inFetchDone, $in.inCompleted, $in.dispositionsPresent)
Add ("  unit stage targets: {0}" -f (($in.unitStageTargets) -join ' ; '))
if ($in.ripFiles.Count) { Add ("  rip files: {0}" -f (($in.ripFiles | ForEach-Object { '{0} ({1})' -f (Split-Path $_.path -Leaf), (Bytes $_.bytes) }) -join ', ')) }
Add ("  tracks.json: {0}" -f $(if ($in.tracksJson.Count) { $in.tracksJson -join ', ' } else { 'none' }))
Add ("  show key (heuristic, sisters only): '{0}'   Season 00 allocation files: {1}" -f $in.showKeyHeuristic, $(if ($in.season00AllocationFiles.Count) { $in.season00AllocationFiles -join ', ' } else { 'none' }))
Add ("  sister dispositions: {0}" -f $(if ($in.sisterDispositions.Count) { $in.sisterDispositions -join ', ' } else { 'none' }))
if ($in.videoTsFiles.Count) { Add '  VIDEO_TS files:'; foreach ($f in $in.videoTsFiles) { Add ("    {0,-22} {1,16}" -f $f.name, (Bytes $f.bytes)) } }
if ($in.stageTopLevel.Count) { Add ("  staging top level: {0}" -f (($in.stageTopLevel | ForEach-Object { $_.name + $(if ($_.dir) { '/' } else { '' }) + $(if ($_.hidden) { ' [hidden]' } else { '' }) }) -join ', ')) }

H1 'CLAIMS (metadata files - never evidence)'
$c = $pack.claims
Add ("  disc id: {0}" -f (Fmt $c.discId))
if ($c.mymovies) {
  $mm = $c.mymovies
  Add ("  mymovies.xml: LocalTitle='{0}'  LocalTitleDisplay='{1}'  year={2}  IMDB={3}  Studio={4}  RunningTime={5}" -f $mm.LocalTitle, (Fmt $mm.LocalTitleDisplay), (Fmt $mm.ProductionYear), (Fmt $mm.IMDB), (Fmt $mm.Studio), (Fmt $mm.RunningTime))
  foreach ($d in @($mm.discs)) {
    Add ("    disc '{0}'{1}  ({2} titles)" -f $d.name, $(if ($d.thisDiscByLocalTitleDisplay) { '  <- THIS DISC per LocalTitleDisplay' } else { '' }), @($d.titles).Count)
    foreach ($t in @($d.titles)) { Add ("      title {0,2}  {1,10}  {2,7} s  chapters={3,2}  episode={4}  S{5}E{6}  '{7}'" -f $t.number, $t.hms, $t.seconds, $t.chapters, $t.containsEpisode, $t.tvSeason, $t.tvEpisode, $t.titleText) }
  }
}
if ($c.nfo) { $n = $c.nfo; Add ("  movie.nfo: title='{0}' year={1} id={2} runtime={3} studio={4} director={5}" -f (Fmt $n.title), (Fmt $n.year), (Fmt $n.id), (Fmt $n.runtime), (Fmt $n.studio), (Fmt $n.director)) }

H1 'CATALOGUE (MakeMKV enumeration + sweep evidence)'
if ($pack.catalogue) {
  $ct = $pack.catalogue
  Add ("  discType={0}  minLength={1}  titleCount={2}  sourceVerified={3}" -f $ct.discType, $ct.minLength, $ct.titleCount, $ct.sourceVerified)
  Add ("  titleNumbering: {0}" -f (Fmt $ct.titleNumbering))
  foreach ($r in $ct.rows) {
    Add ''
    Add ("  {0}  duration {1}  dvdvideoTitle={2}  ambiguous={3}  sizeBytes={4}  disposition={5}" -f $r.makemkvId, $r.duration, (Fmt $r.dvdvideoTitle), $r.mappingAmbiguous, (Bytes $r.sizeBytes), (Fmt $r.disposition))
    Add ("      provenBy: {0}" -f (Fmt $r.mappingProvenBy))
    Add ("      frames: {0}" -f (($r.frames | ForEach-Object { Split-Path $_ -Leaf }) -join ', '))
    Add ("      headStrip: {0}   speechStatus: {1}" -f (Fmt $(if ($r.headStrip) { Split-Path $r.headStrip -Leaf } else { $null })), (Fmt $r.speechStatus))
    if ($r.speechSample) { foreach ($ln in ("$($r.speechSample)" -split "`n")) { Add ("      speech: " + $ln) } }
    foreach ($e in $r.speechSamplesExtra) { Add ("      speech@{0}s (dv{1}, {2}): {3}" -f $e.offsetSec, $e.dvdvideoTitle, $e.capturedBy, $e.text) }
    if ($r.evidenceNote) { Add ("      note: " + $r.evidenceNote) }
  }
}

H1 'MAKEMKV LOG SCAN'
if ($pack.makemkvLog) {
  $ml = $pack.makemkvLog
  Add ("  {0}  ({1} lines)  titles enumerated: {2}{3}" -f $ml.path, $ml.lines, $ml.titlesEnumerated, $(if ($ml.note) { '   NOTE: ' + $ml.note } else { '' }))
  foreach ($t in $ml.titlesAdded) { Add ("    added: " + $t.text) }
  if ($ml.cellsRemovedWarnings.Count) { Add '  *** CELL REMOVAL WARNINGS ***'; foreach ($w in $ml.cellsRemovedWarnings) { Add ("    {0}   (logged right after Title #{1} was added)" -f $w.text, (Fmt $w.afterTitleAdded)) } } else { Add '  cell-removal warnings (MSG:3038): none' }
  if ($ml.decodeFailures.Count) { Add '  *** DECODE FAILURES ***'; foreach ($w in $ml.decodeFailures) { Add ("    " + $w) } } else { Add '  decode failures (MSG:5043): none' }
  foreach ($w in $ml.skippedShortTitles) { Add ("  skipped: " + $w) }
  foreach ($w in $ml.identicalSubtitleSkips) { Add ("  subtitle skip: " + $w) }
  foreach ($w in $ml.otherMessages) { Add ("  MSG:{0}: {1}" -f $w.code, $w.text) }
  foreach ($t in $ml.titles) {
    Add ("  t{0:D2}  {1}  {2} B  source-title claim (TINFO 24)={3}  chapters={4}  segments={5}" -f $t.makemkvTitle, (Fmt $t.duration), (Bytes $t.sizeBytes), (Fmt $t.sourceTitleClaim), (Fmt $t.chapters), (Fmt $t.segmentMap))
    foreach ($s in $t.streams) { Add ("        s{0} {1,-9} {2,-10} {3,-4} {4} {5}" -f $s.stream, (Fmt $s.type), (Fmt $s.codecId), (Fmt $s.lang), (Fmt $s.description), $(if ($s.resolution) { $s.resolution + ' ' + $s.aspect + ' ' + $s.fps + 'fps' } else { '' })) }
  }
}

H1 'BYTE PROOF (prove-dvd-mapping.py, verbatim)'
if ($pack.byteProof) {
  $bp = $pack.byteProof
  Add ("  info-file: {0}   text exit={1}   json exit={2}   verify-claims exit={3} ran={4}" -f (Fmt $bp.infoFile), $bp.textExit, $bp.jsonExit, (Fmt $bp.verifyClaimsExit), (Fmt $bp.verifyClaimsRan))
  foreach ($ln in $bp.textVerbatim) { Add ('  | ' + $ln) }
  if ($bp.verifyClaimsVerbatim) { H2 '--verify-claims (verbatim)'; foreach ($ln in $bp.verifyClaimsVerbatim) { Add ('  | ' + $ln) } }
}

H1 'IFO DECLARATIONS'
if ($pack.ifo) {
  $v = $pack.ifo.vmg
  Add ("  VIDEO_TS.IFO: {0} title set(s); TT_SRPT declares {1} title(s); VMGM video attr {2} ({3} {4} {5}); VMGM audio={6} subp={7}; VIDEO_TS.VOB={8}" -f $v.nrTitleSets, @($v.ttSrpt).Count, $v.vmgmVideoAttr.raw, $v.vmgmVideoAttr.mpeg, $v.vmgmVideoAttr.standard, $v.vmgmVideoAttr.aspect, $v.vmgmAudio.count, $v.vmgmSubp.count, $(if ($v.menuVob) { (Bytes $v.menuVob.bytes) + ' B = ' + $v.menuVob.sectors + ' sectors' } else { 'ABSENT' }))
  Add '  TT_SRPT:'
  foreach ($t in $v.ttSrpt) { Add ("    dvdvideo {0,2}  VTSN={1,2} VTS_TTN={2}  ptts={3,2}  angles={4}  playbackType={5}" -f $t.title, $t.vtsn, $t.vts_ttn, $t.nr_of_ptts, $t.nrOfAngles, $t.playbackType) }
  if (@($pack.ifo.declaredVtsMissingOnDisk).Count) { Add ("  *** VTS DECLARED BUT NOT ON DISK: {0} ***" -f ($pack.ifo.declaredVtsMissingOnDisk -join ', ')) }
  $fp = $v.fpPgc
  Add ("  FP_PGC: {0} cell(s); pre-commands: {1}" -f $fp.nrCells, $(if (@($fp.preCommands).Count) { (($fp.preCommands | Select-Object -First 8 | ForEach-Object { if ($_.decoded) { $_.decoded } else { $_.hex } }) -join ' | ') } else { 'none' }))
  foreach ($k in ($pack.ifo.vts.PSObject.Properties.Name | Sort-Object)) {
    $x = $pack.ifo.vts.$k
    Add ''
    if ($x.error) { Add ("  VTS_{0}: ERROR {1}" -f $k, $x.error); continue }
    Add ("  VTS_{0}  video attr {1} = {2} {3} {4} {5}{6}   audio declared={7} [{8}]   subp declared={9} [{10}]{11}" -f $k, $x.videoAttr.raw, $x.videoAttr.mpeg, $x.videoAttr.standard, $x.videoAttr.aspect, $x.videoAttr.pictureSize, $(if ($x.videoAttr.letterboxed) { ' letterboxed' } else { '' }),
        $x.audio.count, (($x.audio.attrs | ForEach-Object { '{0} {1}ch {2} {3}' -f $_.coding, $_.channels, (Fmt $_.lang), $_.codeExtMeaning }) -join '; '),
        $x.subp.count, (($x.subp.attrs | ForEach-Object { 'lang=' + (Fmt $_.lang) + ' ext=' + $_.langExtMeaning }) -join '; '),
        $(if ($x.subp.count -and $x.subp.allAttrsZero) { '  ALL SUBP ATTRS ZERO (untagged)' } else { '' }))
    Add ("          VTSM video attr {0} ({1})   VTSM audio={2} subp={3}   title VOBs: {4} = {5} sectors   menu VOB: {6}" -f $x.vtsmVideoAttr.raw, $x.vtsmVideoAttr.aspect, $x.vtsmAudio.count, $x.vtsmSubp.count, (($x.titleVobs | ForEach-Object { $_.name }) -join ','), $x.titleDomain.vobSectors, $(if ($x.menuVob) { $x.menuVob.sectors.ToString() + ' sectors' } else { 'ABSENT' }))
    foreach ($p in $x.pgcit) {
      Add ("          PGC {0,2}  {1,3} cell(s) {2,2} prog  {3,12} = {4,9} s  sectors {5}  audio_ctl enabled={6}  subp_ctl enabled={7}{8}{9}" -f $p.pgc, $p.nrCells, $p.nrPrograms, $p.playback, $p.playbackSec, $(if ($p.sectorRange) { ('{0}..{1}' -f $p.sectorRange[0], $p.sectorRange[1]) } else { 'none' }), (($p.audioStreamsEnabled) -join ','), (($p.subpStreamsEnabled) -join ','), $(if ($p.hasAngleBlock) { '  ANGLE BLOCK' } else { '' }), $(if ($p.entryPgc) { ('  entry(title ' + $p.titleNumber + ')') } else { '' }))
    }
    Add ("          PTT_SRPT: {0}" -f (($x.pttSrpt | ForEach-Object { 'ttn ' + $_.vtsTtn + ' -> entry PGC ' + $_.entryPgc + ' (' + @($_.ptts).Count + ' PTT)' }) -join '; '))
    $td = $x.titleDomain
    Add ("          TITLE DOMAIN: cells union {0} sectors vs VOBs {1} -> GAP {2}   (summed {3}, overlap {4}{5})" -f $td.cellSectorsUnion, $td.vobSectors, $td.gapSectors, $td.cellSectorsSummed, $td.overlapSectors, $(if (@($td.cellsBeyondVob).Count) { '; CELLS BEYOND VOB: ' + @($td.cellsBeyondVob).Count } else { '' }))
    $md = $x.menuDomain
    if ($md.declared -eq $false) { Add ("          MENU DOMAIN: no VTSM_PGCI_UT declared; menu VOB {0}" -f $(if ($md.menuVobPresent) { 'present (' + $md.vobSectors + ' sectors)' } else { 'absent' })) }
    else { Add ("          MENU DOMAIN: PGCs with cells [{0}], without [{1}]; cells union {2} vs VOB {3} -> GAP {4} (overlap {5})" -f (($md.pgcsWithCells) -join ','), (($md.pgcsWithoutCells) -join ','), $md.cellSectorsUnion, $md.vobSectors, $md.gapSectors, $md.overlapSectors) }
  }
  $vm = $v.menuDomain
  Add ''
  Add ("  VMGM DOMAIN: {0}; PGCs with cells [{1}], without [{2}]; cells union {3} vs VIDEO_TS.VOB {4} -> GAP {5}" -f $(if ($vm.declared) { 'VMGM_PGCI_UT declared (' + $v.vmgmPgciUt.languageUnits + ' LU)' } else { 'NO VMGM_PGCI_UT' }), (($vm.pgcsWithCells) -join ','), (($vm.pgcsWithoutCells) -join ','), $vm.cellSectorsUnion, $vm.vobSectors, $vm.gapSectors)
  if ($v.vmgmPgciUt) { foreach ($p in $v.vmgmPgciUt.units[0].pgcs) { Add ("    VMGM PGC {0,2}  {1,2} cell(s)  {2,9} s  sectors {3}  {4}  cmds: {5}" -f $p.pgc, $p.nrCells, $p.playbackSec, $(if ($p.sectorRange) { ('{0}..{1}' -f $p.sectorRange[0], $p.sectorRange[1]) } else { 'none' }), $(if ($p.entryPgc) { 'entry/' + (Fmt $p.menuTypeName) } else { '' }), ((@($p.preCommands) + @($p.postCommands) | Select-Object -First 6 | ForEach-Object { if ($_.decoded) { $_.decoded } else { $_.hex } }) -join ' | ')) } }

  H2 'CELL-SET RELATIONS between declared titles (SECTORS, within a VTS) - second doors, containment, overlap'
  if (@($pack.ifo.cellSetRelations).Count) { foreach ($r in $pack.ifo.cellSetRelations) { Add ("  VTS_{0:D2}: dvdvideo {1} vs {2}: {3}  shared {4} sectors (A {5}, B {6})" -f $r.vtsn, $r.titleA, $r.titleB, $r.relation, $r.sharedSectors, $r.sectorsA, $r.sectorsB) } } else { Add '  none - every declared title plays disjoint cell sectors from every other in its VTS' }
  if (@($pack.ifo.pgcsNotReferencedByAnyTitle).Count) { Add '  PGCs in the title domain that NO title PTT references (play-all chains, second PGCs):'; foreach ($u in $pack.ifo.pgcsNotReferencedByAnyTitle) { Add ("    VTS_{0:D2} PGC {1}: {2} cell(s) {3} s cells {4}{5}" -f $u.vtsn, $u.pgc, $u.nrCells, $u.playbackSec, (($u.cellSet | ForEach-Object { $_ -join '..' }) -join ','), $(if (@($u.identicalToTitle).Count) { '  IDENTICAL to dvdvideo ' + ($u.identicalToTitle -join ',') } else { '' })) } }

  H2 'MENU-DOMAIN + SUB-FLOOR TITLE PGCs: carved, decoded, luma-classified'
  $cl = $pack.ifo.classification
  if ($cl) {
    Add ("  threshold: luma range < {0} => 'padding/black' (assert-accounted.ps1 evidence threshold); {1} PGC(s) found, {2}" -f $cl.lumaPaddingThreshold, $cl.jobsFound, $(if ($cl.capped) { 'CAPPED at ' + $cl.maxPgcs } else { 'all classified' }))
    Add ("  title-domain PGCs included (declared-not-enumerated or <=30 s): {0}" -f $(if ($pack.ifoTitlePgcsClassified.Count) { $pack.ifoTitlePgcsClassified -join ', ' } else { 'none' }))
    foreach ($p in $cl.pgcs) {
      if ($p.unavailable) { Add ("  {0,-7} VTS_{1:D2} PGC {2,3}: UNAVAILABLE {3}" -f $p.domain, $p.vts, $p.pgc, $p.unavailable); continue }
      $lu = $p.luma
      $st = (($p.streams | Where-Object { $_.type -ne 'data' } | ForEach-Object { '{0}:{1}={2}' -f $_.type, $_.codec, $_.packets }) -join ' ')
      Add ("  {0,-7} VTS_{1:D2} PGC {2,3}  {3,2} cell(s) {4,8} s  {5,12} B  frames={6,-5} Y {7}-{8} range {9,3} => {10,-13} {11}  png={12}{13}" -f $p.domain, $p.vts, $p.pgc, $p.nrCells, $p.playbackSec, (Bytes $p.totalBytes), $lu.frames, (Fmt $lu.yMin), (Fmt $lu.yMax), (Fmt $lu.lumaRange), (Fmt $lu.class), $st, $(if ($p.firstFrame) { Split-Path $p.firstFrame -Leaf } else { '-' }), $(if ($p.contactSheet) { ' sheet=' + (Split-Path $p.contactSheet -Leaf) } else { '' }))
      if ($lu.note) { Add ("          " + $lu.note) }
    }
  }
}

H1 'PER-TITLE MEASUREMENTS (ffprobe -f dvdvideo -title N -count_packets: a FULL WALK; declared = IFO PGC time)'
if ($pack.titles) {
  foreach ($t in $pack.titles) {
    Add ''
    Add ("  dvdvideo {0,2}  {1}  VTS_{2:D2} ttn {3}  entry PGC {4}  cells={5} progs={6} ptts={7} angles={8}  declared {9} = {10} s  cell bytes {11}{12}" -f $t.dvdvideoTitle, (Fmt $t.makemkvTitle), [int]$t.vtsn, (Fmt $t.vtsTtn), (Fmt $t.entryPgc), (Fmt $t.cells), (Fmt $t.programs), (Fmt $t.nrOfPtts), (Fmt $t.nrOfAngles), (Fmt $t.declared), (Fmt $t.declaredSec), (Bytes $t.cellBytes), $(if ($t.hasAngleBlock) { '  ANGLE BLOCK' } else { '' }))
    if ($t.ifoVideoAttr) { Add ("      IFO: video {0} {1} {2} {3}; audio declared {4}; subp declared {5}; PGC audio_ctl enabled [{6}] subp_ctl enabled [{7}]" -f $t.ifoVideoAttr.raw, $t.ifoVideoAttr.standard, $t.ifoVideoAttr.aspect, $t.ifoVideoAttr.pictureSize, $t.ifoAudioDeclared, $t.ifoSubpDeclared, (($t.audioControlEnabled) -join ','), (($t.subpControlEnabled) -join ',')) }
    if ($t.mappingProvenBy) { Add ("      provenBy: " + $t.mappingProvenBy) }
    if (-not $t.measured) { Add ("      UNAVAILABLE: " + $t.unavailable); continue }
    Add ("      format=duration (metadata) {0} s; video packets {1} @ {2} fps = EMITTED {3} s (delta declared-emitted {4} s)  => expectFrames={1} expectSeconds={3}" -f (Fmt $t.formatDurationDeclared), (Fmt $t.videoPackets), (Fmt $t.fps), (Fmt $t.emittedSec), (Fmt $t.deltaDeclaredMinusEmittedSec))
    foreach ($s in $t.streams) {
      if ($s.type -eq 'video') { Add ("      [{0}] video    {1,-10} {2}x{3} SAR {4} DAR {5} {6} fps field_order={7} {8}  packets={9}" -f $s.index, $s.codec, $s.width, $s.height, $s.sar, $s.dar, (Fmt $s.fps), (Fmt $s.fieldOrder), (Fmt $s.pixFmt), $s.packets) }
      elseif ($s.type -eq 'audio') { Add ("      [{0}] audio    {1,-10} {2}ch {3} {4} Hz {5} bps lang={6}  packets={7} (= {8} s)" -f $s.index, $s.codec, (Fmt $s.channels), (Fmt $s.layout), (Fmt $s.sampleRate), (Fmt $s.bitRate), (Fmt $s.lang), $s.packets, (Fmt $s.derivedSec)) }
      elseif ($s.type -eq 'subtitle') { Add ("      [{0}] subtitle {1,-10} lang={2}  packets={3}{4}" -f $s.index, $s.codec, (Fmt $s.lang), $s.packets, $(if ($s.note) { '   *** ' + $s.note + ' ***' } else { '' })) }
      else { Add ("      [{0}] {1} {2} packets={3}" -f $s.index, $s.type, $s.codec, $s.packets) }
    }
    if ($t.ffprobeStderr) { foreach ($e in $t.ffprobeStderr) { Add ("      ffprobe: " + $e) } }
    Add ("      probe {0} s" -f $t.probeSeconds)
  }
}

H1 'RE-RIP WORKLIST'
if ($pack.worklist) {
  $w = $pack.worklist
  Add ("  {0}" -f $w.path)
  if ($w.header) { Add ("  header: " + $w.header) }
  if ($w.rowVerbatim.Count) { foreach ($r in $w.rowVerbatim) { Add ("  row:    " + $r) } } else { Add ("  " + (Fmt $w.note)) }
  if ($w.parsed) { foreach ($k in $w.parsed.Keys) { Add ("    {0,-20} {1}" -f $k, $w.parsed[$k]) } }
  if ($w.markdownMentions) { foreach ($m in $w.markdownMentions) { Add ("  _rerip-worklist.md " + $m) } }
  if ($w.updatesMedia2Mentions) { Add ("  updates_media2.txt ({0}):" -f $w.updatesMedia2Warning); foreach ($m in $w.updatesMedia2Mentions) { Add ("    " + $m) } }
}

H1 'LIBRARY - what the NAS / Plex already hold for the mapped work'
if ($pack.library) {
  $lb = $pack.library
  Add ("  work resolution: {0}   how: {1}" -f $(if ($lb.workResolution.chosen) { $lb.workResolution.chosen.kind + ' / ' + $lb.workResolution.chosen.work + ' (Plex key ' + (Fmt $lb.workResolution.chosen.plexRatingKey) + ')' } else { 'NOT RESOLVED' }), (Fmt $lb.workResolution.how))
  Add ("  search terms: {0}" -f ($lb.plexSearchTerms -join ' | '))
  Add ("  record candidates: {0}" -f $(if (@($lb.workCandidatesFromRecords).Count) { (($lb.workCandidatesFromRecords | ForEach-Object { $_.source + ': ' + $_.kind + '/' + $_.work }) -join '; ') } else { 'none' }))
  if ($lb.plex -and $lb.plex.matches) { Add ("  Plex matches: {0}" -f (($lb.plex.matches | ForEach-Object { $_.kind + ': ' + $_.title + ' (' + (Fmt $_.year) + ') key=' + $_.ratingKey + $(if ($_.leafCount) { ' leaves=' + $_.leafCount } else { '' }) }) -join '; ')) }
  if ($lb.plexLocations) { Add ("  Plex show locations: " + ($lb.plexLocations -join '; ')) }
  H2 'attribution audit rows (CLAIMS: a prior audit paired these files to this disc)'
  if (@($lb.attributions.rows).Count) { foreach ($a in $lb.attributions.rows) { Add ("  tid {0}  {1,6} min  {2}{3}" -f $a.tid, $a.minutes, $a.nasPath, $(if ($a.note) { '  (' + $a.note + ')' } else { '' })) } } else { Add '  none' }
  H2 'identity register (NAS \_disc-identity)'
  $rg = $lb.identityRegister
  if ($rg.record) {
    $rr = $rg.record
    Add ("  {0}: schema={1} discTitle='{2}' year={3} sourceDrive={4} sweptOn={5} subtitleStreamsOnDisc={6} outputs={7} disagreements={8}" -f $rg.path, $rr.schema, $rr.discTitle, (Fmt $rr.discYear), (Fmt $rr.sourceDrive), (Fmt $rr.sweptOn), (Fmt $rr.subtitleStreamsOnDisc), @($rr.outputs).Count, @($rr.disagreements).Count)
    foreach ($t in @($rr.titles)) { Add ("    t{0:D2} dvdTitle={1} runtime={2} s size={3} audio={4} subs={5} subLangs=[{6}] work={7} S{8}E{9} name='{10}' conf={11} claims: mymovies={12} plex={13}" -f [int]$t.makemkvTitle, (Fmt $t.dvdTitle), (Fmt $t.runtimeSec), (Bytes $t.sizeBytes), (Fmt $t.audioStreams), (Fmt $t.subStreams), (($t.subLangs) -join ','), (Fmt $t.work), (Fmt $t.season), (Fmt $t.episode), (Fmt $t.name), (Fmt $t.confidence), (Fmt $(if ($t.claims) { $t.claims.mymovies } else { $null })), (Fmt $(if ($t.claims) { $t.claims.plex } else { $null }))) }
    foreach ($o in @($rr.outputs)) { Add ("    output: {0} <- {1}" -f (Fmt $o.path), (Fmt $o.source)) }
  } else { Add ("  {0}: {1}" -f (Fmt $rg.path), (Fmt $(if ($rg.unavailable) { 'UNAVAILABLE ' + $rg.unavailable } else { $rg.note }))) }
  H2 'Plex items of the work (duration/geometry/bitrate from Plex metadata)'
  if ($lb.plex -and $lb.plex.items) {
    foreach ($it in $lb.plex.items) {
      $tag = $(if ($null -ne $it.season) { ('S{0:D2}E{1:D2} ' -f [int]$it.season, [int]$it.episode) } else { '' })
      foreach ($f in $it.files) { Add ("  {0}{1,-40} {2,10} s  {3,5}x{4,-4} {5,5} kbps {6} {7}  {8,14} B  {9}" -f $tag, ($it.title.Substring(0, [math]::Min(40, $it.title.Length))), (Fmt $f.durationSec), (Fmt $f.width), (Fmt $f.height), (Fmt $f.bitrateKbps), (Fmt $f.videoCodec), (Fmt $f.audioCodec), (Bytes $f.bytes), (Fmt $f.nasPath)) }
      if ($it.streams) { foreach ($s in $it.streams) { Add ("        media {0} stream type={1} {2} lang={3} title='{4}' {5}{6}" -f $s.mediaId, $s.streamType, $s.codec, (Fmt $s.language), (Fmt $s.title), $(if ($s.width) { $s.width + 'x' + $s.height + ' ' + $s.frameRate + 'fps ' } else { '' }), $(if ($s.channels) { $s.channels + 'ch' } else { '' })) } }
      if ($it.extras) { foreach ($e in $it.extras) { foreach ($f in $e.files) { Add ("        extra '{0}' ({1}) {2} s  {3}" -f $e.title, (Fmt $e.subtype), (Fmt $f.durationSec), (Fmt $f.nasPath)) } } }
    }
  } else { Add '  none / unavailable' }
  H2 'NAS work folder listing (governed read)'
  $ns = $lb.nas
  Add ("  folder: {0}   exists={1}   files={2}   media={3}   bytes={4}" -f (Fmt $ns.workFolder), (Fmt $ns.workFolderExists), @($ns.listing).Count, (Fmt $ns.mediaCount), (Bytes $ns.listingBytes))
  if ($ns.foldersWithSameStem) { Add ("  folders with the same stem under the kind root (split-work trap): {0}" -f ($ns.foldersWithSameStem -join '; ')) }
  $listed = 0
  foreach ($f in @($ns.listing | Where-Object { $_.kind -eq 'media' })) {
    Add ("    {0,-70} {1,14} B  mtime {2}  sidecars: {3}" -f $f.rel, (Bytes $f.bytes), $f.mtime, $(if (@($f.sidecars).Count) { $f.sidecars -join ', ' } else { 'NONE' }))
    $listed++
    if ($listed -ge 150) { Add ("    ... {0} more media files (see JSON)" -f (@($ns.listing | Where-Object { $_.kind -eq 'media' }).Count - $listed)); break }
  }
  $others = @($ns.listing | Where-Object { $_.kind -ne 'media' })
  if ($others.Count) { Add ("    non-media files: {0} ({1})" -f $others.Count, ((($others | Group-Object kind) | ForEach-Object { $_.Name + '=' + $_.Count }) -join ', ')) }
  H2 'NAS header probes (ffprobe, governed; NEVER a full walk)'
  Add ("  selection: {0}" -f (Fmt $ns.probeSelection))
  foreach ($p in @($ns.probes)) {
    if ($p.unavailable) { Add ("  {0}: UNAVAILABLE {1}" -f $p.rel, $p.unavailable); continue }
    $vs = @($p.streams | Where-Object { $_.type -eq 'video' })[0]
    Add ("  {0,-70} {1,10} s  {2}x{3} SAR {4} DAR {5} {6} fps {7} {8} {9} bps  audio [{10}]  subs [{11}]" -f $p.rel, (Fmt $p.durationSec), (Fmt $vs.width), (Fmt $vs.height), (Fmt $vs.sar), (Fmt $vs.dar), (Fmt $vs.fps), (Fmt $vs.fieldOrder), (Fmt $vs.codec), (Fmt $p.bitRate), ($p.audioStreams -join '; '), $(if ($p.subtitleStreams.Count) { $p.subtitleStreams -join '; ' } else { 'NONE' }))
  }
  H2 'duration candidates (disc title <-> library file; corroboration ONLY)'
  Add ("  window +/-{0} s; 'exact' = within {1} s" -f $lb.durationCandidates.windowSec, $lb.durationCandidates.exactSec)
  foreach ($r in $lb.durationCandidates.rows) {
    Add ("  dvdvideo {0,2} ({1}) {2,10} s [{3}]: {4}" -f $r.dvdvideoTitle, (Fmt $r.makemkvTitle), $r.discSec, $r.basis, $(if (@($r.candidates).Count) { '' } else { 'no library file within the window' }))
    foreach ($cd in @($r.candidates)) { Add ("        {0,+9:N3} s {1} {2,10} s  {3}{4}" -f $cd.deltaSec, $(if ($cd.withinExact) { 'EXACT ' } else { '      ' }), $cd.durationSec, $cd.path, $(if ($cd.plexTitle) { "  (Plex: '" + $cd.plexTitle + "')" } else { '' })) }
  }
  H2 '_subtitle-coverage.csv rows for the work'
  if ($lb.subtitleCoverage -and @($lb.subtitleCoverage.rows).Count) { foreach ($r in $lb.subtitleCoverage.rows) { Add ("  {0,-24} {1,-60} bitmap={2,-14} audio={3,-4} {4}" -f $r.category, $r.file, (Fmt $r.bitmapProbe), (Fmt $r.audioProbe), $r.evidence) } } else { Add '  none' }
}

H1 'SUPERSEDES CANDIDATES (resolved exists/not; establish the claim from CONTENT)'
if ($pack.supersedes) { if (@($pack.supersedes.candidates).Count) { foreach ($s in $pack.supersedes.candidates) { Add ("  [{0}] {1}  ->  {2}  exists={3}{4}" -f $s.source, $s.text, (Fmt $s.path), (Fmt $s.exists), $(if ($s.exists) { '  ' + (Bytes $s.bytes) + ' B  mtime ' + $s.mtime } else { '' })) } } else { Add '  none' } }

if ($pack.correlate) {
  H1 'ENVELOPE CORRELATION (disc title window vs NAS candidate window)'
  Add ("  window {0} s at {1} interior offset(s) per title; lag is disc-relative (0 = aligned); r is a fact, not a verdict" -f $pack.correlate.windowSec, $pack.correlate.offsetsPerTitle)
  foreach ($r in $pack.correlate.rows) { if ($r.unavailable) { Add ("  dv{0} @{1}s vs {2}: UNAVAILABLE {3}" -f $r.dvdvideoTitle, $r.offsetSec, (Split-Path $r.nasPath -Leaf), $r.unavailable) } else { Add ("  dv{0} @{1,6}s vs {2,-60} r={3,6:N3} lag={4,6} ms  r0={5}" -f $r.dvdvideoTitle, $r.offsetSec, (Split-Path $r.nasPath -Leaf), $r.r, $r.lagMs, (Fmt $r.rAtZeroLag)) } }
}

H1 'RUNTIME'
foreach ($k in $timings.Keys) { Add ("  {0,-14} {1,7} s" -f $k, $timings[$k]) }
Add ("  {0,-14} {1,7} s" -f 'TOTAL', $pack.runtimeSeconds)
Add ''
Add ("UNAVAILABLE ({0}) - repeated so it is not missed: {1}" -f $unavailable.Count, $(if ($unavailable.Count) { (($unavailable | ForEach-Object { $_.measurement }) -join ', ') } else { 'none' }))

# ---------------------------------------------------------------------------------- write
$tmpJson = $outJson + '.tmp'
$pack | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $tmpJson -Encoding UTF8
Move-Item -LiteralPath $tmpJson -Destination $outJson -Force
Set-Content -LiteralPath $outTxt -Value ($L -join "`n") -Encoding UTF8
Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
Log ("wrote {0} and {1}; {2} UNAVAILABLE; runtime {3} s" -f $outJson, $outTxt, $unavailable.Count, $pack.runtimeSeconds)
Write-Output ("EVIDENCE PACK WRITTEN: {0}  ({1} lines; {2} UNAVAILABLE; {3} s)" -f $outTxt, $L.Count, $unavailable.Count, $pack.runtimeSeconds)
exit 0
