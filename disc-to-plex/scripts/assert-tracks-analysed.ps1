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

# HOW MANY GATED ITEMS SHARE EACH `src`?
#
# For kind "MKV" a src is one file per title, so `<src>.tracks.json` names exactly one analysis.
# For kind "DVD" the src is the DISC FOLDER, shared by every title on it - so a single
# `<src>.tracks.json` is claimed by all of them, and an analysis of title 2 would silently stand as
# evidence for title 3. That is precisely the unearned claim this gate exists to refuse.
#
# Found on The Saint Colour D14 (2026-08-28), which has TWO two-audio titles. It had never bitten
# before only because every earlier DVD had at most one - D1 and D11 in the same batch each had
# exactly one, so their single file was unambiguous. That is luck, not design.
#
# So: count the gated items per src first. Where a DVD src is shared, the evidence must be
# title-aware (`<src>.title<N>.tracks.json`); where it is not, the legacy name stays valid and
# nothing already shipped is invalidated.
$gatedPerSrc = @{}
foreach ($pre in $items) {
  if ($pre.PSObject.Properties.Name -contains 'audioTracks' -or
      $pre.PSObject.Properties.Name -contains 'commentary' -or
      $pre.PSObject.Properties.Name -contains 'audioDescription') {
    $k = "$($pre.src)"
    $gatedPerSrc[$k] = 1 + [int]$gatedPerSrc[$k]
  }
}

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
      # PROBE A DVD THROUGH THE dvdvideo DEMUXER, NOT AS A FILE.
      #
      # For kind "DVD" the manifest's `src` is the FOLDER containing VIDEO_TS - that is the
      # documented format. ffprobe cannot open a directory: it returns "Permission denied", the
      # stream count comes back 0, the single-stream exemption cannot fire, and an ordinary DVD
      # item claiming `audioTracks: [0]` is REFUSED for missing <src>.tracks.json - evidence that
      # can never exist for a folder.
      #
      # The practical effect was worse than a spurious refusal: it pushed the manifest author to
      # OMIT `audioTracks` entirely to dodge the gate (observed on the BBC Shakespeare batch,
      # 2026-08-23). A guard that is cheaper to evade than to satisfy trains people to evade it,
      # and the next omission will be one that mattered.
      #
      # transcode.ps1 reads these with `-f dvdvideo -title N`; probe them the same way.
      $probeArgs = @('-v','error','-select_streams','a','-show_entries','stream=index','-of','csv=p=0')
      if (Test-Path -LiteralPath "$($it.src)" -PathType Container) {
        if ($null -eq $it.title) {
          $problems += "$(Split-Path $out -Leaf): DVD src is a folder but no 'title' is set - required for kind DVD"
          continue
        }
        $probeArgs += @('-f','dvdvideo','-title',"$($it.title)")
      }
      $probeArgs += @('-i',"$($it.src)")
      $n = @(& $ffprobe @probeArgs 2>$null).Count
      if ($n -eq 1) { $trivial = $true }
    }
  }
  if ($trivial) { continue }

  # Prefer title-aware evidence for a DVD; fall back to the legacy name only when this src is not
  # shared by another gated item (see the $gatedPerSrc note above).
  $ev        = "$($it.src).tracks.json"
  $isDvdDir  = (Test-Path -LiteralPath "$($it.src)" -PathType Container) -and ($null -ne $it.title)
  if ($isDvdDir) {
    $titleEv = "$($it.src).title$($it.title).tracks.json"
    if (Test-Path -LiteralPath $titleEv) {
      $ev = $titleEv
    } elseif ([int]$gatedPerSrc["$($it.src)"] -gt 1) {
      $problems += "$(Split-Path $out -Leaf): AMBIGUOUS EVIDENCE - $([int]$gatedPerSrc[""$($it.src)""]) " +
                   "gated items share this DVD folder, so '$(Split-Path $ev -Leaf)' cannot be " +
                   "evidence for title $($it.title) specifically. Write " +
                   "'$(Split-Path $titleEv -Leaf)' (analyze-tracks.py --out) and re-run."
      continue
    }
  }
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
    if ($s.role -eq 'analysis-failed') {
      # The analysis RAN and could not measure this stream (extraction/whisper failure). That is
      # an absence of evidence, not evidence - shipping it means shipping audio nobody has heard.
      $problems += "$(Split-Path $out -Leaf): a:$idx analysis FAILED - no transcript could be " +
                   "taken, so nothing about this stream is evidenced. Re-run analyze-tracks.py"
    }
    if ($s.role -eq 'silent?') {
      # Near-silent, speechless audio is a phantom/menu artifact until someone proves otherwise.
      # (A real score measures loud and gets role 'music', which IS claimable - a silent-film
      # disc like Metropolis ships its orchestral tracks as 'zxx'.)
      $problems += "$(Split-Path $out -Leaf): a:$idx measured NEAR-SILENT with no speech " +
                   "($($s.audioLevelDb) dB) - probably a phantom track. Listen before shipping it"
    }
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
      # NEVER COMPARE AGAINST A LANGUAGE THE ANALYSIS ITSELF DOES NOT TRUST.
      #
      # A MUSIC track has no language, and whisper hallucinates one from a score: Metropolis's
      # Huppertz score came back "la" (Latin) at langProb 0.52 with langReliable=false. Comparing a
      # declaration against that made the track UNPASSABLE - for the score-only trailer NO value
      # could satisfy this check, not even the analyzer's own proposal, because the only "matching"
      # answer was the factually wrong 'la'. A gate that can only be satisfied by a false claim
      # forces exactly the override it exists to prevent.
      #
      # So skip the comparison when the analysis says role 'music' or flags the language
      # unreliable. This does NOT weaken the check that matters: a stream with RELIABLE speech in
      # the wrong language is still refused, which is what caught Thunderball's Italian dub.
      if ($s.role -eq 'music') { continue }
      if ($s.PSObject.Properties.Name -contains 'langReliable' -and -not $s.langReliable) { continue }
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

      # CHANNEL COUNT, INDEPENDENT OF THE TRANSCRIPT. The check above asks the evidence file
      # whether it agrees with the manifest - so when the EVIDENCE is inverted, both agree and
      # both are wrong. That happened on Farscape S1 D6 dvdvideo 3: the episode's dialogue tripped
      # the commentary word-list, the real commentary was elected primary, and the analyzer
      # proposed `commentary: 0` - the 5.1 programme mix. This gate passed it. It was caught by a
      # human reading the transcripts, which is not a control.
      #
      # A commentary is mixed for two speakers in a room: 2.0, sometimes mono. The programme mix
      # is the one with the channels. So a "commentary" carrying MORE channels than the track it
      # would play under is not a commentary, whatever the transcript says - and this holds for
      # dubs, audio description and duplicate mixes too, none of which are ever the widest track.
      $mainIdx = if ($it.PSObject.Properties.Name -contains 'audioTracks' -and @($it.audioTracks).Count) {
                   [int](@($it.audioTracks)[0]) } else { $null }
      if ($null -ne $mainIdx -and $mainIdx -ne $ci) {
        $main = $byIdx[$mainIdx]
        if ($s -and $main -and $s.channels -and $main.channels -and
            [int]$s.channels -gt [int]$main.channels) {
          $problems += "$(Split-Path $out -Leaf): a:$ci is tagged as commentary but carries " +
                       "$($s.channels) channels against a:$mainIdx's $($main.channels) - the " +
                       "wider mix is the programme, so this pair is INVERTED. Re-read both " +
                       "transcripts before changing anything; do not simply swap the numbers"
        }
      }
    }
  }

  if ($it.PSObject.Properties.Name -contains 'audioDescription') {
    foreach ($e in @($it.audioDescription)) {
      $di = if ($e -is [array]) { [int]$e[0] } else { [int]$e }
      $s = $byIdx[$di]
      # 'unknown' was on this allowed list speculatively - no producer has ever emitted it, so it
      # was a fail-open hole: any role the analyzer never generates would have approved an AD
      # claim. The list now names only roles analyze-tracks.py actually writes.
      if ($s -and $s.role -notin @('audioDescription', 'commentary?')) {
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
