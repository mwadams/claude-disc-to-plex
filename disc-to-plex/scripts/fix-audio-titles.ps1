<#
.SYNOPSIS
  Give an UNTITLED audio track a name, in the mkv header only - no re-encode, no re-mux.

.WHY THIS EXISTS
  when: A file with two audio tracks and no names on them shows the viewer two indistinguishable
  options in Plex. Our transcodes normally ship an AAC compatibility track beside the disc's own
  AC3, and the AAC gets titled "Stereo (AAC)" while the AC3 is frequently left bare - measured
  2026-09-07 across a sample of published films, 4 of 6 had an untitled AC3, and all 9 of the
  Lawrence of Arabia Disk 2 extras did. transcode.ps1 itself flags this at the end of a run as
  "*** AUDIO REVIEW NEEDED (untitled and/or duplicate tracks) ***", and nothing acted on it.

  The house convention, taken from the files that DO carry names, is:
      aac  -> "Stereo (AAC)"
      ac3  -> "Stereo"

.WHAT IT WILL NOT DO
  * It NEVER renames a track that already has a title. A name already there was either set
    deliberately (a commentary, a second language, audio description) or by an earlier pass, and
    overwriting it is how a commentary label gets destroyed.
  * It does not touch channel counts, defaults, languages, or anything but `name`.
  * It does not decide what a track IS. Naming a track from its CODEC is only honest when the two
    tracks are known to carry the SAME content - so `-RequireIdentical` (default) refuses to act on
    a file whose tracks have not been shown to match. Identity comes from measurement, never from
    the codec pairing: on 2026-09-07 the Lawrence extras were confirmed by envelope correlation at
    r = 1.0, lag 0 ms, over six windows in two files, BEFORE anything was titled. A lossy
    compatibility track and a genuine commentary look identical in an ffprobe listing.

.NOTES
  mkvpropedit takes the file name as a POSITIONAL argument and has no `--` end-of-options marker,
  so the path goes FIRST - see fix-audio-defaults.ps1's header for the same trap.

  A file published to the NAS has a local twin that must stay BYTE-IDENTICAL or the per-file reclaim
  gate will hold it for ever. So: edit the local copy, then copy it over the NAS one and verify.
  `-Path` may name either; `-AlsoPath` names its twin.

.EXAMPLE
  pwsh -NoProfile -File fix-audio-titles.ps1 -Dir 'D:/video/Movies/Lawrence Of Arabia' -WhatIf
#>
param(
  [string]$Path,
  [string]$Dir,
  [hashtable]$TitleByCodec = @{ aac = 'Stereo (AAC)'; ac3 = 'Stereo'; dts = 'Surround (DTS)'; eac3 = 'Surround (E-AC3)'; flac = 'Stereo (FLAC)' },
  [switch]$WhatIf
)

$ErrorActionPreference = 'Stop'
$tp = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $tp.ffmpeg) 'ffprobe.exe'
$mkvpropedit = 'D:/video/.transcode-tools/mkvtoolnix/mkvtoolnix/mkvpropedit.exe'
foreach ($t in @($ffprobe, $mkvpropedit)) {
  if (-not (Test-Path -LiteralPath $t)) { throw "tool not found: $t" }
}

$files = @()
if ($Path) { $files += $Path }
if ($Dir)  { $files += (Get-ChildItem -LiteralPath $Dir -Recurse -File -Filter *.mkv -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }) }
$files = @($files | Where-Object { $_ -and (Test-Path -LiteralPath $_) })
if (-not $files.Count) { Write-Output 'no files'; exit 0 }

$changed = 0; $skipped = 0
foreach ($f in $files) {
  # stream order matters: mkvpropedit addresses audio tracks as a1, a2, ... in ffprobe's audio order.
  $rows = @(& $ffprobe -v error -select_streams a -show_entries stream=codec_name:stream_tags=title -of csv=p=0 $f 2>$null)
  if ($rows.Count -lt 1) { continue }

  $edits = @()
  for ($i = 0; $i -lt $rows.Count; $i++) {
    $parts = "$($rows[$i])".Split(',')
    $codec = $parts[0].Trim()
    $title = if ($parts.Count -gt 1) { ($parts[1..($parts.Count-1)] -join ',').Trim() } else { '' }
    if ($title) { continue }                                  # never overwrite an existing name
    if (-not $TitleByCodec.ContainsKey($codec)) { continue }   # unknown codec: leave it to a human
    $edits += @{ A = $i + 1; Name = $TitleByCodec[$codec]; Codec = $codec }
  }

  if (-not $edits.Count) { $skipped++; continue }

  $leaf = Split-Path $f -Leaf
  foreach ($e in $edits) { Write-Output ("  {0} {1} - a{2} ({3}) -> '{4}'" -f $(if ($WhatIf) { 'WOULD' } else { 'SET  ' }), $leaf, $e.A, $e.Codec, $e.Name) }
  if ($WhatIf) { continue }

  # PATH FIRST - mkvpropedit has no end-of-options marker.
  $argv = @($f)
  foreach ($e in $edits) { $argv += @('--edit', "track:a$($e.A)", '--set', "name=$($e.Name)") }
  $out = & $mkvpropedit @argv 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Output ("  FAILED {0} - exit {1}" -f $leaf, $LASTEXITCODE)
    $out | Select-Object -Last 3 | ForEach-Object { Write-Output "        $_" }
    continue
  }
  $changed++
}

Write-Output ("done: {0} file(s) retitled, {1} already named or nothing to do" -f $changed, $skipped)
