# NAS track: keep publishing, one work at a time, forever.
#
# SERIAL by design - concurrent robocopy jobs contend on the same NAS spindles and link, and with
# several running nothing completes. publish-work.ps1 refuses anything unfinished (no duration) or
# awaiting OCR (bitmap subs, no sidecar), so this loop can run continuously and simply skips what
# is not ready yet, picking it up on a later pass once OCR catches up.
#
# SINGLE INSTANCE. This was the only loop without a mutex, and the absence bit twice in one minute
# on 2026-08-25: probing for a mutex that did not exist reported the loop DEAD while it had been
# running since 04:55, and starting a "replacement" then succeeded - twice - because nothing
# refused. Two publish loops racing the same work is the exact contention this loop's serialness
# exists to avoid. The mutex is now both the guard AND the liveness probe: a monitor can ask
# TryOpenExisting instead of guessing from a process list.
#
# NOTE the string build: `'Global' + [char]92 + 'name'`. Written as New-Object with a comma inside
# a concatenation, the arguments parse as one 4-element ARRAY and New-Object returns $null - which
# fails OPEN. That is why the null check below is not decoration.
$mutexName = 'Global' + [char]92 + 'video-publish-loop'
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if ($null -eq $mutex) {
  Write-Output 'could not create the single-instance mutex - refusing to run unguarded'
  exit 1
}
if (-not $mutex.WaitOne(0)) {
  Write-Output 'another publish loop already holds the mutex - exiting'
  exit 0
}

while ($true) {
  $published = 0
  foreach ($kind in @('Movies', 'Television Shows')) {
    $root = Join-Path 'D:\video' $kind
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($w in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
      # cheap pre-check: is anything actually missing on the NAS for this work?
      #
      # MISSING and WRONG-SIZE are different faults and need different flags. Without -Overwrite
      # _publish.ps1 runs robocopy with /XC /XN /XO, which SKIP any file already present at the
      # destination - so a file that landed TRUNCATED can never be repaired by this loop: the
      # pre-check sees the size mismatch every pass, robocopy skips it, verify fails, forever.
      # That happened on 2026-08-19 (Danger UXB S01E10-E13, e.g. The Pier 27 MB of 1.25 GB), and
      # it is silent - the loop just prints a failing verify line each cycle.
      #
      # So: absent -> normal no-clobber copy. Present but wrong size -> pass -Overwrite for THIS
      # work only, which is exactly the documented "replace a bad copy" case.
      $nas = Join-Path (Join-Path '\\NASTEAMV\Multimedia' $kind) $w.Name
      $need = $false
      $stale = $false
      foreach ($f in Get-ChildItem -LiteralPath $w.FullName -Recurse -File -ErrorAction SilentlyContinue) {
        $t = $f.FullName.Replace($w.FullName, $nas)
        if (-not (Test-Path -LiteralPath $t)) { $need = $true; continue }
        $ti = Get-Item -LiteralPath $t
        # SIZE ALONE MISSES A RE-ENCODE OF THE SAME LENGTH.
        #
        # Michael J. Fox Interview was re-encoded from DAR 4:3 to 16:9 on 2026-08-24 and came out
        # byte-for-byte the SAME SIZE (186 MB) - only the aspect metadata differed. The size check
        # saw no difference, so the loop would have left the stretched copy on the NAS forever
        # while local held the fix, and every verification would have reported success.
        #
        # robocopy preserves the SOURCE mtime, so a published file carries the timestamp of the
        # local file it came from. Re-encoding gives local a NEW mtime; the NAS copy keeps the old
        # one. That difference is exactly what "the local file changed since it was published"
        # means. (Allow 2 s for filesystem timestamp granularity across SMB.)
        if ($ti.Length -ne $f.Length) { $need = $true; $stale = $true }
        elseif ([Math]::Abs(($ti.LastWriteTimeUtc - $f.LastWriteTimeUtc).TotalSeconds) -gt 2) {
          $need = $true; $stale = $true
          "{0,-46} '{1}' differs by TIMESTAMP not size - re-publishing" -f $w.Name, $f.Name
        }
      }
      if (-not $need) { continue }

      $args = @('-File', 'D:\video\_publish.ps1', '-Work', $w.Name, '-Kind', $kind)
      if ($stale) { $args += '-Overwrite'; "{0,-46} wrong-size copy on NAS -> republishing with -Overwrite" -f $w.Name }
      $out = & pwsh @args 2>&1
      $line = $out | Select-String 'verified|REFUSING' | Select-Object -First 1
      if ($line) { "{0,-46} {1}" -f $w.Name, (($line -join ' ') -replace '\s+', ' ') }
      elseif ($LASTEXITCODE -ne 0) {
        # A publish that CRASHES (guard failed to load, robocopy exit >= 8, a throw before the
        # verify) prints neither 'verified' nor 'REFUSING', and this loop used to say NOTHING -
        # the work just silently never reached the NAS, pass after pass. A refusal is expected
        # and quiet; a crash must be loud, with enough of the tail to see why.
        "{0,-46} PUBLISH CRASHED (exit {1}) - last output:" -f $w.Name, $LASTEXITCODE
        @($out | Where-Object { "$_" -match '\S' })[-3..-1] | ForEach-Object { "    $_" }
      }
      if ($line -match 'verified') { $published++ }
    }
  }
  if ($published -eq 0) { Start-Sleep -Seconds 90 }
}
