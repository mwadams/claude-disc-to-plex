<#
  Tests for lib-nas-governor.ps1.   Run: pwsh -File lib-nas-governor.tests.ps1   (exit 0 = all passed)

  Everything here runs against a TEMP config (env NAS_GOVERNOR_CONFIG) with its own hold file and
  its own mutex names, so a test can never throw the real kill switch or block a real track. The
  cross-process guarantees are proved with a real second pwsh.exe holding the real OS objects -
  an in-process fake would prove nothing about the property that matters.

  Known traps this suite is written around (all real in this project): `,$array` returns making
  @(...).Count read 1; `| Out-Null` swallowing narration; a terminating error truncating the suite
  while it still prints "all tests passed" (hence $reachedEnd); List[object] + @() throwing on
  pwsh 7.6.5 (hence [..]::new()).
#>
$ErrorActionPreference = 'Continue'
$fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('nasgov-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null
$suffix   = [guid]::NewGuid().ToString('N').Substring(0, 8)
$cfgFile  = Join-Path $tmp 'gov.json'
$holdFile = Join-Path $tmp 'hold'
$sweepName = "video-nas-sweep-test-$suffix"
$slotPrefix = "video-nas-read-test-$suffix-"
function WriteCfg([int]$maxReads = 2, [double]$ceiling = 50, [double]$maxPace = 0) {
  [ordered]@{
    readCeilingMbps = $ceiling; maxConcurrentReads = $maxReads; holdFile = $holdFile
    nasPathPattern = '^\\\\NASTEAMV\\'; standDownForPublish = $false; maxPaceSeconds = $maxPace
    sweepMutex = $sweepName; readSlotPrefix = $slotPrefix
  } | ConvertTo-Json | Set-Content -LiteralPath $cfgFile
  # the loader caches by mtime; two writes inside one second must still be seen as a change
  (Get-Item -LiteralPath $cfgFile).LastWriteTime = (Get-Date).AddSeconds([double](Get-Random -Minimum 1 -Maximum 1000))
}
WriteCfg
$env:NAS_GOVERNOR_CONFIG = $cfgFile
. "$PSScriptRoot/lib-nas-governor.ps1"
foreach ($fn in 'Get-NasGovernorConfig', 'Test-NasPath', 'Get-NasHold', 'Wait-NasHold', 'Enter-NasSweep', 'Enter-NasReadSlot', 'Invoke-NasRead', 'Invoke-NasReadProcess', 'Get-NasPaceSeconds', 'Get-NasReadRate') {
  if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) { Write-Output "FAIL: $fn did not load"; exit 1 }
}

# A second PROCESS that holds named mutexes for a while - the only honest way to test cross-process.
function Start-Holder([string[]]$Names, [int]$Seconds) {
  $body = ($Names | ForEach-Object { "`$m$([array]::IndexOf($Names, $_)) = New-Object System.Threading.Mutex(`$false, ('Global' + [char]92 + '$_')); `$m$([array]::IndexOf($Names, $_)).WaitOne(0) | Out-Null;" }) -join ' '
  $body += " Start-Sleep $Seconds"
  Start-Process pwsh -ArgumentList '-NoProfile', '-Command', $body -WindowStyle Hidden -PassThru
}
$narr = [System.Collections.Generic.List[string]]::new()
$say = { param($m) $narr.Add("$m") }

try {
  Write-Output '1. CONFIG: the temp file is read; unknown keys ignored; numbers typed'
  $c = Get-NasGovernorConfig
  Check 'ceiling' $c.readCeilingMbps 50
  Check 'maxReads' $c.maxConcurrentReads 2
  Check 'hold file' $c.holdFile $holdFile
  Check 'sweep mutex name' $c.sweepMutex $sweepName

  Write-Output '2. CONFIG: a missing file means the built-in defaults, never "off"'
  $global:NasGovernorState.ConfigPath = Join-Path $tmp 'does-not-exist.json'; $global:NasGovernorState.Cache = $null
  $c = Get-NasGovernorConfig
  Check 'default ceiling' $c.readCeilingMbps 50
  Check 'default hold file' $c.holdFile 'D:/video/_nas-hold'

  Write-Output '3. CONFIG: an unparseable file means the defaults AND a warning'
  $bad = Join-Path $tmp 'bad.json'; Set-Content -LiteralPath $bad -Value '{ not json'
  $global:NasGovernorState.ConfigPath = $bad; $global:NasGovernorState.Cache = $null
  $w = Get-NasGovernorConfig 3>&1 | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
  $c = Get-NasGovernorConfig
  Check 'defaults used' $c.maxConcurrentReads 2
  Check 'warned' (@($w).Count -ge 1) 'True'
  $global:NasGovernorState.ConfigPath = $cfgFile; $global:NasGovernorState.Cache = $null

  Write-Output '3b. NARRATION goes to the HOST, never into a return value'
  #    The first integration run: `$h = Enter-NasSweep ...` captured every "waiting" line into $h.
  #    Out-Host writes straight to the host (it cannot be redirected with 6>&1), so the proof here
  #    is on the OUTPUT stream: it must carry exactly the return value and no narration. That the
  #    narration does reach the host is proved by _coverage-governor.tests.ps1, which captures a
  #    child pwsh's stdout and finds the lines there.
  $outSay = { param($m) Write-Output "NARR $m" }         # a caller whose Say uses the OUTPUT stream
  Set-Content -LiteralPath $holdFile -Value 'narration test'
  $job = Start-Job -ScriptBlock { param($f) Start-Sleep 2; Remove-Item -LiteralPath $f -Force } -ArgumentList $holdFile
  $all = @(Wait-NasHold -Say $outSay -PollSeconds 1)
  Receive-Job $job -Wait | Out-Null; Remove-Job $job
  Check 'output stream carries ONLY the return value' $all.Count 1
  Check 'return value is the wait, not text' ($all[0] -is [double] -or $all[0] -is [int]) 'True'
  Check 'no narration in the output stream' (@($all | Where-Object { "$_" -match 'NARR' }).Count) 0

  Write-Output '4. Test-NasPath: only the NAS is governed'
  Check 'nas path'   (Test-NasPath '\\NASTEAMV\Multimedia\Movies\x.mkv') 'True'
  Check 'local path' (Test-NasPath 'D:\video\Movies\x.mkv') 'False'
  Check 'other unc'  (Test-NasPath '\\OTHER\share\x.mkv') 'False'
  Check 'empty'      (Test-NasPath '') 'False'

  Write-Output '5. Get-NasPaceSeconds: the arithmetic behind the ceiling'
  Check '625MB in 12s at 50Mbps -> ~92.9s' (Get-NasPaceSeconds -Bytes 655360000 -ElapsedSeconds 12 -CeilingMbps 50) 92.9
  Check 'already under the ceiling -> 0'  (Get-NasPaceSeconds -Bytes 1000000 -ElapsedSeconds 10 -CeilingMbps 50) 0
  Check 'capped'                          (Get-NasPaceSeconds -Bytes 655360000 -ElapsedSeconds 12 -CeilingMbps 50 -MaxPaceSeconds 30) 30
  Check 'ceiling 0 -> 0'                  (Get-NasPaceSeconds -Bytes 655360000 -ElapsedSeconds 12 -CeilingMbps 0) 0

  Write-Output '6. Get-NasReadRate: ffmpeg multiplier from the file''s own bitrate'
  Check '625MB/1783s at 50 -> 17.0' (Get-NasReadRate -Bytes 655360000 -DurationSeconds 1783 -CeilingMbps 50) 17.004
  Check 'unknown duration -> null' ($null -eq (Get-NasReadRate -Bytes 655360000 -DurationSeconds 0 -CeilingMbps 50)) 'True'
  Check 'arg quoting: spaces' (ConvertTo-NasProcessArgument 'a b') '"a b"'
  Check 'arg quoting: plain'  (ConvertTo-NasProcessArgument 'plain') 'plain'
  Check 'arg quoting: quote'  (ConvertTo-NasProcessArgument 'x"y') '"x\"y"'

  Write-Output '7. HOLD: absent -> no wait; present -> Get-NasHold carries the reason'
  Check 'no hold' ($null -eq (Get-NasHold)) 'True'
  Check 'no wait' (Wait-NasHold -Say $say) 0
  Set-Content -LiteralPath $holdFile -Value 'because the network is hammering'
  Check 'hold seen' ((Get-NasHold) -match 'NAS HOLD active .* because the network is hammering') 'True'

  Write-Output '8. HOLD: Wait-NasHold blocks until the file goes, and says so both ways'
  $job = Start-Job -ScriptBlock { param($f) Start-Sleep 3; Remove-Item -LiteralPath $f -Force } -ArgumentList $holdFile
  $narr.Clear()
  $waited = Wait-NasHold -Say $say -PollSeconds 1
  Receive-Job $job -Wait | Out-Null; Remove-Job $job
  Check 'waited >= 2s' ($waited -ge 2) 'True'
  Check 'said standing down' (($narr -join "`n") -match 'standing down: NAS HOLD active') 'True'
  Check 'said released'      (($narr -join "`n") -match 'hold released') 'True'

  Write-Output '9. SWEEP MUTEX: a second PROCESS holding it makes Enter-NasSweep wait, then time out'
  $holder = Start-Holder -Names @($sweepName) -Seconds 12
  Start-Sleep 3
  Check 'held by other process' (Test-NasGovernorMutexHeld -Name $sweepName) 'True'
  $narr.Clear()
  $t0 = Get-Date
  $h = Enter-NasSweep -Name 'test' -Say $say -MaxWaitMinutes 0.05 -PollSeconds 1
  Check 'timed out -> null' ($null -eq $h) 'True'
  Check 'waited ~3s' ((((Get-Date) - $t0).TotalSeconds -ge 2.5)) 'True'
  Check 'said waiting' (($narr -join "`n") -match 'another library-wide NAS sweep holds') 'True'
  $holder.WaitForExit()
  Write-Output '   ...and acquires once the holder exits, and releases cleanly'
  $h = Enter-NasSweep -Name 'test' -Say $say -MaxWaitMinutes 0.05 -PollSeconds 1
  Check 'acquired' ($null -ne $h) 'True'
  Check 'now held' (Test-NasGovernorMutexHeld -Name $sweepName) 'True'
  Exit-NasSweep $h
  Check 'released' (Test-NasGovernorMutexHeld -Name $sweepName) 'False'

  Write-Output '10. READ SLOTS: with both slots held by another process, no slot within the timeout'
  $holder = Start-Holder -Names @(($slotPrefix + '0'), ($slotPrefix + '1')) -Seconds 15
  Start-Sleep 3
  $narr.Clear()
  $s = Enter-NasReadSlot -Name 'test' -Say $say -MaxWaitMinutes 0.05 -PollSeconds 1
  Check 'no slot -> null' ($null -eq $s) 'True'
  Check 'said all taken' (($narr -join "`n") -match 'all 2 NAS read slot\(s\) are taken') 'True'
  Write-Output '   ...raising the cap in the config is seen LIVE (no bounce) and yields slot 2'
  WriteCfg -maxReads 3
  $s = Enter-NasReadSlot -Name 'test' -Say $say -MaxWaitMinutes 0.05 -PollSeconds 1
  Check 'slot 2 acquired' $s.Slot 2
  Exit-NasReadSlot $s
  Write-Output '   ...and a LOCAL path is never made to wait for a slot at all'
  WriteCfg -maxReads 2
  $t0 = Get-Date
  $r = Invoke-NasRead -Path 'D:\video\Movies\x.mkv' -Say $say -Do { 'ran-local' }
  Check 'local ran' $r 'ran-local'
  Check 'local did not wait' ((((Get-Date) - $t0).TotalSeconds) -lt 2) 'True'
  $holder.WaitForExit()

  Write-Output '11. Invoke-NasRead on a NAS path: takes a slot, returns the output, releases the slot'
  $script:heldDuring = $null
  $r = Invoke-NasRead -Path '\\NASTEAMV\Multimedia\Movies\x.mkv' -Say $say -Do { $script:heldDuring = Test-NasGovernorMutexHeld -Name ($slotPrefix + '0'); 'ran-nas' }
  Check 'nas ran' $r 'ran-nas'
  Check 'slot held during' $script:heldDuring 'True'
  Check 'slot released after' (Test-NasGovernorMutexHeld -Name ($slotPrefix + '0')) 'False'
  Write-Output '   ...and a SECOND process sees the slot as taken while we hold it'
  $slotH = Enter-NasReadSlot -Name 'test' -Say $say -MaxWaitMinutes 0.05
  $probe = & pwsh -NoProfile -Command ("`$h = `$null; [System.Threading.Mutex]::TryOpenExisting(('Global' + [char]92 + '{0}'), [ref]`$h) | Out-Null; if (`$h) {{ `$g = `$h.WaitOne(0); if (`$g) {{ `$h.ReleaseMutex() }}; -not `$g }} else {{ 'no-mutex' }}" -f ($slotPrefix + '0'))
  Check 'other process sees it held' "$probe" 'True'
  Exit-NasReadSlot $slotH

  Write-Output '11b. Copy-NasFileThrottled: a level copy at the ceiling, stoppable and restartable mid-copy'
  $srcFile = Join-Path $tmp 'src.bin'; $dstFile = Join-Path $tmp 'dst.bin'
  $rnd = [byte[]]::new(24MB); [Random]::new(7).NextBytes($rnd); [IO.File]::WriteAllBytes($srcFile, $rnd)
  $t0 = Get-Date
  $cp = Copy-NasFileThrottled -Source $srcFile -Destination $dstFile -CeilingMbps 100 -ChunkBytes 1MB -Say $say -Label 'test'
  $el = ((Get-Date) - $t0).TotalSeconds
  Check 'bytes'          $cp.Bytes (24MB)
  Check 'identical'      ((Get-FileHash $srcFile).Hash -eq (Get-FileHash $dstFile).Hash) 'True'
  Check 'took >= 1.8s (24MB at 100Mbps = 2.0s)' ($el -ge 1.8) 'True'
  Check 'measured <= ceiling' ($cp.Mbps -le 105) 'True'
  Remove-Item -LiteralPath $dstFile -Force
  $job = Start-Job -ScriptBlock { param($h) Start-Sleep 1; Set-Content -LiteralPath $h -Value 'test hold'; Start-Sleep 3; Remove-Item -LiteralPath $h -Force } -ArgumentList $holdFile
  $narr.Clear()
  $t0 = Get-Date
  $cp = Copy-NasFileThrottled -Source $srcFile -Destination $dstFile -CeilingMbps 100 -ChunkBytes 1MB -Say $say -Label 'test'
  Receive-Job $job -Wait | Out-Null; Remove-Job $job
  Check 'restarted once'  $cp.Restarts 1
  Check 'still identical' ((Get-FileHash $srcFile).Hash -eq (Get-FileHash $dstFile).Hash) 'True'
  Check 'said mid-copy'   (($narr -join "`n") -match 'hold dropped mid-copy') 'True'
  Check 'took > 5s'       ((((Get-Date) - $t0).TotalSeconds) -gt 5) 'True'
  $threw = $false
  try { Copy-NasFileThrottled -Source $srcFile -Destination '\\NASTEAMV\Multimedia\x.bin' -Say $say | Out-Null } catch { $threw = $true }
  Check 'refuses a NAS destination' $threw 'True'

  Write-Output '12. PACING: bytes over the ceiling produce a sleep (adapter counter faked)'
  $script:fakeBytes = [long]0
  function Get-NasBytesReceived { $script:fakeBytes }
  $t0 = Get-Date
  $narr.Clear()
  # 12.5 MB "received" in ~0 s at 50 Mbps needs 2.0 s -> a ~2 s pace
  Invoke-NasRead -Path '\\NASTEAMV\Multimedia\Movies\x.mkv' -Say $say -Do { $script:fakeBytes += 12500000 } | Out-Null
  $el = ((Get-Date) - $t0).TotalSeconds
  Check 'paced ~2s' (($el -ge 1.5) -and ($el -le 6)) 'True'
  Write-Output '   ...and the cap in the config bounds it'
  WriteCfg -maxPace 1
  $t0 = Get-Date
  Invoke-NasRead -Path '\\NASTEAMV\Multimedia\Movies\x.mkv' -Say $say -Do { $script:fakeBytes += 125000000 } | Out-Null
  $el = ((Get-Date) - $t0).TotalSeconds
  Check 'capped to ~1s' (($el -ge 0.8) -and ($el -le 4)) 'True'
  WriteCfg

  Write-Output '13. Invoke-NasReadProcess: the kill switch stops a read IN FLIGHT and restarts it after'
  $spaced = Join-Path $tmp 'with space'; New-Item -ItemType Directory -Path $spaced -Force | Out-Null
  $marker = Join-Path $spaced 'starts.txt'; $outFile = Join-Path $spaced 'out.txt'
  $cmd = "Add-Content -LiteralPath '$marker' -Value start; Start-Sleep 6; Set-Content -LiteralPath '$outFile' -Value done"
  $job = Start-Job -ScriptBlock { param($h) Start-Sleep 2; Set-Content -LiteralPath $h -Value 'test hold'; Start-Sleep 4; Remove-Item -LiteralPath $h -Force } -ArgumentList $holdFile
  $narr.Clear()
  $t0 = Get-Date
  $code = Invoke-NasReadProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', $cmd) -OutputPath $outFile -Say $say -Label 'test' -PollSeconds 1
  Receive-Job $job -Wait | Out-Null; Remove-Job $job
  Check 'exit 0'        $code 0
  Check 'started twice' (@(Get-Content -LiteralPath $marker).Count) 2
  Check 'output made'   (Test-Path -LiteralPath $outFile) 'True'
  Check 'said stopping' (($narr -join "`n") -match 'hold dropped mid-read - stopping pid') 'True'
  Check 'took > 10s'    ((((Get-Date) - $t0).TotalSeconds) -gt 10) 'True'
  Write-Output '   ...and refuses an output path on the NAS'
  $threw = $false
  try { Invoke-NasReadProcess -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-Command', 'exit 0') -OutputPath '\\NASTEAMV\Multimedia\x.tmp' -Say $say | Out-Null } catch { $threw = $true }
  Check 'refused nas output' $threw 'True'

  Write-Output '14. Get-NasGovernorStatus reports what the others see'
  $st = Get-NasGovernorStatus
  Check 'no hold' ($null -eq $st.Hold) 'True'
  Check 'slots listed' (@($st.ReadSlots).Count) 2
  Check 'sweep free' $st.SweepHeld 'False'

  $script:reachedEnd = $true
}
catch {
  Write-Output "  FAIL exception in the governor tests: $($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
  $script:fails++
}
finally {
  Remove-Item Env:NAS_GOVERNOR_CONFIG -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if (-not $reachedEnd) { Write-Output 'the suite did not reach its end - treating as FAILED'; $fails++ }
if ($fails) { Write-Output "$fails test(s) FAILED"; exit 1 }
Write-Output 'all tests passed'
exit 0
