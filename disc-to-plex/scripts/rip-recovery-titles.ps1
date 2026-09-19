<#
.SYNOPSIS
  Rip ONLY the titles a recovery directive names (D:/video/_recovery/<unit>.json) - e.g. the
  commentary-door playlists of a disc whose episodes shipped without their commentary - and write
  <root>/<unit>/rip/_rip.json for recover-commentary.ps1. Minutes of drive time, not a ~40 GB backup.

REACH FOR THIS WHEN: the optical track logged "*** RECOVERY DISC" (it leaves such a disc in the drive
  and writes <root>/<unit>.inserted.json), or to rehearse against a staged BDMV folder:

  pwsh -NoProfile -File rip-recovery-titles.ps1                                   # the inserted disc
  pwsh -NoProfile -File rip-recovery-titles.ps1 -Unit X -Source 'file:D:/video/_stage/X'   # rehearsal

  Each episode's title is found by its PLAYLIST NAME (MakeMKV attribute 16), never by title number,
  and the rip is verified by counting the output file, its duration against the directive's
  doorSeconds, and its audio stream count - never by reading MakeMKV's exit code or a filtered log.
  Door playlist first; the directive's fallbackPlaylist if the door is not offered.

.EXIT CODES  0 = every episode ripped and verified   2 = at least one did not (see _rip.json)
             3 = nothing to do / no directive / no disc
#>
param(
  [string]$Unit = '',
  [string]$Source = 'dev:F:',
  [string]$RecoveryRoot = 'D:/video/_recovery',
  [string]$MakeMkv = 'C:/Program Files (x86)/MakeMKV/makemkvcon64.exe',
  [string]$FfProbe = 'D:/video/.transcode-tools/ffprobe.exe',
  [int]$MinLength = 600,
  [double]$DurationSlackSeconds = 5
)
$ErrorActionPreference = 'Stop'
function Say([string]$m) { Write-Output ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }
if (-not (Test-Path -LiteralPath $FfProbe)) { $FfProbe = (Get-Command ffprobe -ErrorAction SilentlyContinue).Source }

if (-not $Unit) {
  $ins = @(Get-ChildItem -LiteralPath $RecoveryRoot -Filter '*.inserted.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
  if (-not $ins.Count) { Say 'no inserted recovery disc recorded - nothing to do'; exit 3 }
  $Unit = "$((Get-Content -LiteralPath $ins[0].FullName -Raw | ConvertFrom-Json).unit)"
}
$dirFile = Join-Path $RecoveryRoot ("{0}.json" -f $Unit)
if (-not (Test-Path -LiteralPath $dirFile)) { Say "no directive $dirFile"; exit 3 }
$d = Get-Content -LiteralPath $dirFile -Raw | ConvertFrom-Json
$ripDir = Join-Path (Join-Path $RecoveryRoot $Unit) 'rip'
New-Item -ItemType Directory -Force -Path $ripDir | Out-Null
Say ("{0}: {1} episode(s) to rip from {2}" -f $d.discName, @($d.episodes).Count, $Source)

# ---- enumerate once: title id -> playlist, duration, output name ------------------------------------
$info = @(& $MakeMkv -r --cache=1 "--minlength=$MinLength" info $Source 2>&1 | ForEach-Object { "$_" })
$titles = @{}
foreach ($line in $info) {
  if ($line -match '^TINFO:(\d+),(\d+),\d+,"(.*)"$') {
    $id = [int]$Matches[1]; if (-not $titles.ContainsKey($id)) { $titles[$id] = @{ id = $id } }
    switch ([int]$Matches[2]) { 16 { $titles[$id].playlist = $Matches[3] } 9 { $titles[$id].duration = $Matches[3] } 27 { $titles[$id].outName = $Matches[3] } }
  }
}
if (-not $titles.Count) {
  Say '*** MakeMKV listed no titles - is the disc in and readable? Last lines of its output:'
  $info | Select-Object -Last 8 | ForEach-Object { "    $_" }
  exit 3
}

$results = @()
foreach ($e in @($d.episodes)) {
  $r = [ordered]@{ episode = "$($e.episode)"; playlist = ''; titleId = $null; file = ''; seconds = 0; audio = 0; verified = $false; reason = '' }
  $pick = $null
  foreach ($pl in @("$($e.doorPlaylist)", "$($e.fallbackPlaylist)")) {
    if (-not $pl) { continue }
    $pick = $titles.Values | Where-Object { "$($_.playlist)" -eq $pl } | Select-Object -First 1
    if ($pick) { $r.playlist = $pl; break }
  }
  if (-not $pick) { $r.reason = "neither $($e.doorPlaylist) nor $($e.fallbackPlaylist) is offered by MakeMKV"; Say ("*** {0}: {1}" -f $e.episode, $r.reason); $results += [pscustomobject]$r; continue }
  $r.titleId = $pick.id
  $epDir = Join-Path $ripDir "$($e.episode)"
  New-Item -ItemType Directory -Force -Path $epDir | Out-Null
  $existing = @(Get-ChildItem -LiteralPath $epDir -Filter '*.mkv' -File -ErrorAction SilentlyContinue)
  if (-not $existing.Count) {
    Say ("{0}: ripping title {1} ({2}, {3})" -f $e.episode, $pick.id, $pick.playlist, $pick.duration)
    $log = Join-Path $epDir '_makemkv.log'
    & $MakeMkv -r --cache=1 "--minlength=$MinLength" mkv $Source $pick.id $epDir *> $log
  }
  # VERIFY BY THE OUTPUT, never by the exit code or a filtered log.
  $out = @(Get-ChildItem -LiteralPath $epDir -Filter '*.mkv' -File -ErrorAction SilentlyContinue)
  if ($out.Count -ne 1) {
    $r.reason = "expected 1 .mkv, found $($out.Count)"
    Say ("*** {0}: {1}; log tail:" -f $e.episode, $r.reason); Get-Content -LiteralPath (Join-Path $epDir '_makemkv.log') -Tail 8 -ErrorAction SilentlyContinue | ForEach-Object { "    $_" }
    $results += [pscustomobject]$r; continue
  }
  $j = & $FfProbe -v error -show_entries format=duration:stream=codec_type -of json $out[0].FullName | ConvertFrom-Json
  $r.file = "$($e.episode)/$($out[0].Name)"
  $r.seconds = [math]::Round([double]$j.format.duration, 3)
  $r.audio = @($j.streams | Where-Object codec_type -eq 'audio').Count
  $wantSec = [double]$e.doorSeconds
  if ([math]::Abs($r.seconds - $wantSec) -gt $DurationSlackSeconds) { $r.reason = ("duration {0}s vs the directive's {1}s" -f $r.seconds, $wantSec) }
  elseif ($r.audio -lt 2) { $r.reason = "only $($r.audio) audio stream(s) - no commentary can be in it" }
  else { $r.verified = $true }
  Say ("{0}: {1} - {2:N0}s, {3} audio{4}" -f $e.episode, $(if ($r.verified) { 'VERIFIED' } else { '*** NOT VERIFIED' }), $r.seconds, $r.audio, $(if ($r.reason) { " - $($r.reason)" } else { '' }))
  $results += [pscustomobject]$r
}

[ordered]@{ unit = $Unit; source = $Source; at = (Get-Date).ToString('s'); episodes = $results } |
  ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ripDir '_rip.json') -Encoding UTF8
$bad = @($results | Where-Object { -not $_.verified }).Count
Say ("{0} of {1} episode(s) ripped and verified -> {2}" -f (@($results).Count - $bad), @($results).Count, (Join-Path $ripDir '_rip.json'))
if ($bad) { exit 2 } else { exit 0 }
