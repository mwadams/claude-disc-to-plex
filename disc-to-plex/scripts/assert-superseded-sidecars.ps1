<#
.SYNOPSIS
  Refuse a manifest that would replace a published .mkv IN PLACE while leaving the old subtitle
  sidecar standing beside it.

.THE DEFECT THIS CLOSES
  An in-place supersede keeps the filename: `The Box of Delights - s01e01.mkv` is overwritten by the
  new rip at the path it already occupies. That is correct and deliberate - a new name would ship a
  duplicate alongside the old file instead of replacing it.

  But the `.eng.srt` beside it keeps its name too, and it was OCR'd from the OLD source.

  Normally that resolves itself and nothing needs to be said: the new local encode has no sidecar,
  the OCR track converts this disc's own subtitle stream, and the publish - which passes -Overwrite
  once it sees the size mismatch - copies the new .mkv AND the new .srt over both old files.

  THE HOLE IS A SOURCE WITH NO SUBTITLE STREAM. Nothing is produced locally, so there is nothing to
  overwrite with, and the OLD sidecar survives against the NEW video. `_ocr-loop.ps1` then never
  revisits it: its eligibility test is "does a sidecar exist" (line 64), so a stale one blocks
  re-OCR permanently. Plex reads it, and the desync is discovered by a viewer or not at all.

  It matters most exactly where in-place supersedes happen - a REMASTER. The Box of Delights 40th
  Anniversary Blu-ray (2026-09-10) replaces a DVD publication whose ten files all carry DVD-timed
  sidecars; a restoration is a different transfer, so those timings are not transferable.

  Every gate in this chain exists because prose did not hold. This one is no different: the risk was
  written into the unit's operator notes first, and a note is the weak form - it is read once, by
  one agent, and only if the brief reaches it.

.WHAT COUNTS AS A REPLACEMENT - AND WHAT DOES NOT
  "The NAS file already exists" is NOT the test, and the first cut of this guard used it and was
  wrong: run against 40 completed manifests it refused 16, because a manifest that has ALREADY
  PUBLISHED naturally finds its own outputs sitting on the NAS. A re-gate would have jammed the
  queue on a fault that does not exist.

  The question is whether a DIFFERENT SOURCE put that file there. The pipeline already records the
  answer: every completed manifest in _queue/done names both the `out` path it wrote and the `src`
  unit it consumed. So a row is a replacement when a completed manifest claims the same `out` from a
  DIFFERENT `src` - or when the file is on the NAS and no manifest claims it at all, which is the
  legacy case (a pre-pipeline publication, exactly what a remaster supersedes). Same `out`, same
  `src` is this manifest's own prior run, and says nothing.

.WHAT IT REFUSES
  A row where ALL of:
    1. it REPLACES something, in the sense just defined;
    2. a subtitle sidecar already sits beside that NAS path;
    3. the row names NO subtitle source (`subTrack` absent, empty, or "none"), so this publish will
       produce nothing to overwrite it with;
    4. the row does not carry `staleSidecar` - the author's explicit statement that they looked.

.HOW TO SATISFY IT
  Either name the disc's subtitle stream in `subTrack`, so a fresh sidecar is OCR'd from THIS source
  - which is the answer whenever the disc has one - or, when it genuinely has none, add

      "staleSidecar": "<what you decided and why>"

  to the row. Any non-empty text passes: this gate is not trying to adjudicate the decision, only to
  make sure it was MADE. An author who has read the timings and judged them still valid, and an
  author who wants the old sidecar flagged for the operator to delete, are both answering the
  question. Silence is what must not pass.

.NOTES
  Silent (exit 0) when it cannot judge: no manifest, unreadable JSON, no rows, a row with no `out`.
  A guard that cannot read its input has not found a fault (see assert-tracks-analysed.ps1, whose
  config failed to load and which then enforced nothing while reporting success).

  Exit 0 = nothing to refuse.  Exit 2 = REFUSED.

    pwsh -NoProfile -File assert-superseded-sidecars.ps1 -Manifest D:/video/_pending/foo.json
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  [string]$NasRoot = '\\NASTEAMV\Multimedia',
  [string]$LocalRoot = 'D:/video',
  # The completed manifests, read to learn WHICH SOURCE produced the file already on the NAS.
  [string]$DoneDir = 'D:/video/_queue/done',
  [switch]$Quiet
)

function Say([string]$m) { if (-not $Quiet) { Write-Output $m } }

if (-not (Test-Path -LiteralPath $Manifest)) { Say "assert-superseded-sidecars: no manifest at $Manifest - nothing to check."; exit 0 }
try { $mj = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json }
catch { Say "assert-superseded-sidecars: $Manifest is not readable JSON - leaving it to the gate's own parser."; exit 0 }

# ConvertFrom-Json UNWRAPS A SINGLE-ELEMENT ARRAY, so a one-row manifest is not an array and an
# `-is [System.Array]` test reads zero rows and exits 0 having checked nothing. Ask about `outputs`
# FIRST, then wrap. (Same trap as assert-accounted.ps1, 2026-09-09.)
$rows = @()
if ($null -ne $mj) {
  if ($mj -isnot [System.Array] -and $mj.PSObject.Properties.Name -contains 'outputs') { $rows = @($mj.outputs) }
  else { $rows = @($mj) }
}
if (-not $rows.Count) { Say 'assert-superseded-sidecars: no rows in this manifest.'; exit 0 }

# Sidecar extensions Plex will pick up beside a media file. `.eng.srt` is what this pipeline writes;
# the others are here because a legacy publication may carry them and they are just as stale.
$sidecarSuffixes = @('.eng.srt', '.srt', '.eng.ass', '.ass', '.eng.sub', '.sub')

function Get-ObjText($row, [string]$name) {
  if ($null -eq $row) { return '' }
  if ($row.PSObject.Properties.Name -notcontains $name) { return '' }
  return "$($row.$name)".Trim()
}

# WHO ALREADY WROTE THIS PATH? out (normalised) -> the set of src UNITS that completed manifests
# claim produced it. Read once; a done/ directory of ~730 files is a couple of seconds.
function Get-SrcUnit([string]$src) {
  # `src` is either the staged unit itself ("D:/video/_stage/X-Men") or a file inside it
  # ("D:/video/_stage/topsy-turvy-rip/Topsy Turvy_t00.mkv"). The UNIT is the segment after _stage.
  if ($src -match '(?i)_stage[\\/]([^\\/]+)') { return $Matches[1] }
  return ''
}
$claims = @{}
if (Test-Path -LiteralPath $DoneDir -PathType Container) {
  foreach ($f in @(Get-ChildItem -LiteralPath $DoneDir -Filter '*.json' -ErrorAction SilentlyContinue)) {
    try { $dj = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json } catch { continue }
    $drows = @()
    if ($null -ne $dj) {
      if ($dj -isnot [System.Array] -and $dj.PSObject.Properties.Name -contains 'outputs') { $drows = @($dj.outputs) }
      else { $drows = @($dj) }
    }
    foreach ($dr in $drows) {
      $o = "$($dr.out)".Trim(); if (-not $o) { continue }
      $key = ($o -replace '/', '\').ToLowerInvariant()
      $u = Get-SrcUnit "$($dr.src)"
      if (-not $claims.ContainsKey($key)) { $claims[$key] = New-Object 'System.Collections.Generic.HashSet[string]' }
      [void]$claims[$key].Add($u.ToLowerInvariant())
    }
  }
}

$faults = @()
$checked = 0
$exempt = 0

foreach ($r in $rows) {
  $outPath = Get-ObjText $r 'out'
  if (-not $outPath) { continue }

  # local -> NAS, the same mapping every other script here uses. Manifest `out` is forward-slash by
  # house convention; the backslash form is handled too rather than assumed away.
  $nas = $outPath -replace '^(?i)D:/video/', ($NasRoot.TrimEnd('\') + '\') -replace '^(?i)D:\\video\\', ($NasRoot.TrimEnd('\') + '\')
  $nas = $nas -replace '/', '\'
  if ($nas -eq ($outPath -replace '/', '\')) { continue }   # not under the library root - not ours to judge

  if (-not (Test-Path -LiteralPath $nas -PathType Leaf)) { continue }   # nothing there: a NEW file

  # (1) IS THIS A REPLACEMENT FROM A DIFFERENT SOURCE? See .WHAT COUNTS AS A REPLACEMENT.
  $mySrc = (Get-SrcUnit (Get-ObjText $r 'src')).ToLowerInvariant()
  $key = ($outPath -replace '/', '\').ToLowerInvariant()
  if ($claims.ContainsKey($key)) {
    $others = @($claims[$key] | Where-Object { $_ -and $_ -ne $mySrc })
    if (-not $others.Count) { continue }   # only this same source claims it - a re-gate, not a supersede
  }
  # else: on the NAS, claimed by no manifest at all -> a legacy publication being replaced.
  $checked++

  $stem = [IO.Path]::Combine((Split-Path -Parent $nas), [IO.Path]::GetFileNameWithoutExtension($nas))
  $found = @()
  foreach ($sfx in $sidecarSuffixes) {
    $cand = $stem + $sfx
    if (Test-Path -LiteralPath $cand -PathType Leaf) { $found += (Split-Path -Leaf $cand) }
  }
  if (-not $found.Count) { continue }                                   # (2) no sidecar to go stale

  $sub = Get-ObjText $r 'subTrack'
  if ($sub -and $sub -ne 'none') { $exempt++; continue }                # (3) a fresh one will be made

  $ack = Get-ObjText $r 'staleSidecar'
  if ($ack) { $exempt++; continue }                                     # (4) the author answered

  $faults += [pscustomobject]@{
    Out      = (Split-Path -Leaf $outPath)
    Sidecars = ($found -join ', ')
    Sub      = $(if ($sub) { $sub } else { '(no subTrack field)' })
  }
}

if ($faults.Count) {
  Say ''
  Say ("SUPERSEDED SIDECAR - {0} row(s) would replace a published file IN PLACE and leave its OLD" -f $faults.Count)
  Say  'subtitle sidecar standing beside the new video:'
  Say ''
  foreach ($f in $faults) {
    Say ("   {0}" -f $f.Out)
    Say ("      existing sidecar on the NAS : {0}" -f $f.Sidecars)
    Say ("      subtitle source in this row : {0}" -f $f.Sub)
  }
  Say ''
  Say  'That sidecar was OCR''d from the PREVIOUS source. This row names no subtitle stream, so this'
  Say  'publish produces nothing to overwrite it with - and _ocr-loop.ps1 skips any file that already'
  Say  'has a sidecar, so it will never be revisited. A remaster is a different transfer; its old'
  Say  'timings are not transferable, and the desync surfaces to a viewer, not to a gate.'
  Say ''
  Say  'Either name this disc''s subtitle stream in `subTrack`, or state the decision on the row:'
  Say  '    "staleSidecar": "disc carries no subpicture stream; existing DVD sidecar retained -"'
  Say  '                    "timings spot-checked at 00:02/00:20/00:40 and still match"'
  Say  'Any non-empty text passes. The gate asks that the question was answered, not how.'
  exit 2
}

Say ("assert-superseded-sidecars: OK - {0} in-place replacement(s) checked, {1} carry a subtitle source or a stated decision." -f $checked, $exempt)
exit 0
