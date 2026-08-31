<#
  build-retire-list.ps1 - produce the hand-over list of NAS files that have been
  SUPERSEDED and are therefore safe for the user to remove.

  This script is READ-ONLY. It never removes, renames or moves anything, on any volume.
  It writes a list; acting on that list is the user's decision, and deliberately so.

  WHY IT EXISTS
  A re-rip publishes "X.mkv" into a folder that already holds a legacy "X.mp4". Publishing
  is a robocopy and -Overwrite only replaces a file of the SAME name, so both survive and
  Plex shows the work twice. The pipeline cannot clean that up - nothing here may delete on
  the NAS - so without a record the obligation lives only in someone's memory. A manifest
  item now carries `supersedes`, and this turns those into a checked list.

  THE GATE
  A superseded file is listed ONLY when its replacement is verified present on the NAS.
  Listing it any earlier would invite deleting the old copy while the new one does not yet
  exist. Each candidate must pass, in order:
    1. the replacement exists on the NAS and is a plausible size (>5 MB, or matches local)
    2. the superseded file still exists on the NAS
    3. the two paths are DIFFERENT (never list the file just published)
    4. both lie under the NAS multimedia roots (never emit a D: or E: path)
  Anything failing a check is reported as held back, with the reason, rather than dropped.

  USAGE
    pwsh -File build-retire-list.ps1
    pwsh -File build-retire-list.ps1 -IncludeSubtitles     # also test sidecar SRTs
#>
param(
  [string]$ManifestRoot = 'D:\video\_queue',
  [string]$Out          = 'D:\video\_nas-retire.txt',
  [string]$Report       = 'D:\video\_nas-retire-detail.tsv',
  [switch]$IncludeSubtitles
)

$ErrorActionPreference = 'Stop'

$NasRoot = [IO.Path]::Combine('\\NASTEAMV', 'Multimedia')
$LocalToNas = @{
  'D:\video\Movies'           = [IO.Path]::Combine($NasRoot, 'Movies')
  'D:\video\Television Shows' = [IO.Path]::Combine($NasRoot, 'Television Shows')
}

function To-NasPath($localPath) {
  foreach ($k in $LocalToNas.Keys) {
    if ($localPath.StartsWith($k, [StringComparison]::OrdinalIgnoreCase)) {
      return $LocalToNas[$k] + $localPath.Substring($k.Length)
    }
  }
  return $null
}

function Under-Nas($p) { return $p -and $p.StartsWith($NasRoot, [StringComparison]::OrdinalIgnoreCase) }

$listed = New-Object System.Collections.Generic.List[object]
$held   = New-Object System.Collections.Generic.List[object]

# ---------------------------------------------------------------- manifests
$dirs = @($ManifestRoot,
          (Join-Path $ManifestRoot 'done'),
          (Join-Path $ManifestRoot 'running'),
          (Join-Path $ManifestRoot 'failed')) | Where-Object { Test-Path -LiteralPath $_ }

$manifests = @(foreach ($d in $dirs) { Get-ChildItem -LiteralPath $d -Filter *.json -File -EA SilentlyContinue })
Write-Host "scanning $($manifests.Count) manifest(s) under $ManifestRoot"

foreach ($mf in $manifests) {
  $items = $null
  try { $items = Get-Content -LiteralPath $mf.FullName -Raw | ConvertFrom-Json } catch {
    $held.Add([pscustomobject]@{ Superseded=''; Replacement=''; Source=$mf.Name; Reason="unreadable manifest: $_" })
    continue
  }
  foreach ($it in @($items)) {
    if (-not ($it.PSObject.Properties.Name -contains 'supersedes')) { continue }
    $old = @($it.supersedes) | Where-Object { $_ }
    if (-not $old) { continue }

    $localOut = "$($it.out)" -replace '/', '\'
    $nasNew   = To-NasPath $localOut

    foreach ($o in $old) {
      $o = ($o -replace '/', '\').Trim()
      $rec = [pscustomobject]@{ Superseded=$o; Replacement=$nasNew; Source=$mf.Name; Reason='' }

      if (-not (Under-Nas $o))      { $rec.Reason = 'superseded path is not on the NAS'; $held.Add($rec); continue }
      if (-not $nasNew)             { $rec.Reason = 'output is not under a known library root'; $held.Add($rec); continue }
      if (-not (Under-Nas $nasNew)) { $rec.Reason = 'replacement path is not on the NAS'; $held.Add($rec); continue }
      if ($o -eq $nasNew)           { $rec.Reason = 'REFUSED: superseded path equals the replacement'; $held.Add($rec); continue }

      $newItem = Get-Item -LiteralPath $nasNew -EA SilentlyContinue
      if (-not $newItem)            { $rec.Reason = 'replacement not yet published to the NAS'; $held.Add($rec); continue }

      $localItem = Get-Item -LiteralPath $localOut -EA SilentlyContinue
      if ($localItem -and $localItem.Length -ne $newItem.Length) {
        $rec.Reason = "replacement size mismatch (NAS $($newItem.Length) vs local $($localItem.Length))"
        $held.Add($rec); continue
      }
      if (-not $localItem -and $newItem.Length -lt 5MB) {
        $rec.Reason = "replacement suspiciously small ($($newItem.Length) bytes) and no local copy to compare"
        $held.Add($rec); continue
      }
      if (-not (Test-Path -LiteralPath $o)) { $rec.Reason = 'already gone'; $held.Add($rec); continue }

      $rec.Reason = 'superseded; replacement verified on the NAS'
      $listed.Add($rec)
    }
  }
}

# ---------------------------------------------------------------- sidecar subtitles
# An .srt is OURS if the media beside it still carries the bitmap stream it was read from;
# our OCR does not remove the stream. One that has no such stream cannot have come from
# this pipeline. That structural test is the only reliable one available: a provider-credit
# regex flagged 18 files and EVERY hit was either the disc's own subtitling-house credit
# ("Visiontext Subtitles by ...") or dialogue containing a domain name.
if ($IncludeSubtitles) {
  $paths = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
  $ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'
  $bitmap = @('hdmv_pgs_subtitle','dvd_subtitle','dvb_subtitle','xsub')
  $n = 0
  foreach ($root in $LocalToNas.Values) {
    foreach ($srt in Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.srt -EA SilentlyContinue) {
      $n++
      $stem = $srt.Name -replace '\.[a-zA-Z]{2,3}\.srt$','' -replace '\.srt$',''
      $media = Get-ChildItem -LiteralPath $srt.DirectoryName -File -EA SilentlyContinue |
               Where-Object { $_.Extension -in '.mkv','.mp4','.m4v','.avi' -and
                              [IO.Path]::GetFileNameWithoutExtension($_.Name) -eq $stem } |
               Select-Object -First 1
      if (-not $media) {
        $held.Add([pscustomobject]@{ Superseded=$srt.FullName; Replacement=''; Source='subtitle-scan'
                                     Reason='no sibling media - NOT ours to judge (Plex optimized versions live here)' })
        continue
      }
      $codecs = & $ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 -- $media.FullName 2>$null
      $codecs = @($codecs | Where-Object { $_ })
      if (@($codecs | Where-Object { $bitmap -contains $_ }).Count -gt 0) { continue }  # consistent with our OCR
      $held.Add([pscustomobject]@{ Superseded=$srt.FullName; Replacement=''; Source='subtitle-scan'
                                   Reason='media carries NO bitmap stream - we could not have OCR''d this; external candidate, needs a replacement before it can be retired' })
    }
  }
  Write-Host "subtitle scan: examined $n sidecar(s)"
}

# ---------------------------------------------------------------- output
$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm'
$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("# NAS files superseded by a verified replacement - safe to remove.")
$lines.Add("# Generated $stamp by build-retire-list.ps1. Nothing here has been touched.")
$lines.Add("# Each line's replacement was confirmed present on the NAS before listing.")
$lines.Add('')
foreach ($r in $listed | Sort-Object Superseded) { $lines.Add($r.Superseded) }
Set-Content -LiteralPath $Out -Value $lines -Encoding UTF8

$listed + $held | Select-Object Superseded, Replacement, Source, Reason |
  Export-Csv -LiteralPath $Report -NoTypeInformation -Delimiter "`t" -Encoding UTF8

Write-Host ""
Write-Host "LISTED (replacement verified) : $($listed.Count)   -> $Out"
Write-Host "HELD BACK                     : $($held.Count)     -> $Report"
if ($held.Count) {
  $held | Group-Object Reason | Sort-Object Count -Descending |
    ForEach-Object { "    {0,4}  {1}" -f $_.Count, $_.Name }
}
Write-Host 'RETIRE-LIST-COMPLETE'
