# Remove empty folders left behind by reclaims.
#
# WRITTEN AFTER GETTING THIS WRONG: the first version enumerated with -EA SilentlyContinue and
# deleted with -Recurse. A folder whose listing failed for any reason therefore looked empty, and
# -Recurse then took its contents with it - three unconfirmed 3.5 GB files went that way.
#
# Rules now:
#   1. Never suppress the enumeration error. If a folder cannot be listed, LEAVE IT and say so.
#   2. Delete without -Recurse, so a non-empty folder cannot be removed even if misjudged.
#   3. A folder must contain no files AND no subfolders.

param([string[]]$Roots = @('D:\video\Movies','D:\video\Television Shows','D:\video\_stage','D:\video\_logs4'),
      [switch]$WhatIf)

# REFUSE to run while an encode is writing INTO ONE OF THESE ROOTS. transcode.ps1 creates the
# output folder and ffmpeg opens the file a moment later; a prune in that window deletes the folder
# underneath it and the encode dies with "Error opening output ... No such file or directory" -
# having still printed MANIFEST DONE. That is exactly how The Italian Job failed at 0 s.
#
# The check reads each ffmpeg's COMMAND LINE rather than merely counting processes. A bare
# process count is wrong on a shared machine: an unrelated ffmpeg - another agent's subtitle sync,
# a media server transcoding for a client - blocked pruning indefinitely while being no risk at
# all. Refusing forever is not "safe", it just moves the failure somewhere quieter.
#
# If the command line cannot be read (permissions), treat that process as dangerous and refuse:
# unknown is not the same as harmless.
$live = @(Get-Process ffmpeg -ErrorAction SilentlyContinue)
if ($live.Count -gt 0 -and -not $WhatIf) {
  $threats = @()
  foreach ($p in $live) {
    $cmd = $null
    try { $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)" -ErrorAction Stop).CommandLine } catch { }
    if (-not $cmd) { $threats += "pid $($p.Id) (command line unreadable)"; continue }
    foreach ($root in $Roots) {
      if ($cmd -like "*$root*") { $threats += "pid $($p.Id) -> $root"; break }
    }
  }
  if ($threats.Count -gt 0) {
    Write-Warning "not pruning - ffmpeg is writing into a root being pruned:`n  $($threats -join "`n  ")"
    exit 0
  }
  Write-Host "note: $($live.Count) unrelated ffmpeg process(es) running (none touching these roots) - proceeding"
}

# Belt and braces: never touch a folder created or written in the last few minutes, even if the
# process check passes. An encode that is queued but not yet started leaves exactly that trace.
$cutoff = (Get-Date).AddMinutes(-5)

$removed = 0; $skipped = 0
foreach ($root in $Roots) {
  if (-not (Test-Path -LiteralPath $root)) { continue }

  # deepest first, so a parent emptied by its children is reconsidered in the same pass
  $dirs = Get-ChildItem -LiteralPath $root -Recurse -Directory -ErrorAction Stop |
          Sort-Object { $_.FullName.Length } -Descending

  foreach ($d in $dirs) {
    if (-not (Test-Path -LiteralPath $d.FullName)) { continue }   # already gone with its parent
    try {
      $kids = @(Get-ChildItem -LiteralPath $d.FullName -Force -ErrorAction Stop)
    } catch {
      Write-Warning "cannot list, leaving alone: $($d.FullName)"
      $skipped++; continue
    }
    if ($kids.Count -eq 0) {
      if ($d.LastWriteTime -gt $cutoff -or $d.CreationTime -gt $cutoff) {
        Write-Host "  skip (created/written in the last 5 min, may be an encode target): $($d.Name)"
        $skipped++; continue
      }
      if ($WhatIf) { Write-Host "would remove: $($d.FullName)" }
      else { Remove-Item -LiteralPath $d.FullName -Force -ErrorAction Stop }   # NO -Recurse
      $removed++
    }
  }
}
Write-Host ("empty folders removed: {0}{1}" -f $removed, $(if ($skipped) { ", skipped $skipped unreadable" } else { '' }))
