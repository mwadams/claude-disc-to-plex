<#
  Sweep a whole source drive and record what every disc CONTAINS, before any of it is ripped.

  RUN THIS WHEN A DRIVE IS SWAPPED IN. It is the initial analysis: one pass over the drive that
  answers, for every disc, the question everything downstream depends on - does this disc carry
  subtitles?

  WHY IT MATTERS THAT THIS HAPPENS UP FRONT
  An unsubtitled file in the library is one of three different problems, and they need opposite
  treatments:
      disc HAS subtitles, the rip lost them   -> RE-RIP        (64 titles on media2)
      file HAS bitmap subtitles               -> OCR           (272 files on media2)
      disc NEVER had subtitles                -> TRANSCRIBE    (67 discs on media2)
  Nothing about the library file distinguishes the first from the third. Only the disc does. So
  the classification has to be captured while the drive is present - once it is unplugged, the
  evidence is gone and the only honest answer is "unknown".

  WHAT IT WRITES
    * one identity record per disc in the register, seeded with every title's runtime, stream
      counts and subtitle languages. Existing records are UPDATED IN PLACE: outputs, claims and
      disagreements already recorded are preserved, because those cost real identification work
      and this sweep knows nothing about them.
    * a per-drive classification CSV, for the queueing steps and for the eye.

  Read-only with respect to the drive. Enumeration is cached per disc, so re-running is cheap
  and an interrupted sweep resumes.
#>
param(
  [string]$Drive  = 'E:\Movies',
  [Parameter(Mandatory)][string]$Label,        # e.g. media2 - which physical drive this is
  [string]$Store  = ([IO.Path]::Combine('\\NASTEAMV', 'Multimedia', '_disc-identity')),
  [string]$Cache  = 'D:\video\_disc-info',
  [string]$Report = '',
  [string]$MakeMkv = 'C:\Program Files (x86)\MakeMKV\makemkvcon64.exe',
  [int]$MinLength = 10                          # SECONDS. see below - do not raise this
)
$ErrorActionPreference = 'Stop'
if (-not $Report) { $Report = "D:\video\_sweep-$Label.csv" }
foreach ($p in $Drive, $MakeMkv) { if (-not (Test-Path -LiteralPath $p)) { throw "not found: $p" } }
foreach ($d in $Cache, $Store) { if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null } }

# --minlength=10, NOT the default 120 and NOT 60. The floor decides what you are even able to
# account for: a whole batch was once enumerated at 60 before anyone noticed the per-unit gate's
# "every title accounted for" was being checked against an already-filtered list. It must also
# match the floor used when RIPPING, because a title id is a position in this list, not a
# property of the disc.
function Safe([string]$n) { ($n -replace '[\\/:*?"<>|]', '_') }

$discs = @(Get-ChildItem -LiteralPath $Drive -Directory | Sort-Object Name)
Write-Host "sweeping $($discs.Count) disc(s) on $Drive [$Label]"
$rows = New-Object System.Collections.Generic.List[object]
$i = 0

foreach ($d in $discs) {
  $i++
  $dump = Join-Path $Cache ((Safe $d.Name) + '.txt')
  $lines = $null
  if (Test-Path -LiteralPath $dump) {
    $lines = @(Get-Content -LiteralPath $dump)
    if (@($lines | Where-Object { $_ -match '^TINFO:\d+,9,' }).Count -eq 0) { $lines = $null }
  }
  if (-not $lines) {
    $o = & $MakeMkv -r --cache=1 --minlength=$MinLength info ('file:' + $d.FullName) 2>&1
    $lines = @($o | ForEach-Object { "$_" })
    Set-Content -LiteralPath $dump -Value $lines -Encoding UTF8
  }

  # ---- parse titles and their streams
  $titles = @{}
  foreach ($l in $lines) {
    if ($l -match '^TINFO:(\d+),(\d+),\d+,"(.*)"$') {
      $id = [int]$Matches[1]; $code = [int]$Matches[2]; $v = $Matches[3]
      if (-not $titles.ContainsKey($id)) { $titles[$id] = @{ id=$id; sec=$null; bytes=$null; audio=0; subs=0; langs=@{} } }
      switch ($code) {
        9  { $p = $v -split ':'; $s = 0; foreach ($x in $p) { $s = $s * 60 + [int]$x }; $titles[$id].sec = $s }
        11 { if ($v -match '^\d+$') { $titles[$id].bytes = [int64]$v } }
      }
    }
    elseif ($l -match '^SINFO:(\d+),(\d+),(\d+),\d+,"(.*)"$') {
      $id = [int]$Matches[1]; $sn = [int]$Matches[2]; $code = [int]$Matches[3]; $v = $Matches[4]
      if (-not $titles.ContainsKey($id)) { $titles[$id] = @{ id=$id; sec=$null; bytes=$null; audio=0; subs=0; langs=@{}; _t=@{} } }
      if (-not $titles[$id].ContainsKey('_t')) { $titles[$id]._t = @{} }
      if ($code -eq 1) {
        $titles[$id]._t[$sn] = $v
        if ($v -eq 'Audio')     { $titles[$id].audio++ }
        if ($v -eq 'Subtitles') { $titles[$id].subs++ }
      }
      if ($code -eq 4 -and $titles[$id]._t[$sn] -eq 'Subtitles') { $titles[$id].langs[$v] = $true }
    }
  }
  $tl = @($titles.Values | Where-Object { $null -ne $_.sec } | Sort-Object id)
  $subTotal = ($tl | Measure-Object -Property subs -Sum).Sum
  if (-not $subTotal) { $subTotal = 0 }

  # ---- disc identity, from the disc rather than the folder name
  $idFile = Get-ChildItem -LiteralPath $d.FullName -Filter *.dvdid.xml -File -EA SilentlyContinue | Select-Object -First 1
  $discId = $null
  if ($idFile) {
    $m = [regex]::Match((Get-Content -LiteralPath $idFile.FullName -Raw), '<ID>(.*?)</ID>')
    if ($m.Success -and $m.Groups[1].Value.Trim()) { $discId = $m.Groups[1].Value.Trim() }
  }
  if (-not $discId) {
    $fp = ($tl | ForEach-Object { $_.sec }) -join ','
    $sha = [Security.Cryptography.SHA1]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($fp))
    $discId = 'FP-' + ((($sha | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0,12).ToUpper())
  }
  $localTitle = $null; $year = $null
  $mm = Join-Path $d.FullName 'mymovies.xml'
  if (Test-Path -LiteralPath $mm) {
    $x = Get-Content -LiteralPath $mm -Raw
    $t = [regex]::Match($x, '<LocalTitle>(.*?)</LocalTitle>', 'Singleline'); if ($t.Success) { $localTitle = $t.Groups[1].Value.Trim() }
    $y = [regex]::Match($x, '<ProductionYear>(.*?)</ProductionYear>');       if ($y.Success) { $year = $y.Groups[1].Value.Trim() }
  }

  # ---- upsert the register record, PRESERVING identification work already done
  $recPath = Join-Path $Store ((Safe $discId) + '.json')
  $rec = $null
  if (Test-Path -LiteralPath $recPath) { $rec = Get-Content -LiteralPath $recPath -Raw | ConvertFrom-Json }
  $prevOutputs = if ($rec -and $rec.outputs) { $rec.outputs } else { @() }
  $prevDis     = if ($rec -and $rec.disagreements) { $rec.disagreements } else { @() }
  $prevClaims  = @{}
  if ($rec -and $rec.titles) { foreach ($t in $rec.titles) { if ($t.claims) { $prevClaims[[int]$t.makemkvTitle] = $t.claims } } }

  $titleRecs = foreach ($t in $tl) {
    [ordered]@{
      makemkvTitle = $t.id; dvdTitle = $null; clip = $null
      runtimeSec = $t.sec; sizeBytes = $t.bytes
      audioStreams = $t.audio; subStreams = $t.subs
      subLangs = @($t.langs.Keys | Sort-Object)
      claims = if ($prevClaims.ContainsKey($t.id)) { $prevClaims[$t.id] } else { [ordered]@{ mymovies = $null; plex = $null } }
    }
  }

  [ordered]@{
    schema = 'disc-identity/2'; discId = $discId
    discIdSource = $(if ($idFile) { 'mymovies-discid' } else { 'runtime-fingerprint' })
    discFolder = $d.Name; sourceDrive = $Label
    discTitle = $localTitle; discYear = $year
    fingerprint = [ordered]@{ titleCount = $tl.Count; runtimes = @($tl | ForEach-Object { $_.sec } | Sort-Object) }
    sweptOn = (Get-Date -Format 'yyyy-MM-dd'); sweepMinLength = $MinLength
    subtitleStreamsOnDisc = [int]$subTotal
    titles = @($titleRecs)
    outputs = @($prevOutputs); disagreements = @($prevDis)
    notes = @("swept $(Get-Date -Format 'yyyy-MM-dd') from $Label at minlength=$MinLength")
  } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $recPath -Encoding UTF8

  # ZERO TITLES IS A FAILED READ, NOT A FINDING - AND IT MUST NOT BORROW THE VOCABULARY OF ONE.
  #
  # "This disc offers no subtitles" is a MEASUREMENT: MakeMKV enumerated the titles and none of them
  # carried a subpicture stream. "MakeMKV enumerated nothing at all" is the absence of a
  # measurement, and the two were collapsed here because both end at $subTotal -eq 0.
  #
  # 2026-09-21, media4: 28 consecutive discs ([152]-[179], The Space Museum through UFO Disk 3) came
  # back titles=0 subs=0 and were all filed 'NO-SUBTITLES (transcribable)'. Every one is a real
  # 6-8 GB DVD with a populated VIDEO_TS. Their cached dumps hold a drive listing and nothing else -
  # MakeMKV started, enumerated the optical drives and never opened the source, the same shape the
  # project header warns about for mangled `file:` arguments. The run before and the run after
  # succeeded, so it was a window, not a property of those discs.
  #
  # Left alone that would have routed 28 subtitled discs to TRANSCRIPTION - the most expensive
  # treatment of the three, chosen because the cheap evidence was missing rather than because it said
  # so. The whole point of sweeping while the drive is attached is that "unknown" stops being
  # recoverable once it is unplugged, so "unknown" has to be a word this script can say.
  $class = if ($tl.Count -eq 0) { 'NOT-ENUMERATED (retry: no titles read)' }
           elseif ($subTotal -gt 0) { 'has-subtitles' }
           else { 'NO-SUBTITLES (transcribable)' }
  $rows.Add([pscustomobject]@{
    Drive = $Label; Disc = $d.Name; DiscId = $discId
    DiscTitle = $localTitle; Year = $year
    Titles = $tl.Count; SubtitleStreams = $subTotal
    SubLangs = (@($tl | ForEach-Object { $_.langs.Keys } | Sort-Object -Unique) -join '|')
    Class = $class
  })
  Write-Host ("  [{0}/{1}] {2,-40} titles={3,-3} subs={4,-3} {5}" -f $i, $discs.Count, $d.Name, $tl.Count, $subTotal, $class)
}

$rows | Export-Csv -LiteralPath $Report -NoTypeInformation -Encoding UTF8
# Counted off the CLASS, not off SubtitleStreams - a not-enumerated disc also has 0, and counting it
# as "no subtitles" is the same conflation one layer up.
$unread = @($rows | Where-Object { $_.Class -like 'NOT-ENUMERATED*' })
$noSubs = @($rows | Where-Object { $_.Class -like 'NO-SUBTITLES*' })
$withSubs = @($rows | Where-Object { $_.Class -eq 'has-subtitles' })
Write-Host ''
Write-Host "discs swept                    : $($rows.Count)"
Write-Host "carry subtitles (re-rip/OCR)   : $($withSubs.Count)"
Write-Host "NO subtitles (transcribable)   : $($noSubs.Count)"
if ($unread.Count) {
  Write-Host ''
  Write-Host "*** NOT ENUMERATED - NO MEASUREMENT TAKEN : $($unread.Count) disc(s)" -ForegroundColor Yellow
  Write-Host '    MakeMKV read no titles at all from these, so nothing is known about their subtitles.' -ForegroundColor Yellow
  Write-Host '    They are NOT transcribable-by-measurement - do not queue them as such. Re-run this' -ForegroundColor Yellow
  Write-Host '    sweep (it retries any disc whose cached dump has no title records) WHILE THE DRIVE IS' -ForegroundColor Yellow
  Write-Host '    STILL ATTACHED; the evidence is unrecoverable once it is unplugged.' -ForegroundColor Yellow
  foreach ($u in ($unread | Select-Object -First 30)) { Write-Host ("      {0}" -f $u.Disc) -ForegroundColor Yellow }
  if ($unread.Count -gt 30) { Write-Host ("      ... and {0} more" -f ($unread.Count - 30)) -ForegroundColor Yellow }
}
Write-Host "register updated               : $Store"
Write-Host "report                         : $Report"
Write-Host ''
Write-Host 'Next: queue-transcribable.ps1 turns the no-subtitle discs into a work list, but only'
Write-Host 'where the library file is confirmed to have no subtitle stream and no sidecar.'
