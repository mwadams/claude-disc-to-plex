# Refuse a manifest whose AUDIO decisions are not backed by measured evidence.
#
# WHY. Audio selection was authored from expectation and corrected later. Thunderball's a:5 was
# written down as "commentary 2" because the edition advertises two commentaries - it is an
# ITALIAN DUB tagged `eng`. Its a:1 was assumed a second mix; it is the lossy DTS core. Neither
# was caught by any structural check, because both were structurally perfect.
#
# `analyze-tracks.py` measures what is actually on each stream and writes `<src>.tracks.json`.
# This gate compares the manifest against that file and REFUSES on disagreement, so a casual
# manifest cannot reach the GPU. It checks nothing about video - only the audio claims.
#
#   pwsh -File assert-tracks-analysed.ps1 -Manifest D:\video\_manifests\x.json
#
# Exit 0 = every audio claim is evidenced.  Exit 2 = refused, with the reason.
param(
  [Parameter(Mandatory)][string]$Manifest,
  [switch]$WarnOnly     # report but do not block (use when retro-fitting an old manifest)
)
$ErrorActionPreference = 'Stop'
$paths = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $paths.ffmpeg) 'ffprobe.exe'

$items = Get-Content -LiteralPath $Manifest -Raw | ConvertFrom-Json
if ($items -isnot [array]) { $items = @($items) }

$problems = @()
$checked = 0

foreach ($it in $items) {
  $out = "$($it.out)"
  # Only items that make an explicit audio claim are gated. An item with no audioTracks takes the
  # encoder's automatic pick, which is a different (and separately guarded) decision.
  $hasClaim = $it.PSObject.Properties.Name -contains 'audioTracks' -or
              $it.PSObject.Properties.Name -contains 'commentary' -or
              $it.PSObject.Properties.Name -contains 'audioDescription'
  if (-not $hasClaim) { continue }
  $checked++

  # EXEMPTION: a source with ONE audio stream, claimed as audioTracks [0] and nothing else.
  #
  # Every failure this gate exists to catch needs at least two streams to be possible: picking the
  # lossy core over its lossless parent, tagging a dub as the commentary, shipping a duplicate. With
  # a single stream there is no selection being asserted - "keep the only track" cannot be wrong.
  # Requiring a whisper analysis for each of 37 short extras would buy nothing and would push people
  # to bypass the gate, which is worse than a narrower gate.
  #
  # NOT exempt: the LANGUAGE claim can still be wrong on one stream (Sleep Dealer shipped as `eng`
  # and is Spanish). That is now covered upstream instead - catalogue-disc.ps1 records a
  # speechSample per title, so the language is evidenced for every title before a manifest exists.
  $trivial = $false
  if (-not ($it.PSObject.Properties.Name -contains 'commentary') -and
      -not ($it.PSObject.Properties.Name -contains 'audioDescription')) {
    $claimed = @($it.audioTracks)
    if ($claimed.Count -eq 1 -and [int]$claimed[0] -eq 0) {
      $n = @(& $ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 "$($it.src)" 2>$null).Count
      if ($n -eq 1) { $trivial = $true }
    }
  }
  if ($trivial) { continue }

  $ev = "$($it.src).tracks.json"
  if (-not (Test-Path -LiteralPath $ev)) {
    $problems += "$(Split-Path $out -Leaf): NO EVIDENCE - run analyze-tracks.py on $($it.src)"
    continue
  }

  $a = Get-Content -LiteralPath $ev -Raw | ConvertFrom-Json
  $byIdx = @{}                 # NOT $t/$T - PowerShell variables are case-insensitive and the
  foreach ($s in $a.streams) { $byIdx[[int]$s.a] = $s }   # natural pair collapses into one.

  foreach ($idx in @($it.audioTracks)) {
    $s = $byIdx[[int]$idx]
    if (-not $s) { $problems += "$(Split-Path $out -Leaf): a:$idx not in the analysis"; continue }
    if ($s.role -eq 'redundant') {
      $problems += "$(Split-Path $out -Leaf): a:$idx is REDUNDANT with a:$($s.redundantWith) " +
                   "(lossy core or duplicate) - shipping it wastes space and invites a wrong label"
    }
    if ($s.tagMismatch) {
      $problems += "$(Split-Path $out -Leaf): a:$idx is tagged '$($s.langTag)' but SPOKEN " +
                   "'$($s.spokenLang)' - set audioLangs from the spoken language, not the tag"
    }
  }

  # The declared language must match what is actually spoken.
  if ($it.audioLangs) {
    $tracks = @($it.audioTracks); $langs = @($it.audioLangs)
    for ($i = 0; $i -lt [Math]::Min($tracks.Count, $langs.Count); $i++) {
      $s = $byIdx[[int]$tracks[$i]]
      if (-not $s -or -not $s.spokenLang) { continue }
      $spoken = "$($s.spokenLang)".Substring(0, 2)
      $declared = "$($langs[$i])".Substring(0, [Math]::Min(2, "$($langs[$i])".Length))
      # commentary and audio description are ABOUT the film in the same language - not a mismatch
      if ($s.role -in @('commentary', 'audioDescription')) { continue }
      if ($spoken -ne $declared) {
        $problems += "$(Split-Path $out -Leaf): a:$($tracks[$i]) declared '$($langs[$i])' but " +
                     "whisper heard '$($s.spokenLang)'"
      }
    }
  }

  if ($it.PSObject.Properties.Name -contains 'commentary') {
    # SAME SHAPES AS transcode.ps1: an ordinal, a list of ordinals, or [idx,"Title"] pairs.
    # This used to do [int]$it.commentary, which throws on the array form - and because
    # lane-runner only treated exit 2 as a refusal, an ERRORING gate let the manifest straight
    # through. A guard that fails open is not a guard. Observed on When Harry Met Sally, which
    # carries TWO commentaries.
    foreach ($e in @($it.commentary)) {
      $ci = if ($e -is [array]) { [int]$e[0] } else { [int]$e }
      $s = $byIdx[$ci]
      if ($s -and $s.role -notin @('commentary', 'commentary?')) {
        $problems += "$(Split-Path $out -Leaf): a:$ci tagged as commentary but the analysis " +
                     "calls it '$($s.role)' - a dub labelled 'Audio Commentary' is how " +
                     "Thunderball nearly shipped"
      }
    }
  }

  if ($it.PSObject.Properties.Name -contains 'audioDescription') {
    foreach ($e in @($it.audioDescription)) {
      $di = if ($e -is [array]) { [int]$e[0] } else { [int]$e }
      $s = $byIdx[$di]
      if ($s -and $s.role -notin @('audioDescription', 'commentary?', 'unknown')) {
        $problems += "$(Split-Path $out -Leaf): a:$di tagged as audio description but the " +
                     "analysis calls it '$($s.role)'"
      }
    }
  }
}

if ($checked -eq 0) {
  Write-Output "no audio claims in $(Split-Path $Manifest -Leaf) - nothing to verify"
  exit 0
}

if ($problems.Count -eq 0) {
  Write-Output "audio evidence OK - $checked item(s) verified against their .tracks.json"
  exit 0
}

Write-Warning "AUDIO CLAIMS NOT SUPPORTED BY EVIDENCE ($($problems.Count)):"
$problems | ForEach-Object { Write-Warning "   $_" }
if ($WarnOnly) { exit 0 }
Write-Warning "Refusing. Re-run analyze-tracks.py, or correct the manifest to match the evidence."
exit 2
