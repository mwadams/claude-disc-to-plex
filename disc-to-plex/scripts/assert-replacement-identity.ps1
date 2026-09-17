<#
.SYNOPSIS
  THE "REPLACE AN EXISTING EPISODE" CASE MUST PROVE IT IS THE SAME EPISODE.
  Every dispositions row that claims an SxxEyy the library ALREADY HOLDS is a replacement claim -
  an in-place re-rip, a supersede, or "already published, nothing to gain". Each of those is only
  true if the disc title and the published file are the same episode. This measures it: the disc
  title's own speech sample (catalogue `speechSample`, 45 s transcribed at a recorded offset) is
  compared with the published file's .eng.srt text over the same stretch of the episode.

  REACH FOR THIS WHEN: a disc's rows name episodes the library already has - a re-rip, a supersede,
  or a "nothing worth shipping" closure - and you need to know each really is that episode.

.WHY
  2026-09-17, FRIENDS_S4_DISC_2: t11 was dispositioned `S04E05 The One with Joey's New Girlfriend`.
  S04E05 was already published from Disc 1, so the manifest simply had nothing to build for it and
  the title vanished - it was really S04E21 "The One with the Invitation", the only episode of the
  disc's E13-E24 run that never appeared. Its catalogue sample (the Everest video / Die Hard) shares
  nothing with the published S04E05's subtitles at that point. Nothing asked the question, because
  "already published" was read as a conclusion rather than as a claim to test. The same unasked
  question underwrites every NOTHING IS WORTH SHIPPING closure, which releases the disc.

.VERDICTS (per row)
  MATCH         the sample's words are found in the published subtitles near that offset.
  MISMATCH      at least TWO informative samples (the stored one plus fresh ones transcribed from
                the disc title further in), none matching, pooled score under MismatchBelow - this
                title is NOT the published episode. REFUSES (exit 2).
  INCONCLUSIVE  in between. Reported, not refused: a noisy transcript must not wedge a disc.
  UNVERIFIABLE  the episode exists but there is no sample or no .eng.srt to compare. Reported.
  NEW           the library does not hold that episode - not a replacement, nothing to prove.
  A row whose show cannot be resolved is reported as SHOW NOT RESOLVED - loudly, because a check
  that skips is not a check that passes.

.USAGE
  pwsh -NoProfile -File assert-replacement-identity.ps1 -Disc 'FRIENDS_S4_DISC_2-1a09de4f'
  pwsh -NoProfile -File assert-replacement-identity.ps1 -Disc 'The West Wing Season 4 Disk 1' -Show 'The West Wing'

.EXIT CODES
  0 = no row refuted (MATCH / NEW / INCONCLUSIVE / UNVERIFIABLE only)   2 = at least one MISMATCH
  3 = cannot run (no dispositions or catalogue file)
#>
param(
  [Parameter(Mandatory)][string]$Disc,
  [string]$Catalogue = 'D:/video/_catalogue',
  [string]$NasRoot   = '//NASTEAMV/Multimedia',
  [string]$LocalRoot = 'D:/video',
  [string]$Show,                       # override show resolution (library folder name)
  # CALIBRATION, FRIENDS_S4_DISC_2 against the published Season 4 (2026-09-17). A sample that caught
  # dialogue scored 50-96% against its own episode (11 titles); the one wrong claim, t11 vs S04E05,
  # scored 12% / 19% / 6% over three samples (pooled 12%). A sample that caught the theme song scored
  # 20% against its OWN episode - which is why one sample never refuses and the test is pooled.
  [double]$MatchAt    = 0.35,          # share of the sample's distinctive words found near the offset
  [double]$MismatchBelow = 0.25,       # POOLED over every informative sample; calibrated above
  [int]$WindowPadSec  = 120,           # tolerance either side of the 45 s sample (edits, cold opens, BD first-clip offsets)
  [int]$MinWords      = 12,            # a sample with fewer distinctive words proves nothing either way
  [string]$ToolsDir   = 'D:/video/.transcode-tools',
  [switch]$NoFreshSamples,             # score only the catalogue's stored sample (no transcription)
  [string]$QueueRoot  = 'D:/video',    # where _queue and _pending live (show resolution from manifests)
  [string]$SampleStub                  # TESTS: JSON { "<probe path | dvN>@<seconds>": "text" } replaces ffmpeg+whisper
)
$ErrorActionPreference = 'Stop'

# ---- tools for FRESH samples ------------------------------------------------------------------------
# The catalogue's one 45 s sample is sometimes the theme song (Friends S4 D2 t06/t12: "I'll be there
# for you" x6 - words no subtitle file carries), which scores like a different episode. A single weak
# sample must never REFUSE: before a MISMATCH is called, two more samples are transcribed from the
# disc title itself, further in, and all of them have to disagree with the published subtitles.
$ff = $null
$tpFile = Join-Path $ToolsDir 'tool-paths.json'
if (Test-Path -LiteralPath $tpFile) { try { $ff = (Get-Content -LiteralPath $tpFile -Raw | ConvertFrom-Json).ffmpeg } catch { } }
if (-not $ff) { $ff = (Get-Command ffmpeg -ErrorAction SilentlyContinue).Source }
$whisper = Join-Path $PSScriptRoot 'transcribe-wav.py'
$stub = $null
if ($SampleStub) { $stub = Get-Content -LiteralPath $SampleStub -Raw | ConvertFrom-Json }
function Get-FreshSample([string]$speechFrom, [double]$at) {
  if ($stub) {
    $key = if ($speechFrom -match 'dvdvideoTitle=(\d+)') { "dv$($Matches[1])@$at" } elseif ($speechFrom -match 'probe=([^|]+)') { "$($Matches[1].Trim())@$at" } else { '' }
    $v = $stub.PSObject.Properties[$key]
    return $(if ($v) { "$($v.Value)" } else { $null })
  }
  if (-not $ff -or -not (Test-Path -LiteralPath $whisper)) { return $null }
  $src = @()
  if ($speechFrom -match 'probe=([^|]+)') { $src = @('-ss', "$at", '-i', $Matches[1].Trim()) }
  elseif ($speechFrom -match 'disc=([^|]+)\|dvdvideoTitle=(\d+)') { $src = @('-f', 'dvdvideo', '-title', $Matches[2], '-i', $Matches[1].Trim(), '-ss', "$at") }
  else { return $null }
  $dir = Join-Path ([IO.Path]::GetTempPath()) ('replacement-identity-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
  New-Item -ItemType Directory -Path $dir -Force | Out-Null
  $wav = Join-Path $dir 'sample.wav'
  try {
    & $ff -v error @src -t 45 -map '0:a:0?' -ac 1 -ar 16000 -y $wav 2>$null
    if (-not (Test-Path -LiteralPath $wav)) { return $null }
    $out = @(& python $whisper $wav 2>$null | Where-Object { $_ -is [string] })
    $line = @($out | Where-Object { $_ -match '^\[[a-z]{2,3} [\d.]+\]' }) | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -replace '^\s*\[[a-z]{2,3}\s+[\d.]+\]\s*', '')
  } finally {
    Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
  }
}

$dispPath = Join-Path $Catalogue ($Disc + '.dispositions.txt')
$catPath  = Join-Path $Catalogue ($Disc + '.catalogue.json')
if (-not (Test-Path -LiteralPath $dispPath)) { Write-Host "assert-replacement-identity: no dispositions file $dispPath"; exit 3 }
if (-not (Test-Path -LiteralPath $catPath))  { Write-Host "assert-replacement-identity: no catalogue file $catPath"; exit 3 }
$cat = Get-Content -LiteralPath $catPath -Raw | ConvertFrom-Json

function Get-NameKey([string]$s) {
  $k = $s.ToLowerInvariant()
  $k = $k -replace '-[0-9a-f]{8}$', ''          # optical unit hash suffix
  $k = $k -replace '\(\d{4}\)', ' '             # "(1994)"
  $k = $k -replace '[^a-z0-9]+', ' '
  $k = $k.Trim() -replace '^the ', ''
  return $k
}

# ---- which show? -----------------------------------------------------------------------------------
# A staging folder name is NOT evidence of a title (user, 2026-09-06: "DVD Folder Names are irrelevant
# - some are even just a GUID"). So the show comes, in order, from: -Show; a library show folder the
# DISPOSITIONS THEMSELVES name that really exists; a manifest already written from this disc; and only
# then the folder name, reported as the approximation it is. It is never a reason to refuse - the
# refusal rests on what the disc SAYS against what the published episode SAYS.
$tvRoots = @((Join-Path $NasRoot 'Television Shows'), (Join-Path $LocalRoot 'Television Shows')) | Where-Object { Test-Path -LiteralPath $_ }
function Get-ShowDirsNamed([string[]]$names) {
  $out = @()
  foreach ($n in @($names | Where-Object { $_ } | Sort-Object -Unique)) {
    foreach ($r in $tvRoots) { $q = Join-Path $r $n; if (Test-Path -LiteralPath $q -PathType Container) { $out += (Get-Item -LiteralPath $q).FullName } }
  }
  return @($out | Sort-Object -Unique)
}
$showDirs = @(); $showFrom = ''
if ($Show) { $showDirs = Get-ShowDirsNamed @($Show); $showFrom = '-Show' }
if (-not $showDirs.Count) {
  $named = @([regex]::Matches((Get-Content -LiteralPath $dispPath -Raw), '(?i)Television Shows[\\/]+([^\\/\r\n|`"'']+?)(?=[\\/])') | ForEach-Object { $_.Groups[1].Value.Trim() })
  $showDirs = Get-ShowDirsNamed $named
  if ($showDirs.Count) { $showFrom = 'named in the dispositions' }
}
if (-not $showDirs.Count) {
  $fromManifests = @()
  foreach ($d in @('_queue', '_queue/done', '_queue/running', '_queue/failed', '_pending' | ForEach-Object { Join-Path $QueueRoot $_ })) {
    foreach ($mf in @(Get-ChildItem -LiteralPath $d -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
      $raw = Get-Content -LiteralPath $mf.FullName -Raw -ErrorAction SilentlyContinue
      if (-not $raw -or $raw.IndexOf("_stage/$Disc/", [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
      $fromManifests += @([regex]::Matches($raw, '(?i)Television Shows/([^/"]+)/') | ForEach-Object { $_.Groups[1].Value })
    }
  }
  $showDirs = Get-ShowDirsNamed $fromManifests
  if ($showDirs.Count) { $showFrom = 'a manifest built from this disc' }
}
if (-not $showDirs.Count) {
  $unitKey = Get-NameKey $Disc
  $cands = @{}
  foreach ($r in $tvRoots) {
    foreach ($d in (Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue)) {
      $k = Get-NameKey $d.Name
      if ($k -and ($unitKey -eq $k -or $unitKey.StartsWith($k + ' '))) {
        if (-not $cands.ContainsKey($k)) { $cands[$k] = @() }
        $cands[$k] += $d.FullName
      }
    }
  }
  if ($cands.Count) {
    $best = ($cands.Keys | Sort-Object Length -Descending | Select-Object -First 1)
    $showDirs = @($cands[$best])   # several folders can share a key - "The Prisoner (1967)" and "(2009)"
    $showFrom = 'the staging folder name - an APPROXIMATION, not evidence'
  }
}

# ---- text helpers ---------------------------------------------------------------------------------
$stop = @{}
foreach ($w in ('that','this','with','have','what','your','just','they','them','there','their','then','than','were','would','could','should','about','know','like','yeah','well','here','want','going','gonna','didn','doesn','don','really','right','okay','from','will','been','because','when','where','which','some','come','back','think','said','only','into','over','very','make','take','tell','look','good','sure','thing','things','something','time','these','those','more','much','even','also','other','does','done','still','again','how','why','who','all','any','can','get','got','let','now','one','out','see','she','her','him','his','our','you','are','was','not','but','for','the','and','yes','hey','okay','little','never','always','maybe','Actually'.ToLowerInvariant())) { $stop[$w] = $true }
function Get-Words([string]$text) {
  # A HashSet, never a hashtable: a hashtable's .Count and .Keys are SHADOWED by a key of that name,
  # and transcripts say "count" (Doctor Who, Masque of Mandragora: "6/True words (600%)").
  $set = [System.Collections.Generic.HashSet[string]]::new()
  foreach ($m in [regex]::Matches($text.ToLowerInvariant(), "[a-z][a-z']{3,}")) {
    $w = $m.Value.Trim("'") -replace "'s$", ''
    if ($w.Length -ge 4 -and -not $stop.ContainsKey($w)) { [void]$set.Add($w) }
  }
  return , $set   # the comma stops PowerShell unrolling the set into its items
}
function Read-SrtCues([string]$path) {
  $cues = New-Object System.Collections.Generic.List[object]
  $raw = Get-Content -LiteralPath $path -Raw -ErrorAction SilentlyContinue
  if (-not $raw) { return $cues }
  foreach ($blk in ($raw -split "\r?\n\r?\n")) {
    $m = [regex]::Match($blk, '(\d+):(\d+):(\d+)[,.](\d+)\s*-->\s*(\d+):(\d+):(\d+)[,.](\d+)')
    if (-not $m.Success) { continue }
    $s = [int]$m.Groups[1].Value * 3600 + [int]$m.Groups[2].Value * 60 + [int]$m.Groups[3].Value
    $text = ($blk.Substring($m.Index + $m.Length) -replace '<[^>]+>', ' ').Trim()
    $cues.Add([pscustomobject]@{ Start = $s; Text = $text })
  }
  return $cues
}
function Find-Published([string]$showDir, [int]$season, [int]$episode) {
  $tag = 'S{0:D2}E{1:D2}' -f $season, $episode
  $rx = '(?i)(^|[^a-z0-9])' + $tag + '([^0-9]|$)'
  $hits = @()
  foreach ($sd in (Get-ChildItem -LiteralPath $showDir -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '^(?i)(season|series|specials)')) {
    $hits += @(Get-ChildItem -LiteralPath $sd.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $rx -and $_.Extension -in '.mkv', '.mp4', '.m4v', '.avi' })
  }
  return $hits
}

# ---- rows -----------------------------------------------------------------------------------------
$refuted = 0
$counts = @{}
# The claim is the FIRST SxxEyy in the row's NAME field (field 3), wherever it sits in it: "S04E05 The
# One with...", "It's Your Funeral (S01E11)", "Pilot (... proposed S00E01, an IN-PLACE supersede ...)".
# Never the evidence field - "matches published S01E11" there is a citation, not this row's claim.
$claimRx = '^t(\d+)\|([a-z?]+)\|[^|]*?\bS(\d{1,4})E(\d{1,3})\b'
# An extra's name can MENTION an episode ("companion to the ring-loss plot of S04E22 ... proposed
# S00E50"); where a row says "proposed SxxEyy", that is its claim.
function Get-Claim([string]$row) {
  $m = [regex]::Match($row, $claimRx)
  if (-not $m.Success) { return $null }
  $c = [pscustomobject]@{ T = [int]$m.Groups[1].Value; Kind = $m.Groups[2].Value; S = [int]$m.Groups[3].Value; E = [int]$m.Groups[4].Value }
  $pm = [regex]::Match((($row -split '\|')[2]), '(?i)\bproposed\s+S(\d{1,4})E(\d{1,3})\b')
  if ($pm.Success) { $c.S = [int]$pm.Groups[1].Value; $c.E = [int]$pm.Groups[2].Value }
  return $c
}
$lines = @(Get-Content -LiteralPath $dispPath | Where-Object { $_ -match $claimRx })
if (-not $showDirs.Count) {
  Write-Host ("assert-replacement-identity: SHOW NOT RESOLVED for '{0}' - {1} row(s) claiming an SxxEyy were NOT checked against the library. Pass -Show '<library folder>' to check them." -f $Disc, $lines.Count)
  exit 0
}
Write-Host ("assert-replacement-identity: {0} - show folder(s): {1}  (from {2})" -f $Disc, ($showDirs -join ' | '), $showFrom)

function Get-Refs([int]$season, [int]$episode) {
  $out = @()
  foreach ($sd in $showDirs) {
    foreach ($p in @(Find-Published $sd $season $episode)) {
      $base = [IO.Path]::Combine($p.DirectoryName, [IO.Path]::GetFileNameWithoutExtension($p.Name))
      $srt = @("$base.eng.srt", "$base.en.srt", "$base.srt") | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
      $out += [pscustomobject]@{ File = $p; Cues = $(if ($srt) { Read-SrtCues $srt } else { $null }) }
    }
  }
  return $out
}
function Score-Sample($refList, [string]$text, [double]$at) {
  $words = Get-Words $text
  $bestRef = $null
  foreach ($r in @($refList | Where-Object { $_.Cues })) {
    $lo = $at - $WindowPadSec; $hi = $at + 45 + $WindowPadSec
    $near = Get-Words ((@($r.Cues | Where-Object { $_.Start -ge $lo -and $_.Start -le $hi }) | ForEach-Object { $_.Text }) -join ' ')
    $found = @($words | Where-Object { $near.Contains($_) }).Count
    $s = if ($words.Count) { [math]::Round($found / [double]$words.Count, 2) } else { 0.0 }
    if (-not $bestRef -or $s -gt $bestRef.Score) { $bestRef = [pscustomobject]@{ At = $at; Words = $words.Count; Found = $found; Score = $s; File = $r.File.Name; Text = $text } }
  }
  return $bestRef
}

# Every episode claim on this disc, for the CROSSED test below.
$claims = @(foreach ($l in $lines) { $c = Get-Claim $l; if ($c.Kind -ne 'exclude') { $c } })
$refCache = @{}

foreach ($l in $lines) {
  $c0 = Get-Claim $l
  $tn = $c0.T; $kind = $c0.Kind; $se = $c0.S; $ep = $c0.E
  if ($kind -eq 'exclude') { continue }
  $tag = 'S{0:D2}E{1:D2}' -f $se, $ep
  $label = 't{0:D2} {1}' -f $tn, $tag

  if (-not $refCache.ContainsKey($tag)) { $refCache[$tag] = @(Get-Refs $se $ep) }
  $refs = $refCache[$tag]
  if (-not $refs.Count) { $counts['NEW']++; Write-Host "  NEW          $label - the library does not hold this episode; not a replacement"; continue }
  if (-not @($refs | Where-Object { $_.Cues }).Count) { $counts['UNVERIFIABLE']++; Write-Host ("  UNVERIFIABLE {0} - the library holds it ({1}) but it has no .eng.srt to compare against" -f $label, $refs[0].File.Name); continue }

  $title = @($cat.titles) | Where-Object { [int]$_.title -eq $tn } | Select-Object -First 1
  $from = if ($title) { "$($title.speechFrom)" } else { '' }
  $offset = 0.0
  if ($from -match 'offset=(\d+(?:\.\d+)?)s') { $offset = [double]$Matches[1] }
  $durSec = 0
  if ($title -and "$($title.duration)" -match '^(\d+):(\d+):(\d+)$') { $durSec = [int]$Matches[1] * 3600 + [int]$Matches[2] * 60 + [int]$Matches[3] }

  # A SAMPLE IS EVIDENCE ONLY FOR THE SOURCE IT WAS TAKEN FROM. The DVD catalogue picks a dvdvideo
  # title per row, and on a duration tie it can pick the wrong one: The West Wing S4 Disk 2's rows
  # t02 and t04 were sampled from each other's titles, which the dispositions then proved by bytes
  # ("this title is dv3"). The stored sample scored 91% against the OTHER row's episode. When the
  # dispositions carry such a correction, the stored sample is set aside and fresh samples come
  # from the corrected title.
  $useStored = $true
  if ($l -match '(?i)this title is (?:dv|dvdvideo)\s*(\d+)') {
    $dvFixed = $Matches[1]
    if ($from -match 'dvdvideoTitle=(\d+)' -and $Matches[1] -ne $dvFixed) {
      $from = $from -replace 'dvdvideoTitle=\d+', "dvdvideoTitle=$dvFixed"
      $useStored = $false
    }
  }

  $samples = @()
  $stored = ("$($title.speechSample)" -replace '^\s*\[[a-z]{2,3}\s+[\d.]+\]\s*', '')
  if ($useStored -and $title -and "$($title.speechStatus)" -eq 'ok') { $samples += Score-Sample $refs $stored $offset }
  $matched = @($samples | Where-Object { $_.Words -ge $MinWords -and $_.Score -ge $MatchAt })
  if (-not $matched.Count -and -not $NoFreshSamples -and $from) {
    # Fresh samples further in, kept well inside the title (and early enough for a DVD's first cell).
    $points = @(($offset + 240), ($offset + 480))
    if (-not $useStored) { $points = @($offset) + $points }
    foreach ($at in $points) {
      if ($durSec -and $at -gt ($durSec - 60)) { continue }
      $txt = Get-FreshSample $from $at
      if ($txt) { $samples += Score-Sample $refs $txt $at }
      if (@($samples | Where-Object { $_.Words -ge $MinWords -and $_.Score -ge $MatchAt }).Count) { break }
    }
  }
  $informative = @($samples | Where-Object { $_.Words -ge $MinWords })
  $pooled = if ($informative.Count) { [math]::Round(($informative | Measure-Object Found -Sum).Sum / [double]($informative | Measure-Object Words -Sum).Sum, 2) } else { 0.0 }
  $desc = (@($samples | ForEach-Object { '@{0}s {1}/{2} words ({3:P0})' -f $_.At, $_.Found, $_.Words, $_.Score }) -join '; ')
  if (-not $useStored) { $desc = "stored sample set aside (dispositions prove this title is dvdvideo $dvFixed); $desc" }
  $file = $refs[0].File.Name
  if (@($informative | Where-Object { $_.Score -ge $MatchAt }).Count) {
    $counts['MATCH']++; Write-Host "  MATCH        $label - $desc - $file"
    continue
  }

  # CROSSED: the title AS A WHOLE (its informative samples, pooled) matching ANOTHER row's claimed
  # episode says the catalogue sampled the wrong source - a mapping fault the dispositions have not
  # stated - not that this claim is wrong. Reported, not refused. POOLED, never one sample: t11 on
  # FRIENDS_S4_DISC_2 is "The Invitation", a clip show, and one of its samples was a genuine flashback
  # to S04E16 (44%) while the title as a whole matched nothing claimed on the disc.
  $crossed = $null
  foreach ($c in @($claims | Where-Object { $_.T -ne $tn })) {
    if (-not $informative.Count) { break }
    $ctag = 'S{0:D2}E{1:D2}' -f $c.S, $c.E
    if ($ctag -eq $tag) { continue }
    if (-not $refCache.ContainsKey($ctag)) { $refCache[$ctag] = @(Get-Refs $c.S $c.E) }
    $xs = @($informative | ForEach-Object { Score-Sample $refCache[$ctag] $_.Text $_.At } | Where-Object { $_ })
    if (-not $xs.Count) { continue }
    $xp = ($xs | Measure-Object Found -Sum).Sum / [double]($xs | Measure-Object Words -Sum).Sum
    if ($xp -ge $MatchAt) { $crossed = 't{0:D2} {1} ({2:P0} pooled)' -f $c.T, $ctag, $xp; break }
  }

  if ($crossed) {
    $counts['INCONCLUSIVE']++
    Write-Host "  INCONCLUSIVE $label - CROSSED: this row's sample matches $crossed instead; the catalogue's title-to-source mapping for this row is suspect (prove which title is which by bytes, and write 'this title is dvN' in the row) - $desc - $file"
  }
  elseif ($informative.Count -ge 2 -and $pooled -lt $MismatchBelow) {
    $counts['MISMATCH']++; $refuted++
    Write-Host "  MISMATCH     $label - NOT THE PUBLISHED EPISODE: $($informative.Count) independent samples of the disc title match its subtitles at the same point in only $([math]::Round($pooled * 100))% of their distinctive words, pooled, and match no other episode claimed on this disc: $desc - $file"
    $first = $informative[0].Text
    Write-Host ("               disc said: ""{0}""" -f $(if ($first.Length -gt 160) { $first.Substring(0, 160) + '...' } else { $first }))
  }
  elseif (-not $informative.Count) {
    $counts['UNVERIFIABLE']++; Write-Host "  UNVERIFIABLE $label - the library holds it but no sample of the disc title carried $MinWords+ distinctive words ($(if ($desc) { $desc } else { 'no sample' })) - $file"
  }
  else { $counts['INCONCLUSIVE']++; Write-Host "  INCONCLUSIVE $label - $desc - $file" }
}

$summary = (@('MATCH','MISMATCH','INCONCLUSIVE','UNVERIFIABLE','NEW') | ForEach-Object { '{0} {1}' -f [int]$counts[$_], $_ }) -join ', '
if ($refuted) {
  Write-Host ("REFUSED - {0} row(s) claim an episode the library already holds, but the disc title's own speech does not match that episode's published subtitles. Re-identify those titles from content: a title that is NOT the published episode is a different episode (check the disc's episode run for the gap it fills), never 'already published'. ({1})" -f $refuted, $summary)
  exit 2
}
Write-Host "OK - no replacement claim refuted ($summary)"
exit 0
