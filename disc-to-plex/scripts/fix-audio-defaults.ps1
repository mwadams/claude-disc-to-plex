# Repair files whose audio tracks are ALL flagged `default`, in place, without re-encoding.
#
# WHY THIS EXISTS
# ---------------
# ffmpeg copies the INPUT stream's disposition onto its output even when re-encoding, and MakeMKV
# flags every audio track it writes as `default`. So every kind:"MKV" encode this pipeline made
# shipped with all of its audio flagged default, while kind:"DVD" encodes came out correct.
# 657 published files of 5161 scanned, all TV, no films. Root cause fixed in transcode.ps1 on
# 2026-09-01, so the set cannot grow; this repairs what already shipped.
#
# The convention it restores: the AAC track is the default (a universal direct-play track), the
# bit-for-bit passthru is an alternative, and a commentary is neither. With everything flagged
# default, which track a client picks is undefined.
#
# WHY mkvpropedit AND NOT ffmpeg
# ------------------------------
# This edits the Matroska header only. Measured on the largest affected file - 9.85 GB - it took
# 0.12 s and grew the file by 624 bytes. An ffmpeg `-c copy` remux would rewrite all 933 GB across
# the NAS. It is O(1) in file size: the content is never read or rewritten.
#
# WHAT IT WILL NOT DO
#   - never touches `comment` / `visual_impaired` flags. Commentaries were ALREADY correct
#     (default=0, comment=1) - only the "everything else is default too" part was wrong.
#   - never touches video or subtitle tracks.
#   - never picks a commentary as the default track.
#   - never continues past a file that fails verification. A bad in-place edit damages the ONLY
#     copy (most source discs are released), so the first anomaly stops the run.
#
#   pwsh -File fix-audio-defaults.ps1 -DryRun          # show what would change
#   pwsh -File fix-audio-defaults.ps1 -Limit 20        # do 20, then stop
#   pwsh -File fix-audio-defaults.ps1                  # the lot, resumable#
# NB: mkvpropedit takes the file name as a POSITIONAL argument and has NO `--` end-of-options
# separator - passing one makes it report "More than one file name has been given" and exit 2.
# Caught on the first real file because the run halts on the first failure instead of continuing.
param(
  [string]$Csv       = 'D:/video/_logs/audio-defaults.csv',
  [string]$Log       = 'D:/video/_logs/audio-defaults-fixed.log',
  [string]$ToolPaths = 'D:/video/.transcode-tools/tool-paths.json',
  [int]$Limit        = 0,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$tp = Get-Content -LiteralPath $ToolPaths -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $tp.ffmpeg) 'ffprobe.exe'
$mkvpropedit = 'D:/video/.transcode-tools/mkvtoolnix/mkvtoolnix/mkvpropedit.exe'
foreach ($t in @($ffprobe, $mkvpropedit)) {
  if (-not (Test-Path -LiteralPath $t)) { throw "required tool missing: $t" }
}
if (-not (Test-Path -LiteralPath $Csv)) { throw "file list not found: $Csv - run audit-audio-defaults.ps1 first" }

# RESUME. Every completed path is logged, so a halted run continues where it stopped rather than
# re-editing files that are already right (which would be harmless but slow, and would muddy the
# count of what this run actually changed).
$doneAlready = @{}
if (Test-Path -LiteralPath $Log) {
  foreach ($l in Get-Content -LiteralPath $Log) {
    if ($l -match '^(FIXED|SKIP|MISSING)\t(.+?)\t') { $doneAlready[$Matches[2]] = $true }
  }
}

function Get-AudioState($path) {
  # index / codec / default / comment, in stream order. mkvpropedit addresses audio tracks as
  # a1..aN in this same order, which is what makes the mapping below safe.
  $rows = @(& $ffprobe -v error -select_streams a `
              -show_entries stream=codec_name:stream_disposition=default,comment `
              -of csv=p=0 $path 2>$null)
  $out = @()
  $i = 1
  foreach ($r in $rows) {
    $p = "$r".Trim().TrimEnd(',') -split ','
    if ($p.Count -lt 3) { continue }
    $out += [pscustomobject]@{ a = $i; codec = $p[0]; default = [int]$p[1]; comment = [int]$p[2] }
    $i++
  }
  $out
}
function Get-Duration($path) {
  "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $path 2>$null)".Trim()
}

$rowsIn = @(Import-Csv -LiteralPath $Csv)
Write-Output ("{0} file(s) in the list; {1} already processed in an earlier run" -f $rowsIn.Count, $doneAlready.Count)

$fixed = 0; $skipped = 0; $missing = 0; $considered = 0
foreach ($row in $rowsIn) {
  $path = $row.path
  if ($doneAlready.ContainsKey($path)) { continue }
  if ($Limit -gt 0 -and $considered -ge $Limit) { Write-Output "-Limit $Limit reached - stopping"; break }
  $considered++

  if (-not (Test-Path -LiteralPath $path)) {
    $missing++
    Write-Output "MISSING  $path"
    if (-not $DryRun) { Add-Content -LiteralPath $Log -Value ("MISSING`t{0}`tnot present" -f $path) }
    continue
  }

  $before = Get-AudioState $path
  if ($before.Count -eq 0) { throw "could not read audio streams from $path - refusing to guess" }

  $defaults = @($before | Where-Object { $_.default -eq 1 })
  if ($defaults.Count -le 1) {
    # Already correct - re-encoded since the audit, or fixed by an earlier run.
    $skipped++
    if (-not $DryRun) { Add-Content -LiteralPath $Log -Value ("SKIP`t{0}`talready {1} default" -f $path, $defaults.Count) }
    continue
  }

  # THE TARGET IS THE FIRST AAC THAT IS NOT A COMMENTARY. Chosen, never assumed to be track 1:
  # if a file somehow has no AAC, that is a different shape than this repair was designed for and
  # it must be reported, not guessed at.
  $target = @($before | Where-Object { $_.codec -eq 'aac' -and $_.comment -eq 0 })[0]
  if (-not $target) {
    $skipped++
    Write-Output "SKIP (no non-commentary AAC track - not this defect's shape): $path"
    if (-not $DryRun) { Add-Content -LiteralPath $Log -Value ("SKIP`t{0}`tno aac target" -f $path) }
    continue
  }

  $args = @()
  foreach ($t in $before) {
    $want = if ($t.a -eq $target.a) { 1 } else { 0 }
    $args += @('--edit', "track:a$($t.a)", '--set', "flag-default=$want")
  }

  if ($DryRun) {
    Write-Output ("WOULD  {0}`n         {1} audio, {2} default -> default on a{3} ({4})" -f `
                  $path, $before.Count, $defaults.Count, $target.a, $target.codec)
    continue
  }

  $durBefore = Get-Duration $path
  $out = & $mkvpropedit $path @args 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Output "HALT: mkvpropedit exit $LASTEXITCODE on $path"
    $out | ForEach-Object { "    $_" }
    throw 'stopping on the first failure - this edits the only copy in place'
  }

  # VERIFY FROM THE FILE, NOT FROM THE EXIT CODE. mkvpropedit reporting success is not evidence
  # that the result is what was wanted, and this is a published file with no second copy.
  $after = Get-AudioState $path
  $durAfter = Get-Duration $path
  $afterDefaults = @($after | Where-Object { $_.default -eq 1 })
  $ok = ($after.Count -eq $before.Count) -and
        ($afterDefaults.Count -eq 1) -and
        ($afterDefaults[0].a -eq $target.a) -and
        ($durBefore -eq $durAfter)
  # Commentary flags must be exactly as they were - the repair has no business touching them.
  for ($k = 0; $k -lt $before.Count -and $ok; $k++) {
    if ($before[$k].comment -ne $after[$k].comment) { $ok = $false }
  }
  if (-not $ok) {
    Write-Output "HALT: verification FAILED on $path"
    Write-Output ("   before: {0} streams, {1} default, dur {2}" -f $before.Count, $defaults.Count, $durBefore)
    Write-Output ("   after : {0} streams, {1} default, dur {2}" -f $after.Count, $afterDefaults.Count, $durAfter)
    throw 'stopping on the first anomaly rather than continuing through the library'
  }

  $fixed++
  Add-Content -LiteralPath $Log -Value ("FIXED`t{0}`ta{1} {2} now default, {3} track(s) cleared" -f `
                                        $path, $target.a, $target.codec, ($before.Count - 1))
  if ($fixed % 25 -eq 0) { Write-Output ("  ... {0} fixed" -f $fixed) }
}

Write-Output ''
Write-Output ("done: {0} fixed, {1} skipped (already correct or wrong shape), {2} missing" -f $fixed, $skipped, $missing)
Write-Output "log -> $Log"
