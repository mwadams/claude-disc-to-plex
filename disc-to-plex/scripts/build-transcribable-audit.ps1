<#
.SYNOPSIS
  Build the transcribable AUDIT SET from completed manifests, so a show whose discs carry no
  subtitles enqueues itself for transcription instead of waiting to be noticed.

.WHY
  queue-transcribable.ps1 will only enqueue a NAS file it can tie back to disc evidence, and it
  offers two legitimate routes: the disc-identity register's own `outputs`, or an AUDIT SET. That
  is the right rule - a file with no subtitles is one of three quite different things (the disc had
  none; the rip lost them; they are bitmap subs needing OCR) and only the first belongs here.

  The gap was in how the audit set was produced: BY HAND. On 2026-09-06 Clayhanger's first four
  episodes were added manually, the publish loop was wired to call queue-transcribable on every
  pass - and then twenty more Clayhanger episodes published across discs 2 to 6 and NONE of them
  was enqueued. Twenty-four episodes on the NAS, one .srt between them. The automation was real but
  it was fed by a static file nobody was updating.

  It bites this show particularly because Clayhanger came through the OPTICAL lane, which produces
  no `dvdid.xml`, so no identity record can be keyed for it and route one is closed for ever. Every
  optical-lane show is in the same position - `Tales of the Unexpected` is next.

.THE EVIDENCE IT USES, AND WHY IT IS SOUND
  A completed manifest item carrying `"subTrack": "none"` is not a guess. The manifest author
  established, from a packet walk of the disc, that this title has NO subtitle stream to ship -
  that is the same finding queue-transcribable needs, already made, already written down, and
  already gated: the manifest reached `_queue/done`, so it passed the queue gate and the encode.

  Only `"none"` counts. A missing `subTrack` means unspecified, not absent, and is ignored.

  queue-transcribable.ps1 then re-checks every candidate itself - no sidecar, no subtitle stream in
  the file, a real audio stream to transcribe, long enough to be worth it - so this script decides
  what to OFFER, never what to transcribe.

.MERGING
  Existing audit sets are preserved, not replaced: -Merge names files whose rows are carried through
  (the hand-made media2 set covers ~245 files this cannot see, because those discs were audited
  rather than ripped here). Rows are keyed on kind+rel, so re-running is idempotent.

  pwsh -NoProfile -File build-transcribable-audit.ps1
  pwsh -NoProfile -File build-transcribable-audit.ps1 -WhatIf
#>
param(
  [string]$QueueDone = 'D:/video/_queue/done',
  [string]$Out       = 'D:/video/_audit-transcribable-combined.json',
  [string[]]$Merge   = @('D:/video/_audit-transcribable-media2.json', 'D:/video/_audit-transcribable-manual.json'),
  # MANIFEST DERIVATION IS OPT-IN, and deliberately not the default.
  #
  # The standing rule (user, 2026-09-06): "the queue is only supposed to contain items we have
  # *confirmed missing* from the drives we have processed." A completed manifest declaring
  # `subTrack: "none"` does meet that bar - the disposition packet-counted the title on a disc we
  # ripped - but sweeping EVERY such item at once turns an 88-row queue into roughly 1,200, and the
  # transcribe lane is GPU work measured in hours per hour of video. A change of that size is the
  # operator's to make, not a side effect of a publish.
  #
  # So: off unless asked, and -OnlyWorks narrows it to named shows when the answer is "yes, but just
  # this one". Without the switch this script still carries every hand-evidenced set forward, which
  # is what keeps Porridge Series 1 and the media2 audit in the queue.
  [switch]$FromManifests,
  [string[]]$OnlyWorks = @(),
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

$rows = @()
$seen = @{}
function AddRow($work, $rel, $kind, $disc, $tid) {
  $k = ($kind + '|' + $rel).ToLowerInvariant()
  if ($seen.ContainsKey($k)) { return }
  $seen[$k] = $true
  $script:rows += [ordered]@{ work = $work; rel = $rel; kind = $kind; disc = $disc; tid = $tid }
}

# ---- carried-over sets first, so hand-made evidence always survives a rebuild -------------------
$carried = 0
foreach ($m in $Merge) {
  if (-not (Test-Path -LiteralPath $m -PathType Leaf)) { continue }
  try { $j = Get-Content -LiteralPath $m -Raw | ConvertFrom-Json } catch { continue }
  foreach ($r in @($j)) {
    if (-not "$($r.rel)") { continue }
    AddRow "$($r.work)" "$($r.rel)" "$($r.kind)" "$($r.disc)" $r.tid
    $carried++
  }
}

# ---- manifest-derived rows: OPT-IN, and narrowable to named works -------------------------------
# WHY THIS IS NOT SWEPT IN WHOLESALE, even though the evidence is real. The user, 2026-09-06:
# "Many of these will be restored when we get a proper rip with VOBSUB."
#
# That is the decisive objection and it is this queue's founding rule restated. A machine transcript
# is strictly worse than the disc's own subtitles, and once it exists the file looks finished - so
# enqueuing a file whose subtitles are merely NOT YET RIPPED "permanently substitutes worse content
# for better", in this script's own words. `subTrack: "none"` says THIS disc had none for THIS
# title; it does not say no disc ever will. Measured on 2026-09-06: 1,203 published files would have
# qualified. Transcription is the LAST resort, after the re-rip programme has had its say - not a
# way to fill a column.
#
# Named works only, when the answer is "yes, but just this one": Clayhanger packet-counted ZERO
# subpicture streams disc-wide across all six of its discs, so no future rip can produce any.
$nFromManifests = 0
foreach ($f in @(Get-ChildItem -LiteralPath $QueueDone -File -Filter '*.json' -ErrorAction SilentlyContinue)) {
  if (-not $FromManifests) { break }
  $items = $null
  try { $items = @(Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json) } catch { continue }
  if ($items.Count -eq 1 -and $items[0].PSObject.Properties.Name -contains 'items') { $items = @($items[0].items) }
  foreach ($it in $items) {
    if ("$($it.subTrack)".Trim().ToLowerInvariant() -ne 'none') { continue }
    # NOT `$out`: PowerShell variable names are CASE-INSENSITIVE, so `$out` IS the `$Out` parameter.
    # The first cut used it here and the parameter was silently overwritten with a media path, so
    # the final Set-Content tried to write the audit set to
    # "D:\video\Television Shows\The Zoo Gang (1974)\...\S00E04 - Stills Gallery.mkv" and failed with
    # a path error that pointed nowhere near the actual mistake.
    $outPath = "$($it.out)"
    if (-not $outPath) { continue }
    $norm = $outPath -replace '\\', '/'
    if ($norm -notmatch '(?i)/(Television Shows|Movies)/(.+)$') { continue }
    $kind = $Matches[1]; $rel = $Matches[2]
    # The work is the first path segment under the kind root - taken from where the manifest WROTE,
    # never from the staging folder name, which is a volume label and proves nothing.
    $work = ($rel -split '/')[0]
    if ($OnlyWorks.Count -and ($OnlyWorks -notcontains $work)) { continue }
    $disc = ''
    if ("$($it.src)" -match '_stage[\\/]([^\\/"]+)') { $disc = $Matches[1] }
    AddRow $work ($rel -replace '/', '\') $kind $disc $it.title
    $nFromManifests++
  }
}

Write-Output ("transcribable audit set: {0} row(s) - {1} carried from existing set(s), {2} from manifests declaring subTrack=none" -f $rows.Count, $carried, $nFromManifests)
if ($WhatIf) { Write-Output '  WhatIf: nothing written'; exit 0 }

# NEVER SHRINK SILENTLY. Same reasoning as queue-transcribable's own anti-shrink guard: a rebuild is
# only as wide as the sources it was given, and a smaller set here would quietly narrow what the
# transcribe lane can ever see.
$before = 0
if (Test-Path -LiteralPath $Out -PathType Leaf) {
  try { $before = @(Get-Content -LiteralPath $Out -Raw | ConvertFrom-Json).Count } catch { $before = 0 }
}
if ($before -gt $rows.Count) {
  Write-Output ("REFUSING to shrink {0}: it holds {1} row(s) and this run produced {2}. Nothing written." -f $Out, $before, $rows.Count)
  exit 2
}
($rows | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $Out -Encoding UTF8
Write-Output ("written: {0} ({1} -> {2} rows)" -f $Out, $before, $rows.Count)
exit 0
