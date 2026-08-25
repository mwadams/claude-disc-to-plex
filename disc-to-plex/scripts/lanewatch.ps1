# Print a line ONLY when the number of busy GPU lanes changes, so a Monitor can notify on
# transitions instead of spamming. Counts only ffmpeg processes reading from _stage - other
# agents' ffmpeg (subtitle sync against the NAS) must not be mistaken for an encode lane.
param([int]$Want = 2, [string]$StateFile = 'D:\video\.transcode-tools\lanestate.txt')

$busy = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
          Where-Object { $_.CommandLine -match '_stage' }).Count

$prev = if (Test-Path -LiteralPath $StateFile) { [int](Get-Content -LiteralPath $StateFile -Raw).Trim() } else { -1 }
if ($busy -ne $prev) {
  Set-Content -LiteralPath $StateFile -Value $busy
  if ($busy -lt $Want) {
    $names = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -match '_stage' } |
               ForEach-Object { if ($_.CommandLine -match '"([^"]*\.mkv)"\s*$') { Split-Path $Matches[1] -Leaf } })
    Write-Output ("LANE FREE: {0}/{1} busy{2}" -f $busy, $Want, $(if ($names) { " - still running: $($names -join ', ')" } else { ' - BOTH IDLE' }))
  }
}
