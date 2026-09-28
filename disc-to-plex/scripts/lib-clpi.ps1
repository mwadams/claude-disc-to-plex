# lib-clpi.ps1 - read a Blu-ray CLIPINF\<clip>.clpi's per-stream LANGUAGE declaration, and join it to
# ffprobe's subtitle streams by PID. Dot-source it.
#
# Get-ClpiStreamLangs is a COPY of transcode.ps1's function of the same name (same byte layout, same
# result): the encoder is left untouched, and the two must agree - if one changes, change both.
# First used by derive-manifest-fields.ps1 (2026-09-28) to decide whether an explicit subtitle ordinal
# on a raw .m2ts is verifiable, instead of blanket-rewriting it to "eng".

function Get-ClpiStreamLangs([string]$clpi) {
  $map = @{}
  try {
    $b = [IO.File]::ReadAllBytes($clpi)
    if ([Text.Encoding]::ASCII.GetString($b, 0, 4) -ne 'HDMV') { return $map }
    $be = { param($o, $n) $v = 0; for ($k = 0; $k -lt $n; $k++) { $v = ($v -shl 8) -bor $b[$o + $k] }; $v }
    $p = (& $be 12 4) + 4 + 1
    $nps = $b[$p]; $p++
    for ($s = 0; $s -lt $nps; $s++) {
      $p += 6
      $nst = $b[$p]; $p += 2
      for ($t = 0; $t -lt $nst; $t++) {
        $streamPid = & $be $p 2; $p += 2
        $len = $b[$p]; $ct = $b[$p + 1]
        $lang = $null
        if ($ct -in 0x90, 0x91) { $lang = [Text.Encoding]::ASCII.GetString($b, $p + 2, 3) }
        elseif ($ct -in 0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0xA1, 0xA2) { $lang = [Text.Encoding]::ASCII.GetString($b, $p + 3, 3) }
        if ($lang) { $map[$streamPid] = $lang }
        $p += 1 + $len
      }
    }
  } catch { return @{} }
  return $map
}

function Get-ClpiSubtitleLangs {
  # The CLPI-declared language of each SUBTITLE stream of a raw BDMV\STREAM\<clip>.m2ts, in subtitle
  # ordinal order (s:0, s:1, ...), joined by PID - never by position. $null when it cannot be told
  # (not a BDMV clip, no CLPI, ffprobe lists no subtitle, or any subtitle PID is undeclared).
  param([Parameter(Mandatory)][string]$Src, [Parameter(Mandatory)][string]$Ffprobe)
  if ($Src -notmatch '(?i)[\\/]BDMV[\\/]STREAM[\\/](\d+)\.m2ts$') { return $null }
  $clpi = Join-Path (Split-Path (Split-Path $Src -Parent) -Parent) "CLIPINF/$($Matches[1]).clpi"
  if (-not (Test-Path -LiteralPath $clpi)) { return $null }
  $decl = Get-ClpiStreamLangs $clpi
  $rows = @{}   # stream index -> PID; a .m2ts lists each stream twice (program + streams), so de-duplicate
  foreach ($line in @(& $Ffprobe -v error -select_streams s -show_entries stream=index,id -of csv=p=0 $Src 2>$null)) {
    if ("$line".Trim() -match '^(\d+),(0x[0-9a-fA-F]+)$') { $rows[[int]$Matches[1]] = $Matches[2] }
  }
  if ($rows.Count -eq 0) { return $null }
  $out = @()
  foreach ($k in @($rows.Keys | Sort-Object)) {
    $sid = [Convert]::ToInt32(($rows[$k] -replace '^0x', ''), 16)
    if (-not $decl.ContainsKey($sid)) { return $null }
    $out += $decl[$sid]
  }
  return , $out
}
