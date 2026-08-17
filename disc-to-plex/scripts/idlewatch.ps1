# Report when the OCR track or the NAS track goes idle WHILE WORK IS STILL PENDING.
#
# An idle track is only worth waking someone for if there is something it could be doing - "no
# robocopy running" is the normal state once everything is published. So each check pairs
# "nothing running" with "work outstanding", and prints only on transition.
param([string]$StateFile = 'D:\video\.transcode-tools\idlestate.txt')

$paths   = Get-Content 'D:\video\.transcode-tools\tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'
$msgs    = @()

# ---- OCR: idle with files still carrying bitmap subs and no sidecar -------------------------
$ocrBusy = @(Get-Process tesseract -ErrorAction SilentlyContinue).Count -gt 0
if (-not $ocrBusy) {
  $pending = 0
  foreach ($f in Get-ChildItem 'D:\video\Movies','D:\video\Television Shows' -Recurse -File -Filter *.mkv -ErrorAction SilentlyContinue) {
    $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null)".Trim()
    if (-not $d -or $d -eq 'N/A') { continue }          # still encoding - not OCR's turn yet
    $codecs = @(& $ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 $f.FullName 2>$null)
    if ($codecs | Where-Object { $_ -match 'dvd_subtitle|hdmv_pgs' }) {
      if (-not (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($f.FullName, $null) + 'eng.srt'))) { $pending++ }
    }
  }
  if ($pending -gt 0) { $msgs += "OCR IDLE with $pending file(s) awaiting a sidecar" }
}

# ---- NAS: idle with work that is ACTUALLY publishable ---------------------------------------
#
# Only alarm when the NAS track could be doing something. publish-work.ps1 treats a work
# atomically, so a work containing ANY file still encoding or awaiting an OCR sidecar is correctly
# held back - reporting that as "NAS IDLE" is a false alarm, and a monitor that cries wolf gets
# ignored, which defeats the point of having one.
$nasBusy = @(Get-Process robocopy -ErrorAction SilentlyContinue).Count -gt 0
if (-not $nasBusy) {
  $ready = 0; $blocked = 0
  foreach ($kind in 'Movies','Television Shows') {
    $lroot = "D:\video\$kind"; $nroot = "\\NASTEAMV\Multimedia\$kind"
    if (-not (Test-Path -LiteralPath $lroot)) { continue }
    foreach ($w in Get-ChildItem -LiteralPath $lroot -Directory -ErrorAction SilentlyContinue) {
      $needs = $false; $hold = $false
      foreach ($f in Get-ChildItem -LiteralPath $w.FullName -Recurse -File -ErrorAction SilentlyContinue) {
        $t = $f.FullName.Replace($lroot, $nroot)
        if (-not (Test-Path -LiteralPath $t) -or (Get-Item -LiteralPath $t).Length -ne $f.Length) { $needs = $true }
        if ($f.Extension -ne '.mkv') { continue }
        $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $f.FullName 2>$null)".Trim()
        if (-not $d -or $d -eq 'N/A') { $hold = $true; continue }        # still encoding
        $codecs = @(& $ffprobe -v error -select_streams s -show_entries stream=codec_name -of csv=p=0 $f.FullName 2>$null)
        if ($codecs | Where-Object { $_ -match 'dvd_subtitle|hdmv_pgs' }) {
          if (-not (Test-Path -LiteralPath ([IO.Path]::ChangeExtension($f.FullName, $null) + 'eng.srt'))) { $hold = $true }
        }
      }
      if ($needs) { if ($hold) { $blocked++ } else { $ready++ } }
    }
  }
  if ($ready -gt 0) { $msgs += "NAS IDLE with $ready work(s) READY to publish ($blocked more blocked on OCR/encode)" }
}

# ---- THE GAP: a disc is staged but no manifest exists for it -------------------------------
#
# The lane-runner drains a queue of manifests; nothing FILLS that queue. Authoring a manifest is
# the judgement step (which title is the feature, does it need a MakeMKV rip, what is the original
# language, how is it named) and deliberately stays manual - automating it is what produced a
# Japanese film shipped with only its English dub, and a film filed as a TV series.
#
# So the gap cannot be closed, but it must not be INVISIBLE: staging finishing while the queue is
# empty is precisely when lanes go idle unnoticed. Report it as work waiting for a decision.
$queued = @(Get-ChildItem 'D:\video\_queue' -File -Filter '*.json' -ErrorAction SilentlyContinue).Count
$busyLanes = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
               Where-Object { $_.CommandLine -match '_stage' }).Count
if ($queued -eq 0 -and $busyLanes -lt 2) {
  # A staged folder that an encode is CURRENTLY READING is not awaiting a manifest - it already
  # has one and is in flight. Counting it produces exactly the false alarm this check exists to
  # avoid.
  $inUse = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue |
             ForEach-Object { $_.CommandLine })
  $staged = @(Get-ChildItem 'D:\video\_stage' -Directory -ErrorAction SilentlyContinue |
              Where-Object { $n = $_.Name; -not ($inUse | Where-Object { $_ -match [regex]::Escape("_stage\$n") -or $_ -match [regex]::Escape("_stage/$n") }) } |
              Select-Object -ExpandProperty Name)
  if ($staged.Count) {
    $msgs += "QUEUE EMPTY, $busyLanes/2 lanes busy - staged and awaiting a manifest: $($staged -join ', ')"
  } else {
    $msgs += "QUEUE EMPTY, $busyLanes/2 lanes busy - and NOTHING staged; the source track is the constraint"
  }
}

$now  = ($msgs -join ' | ')
$prev = if (Test-Path -LiteralPath $StateFile) { (Get-Content -LiteralPath $StateFile -Raw).Trim() } else { '' }
if ($now -ne $prev) {
  Set-Content -LiteralPath $StateFile -Value $now
  if ($now) { Write-Output $now }
}
