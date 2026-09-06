<#
.SYNOPSIS
  Correct a published .mkv's DISPLAY ASPECT RATIO without re-encoding a single frame.

.WHY
  Anamorphic standard-definition video stores a 16:9 picture in a 720x576 raster and relies on a
  FLAG to say how wide to display it. When that flag says 4:3, every player obeys it and the picture
  is horizontally squashed - faces come out narrow and tall. Nothing about the encoded pixels is
  wrong, so no re-encode is needed or wanted: re-encoding 332 MB to change a header both wastes an
  hour and loses a generation of quality for no reason.

  Found on `Porridge S00E04.mkv` ("Ronnie Barker Interview", a legacy publish of 2026-07-30):
  718x576 with SAR 16:15, i.e. DAR 4:3, on content that is plainly 16:9 - rendered at 16:9 the
  proportions are natural, at 4:3 the face is visibly narrow.

  NOT a defect in this pipeline's encoder. transcode.ps1 already refuses an implausible declared DAR
  and makes the author LOOK AT A FRAME and state `dar` explicitly; its own comments even note that a
  dark or close-up scene yields a bogus automatic crop. This script exists for the library's LEGACY
  files, which were published before that guard existed.

.WHAT IT DOES
  * copies the published file to a LOCAL working copy (never edits on the NAS in place);
  * rewrites only the container's display dimensions with mkvpropedit;
  * VERIFIES the result: the new DAR is what was asked for, the duration is unchanged, and the video
    stream is bit-identical to the original (an MD5 of the decoded-free packet data), so "no
    re-encode" is proven rather than assumed;
  * leaves the corrected file in -WorkDir for the normal publish path to put back. It does NOT write
    to the NAS itself - publishing is the publish path's job, and this way a bad result is caught
    while it is still local.

  pwsh -NoProfile -File fix-display-aspect.ps1 -File '\\NAS\...\Porridge S00E04.mkv' -Dar 16:9
  pwsh -NoProfile -File fix-display-aspect.ps1 -File ... -Dar 16:9 -WhatIf

.EXIT CODES
  0 = a corrected local copy is ready   2 = refused, nothing written   3 = verification failed
#>
param(
  [Parameter(Mandatory)][string]$File,
  [Parameter(Mandatory)][ValidatePattern('^\d+:\d+$')][string]$Dar,
  [string]$WorkDir = 'D:/video/_aspect-fix',
  [string]$MkvPropEdit = 'D:/video/.transcode-tools/mkvtoolnix/mkvtoolnix/mkvpropedit.exe',
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { Write-Output "REFUSE - no such file: $File"; exit 2 }
if (-not (Test-Path -LiteralPath $MkvPropEdit -PathType Leaf)) { Write-Output "REFUSE - mkvpropedit not found at $MkvPropEdit"; exit 2 }
if ([IO.Path]::GetExtension($File).ToLowerInvariant() -ne '.mkv') { Write-Output 'REFUSE - only .mkv carries the display dimensions this edits'; exit 2 }

$probe = { param($p, $entries) (& ffprobe -v error -select_streams v:0 -show_entries $entries -of csv=p=0 -- $p) }
$before = "$(& $probe $File 'stream=width,height,sample_aspect_ratio,display_aspect_ratio')".Trim()
$durBefore = "$(& $probe $File 'format=duration')".Trim()
Write-Output ("current : {0}   duration {1} s" -f $before, $durBefore)

$w = [int]($Dar -split ':')[0]; $h = [int]($Dar -split ':')[1]
# Display dimensions, not a ratio: mkvpropedit takes pixels. Height is kept at the stored height so
# the intent (widen, do not resample) is explicit in the numbers themselves.
$storedH = [int]("$(& $probe $File 'stream=height')".Trim())
$dispH = $storedH
$dispW = [int][Math]::Round($storedH * ($w / [double]$h))
Write-Output ("target  : DAR {0} -> display {1}x{2} (stored raster untouched)" -f $Dar, $dispW, $dispH)

if ($WhatIf) { Write-Output 'WhatIf: nothing copied, nothing written'; exit 0 }

New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
$local = Join-Path $WorkDir ([IO.Path]::GetFileName($File))
Write-Output "copying to a local working copy (the NAS file is never edited in place)..."
Copy-Item -LiteralPath $File -Destination $local -Force

# The proof that nothing was re-encoded: the video stream's payload hash, before and after.
$md5Before = "$(& ffmpeg -v error -i $local -map 0:v:0 -c copy -f md5 - 2>$null)".Trim()

& $MkvPropEdit $local --edit track:v1 --set display-width=$dispW --set display-height=$dispH | Out-Null
if ($LASTEXITCODE -ne 0) { Write-Output "REFUSE - mkvpropedit exit $LASTEXITCODE; the local copy may be damaged, delete it"; exit 3 }

$after = "$(& $probe $local 'stream=width,height,sample_aspect_ratio,display_aspect_ratio')".Trim()
$durAfter = "$(& $probe $local 'format=duration')".Trim()
$md5After = "$(& ffmpeg -v error -i $local -map 0:v:0 -c copy -f md5 - 2>$null)".Trim()
Write-Output ("result  : {0}   duration {1} s" -f $after, $durAfter)

$fail = @()
$gotDar = ($after -split ',')[-1]
$wantRatio = $w / [double]$h
$gp = $gotDar -split ':'
$gotRatio = if ($gp.Count -eq 2 -and [double]$gp[1] -ne 0) { [double]$gp[0] / [double]$gp[1] } else { 0 }
if ([Math]::Abs($gotRatio - $wantRatio) -gt 0.01) { $fail += "DAR is '$gotDar' (ratio $([Math]::Round($gotRatio,3))), wanted $Dar" }
if ($durBefore -ne $durAfter) { $fail += "duration changed: $durBefore -> $durAfter" }
if ($md5Before -ne $md5After) { $fail += 'the VIDEO STREAM CHANGED - this was supposed to be a header-only edit' }

if ($fail.Count) {
  Write-Output 'VERIFICATION FAILED - do not publish this:'
  foreach ($f in $fail) { Write-Output "    $f" }
  exit 3
}
Write-Output 'verified: display aspect corrected, duration unchanged, video stream bit-identical (no re-encode)'
Write-Output ("ready to publish: {0}" -f $local)
Write-Output 'Publishing it back over the NAS copy is the publish path''s job, not this script''s.'
exit 0
