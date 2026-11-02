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
  # Hand-declared relocations: <superseded path><TAB><replacement path><TAB><why>. See the
  # 'hand relocations' section below for why this exists and what each row is validated against.
  [string]$Manual       = 'D:\video\_nas-retire-manual.tsv',
  [switch]$IncludeSubtitles,
  # Library roots - parameters only so the tests can stand a share in for the NAS.
  [string]$NasRoot      = [IO.Path]::Combine('\\NASTEAMV', 'Multimedia'),
  [string]$LocalRoot    = 'D:\video',
  # A same-episode .mp4/.mkv twin beside a published replacement is retired only when the two
  # programmes measure this close (seconds). See 'same-episode twins' below.
  [double]$TwinToleranceSeconds = 1.0
)

$ErrorActionPreference = 'Stop'

$NasRoot = $NasRoot.TrimEnd('\')
$LocalRoot = $LocalRoot.TrimEnd('\')
$LocalToNas = @{
  (Join-Path $LocalRoot 'Movies')           = [IO.Path]::Combine($NasRoot, 'Movies')
  (Join-Path $LocalRoot 'Television Shows') = [IO.Path]::Combine($NasRoot, 'Television Shows')
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

# A UNC PATH THAT LOST ONE OF ITS TWO LEADING BACKSLASHES. In JSON "\\NASTEAMV\..." decodes to ONE
# backslash, and authors keep writing it that way. 41 supersedes in 9 manifests (Upstairs Downstairs
# S1 D2-D3 and S2 D2, Black Books, Buffy S4, Yes Prime Minister S2, The Alan Clark Diaries) were all
# held back as "not on the NAS", so their legacy .mp4s never reached this list - found 2026-11-02
# only because the operator saw them in Plex. A rooted path that becomes the NAS root with one more
# backslash has no other reading.
function Repair-NasPath([string]$p) {
  if ($p -match '^\\[^\\]' -and ('\' + $p).StartsWith($NasRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return '\' + $p }
  return $p
}

$listed = New-Object System.Collections.Generic.List[object]
$held   = New-Object System.Collections.Generic.List[object]

# ---------------------------------------------------------------- manifests
$dirs = @($ManifestRoot,
          (Join-Path $ManifestRoot 'done'),
          (Join-Path $ManifestRoot 'running'),
          (Join-Path $ManifestRoot 'failed')) | Where-Object { Test-Path -LiteralPath $_ }

$manifests = @(foreach ($d in $dirs) { Get-ChildItem -LiteralPath $d -Filter *.json -File -EA SilentlyContinue })
Write-Host "scanning $($manifests.Count) manifest(s) under $ManifestRoot"

# ---- A SUPERSEDED PATH CAN BE REOCCUPIED, AND THEN IT MUST NEVER BE RETIRED --------------------
# `supersedes` records what a NEW output replaces, and it is written once, when the manifest is
# authored. It says nothing about what lives at that path LATER - and a numbered episode path is
# exactly the kind of address a subsequent publish reuses.
#
# The West Wing, 2026-09-09. Disc 1's manifest declares that `S00E15 - Isaac and Ishmael.mkv`
# supersedes `Season 03\The West Wing S03E01.mkv`, which was correct: the legacy library file at
# that path WAS Isaac and Ishmael, filed as episode 1 because it aired first. The same disc then
# published Manchester (1) - the true episode 1 - to that very path. So the retire list named a
# live, current, correct episode as safe to delete, and every check above passed while it did:
# the replacement (S00E15) really is on the NAS, really is verified, really did supersede
# something. Nothing in that chain asks whether the OLD address is still vacant.
#
# So collect every path any manifest currently declares as an output, and refuse to retire one.
# Cheap, and it fails closed: a path we are actively publishing to is never a path to delete.
$currentOutputs = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$outputLocal = @{}   # NAS output -> [local path, manifest name], for the twin pass below
foreach ($mf in $manifests) {
  $its = $null
  try { $its = Get-Content -LiteralPath $mf.FullName -Raw | ConvertFrom-Json } catch { continue }
  foreach ($it in @($its)) {
    $o = "$($it.out)"
    if (-not $o) { continue }
    $n = To-NasPath ($o -replace '/', '\')
    if ($n) { [void]$currentOutputs.Add($n); $outputLocal[$n] = @(($o -replace '/', '\'), $mf.Name) }
  }
}
Write-Host "$($currentOutputs.Count) path(s) are declared outputs of a live manifest - those can never be retired"

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
      $o = Repair-NasPath (($o -replace '/', '\').Trim())
      $rec = [pscustomobject]@{ Superseded=$o; Replacement=$nasNew; Source=$mf.Name; Reason='' }

      if (-not (Under-Nas $o))      { $rec.Reason = 'superseded path is not on the NAS'; $held.Add($rec); continue }
      if (-not $nasNew)             { $rec.Reason = 'output is not under a known library root'; $held.Add($rec); continue }
      if (-not (Under-Nas $nasNew)) { $rec.Reason = 'replacement path is not on the NAS'; $held.Add($rec); continue }
      if ($o -eq $nasNew)           { $rec.Reason = 'REFUSED: superseded path equals the replacement'; $held.Add($rec); continue }
      # The address was reused by a later publish - whatever is there now is OURS and CURRENT.
      if ($currentOutputs.Contains($o)) {
        $rec.Reason = 'REFUSED: that path is a CURRENT declared output - it was reoccupied after this supersedes was written'
        $held.Add($rec); continue
      }

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

      # REOCCUPATION, PART TWO: A SIDECAR IS REWRITTEN IN PLACE AND IS NEVER A MANIFEST OUTPUT.
      #
      # The $currentOutputs check above catches a path a live manifest still declares - but it is
      # built from manifest `out` values, and a `.eng.srt` is never one of those. It is produced
      # DOWNSTREAM by the OCR lane, at the same path, minutes after the media publishes. So a
      # supersedes naming the old sidecar sails past that guard and lists the NEW one for deletion.
      #
      # Measured 2026-09-10, and the operator caught it, not this script: Lavender Hill Mob's .mkv
      # published 15:19 and the OCR lane wrote `Lavender Hill Mob.eng.srt` at 15:23 - 1,070 cues,
      # correctly timed to the new master. `_nas-retire.txt` listed that live file, and this list is
      # documented as safe to action as-is.
      #
      # The rule needs no knowledge of sidecars: a file that is NEWER than the thing that replaced it
      # cannot be the thing that was replaced. Anything at the old address written after the
      # replacement landed was put there afterwards, by us, on purpose.
      $oldItem = Get-Item -LiteralPath $o -EA SilentlyContinue
      if ($oldItem -and $oldItem.LastWriteTime -gt $newItem.LastWriteTime) {
        $rec.Reason = ("REFUSED: reoccupied - the file at that path was written {0:yyyy-MM-dd HH:mm}, AFTER its replacement landed {1:yyyy-MM-dd HH:mm}, so it is not the superseded copy" -f $oldItem.LastWriteTime, $newItem.LastWriteTime)
        $held.Add($rec); continue
      }

      $rec.Reason = 'superseded; replacement verified on the NAS'
      $listed.Add($rec)
    }
  }
}

# ---------------------------------------------------------------- same-episode twins
#
# A SUPERSEDES THAT WAS NEVER WRITTEN LEAVES ITS TWIN IN PLEX FOREVER. Everything above depends on
# the author having named the old file. A re-rip that publishes "Show - S01E05 - Title.mkv" beside a
# legacy "Show S01E05.mp4" without saying so leaves both, and Plex shows the episode twice.
#
# So look beside every PUBLISHED output for another media file claiming the same single SxxEyy, and
# MEASURE it: the twin is listed only when its programme length agrees with the replacement's to
# within -TwinToleranceSeconds. Agreement within a second is the same programme; a wider gap is
# held back with the figure, because a different cut or a mis-numbered episode is a judgement, not
# a mechanical retire. Ranges (S01E01-E06) are never twins of anything. Every guard the manifest
# path applies holds here too: not a current output, not newer than its replacement, replacement
# verified against the local copy.
$ffprobeExe = $null
function Get-ProgrammeSeconds([string]$p) {
  if (-not $script:ffprobeExe) {
    $tp = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
    $script:ffprobeExe = Join-Path (Split-Path $tp.ffmpeg) 'ffprobe.exe'
  }
  $s = "$(& $script:ffprobeExe -v error -show_entries format=duration -of csv=p=0 -- $p 2>$null | Select-Object -First 1)".Trim()
  $d = 0.0
  if ([double]::TryParse($s, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
  return 0.0
}
function Get-SingleEpisode([string]$leaf) {
  if ($leaf -match '(?i)S(\d{1,3})E(\d{1,4})(?!\d)(-?E\d|-\d)') { return $null }   # a range; " - 1914" is a title
  if ($leaf -match '(?i)S(\d{1,3})E(\d{1,4})(?!\d)') { return ('{0}x{1}' -f [int]$Matches[1], [int]$Matches[2]) }
  return $null
}
$alreadyListed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($r in $listed) { [void]$alreadyListed.Add($r.Superseded) }
$heldPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($r in $held) { if ($r.Superseded) { [void]$heldPaths.Add($r.Superseded) } }
# ONLY A LEGACY CONTAINER IS A TWIN. The pipeline publishes .mkv and nothing else, so an .mp4/.m4v/.avi
# beside a published .mkv is pre-pipeline. A second .mkv for the same episode is most often a hand
# RENAME of a pipeline output (copied to the right name; the manifest still names the old one) -
# Copy-Item keeps the mtime, so the newer-than guard cannot tell them apart and the WANTED copy would
# be listed. Measured 2026-11-02: the first live run held 27 such .mkv "twins", every one the live file.
$legacyExt = @('.mp4', '.m4v', '.avi')
$dirCache = @{}
$twinOk = 0
foreach ($nasNew in @($outputLocal.Keys)) {
  if ([IO.Path]::GetExtension($nasNew) -ne '.mkv') { continue }
  $ep = Get-SingleEpisode (Split-Path $nasNew -Leaf)
  if (-not $ep) { continue }
  $dir = Split-Path $nasNew
  if (-not $dirCache.ContainsKey($dir)) { $dirCache[$dir] = @(Get-ChildItem -LiteralPath $dir -File -EA SilentlyContinue) }
  $newItem = $dirCache[$dir] | Where-Object { $_.FullName -eq $nasNew } | Select-Object -First 1
  if (-not $newItem) { continue }   # this output is not (or no longer) on the NAS - nothing beside it is its twin
  $twins = @($dirCache[$dir] | Where-Object { $legacyExt -contains $_.Extension.ToLowerInvariant() -and (Get-SingleEpisode $_.Name) -eq $ep })
  if (-not $twins) { continue }
  $localOut, $src = $outputLocal[$nasNew]
  foreach ($tw in $twins) {
    $o = $tw.FullName
    if ($alreadyListed.Contains($o)) { continue }
    $rec = [pscustomobject]@{ Superseded = $o; Replacement = $nasNew; Source = "twin:$src"; Reason = '' }
    if ($currentOutputs.Contains($o)) { continue }   # two live outputs: the publish slot-collision check owns that
    $localItem = Get-Item -LiteralPath $localOut -EA SilentlyContinue
    if ($localItem -and $localItem.Length -ne $newItem.Length) { $rec.Reason = "twin: replacement size mismatch (NAS $($newItem.Length) vs local $($localItem.Length))"; $held.Add($rec); continue }
    if (-not $localItem -and $newItem.Length -lt 5MB) { $rec.Reason = "twin: replacement suspiciously small ($($newItem.Length) bytes) and no local copy to compare"; $held.Add($rec); continue }
    if ($tw.LastWriteTime -gt $newItem.LastWriteTime) { $rec.Reason = ("REFUSED: twin written {0:yyyy-MM-dd HH:mm}, after its replacement landed {1:yyyy-MM-dd HH:mm}" -f $tw.LastWriteTime, $newItem.LastWriteTime); $held.Add($rec); continue }
    $dNew = Get-ProgrammeSeconds $nasNew; $dOld = Get-ProgrammeSeconds $o
    if ($dNew -le 0 -or $dOld -le 0) { $rec.Reason = "twin: could not measure both durations (replacement $dNew s, twin $dOld s)"; $held.Add($rec); continue }
    $gap = [math]::Abs($dNew - $dOld)
    if ($gap -gt $TwinToleranceSeconds) {
      $rec.Reason = ("twin: same episode number but the programmes differ by {0:N1}s ({1:N1}s vs {2:N1}s) - a different cut or a different episode; judge it by hand" -f $gap, $dNew, $dOld)
      $held.Add($rec); continue
    }
    if ($heldPaths.Contains($o) -and @($held | Where-Object { $_.Superseded -eq $o -and $_.Reason -like 'REFUSED*' }).Count) { continue }
    $rec.Reason = ("same-episode twin of a verified replacement; programmes agree to {0:N2}s" -f $gap)
    $listed.Add($rec); [void]$alreadyListed.Add($o); $twinOk++
  }
}
Write-Host "$twinOk same-episode twin(s) listed (programme lengths agree within $TwinToleranceSeconds s)"

# ---------------------------------------------------------------- hand relocations
#
# A RELOCATION HAS NO MANIFEST, SO THIS LIST COULD NOT SEE IT.
#
# Everything above derives from a manifest's `supersedes`. That is right for the pipeline's own
# output, but it leaves a whole class of deletion invisible: a file moved BY HAND because it was in
# the wrong place to begin with. The NAS cannot be moved from here - a relocation is a COPY to the
# right path, after which the original is the operator's to remove - and no manifest ever described
# either end of it.
#
# 2026-09-13: two Crown Court episodes had been filed as The Sandbaggers Season 00 S00E01/E02.mp4
# (TheTVDB lists them among The Sandbaggers' specials, which is very likely how they got there).
# They were copied to Crown Court (1972) Season 1972 and byte-verified. The two originals then
# needed retiring - and _HANDOVER-ACTIONS.md says in terms that _nas-retire.txt is THE list, and
# that a second hand-kept list is worse than one incomplete list because you cannot tell which is
# stale. Without this section the only choices were to break that rule or to lose the deletion.
#
# Declared in a TSV so the decision is reviewable and dated, and validated HERE rather than trusted:
# the same guards the manifest path applies, plus one it cannot - a relocation is a byte copy, so
# the target must match the original's LENGTH EXACTLY. That is stronger than the manifest path's
# size test, which compares against a local re-encode that legitimately differs.
#
# KEEP THE TWO SETS OF CHECKS IN STEP. They are written out twice rather than shared; a guard added
# above but not here would silently fail to apply to hand relocations.
$manualOk = 0
if (Test-Path -LiteralPath $Manual) {
  foreach ($line in (Get-Content -LiteralPath $Manual)) {
    $t = "$line".Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $f = $t -split "`t"
    if ($f.Count -lt 2) {
      $held.Add([pscustomobject]@{ Superseded=$t; Replacement=''; Source='manual'; Reason='malformed row - expected <superseded><TAB><replacement>[<TAB><why>]' })
      continue
    }
    $o   = Repair-NasPath (($f[0] -replace '/', '\').Trim())
    $new = Repair-NasPath (($f[1] -replace '/', '\').Trim())
    $why = if ($f.Count -ge 3) { $f[2].Trim() } else { '' }
    $rec = [pscustomobject]@{ Superseded=$o; Replacement=$new; Source='manual'; Reason='' }

    if (-not (Under-Nas $o))   { $rec.Reason = 'superseded path is not on the NAS'; $held.Add($rec); continue }
    if (-not (Under-Nas $new)) { $rec.Reason = 'replacement path is not on the NAS'; $held.Add($rec); continue }
    if ($o -eq $new)           { $rec.Reason = 'REFUSED: superseded path equals the replacement'; $held.Add($rec); continue }
    if ($currentOutputs.Contains($o)) {
      $rec.Reason = 'REFUSED: that path is a CURRENT declared output - a live manifest still produces it'
      $held.Add($rec); continue
    }
    $newItem = Get-Item -LiteralPath $new -EA SilentlyContinue
    if (-not $newItem)         { $rec.Reason = 'relocation target is not on the NAS yet'; $held.Add($rec); continue }
    if (-not (Test-Path -LiteralPath $o)) { $rec.Reason = 'already gone'; $held.Add($rec); continue }
    $oldItem = Get-Item -LiteralPath $o -EA SilentlyContinue
    if ($oldItem.Length -ne $newItem.Length) {
      $rec.Reason = ("REFUSED: a relocation is a byte copy but the sizes differ (original {0:N0} vs target {1:N0}) - do not retire until that is explained" -f $oldItem.Length, $newItem.Length)
      $held.Add($rec); continue
    }
    $rec.Reason = if ($why) { "relocated by hand, target verified: $why" } else { 'relocated by hand, target verified same size on the NAS' }
    $listed.Add($rec)
    $manualOk++
  }
}
Write-Host "$manualOk hand relocation(s) accepted from $Manual"

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
