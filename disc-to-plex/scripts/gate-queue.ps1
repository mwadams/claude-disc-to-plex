# Hold a manifest until its source disc is BYTE-COMPLETE, then drop it in the encode queue.
#
# Enumerating or encoding a half-copied disc is the documented silent failure: titles simply are
# not there yet, durations look plausible, and nothing errors. MakeMKV happily reported a credible
# 2:12:07 feature for Die Hard while 42 of its 266 files were still copying.
#
# So the judgement (which title, what language, how named) is made up front and written into the
# manifest, but the manifest only becomes runnable once source and staged copies match on BOTH
# file count and total bytes.
param(
  [Parameter(Mandatory)][string]$SourceDir,     # e.g. E:\DIE_HARD_1_F1
  [Parameter(Mandatory)][string]$StageDir,      # e.g. D:\video\_stage\DIE_HARD_1_F1
  [Parameter(Mandatory)][string]$Manifest,      # a .json written but NOT yet in the queue
  [string]$Queue = 'D:\video\_queue',
  [int]$PollSec = 30
)

while ($true) {
  $s = Get-ChildItem -LiteralPath $SourceDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
  $t = Get-ChildItem -LiteralPath $StageDir  -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum
  if ($s.Count -gt 0 -and $s.Count -eq $t.Count -and $s.Sum -eq $t.Sum) {
    Move-Item -LiteralPath $Manifest -Destination (Join-Path $Queue (Split-Path $Manifest -Leaf)) -Force
    Write-Output ("gate passed: {0} ({1} files / {2} GB) - queued {3}" -f (Split-Path $StageDir -Leaf), $s.Count, [math]::Round($s.Sum/1GB,2), (Split-Path $Manifest -Leaf))
    break
  }
  Start-Sleep -Seconds $PollSec
}
