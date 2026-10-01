<#
.SYNOPSIS
  REFUSE a DVD row whose numeric subTrack picks a near-empty subtitle stream while the same title
  carries a substantial one - the signature of an ABSOLUTE stream index written where transcode.ps1
  expects a SUBTITLE ORDINAL.

.WHY THIS EXISTS
  2026-10-01, The Enemy Below. The dispositions named the English subtitles "s:7, 939 packets" - 7 being
  the dvdvideo ABSOLUTE stream index (the evidence pack's `index`). The manifest wrote subTrack 7, and
  transcode.ps1 reads subTrack as the Nth SUBTITLE stream: ordinal 7 is 0x27, a 7-packet German
  forced stream. It encoded, was muxed tagged `eng`, and OCR refused it three times (4 cues, 0% English)
  before the publish hold named it. Every figure needed to refuse it before encoding was already in
  _catalogue/<unit>.evidence.json.

.WHAT IT REFUSES
  A row with kind DVD, a folder src, a `title`, and an integer subTrack N, where the title's Nth
  subtitle stream (by order, from the evidence pack) carries <= -SparsePackets packets and another
  subtitle stream carries >= -SubstantialPackets. Also an ordinal past the last subtitle stream.
  A row that genuinely wants the sparse stream (a forced-narrative track) states why:
      subTrackSparseOk: "<what the stream is, from the content>"

.EXIT CODES
  0 = nothing wrong, or nothing checkable (reported - a skip is not a pass)   2 = refuse
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [string]$Catalogue = 'D:/video/_catalogue',
  [int]$SparsePackets = 10,
  [int]$SubstantialPackets = 100,
  [switch]$Quiet
)
$ErrorActionPreference = 'Stop'
function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Say "assert-subtrack-substantial: no manifest at $Manifest"; exit 0 }
try { $doc = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json }
catch { Say ("assert-subtrack-substantial: unreadable manifest ({0}) - not this guard's call" -f $_.Exception.Message); exit 0 }
$items = if ($doc -is [array]) { @($doc) } elseif ($doc.PSObject.Properties.Name -contains 'outputs') { @($doc.outputs) } elseif ($doc.PSObject.Properties.Name -contains 'items') { @($doc.items) } else { @($doc) }

$evCache = @{}
function Get-Evidence([string]$unit) {
  if ($evCache.ContainsKey($unit)) { return $evCache[$unit] }
  $p = Join-Path $Catalogue ($unit + '.evidence.json')
  $ev = $null
  if (Test-Path -LiteralPath $p -PathType Leaf) { try { $ev = Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } catch { $ev = $null } }
  $evCache[$unit] = $ev
  return $ev
}

$refuse = 0; $checked = 0; $unchecked = 0
foreach ($it in $items) {
  if (-not $it) { continue }
  $st = "$($it.subTrack)".Trim()
  if ($st -notmatch '^\d+$') { continue }
  if ("$($it.kind)" -ne 'DVD' -or -not "$($it.title)".Trim()) { continue }
  $leaf = Split-Path "$($it.out)" -Leaf
  $unit = Split-Path ("$($it.src)".TrimEnd('/', '\')) -Leaf
  $ev = Get-Evidence $unit
  $t = if ($ev) { @($ev.titles) | Where-Object { "$($_.dvdvideoTitle)" -eq "$($it.title)" } | Select-Object -First 1 } else { $null }
  $subs = if ($t) { @(@($t.streams) | Where-Object { $_.type -eq 'subtitle' }) } else { @() }
  if (-not $t -or -not @($subs | Where-Object { $_.packetsKeyPresent }).Count) {
    $unchecked++; Say ("  UNCHECKED  {0} - no packet-walked subtitle streams for {1} title {2} in the evidence pack (a skip is not a pass)" -f $leaf, $unit, $it.title); continue
  }
  $checked++
  if ($it.PSObject.Properties.Name -contains 'subTrackSparseOk' -and "$($it.subTrackSparseOk)".Trim()) {
    Say ("  explained  {0} subTrack {1}: {2}" -f $leaf, $st, "$($it.subTrackSparseOk)".Trim()); continue
  }
  $n = [int]$st
  $big = @(for ($i = 0; $i -lt $subs.Count; $i++) { if ([int]$subs[$i].packets -ge $SubstantialPackets) { [pscustomobject]@{ Ord = $i; S = $subs[$i] } } })
  $hint = ''
  $abs = @($big | Where-Object { [int]$_.S.index -eq $n })
  if ($abs.Count) { $hint = (" - {0} is the ABSOLUTE stream index of the {1} stream ({2} packets); its subtitle ORDINAL is {3}" -f $n, $abs[0].S.lang, $abs[0].S.packets, $abs[0].Ord) }
  if ($n -ge $subs.Count) {
    $refuse++
    Say ("  REFUSED  {0}: subTrack {1}, but title {2} has only {3} subtitle stream(s) (ordinals 0-{4}){5}" -f $leaf, $n, $it.title, $subs.Count, ($subs.Count - 1), $hint)
    continue
  }
  $pk = [int]$subs[$n].packets
  if ($pk -le $SparsePackets -and $big.Count) {
    $refuse++
    Say ("  REFUSED  {0}: subTrack {1} is subtitle stream {1} ({2}, {3} packets) - near-empty, while the title carries {4}{5}" -f `
         $leaf, $n, $subs[$n].lang, $pk, (($big | ForEach-Object { "ordinal {0} = {1} {2} pkts" -f $_.Ord, $_.S.lang, $_.S.packets }) -join '; '), $hint)
  }
}
if ($refuse) {
  Say ''
  Say ("assert-subtrack-substantial: REFUSED - {0} row(s) pick a near-empty subtitle stream. subTrack is the SUBTITLE ORDINAL (0 = first subtitle stream), not the absolute stream index. Set the ordinal, or state subTrackSparseOk with what the stream is." -f $refuse)
  exit 2
}
Say ("assert-subtrack-substantial: OK - {0} DVD row(s) with a numeric subTrack checked against the evidence pack, {1} not checkable" -f $checked, $unchecked)
exit 0
