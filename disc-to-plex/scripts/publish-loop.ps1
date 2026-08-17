# NAS track: keep publishing, one work at a time, forever.
#
# SERIAL by design - concurrent robocopy jobs contend on the same NAS spindles and link, and with
# several running nothing completes. publish-work.ps1 refuses anything unfinished (no duration) or
# awaiting OCR (bitmap subs, no sidecar), so this loop can run continuously and simply skips what
# is not ready yet, picking it up on a later pass once OCR catches up.

while ($true) {
  $published = 0
  foreach ($kind in @('Movies', 'Television Shows')) {
    $root = Join-Path 'D:\video' $kind
    if (-not (Test-Path -LiteralPath $root)) { continue }
    foreach ($w in Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue) {
      # cheap pre-check: is anything actually missing on the NAS for this work?
      $nas = Join-Path (Join-Path '\\NASTEAMV\Multimedia' $kind) $w.Name
      $need = $false
      foreach ($f in Get-ChildItem -LiteralPath $w.FullName -Recurse -File -ErrorAction SilentlyContinue) {
        $t = $f.FullName.Replace($w.FullName, $nas)
        if (-not (Test-Path -LiteralPath $t) -or (Get-Item -LiteralPath $t).Length -ne $f.Length) { $need = $true; break }
      }
      if (-not $need) { continue }

      $out = & pwsh -File 'D:\video\_publish.ps1' -Work $w.Name -Kind $kind 2>&1
      $line = $out | Select-String 'verified|REFUSING' | Select-Object -First 1
      if ($line) { "{0,-46} {1}" -f $w.Name, (($line -join ' ') -replace '\s+', ' ') }
      if ($line -match 'verified') { $published++ }
    }
  }
  if ($published -eq 0) { Start-Sleep -Seconds 90 }
}
