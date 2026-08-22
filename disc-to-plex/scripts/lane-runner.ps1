# Keep N encode lanes busy from a QUEUE of manifests, without a human noticing a lane went idle.
#
# WHY THIS EXISTS. Two GPU lanes were repeatedly left idle across a long batch. A monitor that
# reports "LANE FREE" is necessary but not sufficient: something still has to decide what goes in
# next, and that decision kept losing to whatever identification work was in front of it. The
# result was an expensive GPU sitting idle while its operator read title cards.
#
# The queue inverts that. Manifests are dropped in a folder; this drains them, oldest first, and
# always keeps $Lanes running. Identification work then happens WHILE the GPU is busy, which is
# the whole point of having separate tracks.
#
#   pwsh -File lane-runner.ps1                     # drain D:\video\_queue with 2 lanes
#   pwsh -File lane-runner.ps1 -Lanes 1            # e.g. while something else needs the GPU
#
# Drop a manifest in with any name ending .json. Done manifests move to _queue\done, failures to
# _queue\failed, so the queue folder itself is always "what is left".

param(
  [string]$Queue   = 'D:\video\_queue',
  [string]$LogRoot = 'D:\video\_logs',
  [int]$Lanes      = 2,
  [int]$PollSec    = 20
)

$transcode = 'D:\video\.claude\skills\disc-to-plex\scripts\transcode.ps1'
foreach ($d in @($Queue, (Join-Path $Queue 'running'), (Join-Path $Queue 'done'), (Join-Path $Queue 'failed'), $LogRoot)) {
  New-Item -ItemType Directory -Force $d | Out-Null
}

# A lane is busy if an ffmpeg is reading from _stage. Counting ffmpeg alone is wrong on a shared
# machine - other agents run ffmpeg against the NAS and must not be mistaken for an encode lane.
function Busy-Lanes {
  @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -match '_stage' }).Count
}

Write-Output "lane-runner: draining $Queue with $Lanes lane(s)"
$idle = 0
while ($true) {
  $busy = Busy-Lanes
  $next = Get-ChildItem -LiteralPath $Queue -File -Filter '*.json' -ErrorAction SilentlyContinue |
          Sort-Object CreationTime | Select-Object -First 1

  if ($next) {
    $log = Join-Path $LogRoot ([IO.Path]::GetFileNameWithoutExtension($next.Name))
    New-Item -ItemType Directory -Force $log | Out-Null

    # Claim the manifest FIRST by moving it out of the queue, so a second runner instance cannot
    # pick up the same one. The queue folder is then always "what is left".
    #
    # It is claimed into `running\`, NOT `done\`. Claiming straight into `done` made an IN-PROGRESS
    # manifest indistinguishable from a finished one: a run 20 items into 23 showed its manifest in
    # `done` with three outputs absent, which reads exactly like three items that failed silently -
    # and "MANIFEST DONE with failed items" is a real failure mode this pipeline has. Checking the
    # lane log was the only way to tell the two apart. Now the folder name states which it is.
    $claim = Join-Path $Queue "running\$($next.Name)"
    try { Move-Item -LiteralPath $next.FullName -Destination $claim -Force }
    catch { Start-Sleep -Seconds 2; continue }        # another instance claimed it first

    Write-Output "lane: running $($next.Name)"
    # RUN IT SYNCHRONOUSLY. An earlier version launched detached via Start-Process and the launch
    # silently did nothing - the manifest left the queue, no ffmpeg appeared, and the only symptom
    # was an idle GPU that looked like an empty queue. Running in-process means the exit code and
    # all output are right here, and "this instance is busy" is simply "this instance is blocked".
    # Concurrency comes from starting N instances of this script, not from N detached children.
    # WARNING is in this list because it was NOT, and that is how a Japanese subtitle track reached
    # the NAS labelled English: transcode.ps1 announced the fallback on a WARNING line, this filter
    # dropped it, and no log a human reads ever mentioned it. A filter that hides warnings turns a
    # noisy failure into a silent one.
    & pwsh -File $transcode -Manifest $claim -LogDir $log 2>&1 |
      Select-String 'OK |FAILED|ABORT|REFUS|WARNING|MANIFEST DONE|AUDIO REVIEW' | ForEach-Object { "    $_" }
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
      Write-Output "    lane exit $LASTEXITCODE - moving to failed"
      Move-Item -LiteralPath $claim -Destination (Join-Path $Queue "failed\$($next.Name)") -Force
    }
    else {
      # Only NOW is it done. `running\` empty + `done\` populated is the truthful resting state.
      Move-Item -LiteralPath $claim -Destination (Join-Path $Queue "done\$($next.Name)") -Force
    }
    $idle = 0
    continue
  }

  if (-not $next -and $busy -eq 0) {
    $idle++
    if ($idle -eq 1) { Write-Output 'queue empty and lanes idle - waiting for work' }
  }
  Start-Sleep -Seconds $PollSec
}
