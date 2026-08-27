# Answer "what is running, and is it pipeline-managed?" - in ONE place, from ONE definition.
#
# WHY THIS EXISTS
# ---------------
# On 2026-08-25 I tried to answer that by hand: I listed `_manifests/`, `_queue/done/` and
# `_queue/failed/`, found no Grange Hill manifest, and concluded a subagent was hand-running
# encodes outside the pipeline. It was not. Both manifests were in `_queue/running/` - the one
# directory I did not list. On that reading I killed four legitimate lane encodes, truncating four
# episodes, and stopped an agent that was doing its job correctly.
#
# The ad-hoc check was the defect. An enumeration written fresh each time will eventually omit a
# state, and the omission looks exactly like absence. So: enumerate ALL queue states from one list,
# and map each running ffmpeg to the manifest that claims its output.
#
# An ffmpeg with no claiming manifest is the only thing that warrants suspicion - and even then it
# is reported, not acted on. Nothing here kills anything.
#
#   pwsh -File _whatsrunning.ps1

param(
  [string]$Queue     = 'D:/video/_queue',
  [string]$Manifests = 'D:/video/_manifests'
)

$ErrorActionPreference = 'Stop'

# EVERY state a manifest can be in. Adding a state means adding it here, once.
$states = @{
  'queued'  = "$Queue/*.json"
  'running' = "$Queue/running/*.json"
  'done'    = "$Queue/done/*.json"
  'failed'  = "$Queue/failed/*.json"
  'unqueued'= "$Manifests/*.json"
}

# Map every output path any manifest claims -> "<state>/<manifest>"
$claims = @{}
foreach ($state in $states.Keys) {
  foreach ($m in Get-ChildItem $states[$state] -ErrorAction SilentlyContinue) {
    $items = $null
    try { $items = Get-Content -LiteralPath $m.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
    if ($null -eq $items) { continue }
    if ($items -isnot [array]) { $items = @($items) }
    foreach ($it in $items) {
      if (-not $it.out) { continue }
      $key = ("$($it.out)" -replace '/', '\').ToLowerInvariant()
      if (-not $claims.ContainsKey($key)) { $claims[$key] = "$state/$($m.Name)" }
    }
  }
}

$procs = @(Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue)
if ($procs.Count -eq 0) {
  Write-Output 'no ffmpeg running.'
} else {
  Write-Output "$($procs.Count) ffmpeg process(es):"
  foreach ($p in $procs) {
    $c = "$($p.CommandLine)"
    # ffmpeg's output is the last path-looking argument; accept quoted or bare.
    $m = [regex]::Matches($c, '"?([A-Za-z]:[^"]*?\.mkv)"?')
    $out = if ($m.Count) { $m[$m.Count - 1].Groups[1].Value } else { $null }
    # LABEL THIS. Bare "00:06:41" beside a process reads as elapsed/CPU time, and a start time that
    # is (correctly) identical on every poll then looks like a WEDGED encode. Misread three times
    # in a row on 2026-08-28 before the growing output file settled it. The prefix costs nothing.
    $started = 'started ' + $p.CreationDate.ToString('HH:mm:ss')

    # A REAL OUTPUT GOES INTO THE LIBRARY. Anything else is an input being read.
    #
    # This took the LAST .mkv on the command line as the output, which is right for an encode and
    # WRONG for a probe: `ffmpeg -ss 1981 -t 30 -i _stage/sunrise-rip/title_t00.mkv` writes nothing,
    # and the only .mkv present is the SOURCE. The tool then announced
    # "*** NO MANIFEST CLAIMS THIS OUTPUT ***" over an agent's ordinary identification read - the
    # exact false alarm this script exists to prevent, since the whole point of it is that I once
    # killed legitimate encodes on a wrong reading of what was running.
    #
    # Same rule as the lane counters: judge by what a process WRITES, and the library roots are the
    # only place a real output lands.
    $libRoots = @('d:\video\movies', 'd:\video\television shows')
    $isLibraryOut = $false
    if ($out) {
      $norm = ($out -replace '/', '\').ToLowerInvariant()
      $isLibraryOut = [bool]($libRoots | Where-Object { $norm.StartsWith($_) })
    }
    if (-not $isLibraryOut) {
      $what = if ($out) { "reading $(Split-Path $out -Leaf)" } else { 'no .mkv output' }
      Write-Output ("  pid {0,-6} {1}  READ-ONLY ({2}) - probe/frame extraction" -f $p.ProcessId, $started, $what)
      continue
    }
    $key = ($out -replace '/', '\').ToLowerInvariant()
    $owner = $claims[$key]
    if ($owner) {
      Write-Output ("  pid {0,-6} {1}  {2}" -f $p.ProcessId, $started, (Split-Path $out -Leaf))
      Write-Output ("         claimed by {0}" -f $owner)
    } else {
      Write-Output ("  pid {0,-6} {1}  {2}" -f $p.ProcessId, $started, (Split-Path $out -Leaf))
      Write-Output  "         *** NO MANIFEST CLAIMS THIS OUTPUT - investigate before concluding anything ***"
      Write-Output ("         out: {0}" -f $out)
    }
  }
}

Write-Output ''
# `unqueued` is the manifest ARCHIVE - every manifest ever authored stays there after _gate-queue
# copies it onward, so it runs to hundreds of entries and naming them all buries the three lines
# that matter. Count it; name the states that represent live or stuck work.
foreach ($state in @('queued', 'running', 'failed')) {
  $n = @(Get-ChildItem $states[$state] -ErrorAction SilentlyContinue)
  if ($n.Count) { Write-Output ("{0,-9} {1}" -f $state, (($n.Name) -join ', ')) }
}
$archive = @(Get-ChildItem $states['unqueued'] -ErrorAction SilentlyContinue).Count
if ($archive) { Write-Output ("archive   {0} manifest(s) in _manifests (claims still honoured above)" -f $archive) }

# TRUNCATED OUTPUTS. A manifest reaching `done` does not mean its outputs are finalised - if an
# encode is killed, the item can be left over 5 MB with no duration, and nothing retries it because
# the manifest is no longer queued. That is exactly what my kills produced. Report it; re-queueing
# the manifest is the repair, because transcode.ps1 deletes and re-encodes any duration-less output.
$paths = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'
$live = @($procs | ForEach-Object {
  $m = [regex]::Matches("$($_.CommandLine)", '"?([A-Za-z]:[^"]*?\.mkv)"?')
  if ($m.Count) { ($m[$m.Count-1].Groups[1].Value -replace '/', '\').ToLowerInvariant() }
})
$partial = @()
foreach ($m in Get-ChildItem $states['done'] -ErrorAction SilentlyContinue) {
  $items = $null
  try { $items = Get-Content -LiteralPath $m.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
  if ($null -eq $items) { continue }
  if ($items -isnot [array]) { $items = @($items) }
  foreach ($it in $items) {
    if (-not $it.out) { continue }
    $p = "$($it.out)" -replace '/', '\'
    if (-not (Test-Path -LiteralPath $p)) { continue }
    if ((Get-Item -LiteralPath $p).Length -le 5MB) { continue }
    if ($live -contains $p.ToLowerInvariant()) { continue }   # being written right now
    $d = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $p 2>$null)".Trim()
    $dv = 0.0; [void][double]::TryParse($d, [ref]$dv)
    if ($dv -le 0) { $partial += "$($m.Name): $(Split-Path $p -Leaf)" }
  }
}
if ($partial.Count) {
  Write-Output ''
  Write-Output "TRUNCATED OUTPUT under a 'done' manifest - nothing will retry these ($($partial.Count)):"
  $partial | ForEach-Object { Write-Output "   $_" }
  Write-Output "   repair: re-queue the manifest with _gate-queue.ps1 (transcode.ps1 re-encodes duration-less outputs)"
}
