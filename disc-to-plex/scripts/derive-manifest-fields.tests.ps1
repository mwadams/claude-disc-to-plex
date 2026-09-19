<#
.SYNOPSIS
  Tests for derive-manifest-fields.ps1 against tiny generated media and small synthetic
  .tracks.json evidence. Every derived field has a KNOWN-NEGATIVE (a row that must NOT change), and
  the three real cases that motivated the script are reproduced: Friends S8 D2's dropped S08E23
  commentary, its kind "BD" on 720x480 extras, and the expectSeconds clerical slips that
  fix-manifest-expectations.ps1 was written for (Friends S1 D1 -0.96 s; Rubber-Keyed Wonder D2
  +1.000 s / +30 frames). Exit 0 = all passed.

  pwsh -NoProfile -File derive-manifest-fields.tests.ps1 [-ScratchRoot D:/video/_reviews/manifest-derivation-work]
#>
param([string]$ScratchRoot = [IO.Path]::GetTempPath())
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'derive-manifest-fields.ps1'
$root = Join-Path $ScratchRoot ('dmf-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$fail = 0; $pass = 0
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Write-Host "  PASS  $name" } else { $script:fail++; Write-Host "  FAIL  $name`n        $detail" }
}
function J($v) { ConvertTo-Json -InputObject $v -Compress -Depth 8 }
try {
  New-Item -ItemType Directory -Force -Path $root | Out-Null
  $ff = (Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json).ffmpeg
  function Make([string]$name, [string]$args1) {
    $p = Join-Path $root $name
    $a = @('-v', 'error', '-y') + ($args1 -split ' ') + @($p)
    & $ff @a
    if (-not (Test-Path -LiteralPath $p)) { throw "fixture $name was not created" }
    return ($p -replace '\\', '/')
  }
  # 10 s @25 fps (250 frames) HD and SD; 30 s SD; an SD raw-TS "m2ts"; a tagged-subtitle mkv.
  $hd10 = Make 'hd10.mkv'  '-f lavfi -i color=c=black:s=1280x720:r=25 -f lavfi -i sine=f=440:r=48000 -t 10 -c:v libx264 -preset ultrafast -c:a aac'
  $sd10 = Make 'sd10.mkv'  '-f lavfi -i color=c=black:s=720x480:r=25 -f lavfi -i sine=f=440:r=48000 -t 10 -c:v libx264 -preset ultrafast -c:a aac'
  $sd30 = Make 'sd30.mkv'  '-f lavfi -i color=c=black:s=720x480:r=25 -t 30 -c:v libx264 -preset ultrafast'
  $sdts = Make 'sd.m2ts'   '-f lavfi -i color=c=black:s=720x480:r=25 -f lavfi -i sine=f=440:r=48000 -t 10 -c:v libx264 -preset ultrafast -c:a ac3 -f mpegts'
  $srtJ = Join-Path $root 'j.srt'; $srtE = Join-Path $root 'e.srt'
  Set-Content -LiteralPath $srtJ -Value "1`r`n00:00:01,000 --> 00:00:02,000`r`nkonnichiwa`r`n" -Encoding ascii
  Set-Content -LiteralPath $srtE -Value "1`r`n00:00:01,000 --> 00:00:02,000`r`nhello`r`n" -Encoding ascii
  $subs = Join-Path $root 'subs.mkv'
  & $ff -v error -y -i $sd10 -i $srtJ -i $srtE -map 0 -map 1 -map 2 -c copy -c:s srt -metadata:s:s:0 language=jpn -metadata:s:s:1 language=eng $subs
  $subs = $subs -replace '\\', '/'

  $m = Join-Path $root 'm.json'
  $ledger = Join-Path $root 'gated.jsonl'
  function Write-Manifest($rows) { Set-Content -LiteralPath $m -Value (ConvertTo-Json -InputObject @($rows) -Depth 8) -Encoding UTF8 }
  function Run([string[]]$extra = @()) {
    $a = @('-NoProfile', '-File', $script, '-Manifest', $m) + $extra
    $o = @(& pwsh @a 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    return [pscustomobject]@{ Code = $code; Text = ($o -join "`n"); Rows = @(Get-Content -LiteralPath $m -Raw | ConvertFrom-Json) }
  }
  # Synthetic evidence: only the fields the derivation reads. Written AFTER the media, so it is fresh.
  function Write-Evidence([string]$src, $streams, $proposal) {
    $o = [ordered]@{ src = $src; streams = $streams; proposal = $proposal; warnings = @() }
    Set-Content -LiteralPath (($src -replace '/', '\') + '.tracks.json') -Value (ConvertTo-Json -InputObject $o -Depth 8) -Encoding UTF8
  }
  function S([int]$a, [int]$ch, [string]$role, [string]$lang, [bool]$rel = $true, $red = $null) {
    [ordered]@{ a = $a; codec = 'ac3'; channels = $ch; role = $role; spokenLang = $lang; langReliable = $rel; redundantWith = $red; langTag = $null; tagMismatch = $false; audioLevelDb = $null }
  }

  # ============================================================================ kind
  Write-Host 'kind'
  Write-Manifest @(
    @{ out = 'x/SD-BD.mkv'; src = $sdts; kind = 'BD'; subTrack = 'eng' },     # REAL CASE: Friends S8 D2 00001/00023/00040 (720x480, kind BD)
    @{ out = 'x/HD-BD.mkv'; src = $hd10; kind = 'BD'; subTrack = 'eng' },     # known-negative
    @{ out = 'x/SD-MKV.mkv'; src = $sd10; kind = 'MKV'; subTrack = 'eng' },   # known-negative
    @{ out = 'x/HD-MKV.mkv'; src = $hd10; kind = 'MKV'; subTrack = 'eng' },
    @{ out = 'x/DVD.mkv'; src = ($root -replace '\\', '/'); kind = 'DVD'; title = 3 }   # known-negative: folder
  )
  $r = Run
  Check 'exit 0' ($r.Code -eq 0) $r.Text
  Check 'REAL: SD source authored BD -> MKV' ($r.Rows[0].kind -eq 'MKV') $r.Text
  Check 'the override is logged in the row' ((J $r.Rows[0].derived) -match '"field":"kind".*"from":"BD".*"to":"MKV".*720x480') (J $r.Rows[0].derived)
  Check 'known-negative: HD BD stays BD, no derived record' ($r.Rows[1].kind -eq 'BD' -and $null -eq $r.Rows[1].derived)
  Check 'known-negative: SD MKV stays MKV' ($r.Rows[2].kind -eq 'MKV' -and $null -eq $r.Rows[2].derived)
  Check 'HD source authored MKV -> BD' ($r.Rows[3].kind -eq 'BD') $r.Text
  Check 'known-negative: DVD folder row untouched' ($r.Rows[4].kind -eq 'DVD' -and $null -eq $r.Rows[4].derived)

  # ============================================================================ expectSeconds
  Write-Host 'expectSeconds (absorbs fix-manifest-expectations.ps1)'
  Write-Manifest @(
    @{ out = 'x/A.mkv'; src = $sd10; kind = 'MKV'; subTrack = 'eng'; expectSeconds = 9.04 },    # REAL CASE: Friends S1 D1 class (-0.96 s)
    @{ out = 'x/B.mkv'; src = $sd10; kind = 'MKV'; subTrack = 'eng'; expectSeconds = 10.0 },    # known-negative: already right
    @{ out = 'x/C.mkv'; src = $sd30; kind = 'MKV'; subTrack = 'eng'; expectSeconds = 10.0 },    # wrong SOURCE: never silently fixed
    @{ out = 'x/D.mkv'; src = $sd10; kind = 'MKV'; subTrack = 'eng' }                          # absent: never filled
  )
  $r = Run
  Check 'exit 2 - a wrong-source row is left for the gate' ($r.Code -eq 2) $r.Text
  Check 'REAL: clerical slip corrected to the container duration' ([math]::Abs([double]$r.Rows[0].expectSeconds - 10.0) -le 0.1) (J $r.Rows[0])
  Check 'known-negative: correct row unchanged' ([double]$r.Rows[1].expectSeconds -eq 10.0 -and -not ((J $r.Rows[1].derived) -match 'expectSeconds'))
  Check 'wrong source: 20 s gap left exactly as authored' ([double]$r.Rows[2].expectSeconds -eq 10.0) (J $r.Rows[2])
  Check 'wrong source: reported as an IDENTITY question' ($r.Text -match 'C\.mkv: LEFT expectSeconds.*IDENTITY') $r.Text
  Check 'absent expectSeconds is not filled' ($r.Rows[3].PSObject.Properties.Name -notcontains 'expectSeconds') (J $r.Rows[3])

  # ============================================================================ expectFrames
  Write-Host 'expectFrames'
  Write-Manifest @(
    @{ out = 'x/R.mkv'; src = $sd10; kind = 'MKV'; subTrack = 'eng'; expectSeconds = 11.0; expectFrames = 275 },   # REAL CASE: Rubber-Keyed Wonder D2 (+1.000 s, +N frames)
    @{ out = 'x/N.mkv'; src = $sd10; kind = 'MKV'; subTrack = 'eng'; expectSeconds = 10.0; expectFrames = 250 },   # known-negative
    @{ out = 'x/F.mkv'; src = $sd10; kind = 'MKV'; subTrack = 'eng'; expectSeconds = 10.0 },                      # absent frames: filled (identity settled by seconds)
    @{ out = 'x/W.mkv'; src = $sd30; kind = 'MKV'; subTrack = 'eng'; expectSeconds = 10.0; expectFrames = 250 }    # wrong source: frames not touched
  )
  $r = Run
  Check 'REAL: +1 s seconds corrected' ([math]::Abs([double]$r.Rows[0].expectSeconds - 10.0) -le 0.1) (J $r.Rows[0])
  Check 'REAL: +25 frames corrected to the packet count (250)' ([int]$r.Rows[0].expectFrames -eq 250) (J $r.Rows[0])
  Check 'known-negative: right figures produce no derived record' ($null -eq $r.Rows[1].derived) (J $r.Rows[1].derived)
  Check 'absent expectFrames filled from the packet count' ([int]$r.Rows[2].expectFrames -eq 250) (J $r.Rows[2])
  Check 'wrong source: expectFrames left alone' ([int]$r.Rows[3].expectFrames -eq 250 -and -not ((J $r.Rows[3].derived) -match 'expectFrames'))

  # ============================================================================ subTrack
  Write-Host 'subTrack'
  Write-Manifest @(
    @{ out = 'x/T0.mkv'; src = $sdts; kind = 'MKV'; subTrack = 0 },          # raw .m2ts ordinal -> eng (Friends S3 D1: s:0 was Japanese)
    @{ out = 'x/T1.mkv'; src = $subs; kind = 'MKV'; subTrack = 0 },          # tagged jpn -> eng
    @{ out = 'x/T2.mkv'; src = $subs; kind = 'MKV'; subTrack = 1 },          # known-negative: tagged eng
    @{ out = 'x/T3.mkv'; src = $subs; kind = 'MKV'; subTrack = 'none' }      # known-negative: a decision, never touched
  )
  $r = Run
  Check 'm2ts ordinal -> "eng"' ($r.Rows[0].subTrack -eq 'eng') (J $r.Rows[0])
  Check 'ordinal on a jpn-tagged stream -> "eng"' ($r.Rows[1].subTrack -eq 'eng') (J $r.Rows[1])
  Check 'known-negative: ordinal on the eng-tagged stream stays' ("$($r.Rows[2].subTrack)" -eq '1') (J $r.Rows[2])
  Check 'known-negative: "none" untouched' ($r.Rows[3].subTrack -eq 'none')

  # ============================================================================ audio
  Write-Host 'audio (from .tracks.json)'
  # Each audio case gets its own source so its evidence file is its own.
  $srcs = @{}
  foreach ($n in 'e23', 'e24', 'plain', 'thb', 'inv', 'red', 'lang', 'unrel', 'ad', 'stale', 'score', 'jpn') { $srcs[$n] = Make "$n.mkv" '-f lavfi -i color=c=black:s=320x240:r=25 -t 1 -c:v libx264 -preset ultrafast' }
  Start-Sleep -Milliseconds 1100      # evidence must be NEWER than its source
  # REAL CASE: Friends S08E23 (00073.m2ts) - reduced from the disc's own tracks.json.
  Write-Evidence $srcs.e23 @((S 0 6 'primary' 'en'), (S 1 2 'dub' 'fr'), (S 2 2 'dub' 'de'), (S 3 2 'dub' 'es'), (S 4 2 'dub' 'ja'), (S 5 2 'commentary' 'en'), (S 6 2 'redundant' $null $false 5), (S 7 2 'redundant' $null $false 5), (S 8 2 'redundant' $null $false 5)) ([ordered]@{ audioTracks = @(0, 5); audioLangs = @('eng', 'eng'); commentary = 5 })
  # Friends S08E24 (00074.m2ts): a:3 is commentary? spoken 'ca' at 0.71 - unreliable.
  Write-Evidence $srcs.e24 @((S 0 6 'primary' 'en'), (S 1 2 'dub' 'fr'), (S 2 2 'dub' 'de'), (S 3 2 'commentary?' 'ca' $false), (S 4 2 'dub' 'ja'), (S 5 2 'commentary' 'en'), (S 6 2 'redundant' $null $false 5)) ([ordered]@{ audioTracks = @(0, 3, 5); audioLangs = @('eng', 'cat', 'eng'); commentary = 5; commentaryUncertain = @(3) })
  Write-Evidence $srcs.plain @((S 0 6 'primary' 'en'), (S 1 2 'dub' 'fr')) ([ordered]@{ audioTracks = @(0); audioLangs = @('eng') })
  Write-Evidence $srcs.thb @((S 0 6 'primary' 'en'), (S 1 2 'dub' 'it')) ([ordered]@{ audioTracks = @(0); audioLangs = @('eng') })         # Thunderball: dub labelled commentary
  Write-Evidence $srcs.inv @((S 0 2 'primary' 'en'), (S 1 6 'commentary' 'en')) ([ordered]@{ audioTracks = @(0, 1); commentary = 1 })        # Farscape S1 D6 inversion shape
  Write-Evidence $srcs.red @((S 0 6 'primary' 'en'), (S 1 2 'commentary' 'en'), (S 2 2 'redundant' $null $false 1)) ([ordered]@{ audioTracks = @(0, 1); commentary = 1 })
  Write-Evidence $srcs.lang @((S 0 6 'primary' 'fr'), (S 1 2 'dub' 'en')) ([ordered]@{ audioTracks = @(0, 1) })
  Write-Evidence $srcs.unrel @((S 0 2 'primary' 'en'), (S 1 2 'music' 'la' $false)) ([ordered]@{ audioTracks = @(0, 1) })
  Write-Evidence $srcs.ad @((S 0 6 'primary' 'en'), (S 1 6 'audioDescription' 'en')) ([ordered]@{ audioTracks = @(0, 1); audioDescription = 1 })
  Write-Evidence $srcs.score @((S 0 2 'music' 'la' $false)) ([ordered]@{ audioTracks = @(0); audioLangs = @('zxx') })   # Robin of Sherwood opening titles: score only, no primary
  Write-Evidence $srcs.jpn @((S 0 2 'primary' 'fr' $false)) ([ordered]@{ audioTracks = @(0); audioLangs = @('fra') })   # Porco Rosso J trailer: whisper unsure (fr @0.60)
  Write-Evidence $srcs.stale @((S 0 6 'primary' 'en'), (S 1 2 'commentary' 'en')) ([ordered]@{ audioTracks = @(0, 1); commentary = 1 })
  Start-Sleep -Milliseconds 1100
  & $ff -v error -y -f lavfi -i 'color=c=black:s=320x240:r=25' -t 1 -c:v libx264 -preset ultrafast ($srcs.stale -replace '/', '\')   # re-rip AFTER the analysis

  Write-Manifest @(
    @{ out = 'x/S08E23.mkv'; src = $srcs.e23; kind = 'BD'; audioTracks = @(0); audioLangs = @('eng') },                                            # 0 REAL: dropped confirmed commentary
    @{ out = 'x/S08E24.mkv'; src = $srcs.e24; kind = 'BD'; audioTracks = @(0, 5); audioLangs = @('eng', 'eng'); commentary = @(, @(5, 'Audio Commentary')); notCommentary = @(3) },   # 1 known-negative: the fixed manifest
    @{ out = 'x/PLAIN.mkv'; src = $srcs.plain; kind = 'BD'; audioTracks = @(0); audioLangs = @('eng') },                                         # 2 known-negative
    @{ out = 'x/THB.mkv'; src = $srcs.thb; kind = 'BD'; audioTracks = @(0, 1); audioLangs = @('eng', 'eng'); commentary = @(, @(1, 'Commentary 2')) },  # 3 dub labelled commentary
    @{ out = 'x/INV.mkv'; src = $srcs.inv; kind = 'BD'; audioTracks = @(0); audioLangs = @('eng') },                                             # 4 implausible evidence
    @{ out = 'x/RED.mkv'; src = $srcs.red; kind = 'BD'; audioTracks = @(0, 2); audioLangs = @('eng', 'eng'); commentary = @(, @(2, 'Audio Commentary with the Director')) },  # 5 redundant copy kept
    @{ out = 'x/LANG.mkv'; src = $srcs.lang; kind = 'BD'; audioTracks = @(0, 1); audioLangs = @('fre', 'spa') },                                 # 6 author 'fre' = spoken fr (keep); 'spa' vs spoken en (fix)
    @{ out = 'x/UNREL.mkv'; src = $srcs.unrel; kind = 'BD'; audioTracks = @(0, 1); audioLangs = @('eng', 'eng') },                              # 7 music -> zxx
    @{ out = 'x/AD.mkv'; src = $srcs.ad; kind = 'BD'; audioTracks = @(0, 1); audioLangs = @('eng', 'eng'); commentary = @(, @(1, 'Audio Commentary')) },  # 8 Casino Royale: AD labelled commentary
    @{ out = 'x/STALE.mkv'; src = $srcs.stale; kind = 'BD'; audioTracks = @(0); audioLangs = @('eng') },                                         # 9 stale evidence: ignored
    @{ out = 'x/E24-open.mkv'; src = $srcs.e24; kind = 'BD'; audioTracks = @(0); audioLangs = @('eng') },                                        # 10 REAL (original E24 shape): commentary added, a:3 left
    @{ out = 'x/SCORE.mkv'; src = $srcs.score; kind = 'MKV'; audioTracks = @(0); audioLangs = @('eng') },                                        # 11 REAL: Robin of Sherwood S00E23, a score labelled English
    @{ out = 'x/JPN.mkv'; src = $srcs.jpn; kind = 'MKV'; audioTracks = @(0); audioLangs = @('jpn') }                                             # 12 REAL known-negative: Porco Rosso J trailer, content-confirmed jpn
  )
  $r = Run @('-AudioOnly')
  $x = $r.Rows
  Check 'exit 2 - E24''s uncertain a:3 is left for a human' ($r.Code -eq 2) $r.Text
  Check 'REAL S08E23: audioTracks [0] -> [0,5]' ((J $x[0].audioTracks) -eq '[0,5]') (J $x[0])
  Check 'REAL S08E23: commentary tagged on a:5' ((J $x[0].commentary) -eq '[[5,"Audio Commentary"]]') (J $x[0].commentary)
  Check 'REAL S08E23: audioLangs follows the tracks' ((J $x[0].audioLangs) -eq '["eng","eng"]') (J $x[0].audioLangs)
  Check 'REAL S08E23: the change is logged with its evidence file' ((J $x[0].derived) -match 'e23\.mkv\.tracks\.json.*added a:5 \(commentary\)') (J $x[0].derived)
  Check 'known-negative: the fixed S08E24 manifest is unchanged' ($null -eq $x[1].derived -and (J $x[1].audioTracks) -eq '[0,5]') (J $x[1])
  Check 'known-negative: primary-only evidence, [0] unchanged' ($null -eq $x[2].derived) (J $x[2])
  Check 'Thunderball: commentary label removed from a measured dub' ($x[3].PSObject.Properties.Name -notcontains 'commentary') (J $x[3])
  Check 'Thunderball: the dub keeps its place (author preference) but gains its spoken language' ((J $x[3].audioTracks) -eq '[0,1]' -and (J $x[3].audioLangs) -eq '["eng","ita"]') (J $x[3])
  Check 'Farscape inversion: nothing derived from implausible evidence' ((J $x[4].audioTracks) -eq '[0]' -and $x[4].PSObject.Properties.Name -notcontains 'commentary') (J $x[4])
  Check 'Farscape inversion: reported' ($r.Text -match 'INV\.mkv: LEFT audio - evidence not acted on') $r.Text
  Check 'redundant copy replaced by its original, author title carried over' ((J $x[5].audioTracks) -eq '[0,1]' -and (J $x[5].commentary) -eq '[[1,"Audio Commentary with the Director"]]') (J $x[5])
  Check 'known-negative: author "fre" for spoken fr is kept; wrong "spa" for spoken en fixed' ((J $x[6].audioLangs) -eq '["fre","eng"]') (J $x[6].audioLangs)
  Check 'music stream -> zxx, never the hallucinated language' ((J $x[7].audioLangs) -eq '["eng","zxx"]') (J $x[7].audioLangs)
  Check 'Casino Royale: AD labelled commentary becomes audioDescription' ($x[8].PSObject.Properties.Name -notcontains 'commentary' -and (J $x[8].audioDescription) -eq '[[1,"Audio Description"]]') (J $x[8])
  Check 'stale evidence (older than its source) is not used' ((J $x[9].audioTracks) -eq '[0]' -and $r.Text -match 'STALE\.mkv: LEFT audio - .*predates') $r.Text
  Check 'REAL S08E24 original shape: a:5 added' ((J $x[10].audioTracks) -eq '[0,5]' -and (J $x[10].commentary) -eq '[[5,"Audio Commentary"]]') (J $x[10])
  Check 'REAL S08E24 original shape: a:3 NOT guessed, named for a human' ($r.Text -match 'E24-open\.mkv: LEFT commentary - a:3 is commentaryUncertain') $r.Text
  Check '-AudioOnly probes nothing: kind untouched on these rows' (@($x | Where-Object { $_.kind -notin @('BD', 'MKV') }).Count -eq 0 -and $x[11].kind -eq 'MKV')
  Check 'REAL known-negative: an UNRELIABLE language never overrides the author''s code on a single [0] track' ((J $x[12].audioLangs) -eq '["jpn"]' -and $null -eq $x[12].derived -and $r.Text -notmatch 'JPN\.mkv: LEFT') $r.Text
  Check 'REAL: a score-only title with no primary is NOT an alarm, and its language becomes zxx' ((J $x[11].audioLangs) -eq '["zxx"]' -and $r.Text -notmatch 'SCORE\.mkv: LEFT audio') $r.Text

  # ============================================================================ rip of a door-shadowed playlist
  Write-Host 'src: a rip that cannot carry the commentary door (report only)'
  $catDir = Join-Path $root 'cat'; New-Item -ItemType Directory -Force -Path $catDir | Out-Null
  $ripDir = Join-Path $root 'unit_x-1234abcd-rip'; New-Item -ItemType Directory -Force -Path $ripDir | Out-Null
  Copy-Item -LiteralPath $sd10 -Destination (Join-Path $ripDir 'Unit X_t05.mkv')
  Copy-Item -LiteralPath $sd10 -Destination (Join-Path $ripDir 'Unit X_t06.mkv')
  function A([string]$l, [int]$c) { [ordered]@{ type = 'Audio'; lang = $l; channels = "$c" } }
  $cat = [ordered]@{ disc = 'UNIT_X-1234abcd'; titles = @(
      [ordered]@{ title = 5; source = '00073.mpls'; probeFile = 'D:/x/BDMV/STREAM/00062.m2ts'; streams = @((A 'English' 6), (A 'French' 2)) },
      [ordered]@{ title = 6; source = '00074.mpls'; probeFile = 'D:/x/BDMV/STREAM/00063.m2ts'; streams = @((A 'English' 6), (A 'French' 2)) },
      [ordered]@{ title = 15; source = '00201.mpls'; probeFile = 'D:/x/BDMV/STREAM/00062.m2ts'; streams = @((A 'English' 2), (A 'English' 2), (A 'English' 2), (A 'English' 2)) },
      [ordered]@{ title = 21; source = '00603.mpls'; probeFile = 'D:/x/BDMV/STREAM/00063.m2ts'; streams = @((A 'English' 6), (A 'Japanese' 2)) }) }
  Set-Content -LiteralPath (Join-Path $catDir 'UNIT_X-1234abcd.catalogue.json') -Value (ConvertTo-Json -InputObject $cat -Depth 8) -Encoding UTF8
  Write-Manifest @(
    @{ out = 'x/E03.mkv'; src = ((Join-Path $ripDir 'Unit X_t05.mkv') -replace '\\', '/'); kind = 'MKV'; subTrack = 'eng'; expectSeconds = 10.0; expectFrames = 250 },  # REAL shape: Friends S8 D1 E03
    @{ out = 'x/E04.mkv'; src = ((Join-Path $ripDir 'Unit X_t06.mkv') -replace '\\', '/'); kind = 'MKV'; subTrack = 'eng'; expectSeconds = 10.0; expectFrames = 250 }   # known-negative: only a Japanese-market twin
  )
  $r = Run @('-CatalogueDir', $catDir)
  Check 'REAL shape: a rip shadowed by a richer playlist on its clip is named' ($r.Code -eq 2 -and $r.Text -match 'E03\.mkv: LEFT src - this is a rip of t05 .*00062\.m2ts.*t15 00201\.mpls') $r.Text
  Check 'the source is never changed' ($r.Rows[0].src -match 'Unit X_t05\.mkv$')
  Check 'known-negative: a twin with no extra English audio is not flagged' ($r.Text -notmatch 'E04\.mkv: LEFT src') $r.Text

  # ============================================================================ DVD rows, from evidence.json
  Write-Host 'DVD rows (folder + title) from _catalogue/<unit>.evidence.json'
  $dvd = Join-Path $root 'DVD UNIT'; New-Item -ItemType Directory -Force -Path (Join-Path $dvd 'VIDEO_TS') | Out-Null
  $evj = [ordered]@{ titles = @(
      [ordered]@{ dvdvideoTitle = 2; measured = $true; expectSeconds = 1500.0; expectFrames = 37500 },
      [ordered]@{ dvdvideoTitle = 3; measured = $true; expectSeconds = 1501.5; expectFrames = 37537 },
      [ordered]@{ dvdvideoTitle = 4; measured = $true; expectSeconds = 1650.0; expectFrames = 41250 }) }
  Set-Content -LiteralPath (Join-Path $catDir 'DVD UNIT.evidence.json') -Value (ConvertTo-Json -InputObject $evj -Depth 6) -Encoding UTF8
  $dsrc = $dvd -replace '\\', '/'
  Write-Manifest @(
    @{ out = 'x/D4.mkv'; src = $dsrc; kind = 'DVD'; title = 4; expectSeconds = 1649.2; expectFrames = 41230 },   # clerical: corrected from evidence
    @{ out = 'x/D2.mkv'; src = $dsrc; kind = 'DVD'; title = 2; expectSeconds = 1500.0; expectFrames = 37500 },   # known-negative
    @{ out = 'x/D2b.mkv'; src = $dsrc; kind = 'DVD'; title = 2; expectSeconds = 1501.4 },                        # off-by-one: title 3 fits better
    @{ out = 'x/D4c.mkv'; src = $dsrc; kind = 'DVD'; title = 4; chapterStart = 2; expectSeconds = 300.0 }       # partial title: never compared to the whole
  )
  $r = Run @('-CatalogueDir', $catDir)
  Check 'DVD clerical slip corrected from evidence.json (seconds and frames)' ([double]$r.Rows[0].expectSeconds -eq 1650.0 -and [int]$r.Rows[0].expectFrames -eq 41250) (J $r.Rows[0])
  Check 'known-negative: matching DVD row unchanged' ($null -eq $r.Rows[1].derived) (J $r.Rows[1])
  Check 'a figure that fits ANOTHER title better is left for the numbering guard' ([double]$r.Rows[2].expectSeconds -eq 1501.4 -and $r.Text -match 'D2b\.mkv: LEFT expectSeconds.*title-NUMBERING') $r.Text
  Check 'known-negative: a chapter-limited DVD row is not compared to the whole title' ([double]$r.Rows[3].expectSeconds -eq 300.0 -and $null -eq $r.Rows[3].derived) (J $r.Rows[3])

  # ============================================================================ idempotence + ledger
  Write-Host 'idempotence and the gate ledger'
  $before = (Get-FileHash -LiteralPath $m -Algorithm SHA256).Hash
  $r2 = Run @('-AudioOnly')
  $after = (Get-FileHash -LiteralPath $m -Algorithm SHA256).Hash
  Check 'a second run changes nothing and leaves the bytes alone' ($before -eq $after -and $r2.Text -match '0 field change') $r2.Text

  Write-Manifest @(@{ out = 'x/S08E23.mkv'; src = $srcs.e23; kind = 'BD'; audioTracks = @(0); audioLangs = @('eng') })
  $h0 = (Get-FileHash -LiteralPath $m -Algorithm SHA256).Hash
  Set-Content -LiteralPath $ledger -Value ((@{ name = 'm.json'; sha256 = $h0; gated = 'x'; how = 'test' } | ConvertTo-Json -Compress)) -Encoding UTF8
  $r = Run @('-AudioOnly', '-Ledger', $ledger)
  $h1 = (Get-FileHash -LiteralPath $m -Algorithm SHA256).Hash
  $led = @(Get-Content -LiteralPath $ledger | ForEach-Object { $_ | ConvertFrom-Json })
  Check 'gated manifest: the derived content is recorded in the ledger' ($led.Count -eq 2 -and $led[1].sha256 -eq $h1 -and $led[1].how -like 'derived:*') ($led | ConvertTo-Json -Compress)
  Write-Manifest @(@{ out = 'x/S08E23.mkv'; src = $srcs.e23; kind = 'BD'; audioTracks = @(0); audioLangs = @('eng') })
  Set-Content -LiteralPath $ledger -Value ((@{ name = 'm.json'; sha256 = 'NOT-THIS'; gated = 'x'; how = 'test' } | ConvertTo-Json -Compress)) -Encoding UTF8
  $r = Run @('-AudioOnly', '-Ledger', $ledger)
  Check 'known-negative: an UNGATED manifest gains no ledger entry' (@(Get-Content -LiteralPath $ledger).Count -eq 1)

  Write-Host 'WhatIf writes nothing'
  Write-Manifest @(@{ out = 'x/S08E23.mkv'; src = $srcs.e23; kind = 'BD'; audioTracks = @(0); audioLangs = @('eng') })
  $h0 = (Get-FileHash -LiteralPath $m -Algorithm SHA256).Hash
  $r = Run @('-AudioOnly', '-WhatIf')
  Check 'WhatIf: reports the change, file untouched' ($r.Text -match 'audioTracks \[0\] -> \[0,5\]' -and (Get-FileHash -LiteralPath $m -Algorithm SHA256).Hash -eq $h0) $r.Text
}
finally {
  Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ("{0} passed, {1} failed" -f $pass, $fail)
if ($fail) { exit 1 }
Write-Host 'all tests passed'
exit 0
