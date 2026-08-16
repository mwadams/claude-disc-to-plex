# Inventory every .mp4 in the Plex library: when it was copied, and whether it is a stub.
#
# "Copied" = the NAS file's CreationTime. robocopy /COPY:DAT preserves the SOURCE's
# LastWriteTime, so LastWriteTime is the file's own age and CreationTime is when it landed here.
# Both are reported, because a LastWriteTime far older than CreationTime is the normal signature
# of a preserved copy, not an anomaly.
#
# Stub detection is two-stage so it stays cheap over SMB:
#   1. Size heuristics on all 1200+ files - no I/O beyond the directory listing.
#   2. ffprobe ONLY the candidates, to confirm. A stub either fails to report a duration at all
#      or reports one wildly short for its slot. Probing everything would take ~30 minutes.

param(
  [string]$Out = 'D:\video\mp4-inventory.md',
  [double]$AbsoluteMB = 20,      # below this, a feature or episode is broken regardless of context
  [double]$SiblingFrac = 0.25    # or below this fraction of the median of its siblings
)

$ErrorActionPreference = 'Continue'
$paths   = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'

$roots = @{
  'Movies'           = '\\NASTEAMV\Multimedia\Movies'
  'Television Shows' = '\\NASTEAMV\Multimedia\Television Shows'
}

$rows = @()
foreach ($kind in $roots.Keys) {
  $root = $roots[$kind]
  Write-Host "scanning $kind ..."
  foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Filter *.mp4 -EA SilentlyContinue) {
    $rel = $f.FullName.Substring($root.Length + 1)
    $rows += [pscustomobject]@{
      Kind      = $kind
      Work      = ($rel -split '\\')[0]
      Rel       = $rel
      Dir       = $f.DirectoryName
      Name      = $f.Name
      MB        = [math]::Round($f.Length / 1MB, 2)
      Bytes     = $f.Length
      Copied    = $f.CreationTime
      Modified  = $f.LastWriteTime
      Full      = $f.FullName
    }
  }
}
Write-Host "found $($rows.Count) mp4 files"

# --- stage 1: size heuristics
$byDir = $rows | Group-Object Dir
$medians = @{}
foreach ($g in $byDir) {
  $sizes = @($g.Group.Bytes | Sort-Object)
  $medians[$g.Name] = $sizes[[int]($sizes.Count / 2)]
}

foreach ($r in $rows) {
  $med = $medians[$r.Dir]
  $frac = if ($med -gt 0) { [math]::Round($r.Bytes / $med, 3) } else { 1 }
  $suspect = ($r.MB -lt $AbsoluteMB) -or (($frac -lt $SiblingFrac) -and ($med -gt 50MB))
  Add-Member -InputObject $r -NotePropertyName SiblingFrac -NotePropertyValue $frac
  Add-Member -InputObject $r -NotePropertyName Suspect     -NotePropertyValue $suspect
  Add-Member -InputObject $r -NotePropertyName Duration    -NotePropertyValue $null
  Add-Member -InputObject $r -NotePropertyName Verdict     -NotePropertyValue 'ok'
}

$cands = @($rows | Where-Object Suspect)
Write-Host "size-flagged candidates: $($cands.Count) - probing each"

# --- stage 2: confirm the candidates by probing
#
# "Short" only means "broken" relative to what the file is SUPPOSED to be. A one-minute
# featurette part is entirely normal; a one-minute feature film is not. Judging everything
# against a flat duration floor called 30 healthy extras broken, which is worse than useless -
# it buries the four genuine failures. So classify the role first, then apply a floor that
# suits it.
foreach ($c in $cands) {
  $parent = Split-Path $c.Dir -Leaf
  $role =
    if ($parent -in @('Featurettes','Behind The Scenes','Deleted Scenes','Interviews','Scenes','Shorts','Trailers','Other','Extras')) { 'Extra' }
    elseif ($c.Name -match '(?i)(trailer|teaser)') { 'Extra' }   # a trailer is short by definition
    elseif ($c.Name -match '(?i)s00e\d+')      { 'Special' }
    elseif ($c.Name -match '(?i)s\d+e\d+')     { 'Episode' }
    elseif ($c.Name -match '(?i)[ -]pt\d+\.')  { 'Part' }        # " - pt02." and "Screen pt02." both
    else                                       { 'Feature' }
  Add-Member -InputObject $c -NotePropertyName Role -NotePropertyValue $role -Force

  $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $c.Full 2>$null)".Trim()
  if (-not $d -or $d -eq 'N/A') {
    $c.Duration = $null
    $c.Verdict  = 'STUB (unreadable - no duration)'
    continue
  }
  $mins = [math]::Round([double]$d / 60, 2)
  $c.Duration = $mins

  # floor = the shortest this role could plausibly be and still be complete
  $floor = switch ($role) {
    'Feature' { 30 }   # a feature film
    'Episode' { 10 }   # even a short-form episode clears this
    'Part'    { 2 }    # segments of a split feature
    default   { 0.2 }  # extras and specials are short by nature
  }
  $c.Verdict =
    if ($mins -lt ($floor / 3)) { "STUB ($mins min for a $($role.ToLower()))" }
    elseif ($mins -lt $floor)   { "SUSPECT (short for a $($role.ToLower()))" }
    else                        { 'ok (small but plays full length)' }
}

# --- report
$stubs    = @($rows | Where-Object { $_.Verdict -like 'STUB*' })
$suspects = @($rows | Where-Object { $_.Verdict -like 'SUSPECT*' })
$smallOk  = @($rows | Where-Object { $_.Verdict -like 'ok (small*' })

$sb = [Text.StringBuilder]::new()
[void]$sb.AppendLine("# MP4 inventory — Plex library")
[void]$sb.AppendLine()
[void]$sb.AppendLine("Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') from ``\\NASTEAMV\Multimedia``.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("**$($rows.Count) mp4 files**, $([math]::Round(($rows|Measure-Object Bytes -Sum).Sum/1GB,1)) GB total.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("| | Count |")
[void]$sb.AppendLine("|---|---|")
[void]$sb.AppendLine("| Broken stubs | **$($stubs.Count)** |")
[void]$sb.AppendLine("| Suspect (very short) | $($suspects.Count) |")
[void]$sb.AppendLine("| Small but full length | $($smallOk.Count) |")
[void]$sb.AppendLine("| Normal | $($rows.Count - $stubs.Count - $suspects.Count - $smallOk.Count) |")
[void]$sb.AppendLine()
[void]$sb.AppendLine("**Copied** is the NAS file's creation time — when it landed here. **Modified** is")
[void]$sb.AppendLine("the source file's own timestamp, preserved by ``robocopy /COPY:DAT``; it being older")
[void]$sb.AppendLine("than Copied is normal and not a fault.")
[void]$sb.AppendLine()
[void]$sb.AppendLine("Stub detection flagged anything under $AbsoluteMB MB, or under $($SiblingFrac*100)% of the median")
[void]$sb.AppendLine("size of its folder siblings, then confirmed each by probing its actual duration.")
[void]$sb.AppendLine()

if ($stubs.Count) {
  [void]$sb.AppendLine("## Broken stubs — flagged, not touched")
  [void]$sb.AppendLine()
  [void]$sb.AppendLine("| File | MB | vs siblings | Duration | Copied | Verdict |")
  [void]$sb.AppendLine("|---|---|---|---|---|---|")
  foreach ($r in $stubs | Sort-Object Kind, Rel) {
    $dur = if ($null -eq $r.Duration) { 'unreadable' } else { "$($r.Duration) min" }
    [void]$sb.AppendLine("| ``$($r.Kind)\$($r.Rel)`` | $($r.MB) | $([math]::Round($r.SiblingFrac*100))% | $dur | $($r.Copied.ToString('yyyy-MM-dd')) | $($r.Verdict) |")
  }
  [void]$sb.AppendLine()
}

if ($suspects.Count) {
  [void]$sb.AppendLine("## Suspect — short, worth a look")
  [void]$sb.AppendLine()
  [void]$sb.AppendLine("| File | MB | Duration | Copied |")
  [void]$sb.AppendLine("|---|---|---|---|")
  foreach ($r in $suspects | Sort-Object Kind, Rel) {
    [void]$sb.AppendLine("| ``$($r.Kind)\$($r.Rel)`` | $($r.MB) | $($r.Duration) min | $($r.Copied.ToString('yyyy-MM-dd')) |")
  }
  [void]$sb.AppendLine()
}

if ($smallOk.Count) {
  [void]$sb.AppendLine("## Small but complete — no action")
  [void]$sb.AppendLine()
  [void]$sb.AppendLine("Flagged on size, but they play their full length. Mostly Season 00 extras and")
  [void]$sb.AppendLine("low-bitrate archive rips.")
  [void]$sb.AppendLine()
  [void]$sb.AppendLine("| File | MB | Duration |")
  [void]$sb.AppendLine("|---|---|---|")
  foreach ($r in $smallOk | Sort-Object Kind, Rel) {
    [void]$sb.AppendLine("| ``$($r.Kind)\$($r.Rel)`` | $($r.MB) | $($r.Duration) min |")
  }
  [void]$sb.AppendLine()
}

# --- full inventory, grouped by copy date so batches are visible
[void]$sb.AppendLine("## Full inventory by copy date")
[void]$sb.AppendLine()
foreach ($g in $rows | Group-Object { $_.Copied.ToString('yyyy-MM-dd') } | Sort-Object Name -Descending) {
  [void]$sb.AppendLine("### $($g.Name) — $($g.Count) file(s), $([math]::Round(($g.Group|Measure-Object Bytes -Sum).Sum/1GB,2)) GB")
  [void]$sb.AppendLine()
  [void]$sb.AppendLine("| File | MB | Modified | Status |")
  [void]$sb.AppendLine("|---|---|---|---|")
  foreach ($r in $g.Group | Sort-Object Kind, Rel) {
    $flag = if ($r.Verdict -like 'STUB*') { '**STUB**' } elseif ($r.Verdict -like 'SUSPECT*') { 'suspect' } else { '' }
    [void]$sb.AppendLine("| ``$($r.Kind)\$($r.Rel)`` | $($r.MB) | $($r.Modified.ToString('yyyy-MM-dd')) | $flag |")
  }
  [void]$sb.AppendLine()
}

Set-Content -LiteralPath $Out -Value $sb.ToString() -Encoding UTF8
Write-Host "wrote $Out"
Write-Host "stubs=$($stubs.Count) suspect=$($suspects.Count) smallOk=$($smallOk.Count)"
