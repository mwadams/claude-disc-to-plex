<#
.SYNOPSIS
  WRITE a manifest's MEASURABLE fields from the evidence the pipeline already produced, so the
  authoring agent's value for those fields is never the one that ships. Every override is logged in
  the row's own `derived` record. Where the evidence is absent, ambiguous or implausible it changes
  nothing and says why - the gate then refuses exactly as it would have.

REACH FOR THIS WHEN: a manifest has been authored and is about to be gated or encoded - or a gate
  has just refused a field (kind, expectSeconds, expectFrames, audioTracks, audioLangs, commentary,
  audioDescription, subTrack) that a measurement could have settled.

  pwsh -NoProfile -File derive-manifest-fields.ps1 -Manifest D:/video/_pending/x.json [-AudioOnly] [-Ledger D:/video/_queue/.gated.jsonl] [-WhatIf]

.WHY THIS EXISTS
  The per-disc agent authors every field of a manifest, including ones a machine has already
  measured, and for months each wrong field got a new guard that REFUSED the manifest afterwards
  while the agent carried on authoring the field. The refusals were right and the quality stayed
  poor: every refusal is a re-authoring run, and every field no guard happens to police ships.

  2026-09-19, Friends Season 8 Disc 2, one manifest, two refusals and one silent loss:
    - `audioTracks: [0]` on S08E23 dropped the cast commentary that analyze-tracks.py had CONFIRMED
      (role "commentary") and PROPOSED in <src>.tracks.json. The analyzer proposed; nothing applied
      the proposal. The same shape had already published ~16 Friends episodes without their
      commentaries (S3-S8) - see _reviews/2026-09-19-manifest-derivation.md.
    - `kind: "BD"` on three 720x480 extras. transcode.ps1's preflight MEASURED the resolution,
      printed the exact remedy ("set kind MKV"), and aborted instead of applying it.
  And fix-manifest-expectations.ps1 exists because authors wrote the wrong expectSeconds three
  times (Friends S1 D1, The Rubber-Keyed Wonder D2, Friends S6 D1). Its logic is absorbed here.

.WHAT IT DERIVES (and what it will NOT)
  kind           file source, kind BD|MKV: SD raster (<=720x576) -> MKV, HD -> BD. DVD folders,
                 STILLS and anything unprobeable are untouched.
  expectSeconds  file source, no `title`: the source's container duration - ONLY when the author's
                 figure is within -MaxDeltaSeconds (the clerical class). A bigger gap is an IDENTITY
                 question (wrong clip / wrong title) and is left for the gate. A figure that matches
                 the source's last video or audio packet (a container that outlasts its programme)
                 is left alone. DVD rows (folder + `title`) are corrected the same way from
                 _catalogue/<unit>.evidence.json. An ABSENT expectSeconds is never filled: the
                 author's duration is also the claim of which title this is.
  expectFrames   the source's video PACKET count (halved for field-coded H.264 - each field is its
                 own packet), or evidence.json's measured count for a DVD title - written only when
                 expectSeconds agrees with the same source, i.e. identity is already settled.
  audio fields   from <src>.tracks.json (analyze-tracks.py), when present, fresh and plausible:
                   - a confirmed `commentary` / `audioDescription` stream the row drops is ADDED and
                     tagged ("Audio Commentary" / "Audio Description" - an author's own title wins);
                   - a kept `redundant` stream is replaced by the stream it copies;
                   - a commentary tag on a stream measured as a dub / primary / music is removed; a
                     commentary tag on a measured audio-description stream becomes audioDescription;
                   - a commentary or AD stream in FIRST position (= default) is moved behind the primary;
                   - audioLangs is set from the SPOKEN language where the analysis marks it reliable
                     (music -> zxx); an author's code that already means that language is kept.
                 It never writes `notCommentary`, never decides a `commentary?` (commentaryUncertain)
                 stream, never drops a stream the author chose to keep for preference (a dub), and
                 never acts on evidence that is internally implausible (a "commentary" wider than
                 the primary - the Farscape S1 D6 inversion). An author's `notCommentary` on a
                 confirmed commentary is honoured as an explicit decision and reported.
  subTrack       a numeric ordinal on a raw Blu-ray .m2ts -> "eng" (the streams are untagged;
                 transcode.ps1 resolves "eng" from the disc's CLPI - Friends S3 D1's `subTrack: 0`
                 was Japanese). On a tagged file, an ordinal whose stream is tagged a NON-English
                 language -> "eng", if an English-tagged stream exists. "none" is never touched.

  src            REPORTED, never changed: a MakeMKV rip (`<unit>-rip/..._tNN.mkv`) of a playlist whose
                 clip is also served by another playlist with MORE English audio - the commentary-door
                 shape that cost Friends 16 commentaries. Swapping the source is a human's call.

  Judgement fields - out, title, plexTitle, supersedes, staleSidecar, notCommentary, commentary
  TITLES, dar, deinterlace, crop, the STILLS fields - are never written.

.THE `derived` RECORD
  Each row that changed gains (or extends) `derived`: a list of runs, each
  { at, by, mode, changes: [ {field, from, to, evidence} ], left: [ {field, reason} ] }.
  A run that changes nothing writes nothing, so the file (and its gate-ledger hash) is stable.

.LEDGER
  lane-runner.ps1 refuses a manifest whose SHA256 is not in _queue/.gated.jsonl. With -Ledger, a
  derivation that rewrites a manifest whose PREVIOUS hash is in the ledger appends a ledger entry for
  the new content (how = "derived:<old hash prefix>"), so a derived manifest returned to the queue on
  an evidence deferral is still recognised. A manifest that was never gated gains nothing.

.EXIT CODES
  0 = done (fields derived, or nothing to derive)
  2 = done, but at least one measurable field disagrees in a way this script must not settle
      (named in the output) - the gate is expected to refuse it
  3 = could not run (no manifest, unreadable JSON, no ffprobe)
#>
param(
  [Parameter(Mandatory)][string]$Manifest,
  # Audio fields only: pure JSON reads, no probing. For lane-runner, which re-runs on every
  # deferral pass while the analyse track catches up.
  [switch]$AudioOnly,
  [string]$Ledger,
  [double]$MaxDeltaSeconds = 3.0,
  [double]$ToleranceSeconds = 0.50,       # matches assert-expectations-match-source.ps1
  [string]$ToolsDir = 'D:/video/.transcode-tools',
  [string]$CatalogueDir = 'D:/video/_catalogue',
  [switch]$WhatIf
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Manifest -PathType Leaf)) { Write-Output "derive-manifest-fields: no manifest at $Manifest"; exit 3 }
$raw = Get-Content -LiteralPath $Manifest -Raw
try { $doc = $raw | ConvertFrom-Json } catch { Write-Output "derive-manifest-fields: $Manifest is not readable JSON"; exit 3 }
$oldHash = (Get-FileHash -LiteralPath $Manifest -Algorithm SHA256).Hash
# ConvertFrom-Json UNWRAPS a one-element array; keep the shape we were given.
$shape = if ($doc -is [array]) { 'array' } elseif ($null -ne $doc -and $doc.PSObject.Properties.Name -contains 'outputs') { 'outputs' } else { 'single' }
$rows = switch ($shape) { 'array' { @($doc) } 'outputs' { @($doc.outputs) } default { @($doc) } }

. "$PSScriptRoot/lib-audio-evidence.ps1"
if (-not (Get-Command Get-AudioEvidencePath -ErrorAction SilentlyContinue)) {
  Write-Output 'derive-manifest-fields: lib-audio-evidence.ps1 did not load - refusing to derive with half a library'; exit 3
}

$ffprobe = $null
if (-not $AudioOnly) {
  try { $ffprobe = Join-Path (Split-Path ((Get-Content (Join-Path $ToolsDir 'tool-paths.json') -Raw | ConvertFrom-Json).ffmpeg)) 'ffprobe.exe' } catch { }
  if (-not $ffprobe -or -not (Test-Path -LiteralPath $ffprobe)) { Write-Output 'derive-manifest-fields: ffprobe not found - nothing measured, nothing changed'; exit 3 }
}

# --------------------------------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------------------------------
function Has($o, [string]$n) { $null -ne $o -and $o.PSObject.Properties.Name -contains $n -and $null -ne $o.$n -and "$($o.$n)" -ne '' }
function Set-Field($o, [string]$n, $v) { $o | Add-Member -NotePropertyName $n -NotePropertyValue $v -Force }
function Get-Text($o, [string]$n) { if (Has $o $n) { "$($o.$n)".Trim() } else { '' } }
function Show($v) { if ($null -eq $v) { return '(absent)' }; return (ConvertTo-Json -InputObject $v -Compress -Depth 6) }

# whisper speaks ISO 639-1, discs and mkv want 639-2. MIRRORS assert-tracks-analysed.ps1's
# Get-LanguageMatchSet and analyze-tracks.py's ISO2TO3 - keep all three identical.
$Iso2to3 = @{
  'en' = 'eng'; 'es' = 'spa'; 'fr' = 'fra'; 'de' = 'deu'; 'pt' = 'por'; 'it' = 'ita'; 'nl' = 'nld'
  'ja' = 'jpn'; 'zh' = 'zho'; 'ru' = 'rus'; 'sv' = 'swe'; 'da' = 'dan'; 'no' = 'nor'; 'fi' = 'fin'
  'pl' = 'pol'; 'cs' = 'ces'; 'hu' = 'hun'; 'tr' = 'tur'; 'ko' = 'kor'; 'ar' = 'ara'; 'he' = 'heb'
  'el' = 'ell'; 'th' = 'tha'; 'hi' = 'hin'; 'uk' = 'ukr'; 'ro' = 'ron'; 'ca' = 'cat'
}
$AltCode = @{ 'fra' = 'fre'; 'deu' = 'ger'; 'nld' = 'dut'; 'ces' = 'cze'; 'ell' = 'gre'; 'zho' = 'chi'; 'ron' = 'rum' }
function Get-SpokenCode([string]$spoken) {
  $two = "$spoken".ToLowerInvariant(); if ($two.Length -gt 2) { $two = $two.Substring(0, 2) }
  if ($Iso2to3.ContainsKey($two)) { return $Iso2to3[$two] } else { return $null }
}
function Test-SameLanguage([string]$declared, [string]$three) {
  $d = "$declared".ToLowerInvariant(); if (-not $d -or -not $three) { return $false }
  $two = ($Iso2to3.GetEnumerator() | Where-Object { $_.Value -eq $three } | Select-Object -First 1).Key
  $set = @($three, $two); if ($AltCode.ContainsKey($three)) { $set += $AltCode[$three] }
  return ($set -contains $d)
}

function Probe-Json([string[]]$ffArgs) {
  $out = (& $ffprobe @ffArgs 2>$null) -join "`n"
  if ($LASTEXITCODE -ne 0 -or -not "$out".Trim()) { return $null }
  try { return ($out | ConvertFrom-Json) } catch { return $null }
}
function Get-VideoFacts([string]$src) {
  $j = Probe-Json @('-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=codec_name,width,height,field_order,avg_frame_rate,r_frame_rate:format=duration', '-of', 'json', $src)
  if ($null -eq $j) { return $null }
  $s = @($j.streams)[0]
  $fps = 0.0
  foreach ($k in 'avg_frame_rate', 'r_frame_rate') {
    if ($s -and "$($s.$k)" -match '^(\d+)/(\d+)$' -and [double]$Matches[2] -ne 0 -and [double]$Matches[1] -gt 0) { $fps = [double]$Matches[1] / [double]$Matches[2]; break }
  }
  $dur = 0.0; if ($j.format) { [void][double]::TryParse("$($j.format.duration)", [ref]$dur) }
  return [pscustomobject]@{
    Codec = "$($s.codec_name)"; Width = [int]$s.width; Height = [int]$s.height
    FieldOrder = "$($s.field_order)"; Fps = $fps; Duration = $dur
  }
}
function Get-VideoPackets([string]$src) {
  $j = Probe-Json @('-v', 'error', '-count_packets', '-select_streams', 'v:0', '-show_entries', 'stream=nb_read_packets', '-of', 'json', $src)
  if ($null -eq $j) { return 0 }
  $n = 0; [void][int]::TryParse("$(@($j.streams)[0].nb_read_packets)", [ref]$n); return $n
}
function Get-StreamEnds([string]$src, [double]$dur) {
  # The last video and audio packet: a container can outlast its programme (Friends S7 D2 t06, a PGS
  # stream declaring a minute past the A/V). Same probe as assert-expectations-match-source.ps1.
  $ends = @{ v = 0.0; a = 0.0 }
  $from = [math]::Max(0, $dur - 120)
  foreach ($sel in 'v:0', 'a:0') {
    $pts = @(& $ffprobe -v error -select_streams $sel -read_intervals ("{0}%+#100000" -f [int]$from) -show_entries packet=pts_time -of csv=p=0 $src 2>$null |
             Where-Object { $_ -match '^[0-9]+(\.[0-9]+)?$' })
    if ($pts.Count) { $ends[$sel.Substring(0, 1)] = [double]$pts[-1] }
  }
  return $ends
}
function Get-SubtitleLangs([string]$src) {
  $j = Probe-Json @('-v', 'error', '-select_streams', 's', '-show_entries', 'stream=index:stream_tags=language', '-of', 'json', $src)
  if ($null -eq $j) { return $null }
  return @(@($j.streams) | ForEach-Object { if ($_.tags -and $_.tags.language) { "$($_.tags.language)".ToLowerInvariant() } else { '' } })
}
function Get-UnitEvidenceTitle([string]$src, $title) {
  # DVD row: src is D:/video/_stage/<unit>; disposition-evidence.ps1 measured each dvdvideoTitle.
  $unit = Split-Path ($src.TrimEnd('/', '\')) -Leaf
  $ev = Join-Path $CatalogueDir ($unit + '.evidence.json')
  if (-not (Test-Path -LiteralPath $ev)) { return $null }
  try { $e = Get-Content -LiteralPath $ev -Raw | ConvertFrom-Json } catch { return $null }
  $mine = @($e.titles) | Where-Object { "$($_.dvdvideoTitle)" -eq "$title" -and $_.measured } | Select-Object -First 1
  if (-not $mine) { return $null }
  return [pscustomobject]@{ Title = $mine; Others = @(@($e.titles) | Where-Object { "$($_.dvdvideoTitle)" -ne "$title" -and $_.measured -and $_.expectSeconds }) }
}
function Get-Entries($v) {
  # commentary / audioDescription: an ordinal, a list of ordinals, or [idx,"Title"] pairs.
  $list = @()
  if ($null -eq $v) { return $list }
  $items = @($v)
  # a bare pair [5,"Title"] arrives as a flat array of (int, string)
  if ($items.Count -eq 2 -and $items[0] -isnot [array] -and $items[1] -is [string]) {
    return @([pscustomobject]@{ Idx = [int]$items[0]; Title = "$($items[1])" })
  }
  foreach ($e in $items) {
    if ($e -is [array]) { $list += [pscustomobject]@{ Idx = [int]$e[0]; Title = $(if ($e.Count -gt 1) { "$($e[1])" } else { '' }) } }
    else { $list += [pscustomobject]@{ Idx = [int]$e; Title = '' } }
  }
  return $list
}
function ConvertTo-PairList($entries, [string]$default) {
  $out = New-Object System.Collections.ArrayList
  foreach ($e in $entries) { [void]$out.Add(@([int]$e.Idx, $(if ($e.Title) { $e.Title } else { $default }))) }
  return , $out.ToArray()
}

# --------------------------------------------------------------------------------------------------
# per row
# --------------------------------------------------------------------------------------------------
$now = Get-Date -Format 'yyyy-MM-ddTHH:mm:ss'
$totalChanges = 0; $unsettled = 0
foreach ($r in $rows) {
  $changes = New-Object System.Collections.ArrayList
  $left = New-Object System.Collections.ArrayList
  $leaf = Split-Path (Get-Text $r 'out') -Leaf
  $kind = Get-Text $r 'kind'
  $src = Get-Text $r 'src'
  $srcWin = $src -replace '/', '\'
  $isFile = $src -and (Test-Path -LiteralPath $srcWin -PathType Leaf)
  $isDir = $src -and (Test-Path -LiteralPath $srcWin -PathType Container)
  $ext = if ($isFile) { [IO.Path]::GetExtension($srcWin).ToLowerInvariant() } else { '' }
  $isMedia = $isFile -and ($ext -notin @('.txt', '.json', '.md', '.csv', '.xml'))
  $hasTitle = (Get-Text $r 'title') -ne ''
  $partial = (Has $r 'chapterStart') -or (Has $r 'chapterEnd') -or (Has $r 'vobSectors')

  if (-not $AudioOnly -and $kind -ne 'STILLS') {
    $vf = if ($isMedia) { Get-VideoFacts $srcWin } else { $null }

    # ---- kind --------------------------------------------------------------------------------
    if ($vf -and $vf.Width -gt 0 -and $kind -in @('BD', 'MKV')) {
      $sd = ($vf.Width -le 720 -and $vf.Height -le 576)
      $want = if ($sd) { 'MKV' } else { 'BD' }
      if ($want -ne $kind) {
        [void]$changes.Add([ordered]@{ field = 'kind'; from = $kind; to = $want; evidence = ("ffprobe v:0 {0}x{1} - {2} source" -f $vf.Width, $vf.Height, $(if ($sd) { 'standard-definition' } else { 'high-definition' })) })
        Set-Field $r 'kind' $want; $kind = $want
      }
    }

    # ---- expectSeconds / expectFrames --------------------------------------------------------
    $secondsSettled = $false
    $measSec = 0.0; $measFrames = 0; $frameBasis = ''
    if ($vf -and -not $hasTitle -and $vf.Duration -gt 0) {
      $measSec = $vf.Duration; $frameBasis = 'file'
    } elseif ($isDir -and $hasTitle -and $kind -eq 'DVD' -and -not $partial) {
      $etAll = Get-UnitEvidenceTitle $src (Get-Text $r 'title')
      $et = if ($etAll) { $etAll.Title } else { $null }
      if ($et -and $et.expectSeconds) { $measSec = [double]$et.expectSeconds; $measFrames = [int]$et.expectFrames; $frameBasis = 'evidence' }
    }
    if ($measSec -gt 0) {
      $expSec = 0.0
      if ((Has $r 'expectSeconds') -and [double]::TryParse((Get-Text $r 'expectSeconds'), [ref]$expSec) -and $expSec -gt 0) {
        $delta = $expSec - $measSec
        if ([math]::Abs($delta) -le $ToleranceSeconds) { $secondsSettled = $true }
        else {
          $endMatch = $null
          if ($frameBasis -eq 'file') {
            $ends = Get-StreamEnds $srcWin $measSec
            foreach ($k in 'v', 'a') { if ($ends[$k] -gt 0 -and [math]::Abs($expSec - $ends[$k]) -le ($ToleranceSeconds + 0.05)) { $endMatch = $k } }
          }
          if ($endMatch) {
            $secondsSettled = $true
            [void]$left.Add([ordered]@{ field = 'expectSeconds'; reason = ("{0:N3}s matches the source's last {1} packet, not its {2:N3}s container - a container that outlasts its programme; left as authored" -f $expSec, $(if ($endMatch -eq 'v') { 'video' } else { 'audio' }), $measSec) })
          } elseif ($frameBasis -eq 'evidence' -and @($etAll.Others | Where-Object { [math]::Abs([double]$_.expectSeconds - $expSec) -lt [math]::Abs($delta) }).Count) {
            # ANOTHER TITLE FITS THE AUTHORED FIGURE BETTER. Equal-length episodes sit seconds apart,
            # so "correcting" the figure to the authored title would erase the only signal
            # assert-dvd-title-numbering.ps1 has for an off-by-one title (Tales of the Unexpected S4).
            $better = @($etAll.Others | Sort-Object { [math]::Abs([double]$_.expectSeconds - $expSec) } | Select-Object -First 1)[0]
            $unsettled++
            [void]$left.Add([ordered]@{ field = 'expectSeconds'; reason = ("authored {0:N3}s; title {1} measures {2:N3}s but title {3} measures {4:N3}s, closer - a title-NUMBERING question, not arithmetic. Not changed" -f $expSec, (Get-Text $r 'title'), $measSec, $better.dvdvideoTitle, [double]$better.expectSeconds) })
          } elseif ([math]::Abs($delta) -le $MaxDeltaSeconds) {
            $to = [double][math]::Round($measSec, 3)
            [void]$changes.Add([ordered]@{ field = 'expectSeconds'; from = $expSec; to = $to; evidence = $(if ($frameBasis -eq 'file') { "source container duration (ffprobe format=duration), author off by {0:+0.000;-0.000}s" -f $delta } else { "evidence.json dvdvideoTitle $(Get-Text $r 'title') measured {0:N3}s, author off by {1:+0.000;-0.000}s" -f $measSec, $delta }) })
            Set-Field $r 'expectSeconds' $to; $secondsSettled = $true
          } else {
            $unsettled++
            [void]$left.Add([ordered]@{ field = 'expectSeconds'; reason = ("authored {0:N3}s, source measures {1:N3}s ({2:+0.000;-0.000}s) - past the {3:N1}s clerical allowance, so this is an IDENTITY question (wrong clip or title), not arithmetic. Not changed; the gate refuses it" -f $expSec, $measSec, $delta, $MaxDeltaSeconds) })
          }
        }
      } else {
        [void]$left.Add([ordered]@{ field = 'expectSeconds'; reason = 'absent - never filled: the authored duration is also the claim of WHICH title this row is' })
      }

      if ($secondsSettled) {
        if ($frameBasis -eq 'file') {
          $fields = ($vf.FieldOrder -match '^(tt|bb|tb|bt)$') -and ($vf.Codec -eq 'h264')
          $pk = 0
          $expF = 0; $haveF = (Has $r 'expectFrames') -and [int]::TryParse(((Get-Text $r 'expectFrames') -replace '\.0+$', ''), [ref]$expF) -and $expF -gt 0
          $pk = Get-VideoPackets $srcWin
          if ($pk -gt 0) {
            # PAFF: each FIELD is a packet, so the packet rate is twice the frame rate.
            $isPaff = $fields -and $vf.Fps -gt 0 -and [math]::Abs(($pk / [math]::Max(0.001, $measSec)) - 2 * $vf.Fps) -le 0.02 * 2 * $vf.Fps
            $measFrames = if ($isPaff) { [int][math]::Floor($pk / 2) } else { $pk }
            $basis = if ($isPaff) { "source v:0 packet count $pk halved - field-coded H.264 (field_order $($vf.FieldOrder)) carries one packet per FIELD" } else { "source v:0 packet count (ffprobe -count_packets)" }
            if (-not $haveF) {
              [void]$changes.Add([ordered]@{ field = 'expectFrames'; from = $null; to = $measFrames; evidence = $basis })
              Set-Field $r 'expectFrames' $measFrames
            } elseif ($expF -ne $measFrames) {
              $slack = [math]::Max(1, [int]($MaxDeltaSeconds * [math]::Max(1, $vf.Fps)))
              if ([math]::Abs($expF - $measFrames) -le $slack -or ($isPaff -and $expF -eq $pk)) {
                [void]$changes.Add([ordered]@{ field = 'expectFrames'; from = $expF; to = $measFrames; evidence = $basis })
                Set-Field $r 'expectFrames' $measFrames
              } else {
                $unsettled++
                [void]$left.Add([ordered]@{ field = 'expectFrames'; reason = "authored $expF, source measures $measFrames - further apart than the seconds agreement allows; not changed" })
              }
            }
          }
        } elseif ($frameBasis -eq 'evidence' -and $measFrames -gt 0) {
          $expF = 0; $haveF = (Has $r 'expectFrames') -and [int]::TryParse(((Get-Text $r 'expectFrames') -replace '\.0+$', ''), [ref]$expF) -and $expF -gt 0
          if (-not $haveF -or $expF -ne $measFrames) {
            $slack = [int]($MaxDeltaSeconds * 30)
            if (-not $haveF -or [math]::Abs($expF - $measFrames) -le $slack) {
              [void]$changes.Add([ordered]@{ field = 'expectFrames'; from = $(if ($haveF) { $expF } else { $null }); to = $measFrames; evidence = "evidence.json dvdvideoTitle $(Get-Text $r 'title') emitted video packets" })
              Set-Field $r 'expectFrames' $measFrames
            } else {
              $unsettled++
              [void]$left.Add([ordered]@{ field = 'expectFrames'; reason = "authored $expF, evidence.json measures $measFrames; not changed" })
            }
          }
        }
      }
    }

    # ---- a RIP that cannot carry the disc's extra audio ----------------------------------------
    # A Blu-ray serves one clip through several playlists. Friends ships each commentary episode's
    # clip under its main playlist (English 5.1 + dubs) AND a "commentary door" playlist (4x English
    # 2.0). MakeMKV rips a PLAYLIST, so `_tNN.mkv` of the main playlist physically lacks the
    # commentary - analyze-tracks.py measures the rip, finds none, and every check downstream agrees.
    # 16 published Friends episodes lost their commentaries this way (S3-S8). Nothing here can
    # substitute the source (ordinals and evidence would all change), so it is named for the gate.
    if ($isMedia -and $src -match '[\\/]([^\\/]+)-rip[\\/][^\\/]*_t(\d+)\.mkv$') {
      $ripUnit = ($Matches[1].ToLowerInvariant() -replace '[^a-z0-9]', ''); $ripT = [int]$Matches[2]
      $catFile = Get-ChildItem -LiteralPath $CatalogueDir -Filter '*.catalogue.json' -File -ErrorAction SilentlyContinue |
                 Where-Object { ($_.Name.Substring(0, $_.Name.Length - 15).ToLowerInvariant() -replace '[^a-z0-9]', '') -eq $ripUnit } | Select-Object -First 1
      if ($catFile) {
        try { $cat = Get-Content -LiteralPath $catFile.FullName -Raw | ConvertFrom-Json } catch { $cat = $null }
        $ct = if ($cat) { @($cat.titles) | Where-Object { [int]$_.title -eq $ripT } | Select-Object -First 1 } else { $null }
        if ($ct -and $ct.probeFile) {
          $engOf = { param($t) @(@($t.streams) | Where-Object { $_.type -eq 'Audio' -and "$($_.lang)" -in @('English', '') }).Count }
          $mine = & $engOf $ct
          $clip = Split-Path "$($ct.probeFile)" -Leaf
          $richer = @(@($cat.titles) | Where-Object { [int]$_.title -ne $ripT -and $_.probeFile -and (Split-Path "$($_.probeFile)" -Leaf) -eq $clip -and (& $engOf $_) -gt $mine })
          # SWAP TO THE RAW CLIP WHEN THAT IS PROVABLY THE SAME PROGRAMME - the step the gate kept
          # handing to a human (Friends S10 D2 "The Last One", 2026-09-19, fixed by hand the same way).
          # Proven means: the raw clip is staged, its OWN A/V length (last video packet minus its start
          # timestamp - a raw BD clip does not start at 0, and its format=duration can be wrong) matches
          # this row's expectSeconds within 1.5 s, and the playlist's first audio stream is English, so
          # audioTracks [0] still names the programme. The audio evidence is then measured on the clip
          # and the audio pass (here or in lane-runner) adds the commentary. Anything unproven still
          # escalates below, unchanged.
          $swapped = $false
          $unitName = $catFile.Name.Substring(0, $catFile.Name.Length - 15)
          $rawClip = (Join-Path (Join-Path (Join-Path (Join-Path (Split-Path (Split-Path $srcWin -Parent) -Parent) $unitName) 'BDMV') 'STREAM') $clip) -replace '\\', '/'
          $firstAud = @(@($ct.streams) | Where-Object { $_.type -eq 'Audio' }) | Select-Object -First 1
          $expRow = 0.0; [void][double]::TryParse("$(Get-Text $r 'expectSeconds')", [ref]$expRow)
          if ($richer.Count -and $expRow -gt 0 -and $firstAud -and "$($firstAud.lang)" -eq 'English' -and (Test-Path -LiteralPath $rawClip -PathType Leaf)) {
            $st0 = 0.0; $stTxt = "$(& $ffprobe -v error -show_entries format=start_time -of csv=p=0 $rawClip 2>$null | Select-Object -First 1)".Trim()
            if ($stTxt -match '^[0-9]+(\.[0-9]+)?$') { $st0 = [double]$stTxt }
            $pts = @(& $ffprobe -v error -select_streams v:0 -read_intervals ("{0}%+#100000" -f [int]($st0 + [math]::Max(0, $expRow - 120))) -show_entries packet=pts_time -of csv=p=0 $rawClip 2>$null | Where-Object { $_ -match '^[0-9]+(\.[0-9]+)?$' })
            $clipLen = if ($pts.Count) { [double]$pts[-1] - $st0 } else { 0.0 }
            if ($clipLen -gt 0 -and [math]::Abs($clipLen - $expRow) -le 1.5) {
              [void]$changes.Add([ordered]@{ field = 'src'; from = $src; to = $rawClip; evidence = ("rip of t{0:D2} ({1}) cannot carry the English audio that {2} serve over the SAME clip {3}; the raw clip's A/V length {4:N3}s matches expectSeconds {5:N3}s, first audio English" -f $ripT, $ct.source, (($richer | ForEach-Object { "t{0:D2} {1}" -f [int]$_.title, $_.source }) -join ', '), $clip, $clipLen, $expRow) })
              Set-Field $r 'src' $rawClip
              Set-Field $r 'audioTracks' @(0); Set-Field $r 'audioLangs' @('eng')
              if ((Get-Text $r 'subTrack') -match '^\d+$') { Set-Field $r 'subTrack' 'eng' }
              if ($r.PSObject.Properties.Name -contains 'expectFrames') { $r.PSObject.Properties.Remove('expectFrames') }
              $src = $rawClip; $srcWin = $rawClip -replace '/', '\'; $ext = '.m2ts'
              $swapped = $true
            }
          }
          if ($richer.Count -and -not $swapped) {
            $unsettled++
            [void]$left.Add([ordered]@{ field = 'src'; reason = ("this is a rip of t{0:D2} ({1}, {2} English audio stream(s)); the SAME clip {3} is also served by {4} with MORE English audio ({5}). The rip cannot carry those streams - a commentary door looks exactly like this. Encode from the raw clip (BDMV/STREAM/{3}) or rip the other playlist; a human decides" -f $ripT, $ct.source, $mine, $clip, (($richer | ForEach-Object { "t{0:D2} {1}" -f [int]$_.title, $_.source }) -join ', '), (($richer | ForEach-Object { (& $engOf $_) }) -join '/')) })
          }
        }
      }
    }

    # ---- subTrack ------------------------------------------------------------------------------
    $st = Get-Text $r 'subTrack'
    if ($isMedia -and $st -match '^\d+$') {
      if ($ext -eq '.m2ts') {
        [void]$changes.Add([ordered]@{ field = 'subTrack'; from = [int]$st; to = 'eng'; evidence = 'raw Blu-ray .m2ts: subtitle streams carry no language tags, so an ordinal is unverifiable; "eng" is resolved by transcode.ps1 from the disc''s CLPI declaration (and aborts if none is English)' })
        Set-Field $r 'subTrack' 'eng'
      } else {
        $langs = Get-SubtitleLangs $srcWin
        if ($null -ne $langs -and [int]$st -lt $langs.Count) {
          $tag = $langs[[int]$st]
          $englishExists = @($langs | Where-Object { $_ -in @('eng', 'en') }).Count -gt 0
          if ($tag -and $tag -notin @('eng', 'en', 'und') -and $englishExists) {
            [void]$changes.Add([ordered]@{ field = 'subTrack'; from = [int]$st; to = 'eng'; evidence = "s:$st is tagged '$tag' on the source; an English-tagged stream exists" })
            Set-Field $r 'subTrack' 'eng'
          }
        }
      }
    }
  }

  # ---- audio -----------------------------------------------------------------------------------
  $names = $r.PSObject.Properties.Name
  $titleArg = if ($hasTitle) { $r.title } else { $null }
  $evPath = if ($src) { Get-AudioEvidencePath -Src $srcWin -Title $titleArg } else { $null }
  $ev = $null
  if ($evPath -and (Test-Path -LiteralPath $evPath)) {
    $fresh = $true
    if ($isFile -and (Get-Item -LiteralPath $evPath).LastWriteTime -le (Get-Item -LiteralPath $srcWin).LastWriteTime) { $fresh = $false }
    if ($fresh) { try { $ev = Get-Content -LiteralPath $evPath -Raw | ConvertFrom-Json } catch { $ev = $null } }
    else { [void]$left.Add([ordered]@{ field = 'audio'; reason = "$(Split-Path $evPath -Leaf) predates its source - stale evidence describes other streams; not used" }) }
  }
  if ($ev -and $partial) {
    # The evidence was sampled across the WHOLE title; this row plays a chapter range or a sector
    # carve of it (Porco Rosso's trailer is chapter 6 of a 13-trailer reel). What the title carries
    # is not evidence of what the excerpt carries.
    [void]$left.Add([ordered]@{ field = 'audio'; reason = 'row plays part of a title (chapterStart/chapterEnd/vobSectors); the whole-title evidence is not applied to it' })
    $ev = $null
  }
  if ($ev -and @($ev.streams).Count -gt 0) {
    $by = @{}; foreach ($s in @($ev.streams)) { $by[[int]$s.a] = $s }
    $primary = @($ev.streams | Where-Object { $_.role -eq 'primary' }) | Select-Object -First 1
    # PLAUSIBILITY. A "commentary" wider than the programme mix is the inverted-evidence shape
    # (Farscape S1 D6: the 5.1 episode came out `commentary`). Mono programme + <=2.0 commentary is
    # the ordinary archive-TV shape and is fine. Acting on inverted evidence would label the
    # programme a commentary AND defeat the gate's own channel check, so derive nothing.
    $implausible = ''
    # No primary is ordinary for a score-only title (Robin of Sherwood's opening-titles extras: one
    # 'music' stream). It only blocks derivation when there is a commentary or description to place
    # behind a programme track that the analysis could not find.
    $placed = @($ev.streams | Where-Object { $_.role -in @('commentary', 'audioDescription') })
    if (-not $primary) { if ($placed.Count) { $implausible = 'the analysis elected no primary stream, yet names a commentary/description to place behind one' } }
    else {
      foreach ($s in @($ev.streams | Where-Object { $_.role -in @('commentary', 'audioDescription') })) {
        $monoMain = ([int]$primary.channels -eq 1 -and [int]$s.channels -le 2)
        if ([int]$s.channels -gt [int]$primary.channels -and -not $monoMain) { $implausible = "a:$($s.a) is '$($s.role)' with $($s.channels) channels against the primary a:$($primary.a)'s $($primary.channels) - inverted evidence" }
      }
    }
    if ($implausible) {
      $unsettled++
      [void]$left.Add([ordered]@{ field = 'audio'; reason = "evidence not acted on: $implausible. Re-read the transcripts; the gate decides" })
    } else {
      # NOT `$x = if (...) { @(...) }`: an `if` used as an expression UNROLLS its output, so a
      # one-element list comes back as a scalar and [0] would compare unequal to [0].
      $origTracks = $null; $origLangs = $null
      # Reset PER ROW. A leftover from the previous title would attach its reorder evidence to a row
      # that was never reordered - the same stale-value shape that made one artefact's hold read as
      # another's silence in _reclaim-loop.ps1.
      $audioReordered = ''
      if ($names -contains 'audioTracks' -and $null -ne $r.audioTracks) { $origTracks = [int[]]@($r.audioTracks | ForEach-Object { [int]$_ }) }
      if (Has $r 'audioLangs') { $origLangs = [string[]]@($r.audioLangs | ForEach-Object { "$_" }) }
      $origComm = $null; if ($names -contains 'commentary') { $origComm = $r.commentary }
      $origAd = $null; if ($names -contains 'audioDescription') { $origAd = $r.audioDescription }
      $langFor = @{}
      # `$null -ne`, not truthiness: @(0) - the commonest audioTracks of all - is FALSY in PowerShell.
      if ($null -ne $origTracks -and $null -ne $origLangs) { for ($i = 0; $i -lt [math]::Min($origTracks.Count, $origLangs.Count); $i++) { $langFor[$origTracks[$i]] = $origLangs[$i] } }
      $comm = @(Get-Entries $r.commentary)
      $ad = @(Get-Entries $r.audioDescription)
      # untouched copies for the before/after comparison - the remap below edits $comm/$ad in place
      $origCommEntries = @(Get-Entries $r.commentary)
      $origAdEntries = @(Get-Entries $r.audioDescription)
      $rejected = @(); if ($names -contains 'notCommentary' -and $null -ne $r.notCommentary) { $rejected = @($r.notCommentary | ForEach-Object { [int]$_ }) }

      if ($null -eq $origTracks) {
        # No claim at all = transcode's automatic pick, which treats untagged Blu-ray audio as
        # English and keeps every dub. The analyzer's keep-set is strictly better.
        $tracks = @($ev.streams | Where-Object { $_.role -in @('primary', 'commentary', 'commentary?', 'audioDescription', 'alternateMix', 'music') } | ForEach-Object { [int]$_.a })
        if ($tracks.Count) { [void]$changes.Add([ordered]@{ field = 'audioTracks'; from = $null; to = $tracks; evidence = "no audioTracks authored (automatic pick keeps untagged dubs); analysis keep-set from $(Split-Path $evPath -Leaf)" }) }
      } else {
        $tracks = New-Object System.Collections.ArrayList; foreach ($t in $origTracks) { [void]$tracks.Add($t) }
      }
      $tracks = [System.Collections.ArrayList]@($tracks)
      $remap = @{}

      # 1. a kept REDUNDANT stream (lossy core / duplicate) -> the stream it copies.
      foreach ($t in @($tracks)) {
        $s = $by[[int]$t]
        if ($s -and $s.role -eq 'redundant' -and $null -ne $s.redundantWith) {
          $orig = [int]$s.redundantWith
          if ($tracks -contains $orig) { $tracks.Remove($t) } else { $tracks[$tracks.IndexOf($t)] = $orig }
          $remap[[int]$t] = $orig
          if ($langFor.ContainsKey([int]$t) -and -not $langFor.ContainsKey($orig)) { $langFor[$orig] = $langFor[[int]$t] }
        }
      }
      foreach ($e in @($comm + $ad)) { if ($remap.ContainsKey($e.Idx)) { $e.Idx = $remap[$e.Idx] } }

      # 2. tags that the measurement contradicts.
      $newComm = New-Object System.Collections.ArrayList; $newAd = New-Object System.Collections.ArrayList
      foreach ($e in $comm) {
        $s = $by[$e.Idx]
        if (-not $s -or $s.role -in @('commentary', 'commentary?')) { if (-not ($newComm | Where-Object { $_.Idx -eq $e.Idx })) { [void]$newComm.Add($e) } }
        elseif ($s.role -eq 'audioDescription') { [void]$newAd.Add([pscustomobject]@{ Idx = $e.Idx; Title = '' }) }
        # any other measured role (dub, primary, music, alternateMix, silent?): the label goes.
      }
      foreach ($e in $ad) {
        $s = $by[$e.Idx]
        if (-not $s -or $s.role -in @('audioDescription', 'commentary?')) { if (-not ($newAd | Where-Object { $_.Idx -eq $e.Idx })) { [void]$newAd.Add($e) } }
        elseif ($s.role -eq 'commentary') { if (-not ($newComm | Where-Object { $_.Idx -eq $e.Idx })) { [void]$newComm.Add([pscustomobject]@{ Idx = $e.Idx; Title = '' }) } }
      }

      # 3. confirmed commentary / audio description the row drops.
      foreach ($s in @($ev.streams | Where-Object { $_.role -eq 'commentary' })) {
        $ci = [int]$s.a
        if ($rejected -contains $ci) {
          [void]$left.Add([ordered]@{ field = 'commentary'; reason = "a:$ci is a CONFIRMED commentary in the evidence; the author's notCommentary rejects it - honoured as an explicit decision" })
          continue
        }
        if ($tracks -notcontains $ci) { [void]$tracks.Add($ci) }
        if (-not ($newComm | Where-Object { $_.Idx -eq $ci })) { [void]$newComm.Add([pscustomobject]@{ Idx = $ci; Title = '' }) }
      }
      foreach ($s in @($ev.streams | Where-Object { $_.role -eq 'audioDescription' })) {
        $di = [int]$s.a
        if ($rejected -contains $di) { continue }
        if ($tracks -notcontains $di) { [void]$tracks.Add($di) }
        if (-not ($newAd | Where-Object { $_.Idx -eq $di })) { [void]$newAd.Add([pscustomobject]@{ Idx = $di; Title = '' }) }
      }

      # 4. the FIRST kept track is the default: never a commentary / description / copy.
      if ($tracks.Count -and $primary) {
        $first = $by[[int]$tracks[0]]
        if ($first -and $first.role -in @('commentary', 'audioDescription', 'redundant', 'commentary?')) {
          $p = [int]$primary.a
          if ($tracks -contains $p) { $tracks.Remove($p) }
          $tracks.Insert(0, $p)
        }
      }

      # 4b. A TITLE WHOSE EVERY STREAM IS SILENT HAS NO AUDIO TO KEEP, AND THAT IS MEASURED, NOT
      # JUDGED. assert-tracks-analysed refuses a kept stream whose role is 'silent?' ("phantom
      # track - listen before shipping it") and separately accepts audioTracks [] when every
      # stream is evidenced silent. Between those two the author has to guess, and on The Man Who
      # Wasn't There (2026-09-20) they guessed differently for four identical titles: three
      # barbershop clips kept a:0 at -89 to -91 dB and one dropped it, so the manifest was refused
      # twice over. A duplicate of a silent stream is silent - analyze-tracks.py proves redundancy
      # by subtraction and then skips re-measuring the copy, so follow that link rather than read
      # the skipped measurement as "unknown".
      $quiet = @{}
      foreach ($s in @($ev.streams)) { if ($null -ne $s.audioLevelDb -and [double]$s.audioLevelDb -le -60) { $quiet[[int]$s.a] = $true } }
      foreach ($s in @($ev.streams)) {
        if ($quiet.ContainsKey([int]$s.a)) { continue }
        if ($null -ne $s.redundantWith -and $quiet.ContainsKey([int]$s.redundantWith)) { $quiet[[int]$s.a] = $true }
      }
      $allQuiet = $false
      if (@($ev.streams).Count -gt 0 -and $quiet.Count -eq @($ev.streams).Count -and $tracks.Count) {
        $allQuiet = $true
        $tracks = [System.Collections.ArrayList]@()
      }

      # 4b. THE FIRST TRACK IS THE ONE THAT PLAYS. PUT ENGLISH THERE.
      #
      # `audioTracks` is an ORDERED list: transcode.ps1 muxes in this order, position 0 becomes the
      # default stream, and Plex plays the default. Everything above decides WHICH streams to keep
      # and nothing decided which comes FIRST - so the order was whatever the manifest author wrote,
      # which on a disc whose a:0 is a dub is the dub.
      #
      # 2026-09-21, Deep Space Nine: 16 of 51 re-ripped episodes shipped with GERMAN as the default
      # audio (S02 E01/03/04/06/07/21/22/25, S04 E03/10/11/13/15/16/19/24). English was never lost -
      # it sat fourth, as the passthrough AC3 - but every one of those episodes PLAYED IN GERMAN, and
      # eight had already been confirmed and reclaimed before the operator found it. These are
      # multi-language European discs, which is the same property that put a Danish subtitle stream
      # in the library in the first place; on such a disc "the first audio track" means nothing.
      #
      # AND THIS SCRIPT MUST NOT FIX IT BY PROMOTING ENGLISH. That was written first, and one of this
      # file's own tests refused it inside a minute: a fixture with spoken French at a:0 and spoken
      # English at a:1 came back reordered. That is a DUB being promoted over the programme audio.
      # This library holds Porco Rosso (whose re-rip exists precisely to restore the original
      # Japanese), Amelie, Black Narcissus - "English first" is not a rule here, it is a bug that
      # would ship silently on exactly the titles where the original language matters most.
      #
      # The distinction between DS9 and a French film is NOT measurable from the streams: both are
      # "a:0 is not English and an English track exists". What differs is which language the
      # PROGRAMME was made in, and that is in the dispositions, not in the audio.
      #
      # So this is left to the gate, which can say so and stop: see assert-audio-default-language.ps1,
      # which refuses a manifest whose first kept track is a dub of a work that already publishes in
      # English, and names both candidates. The author - who has the dispositions - decides. A refusal
      # an agent resolves costs one gate round-trip; a wrong default costs 16 episodes nobody notices
      # until the operator plays one.
      $audioReordered = ''

      # 5. languages, positional against the final audioTracks.
      $langs = @(); $langKnown = $true
      foreach ($t in $tracks) {
        $s = $by[[int]$t]; $code = $null
        if ($s -and $s.role -eq 'music') { $code = 'zxx' }
        elseif ($s -and $s.langReliable -and $s.spokenLang) { $code = Get-SpokenCode $s.spokenLang }
        $auth = if ($langFor.ContainsKey([int]$t)) { $langFor[[int]$t] } else { $null }
        if ($code) {
          if ($auth -and (Test-SameLanguage $auth $code)) { $langs += $auth } else { $langs += $code }
        } elseif ($auth) { $langs += $auth }
        else { $langKnown = $false; $langs += $null }
      }

      # ---- write back what changed ----
      $finalTracks = @($tracks | ForEach-Object { [int]$_ })
      if ($null -eq $origTracks -or (Show $finalTracks) -ne (Show $origTracks)) {
        if ($null -ne $origTracks) {
          $why = @()
          if ($allQuiet) { $why += 'every audio stream of this title is silent (measured at or below -60 dB, or proven same-content as one that is) - nothing to keep' }
          if ($remap.Count) { $why += ('redundant ' + (($remap.GetEnumerator() | ForEach-Object { "a:$($_.Key)->a:$($_.Value)" }) -join ', ')) }
          $added = @($finalTracks | Where-Object { $origTracks -notcontains $_ } | ForEach-Object { "a:$_ ($($by[$_].role))" })
          if ($added.Count) { $why += ('added ' + ($added -join ', ')) }
          if ($finalTracks.Count -and $origTracks.Count -and $finalTracks[0] -ne $origTracks[0]) { $why += "primary a:$($finalTracks[0]) first (default)" }
          if ($audioReordered) { $why += $audioReordered }
          [void]$changes.Add([ordered]@{ field = 'audioTracks'; from = $origTracks; to = $finalTracks; evidence = "$(Split-Path $evPath -Leaf): " + ($why -join '; ') })
        }
        Set-Field $r 'audioTracks' $finalTracks
      }
      $commOut = $null; if ($newComm.Count) { $commOut = ConvertTo-PairList $newComm 'Audio Commentary' }
      $origCommShow = $null; if ($names -contains 'commentary') { $origCommShow = Show (ConvertTo-PairList $origCommEntries 'Audio Commentary') }
      if ($newComm.Count -and (Show $commOut) -ne $origCommShow) {
        [void]$changes.Add([ordered]@{ field = 'commentary'; from = $origComm; to = $commOut; evidence = "$(Split-Path $evPath -Leaf): role per stream" })
        Set-Field $r 'commentary' $commOut
      } elseif (-not $newComm.Count -and $names -contains 'commentary' -and $comm.Count) {
        [void]$changes.Add([ordered]@{ field = 'commentary'; from = $origComm; to = $null; evidence = "$(Split-Path $evPath -Leaf): the tagged stream(s) measure as " + (($comm | ForEach-Object { "a:$($_.Idx)=$($by[$_.Idx].role)" }) -join ', ') + ' - not a commentary' })
        $r.PSObject.Properties.Remove('commentary')
      }
      $adOut = $null; if ($newAd.Count) { $adOut = ConvertTo-PairList $newAd 'Audio Description' }
      $origAdShow = $null; if ($names -contains 'audioDescription') { $origAdShow = Show (ConvertTo-PairList $origAdEntries 'Audio Description') }
      if ($newAd.Count -and (Show $adOut) -ne $origAdShow) {
        [void]$changes.Add([ordered]@{ field = 'audioDescription'; from = $origAd; to = $adOut; evidence = "$(Split-Path $evPath -Leaf): role audioDescription" })
        Set-Field $r 'audioDescription' $adOut
      } elseif (-not $newAd.Count -and $names -contains 'audioDescription' -and $ad.Count) {
        [void]$changes.Add([ordered]@{ field = 'audioDescription'; from = $origAd; to = $null; evidence = "$(Split-Path $evPath -Leaf): the tagged stream(s) do not measure as audio description" })
        $r.PSObject.Properties.Remove('audioDescription')
      }
      if ($langKnown) {
        if ((Show $langs) -ne (Show $origLangs)) {
          [void]$changes.Add([ordered]@{ field = 'audioLangs'; from = $origLangs; to = $langs; evidence = "$(Split-Path $evPath -Leaf): spoken language where langReliable (music = zxx); an author code meaning the same language is kept" })
          Set-Field $r 'audioLangs' $langs
        }
      } else {
        [void]$left.Add([ordered]@{ field = 'audioLangs'; reason = 'at least one kept stream has no reliable spoken language and no authored code - left as authored' })
      }
      if ($ev.proposal -and $ev.proposal.PSObject.Properties.Name -contains 'commentaryUncertain') {
        foreach ($u in @($ev.proposal.commentaryUncertain)) {
          $ui = [int]$u
          $decided = ($newComm | Where-Object { $_.Idx -eq $ui }) -or ($newAd | Where-Object { $_.Idx -eq $ui }) -or ($rejected -contains $ui)
          if (-not $decided) {
            $unsettled++
            [void]$left.Add([ordered]@{ field = 'commentary'; reason = "a:$ui is commentaryUncertain (role 'commentary?', spoken '$($by[$ui].spokenLang)', reliable=$($by[$ui].langReliable)) - a human must listen; not decided here" })
          }
        }
      }
    }
  }

  foreach ($c in $changes) { Write-Output ("   {0}: {1} {2} -> {3}   [{4}]" -f $leaf, $c.field, (Show $c.from), (Show $c.to), $c.evidence) }
  foreach ($l in $left) { Write-Output ("   {0}: LEFT {1} - {2}" -f $leaf, $l.field, $l.reason) }
  if ($changes.Count) {
    $totalChanges += $changes.Count
    $run = [ordered]@{ at = $now; by = 'derive-manifest-fields.ps1'; mode = $(if ($AudioOnly) { 'audio-only' } else { 'full' }); changes = @($changes); left = @($left) }
    $hist = @(); if ($names -contains 'derived' -and $null -ne $r.derived) { $hist = @($r.derived) }
    Set-Field $r 'derived' (@($hist) + @([pscustomobject]$run))
  }
}

if ($totalChanges -and -not $WhatIf) {
  $out = switch ($shape) { 'array' { , @($rows) } 'outputs' { $doc.outputs = @($rows); $doc } default { , @($rows) } }
  $json = ConvertTo-Json -InputObject $out -Depth 12
  Set-Content -LiteralPath $Manifest -Value $json -Encoding UTF8
  if ($Ledger -and (Test-Path -LiteralPath $Ledger)) {
    $name = Split-Path $Manifest -Leaf
    $known = $false
    foreach ($line in @(Get-Content -LiteralPath $Ledger -ErrorAction SilentlyContinue)) {
      if (-not "$line".Trim()) { continue }
      try { $e = "$line" | ConvertFrom-Json } catch { continue }
      if ($e.name -eq $name -and $e.sha256 -eq $oldHash) { $known = $true; break }
    }
    if ($known) {
      $entry = [ordered]@{ name = $name; sha256 = (Get-FileHash -LiteralPath $Manifest -Algorithm SHA256).Hash; gated = $now; how = ('derived:' + $oldHash.Substring(0, 12)) }
      Add-Content -LiteralPath $Ledger -Value ($entry | ConvertTo-Json -Compress)
      Write-Output "   ledger: the gated content was derived; recorded the new hash as derived from $($oldHash.Substring(0, 12))"
    }
  }
}
Write-Output ("derive-manifest-fields: {0} field change(s) across {1} row(s){2}; {3} measurable disagreement(s) left for the gate" -f $totalChanges, $rows.Count, $(if ($WhatIf) { ' (WhatIf - nothing written)' } else { '' }), $unsettled)
if ($unsettled) { exit 2 }
exit 0
