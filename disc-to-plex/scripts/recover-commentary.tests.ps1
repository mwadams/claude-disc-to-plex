<#
.SYNOPSIS
  End-to-end tests for the commentary recovery: rip-recovery-titles.ps1 (targeted MakeMKV rip of a
  directive's door playlists, against STAGED BDMV folders via a `file:` source - no disc needed),
  recover-commentary.ps1 (identity by analyze-tracks.py, sync by commentary-sync-proof.py, mkvmerge
  build, verify, hand-over) and the known-negatives that must be left untouched. Up to, and NOT
  including, publishing: the hand-over goes into a scratch "library" the publish loop never reads.

  Needs, and only READS: D:/video/_stage/FRIENDS_SEASON_8_DISC_2-06b13a86 (2) (door 00201 over clip
  00073 = S08E23, whose commentary was shipped from the raw clip - the ground truth), the local
  S08E13 / S08E23 encodes under D:/video/Television Shows/Friends (1994)/Season 08, and
  D:/video/_stage/FRIENDS_S9_D1-3c42983c (door 00201 over clip 00062). Takes ~15 minutes and up to
  ~12 GB of scratch on D:, released at the end. Exit 0 = all passed.

  pwsh -NoProfile -File recover-commentary.tests.ps1 [-ScratchRoot D:/video/_reviews/manifest-derivation-work] [-SkipS9]
#>
param([string]$ScratchRoot = 'D:/video/_reviews/manifest-derivation-work', [switch]$SkipS9)
$ErrorActionPreference = 'Stop'
$S = 'D:/video/.claude/skills/disc-to-plex/scripts'
$B = 'D:/video/.claude/skills/disc-backup/scripts'
$S8 = 'D:/video/_stage/FRIENDS_SEASON_8_DISC_2-06b13a86 (2)'
$S9 = 'D:/video/_stage/FRIENDS_S9_D1-3c42983c'
$season8 = 'D:/video/Television Shows/Friends (1994)/Season 08'
$E23 = "$season8/Friends (1994) - S08E23 - The One Where Rachel Has a Baby.mkv"
$E13 = "$season8/Friends (1994) - S08E13 - The One Where Chandler Takes a Bath.mkv"
$root = Join-Path $ScratchRoot ('rc-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$rroot = "$root/recovery"; $lib = "$root/library/"
$tools = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
$ffmpeg = $tools.ffmpeg; $ffprobe = Join-Path (Split-Path $ffmpeg) 'ffprobe.exe'; $mkvmerge = Join-Path (Split-Path $tools.mkvextract) 'mkvmerge.exe'
$fail = 0; $pass = 0; $skipped = @()
function Check([string]$name, [bool]$ok, [string]$detail = '') {
  if ($ok) { $script:pass++; Write-Host "  PASS  $name" } else { $script:fail++; Write-Host "  FAIL  $name`n        $detail" }
}
function Directive([string]$unit, $episodes) {
  $d = [ordered]@{ schema = 'recovery-directive/1'; purpose = 'commentary'; unit = $unit; discName = $unit; label = $unit; fingerprint = ('test-' + $unit); discType = 'BD'; episodes = $episodes }
  $p = "$rroot/$unit.json"; $d | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $p -Encoding UTF8; return $p
}
function Recover([string]$unit, [string[]]$extra) {
  $cmd = "& '$S/recover-commentary.ps1' -Unit '$unit' -RecoveryRoot '$rroot' -LibraryPrefix '$lib' $($extra -join ' '); exit `$LASTEXITCODE"
  $o = @(& pwsh -NoProfile -Command $cmd 2>&1 | ForEach-Object { "$_" })
  return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ($o -join "`n") }
}
function Result([string]$unit, [string]$ep) { $p = "$rroot/$unit/$ep/result.json"; if (Test-Path -LiteralPath $p) { Get-Content -LiteralPath $p -Raw | ConvertFrom-Json } else { $null } }
function Env-Corr([string]$a, [int]$ai, [string]$b, [int]$bi, [int]$at) {
  & $ffmpeg -v error -y -i $a -ss $at -t 30 -map "0:a:$ai" -ac 1 -ar 8000 "$root/x.wav"
  & $ffmpeg -v error -y -i $b -ss $at -t 30 -map "0:a:$bi" -ac 1 -ar 8000 "$root/y.wav"
  python "$S/audio-envelope-correlate.py" "$root/x.wav" "$root/y.wav" --max-lag 3 --json | ConvertFrom-Json
}

try {
  New-Item -ItemType Directory -Force -Path $rroot, $lib | Out-Null
  # THE S8 D2 FIXTURES ARE RELEASED BY THE ORDINARY RECLAIM once the owner confirms Friends in Plex
  # (it happened at 09:05 on 2026-09-19, mid-development). A missing fixture is reported as SKIPPED
  # and the suite exits 4 - never 0: a check that skips is not a check that passes.
  $haveS8 = @($S8, $E23, $E13 | Where-Object { -not (Test-Path -LiteralPath $_) }).Count -eq 0
  if (-not $haveS8) { $script:skipped += 'S8 D2 sections (staging or local encodes released)'; Write-Host '  SKIP  S8 D2 sections - fixtures released' }
  if ($haveS8) {
  # NOT $e23/$e13: PowerShell variable names are case-insensitive, and $E23/$E13 are the fixture paths.
  $dir23 = [ordered]@{ episode = 'S08E23'; title = 'The One Where Rachel Has a Baby'; clip = '00073.m2ts'; doorPlaylist = '00201.mpls'; doorSeconds = 1317
                     doorAudio = @{ count = 4; channels = 2; lang = 'eng' }; fallbackPlaylist = '00401.mpls'; fallbackAudio = @{ count = 2; channels = 2; lang = 'eng' }
                     mainPlaylist = '00081.mpls'; publishedName = (Split-Path $E23 -Leaf); nasPath = '(test)'; localPath = ($lib + 'Season 08/' + (Split-Path $E23 -Leaf)) }
  # KNOWN-NEGATIVE: S08E13's clip 00062 has NO door. The directive names a playlist that does not
  # exist and, as the "fallback", the episode's own MAIN playlist (English 5.1 + dubs) - which must be
  # refused as not a door, not ripped.
  $dir13 = [ordered]@{ episode = 'S08E13'; title = 'The One Where Chandler Takes a Bath'; clip = '00062.m2ts'; doorPlaylist = '00299.mpls'; doorSeconds = 1298
                     doorAudio = @{ count = 4; channels = 2; lang = 'eng' }; fallbackPlaylist = '00071.mpls'; fallbackAudio = @{ count = 4; channels = 2; lang = 'eng' }
                     mainPlaylist = '00071.mpls'; publishedName = (Split-Path $E13 -Leaf); nasPath = '(test)'; localPath = ($lib + 'Season 08/' + (Split-Path $E13 -Leaf)) }

  Write-Host 'rip-recovery-titles.ps1 - targeted MakeMKV rip from a staged BDMV (file: source)'
  $dp = Directive 'T8' @($dir23, $dir13)
  $o = @(& pwsh -NoProfile -File "$B/rip-recovery-titles.ps1" -Directive $dp -Folder $S8 -OutRoot $rroot 2>&1 | ForEach-Object { "$_" }); $code = $LASTEXITCODE
  $rip = Get-Content -LiteralPath "$rroot/T8/rip/_rip.json" -Raw | ConvertFrom-Json
  $r23 = @($rip.episodes | Where-Object { $_.episode -eq 'S08E23' })[0]
  Check 'exit 2: one episode could not be taken' ($code -eq 2) ($o -join "`n")
  Check 'S08E23: door 00201 matched BY PLAYLIST NAME and ripped, verified' ($r23 -and $r23.verified -and $r23.playlist -eq '00201.mpls' -and (Test-Path -LiteralPath "$rroot/T8/rip/$($r23.file)")) ($o -join "`n")
  $door23 = "$rroot/T8/rip/$($r23.file)"
  $na = @((& $ffprobe -v error -select_streams a -show_entries stream=channels -of csv=p=0 $door23) | Where-Object { $_ })
  Check 'the rip holds the door''s 4 English 2.0 streams' ($na.Count -eq 4 -and @($na | Where-Object { "$_".Trim() -ne '2' }).Count -eq 0) ($na -join ',')
  Check 'KNOWN-NEGATIVE: door-less S08E13 NOT ripped' (@($rip.episodes | Where-Object { $_.episode -eq 'S08E13' }).Count -eq 0)
  Check 'KNOWN-NEGATIVE: its main playlist refused as not a door, named' (($o -join "`n") -match 'S08E13: no matching door title - 00299\.mpls not on this disc \| 00071\.mpls \(t\d+\) does not match the directive: .*not all English 2\.0') ($o -join "`n")
  Check 'only one .mkv written anywhere under the unit' (@(Get-ChildItem -LiteralPath "$rroot/T8" -Recurse -Filter *.mkv).Count -eq 1)
  $o = @(& pwsh -NoProfile -File "$B/rip-recovery-titles.ps1" -Directive $dp -Folder $S8 -OutRoot $rroot 2>&1 | ForEach-Object { "$_" })
  Check 'a second run does not re-rip what is verified' (($o -join "`n") -notmatch 'S08E23: ripping') ($o -join "`n")

  # A fixture of the PRE-FIX published episode: the local S08E23 minus the commentary transcode shipped.
  $pubFix = "$root/E23-as-published-before.mkv"
  $mj = & $mkvmerge -J $E23 | ConvertFrom-Json
  $keep = (@($mj.tracks | Where-Object { $_.type -eq 'audio' -and -not $_.properties.flag_commentary } | ForEach-Object { $_.id }) -join ',')
  & $mkvmerge -q -o $pubFix -a $keep $E23
  $e13Before = (Get-Item -LiteralPath $E13).LastWriteTimeUtc.Ticks, (Get-Item -LiteralPath $E13).Length

  Write-Host 'recover-commentary.ps1 - KNOWN-NEGATIVE: a door-less episode given the WRONG door'
  $r = Recover 'T8' @('-Episode', 'S08E13', '-Publish', "-PublishedOverride @{ 'S08E13' = '$E13' }", "-DoorOverride @{ 'S08E13' = '$door23' }")
  $x = Result 'T8' 'S08E13'
  Check 'exit 2, status stopped' ($r.Code -eq 2 -and $x.status -eq 'stopped') $r.Text
  Check 'stopped on SYNC (the video and the audio both say: not this programme)' ((@($x.reasons) -join ' ') -match 'sync NOT proven: .*video' -and (@($x.reasons) -join ' ') -match 'audio') (@($x.reasons) -join ' | ')
  Check 'nothing built, nothing handed over' (-not (Test-Path -LiteralPath "$lib/Season 08/$(Split-Path $E13 -Leaf)") -and -not (Test-Path -LiteralPath "$rroot/T8/S08E13/built"))
  Check 'the published S08E13 is untouched' (((Get-Item -LiteralPath $E13).LastWriteTimeUtc.Ticks, (Get-Item -LiteralPath $E13).Length) -join ',' -eq ($e13Before -join ','))

  Write-Host 'recover-commentary.ps1 - a published file that ALREADY has a commentary is left alone'
  $r = Recover 'T8' @('-Episode', 'S08E23', "-PublishedOverride @{ 'S08E23' = '$E23' }")
  $x = Result 'T8' 'S08E23'
  Check 'status already-has-commentary, nothing built' ($x.status -eq 'already-has-commentary' -and -not (Test-Path -LiteralPath "$rroot/T8/S08E23/built")) $r.Text
  Remove-Item -LiteralPath "$rroot/T8/S08E23" -Recurse -Force

  Write-Host 'recover-commentary.ps1 - S08E23 end to end (identity, sync, build, verify, hand-over)'
  $r = Recover 'T8' @('-Episode', 'S08E23', '-Publish', "-PublishedOverride @{ 'S08E23' = '$pubFix' }")
  $x = Result 'T8' 'S08E23'
  $out = "$lib/Season 08/$(Split-Path $E23 -Leaf)"
  Check 'status handed-over' ($x.status -eq 'handed-over' -and (Test-Path -LiteralPath $out)) $r.Text
  Check 'identity: programme primary, ONE commentary, the rest copies of it' ($x.steps.identity.roles -eq 'a:0=primary, a:1=commentary, a:2=redundant(of a:1), a:3=redundant(of a:1), a:4=redundant(of a:1)') $x.steps.identity.roles
  Check 'sync proven, video offset within one frame' ($x.steps.sync.ok -and [math]::Abs([int]$x.steps.sync.offsetMs) -le 42) ($x.steps.sync | ConvertTo-Json -Compress)
  $bj = (& $ffprobe -v error -show_entries 'stream=codec_type,codec_name,channels:stream_tags=language,title:stream_disposition=default,comment' -of json $out) -join "`n" | ConvertFrom-Json
  $aud = @($bj.streams | Where-Object { $_.codec_type -eq 'audio' })
  Check 'four audio tracks: the published three, then the commentary' ($aud.Count -eq 4 -and $aud[0].codec_name -eq 'aac' -and $aud[2].codec_name -eq 'ac3' -and $aud[3].codec_name -eq 'ac3') (($aud | ForEach-Object { $_.codec_name }) -join ',')
  Check 'the commentary: eng, "Audio Commentary", commentary flag, NOT default' ($aud[3].tags.language -eq 'eng' -and $aud[3].tags.title -eq 'Audio Commentary' -and $aud[3].disposition.comment -eq 1 -and $aud[3].disposition.default -eq 0) ($aud[3] | ConvertTo-Json -Compress)
  Check 'the published default track is still the default' ($aud[0].disposition.default -eq 1)
  Check 'subtitles carried over' (@($bj.streams | Where-Object { $_.codec_type -eq 'subtitle' }).Count -eq 1)
  Check 'video packets identical to the published file' ([string]$x.steps.verify.videoPackets -eq [string]$x.steps.verify.publishedVideoPackets -and $x.steps.verify.videoPackets)
  # GROUND TRUTH: this episode's commentary WAS shipped (from the raw clip, by transcode.ps1). The
  # recovered one must be the same audio at the same time.
  $gt = @(600, 1100 | ForEach-Object { Env-Corr $out 3 $E23 3 $_ })
  Check 'GROUND TRUTH: recovered commentary = the shipped one, lag 0, r >= 0.9' (@($gt | Where-Object { $_.r -ge 0.9 -and $_.lagMs -eq 0 }).Count -eq 2) (($gt | ForEach-Object { "r=$($_.r) lag=$($_.lagMs)" }) -join '; ')
  Check 'door rip KEPT while another episode of the unit is unresolved (S08E13 stopped)' (@(Get-ChildItem -LiteralPath "$rroot/T8/rip" -Filter *.mkv -ErrorAction SilentlyContinue).Count -eq 1)
  $r2 = Recover 'T8' @('-Episode', 'S08E23', '-Publish', "-PublishedOverride @{ 'S08E23' = '$pubFix' }")
  Check 'a second run does nothing to a handed-over episode' ($r2.Text -notmatch 'STOPPED|HANDED OVER' -and $r2.Text -match 'S08E23: handed-over') $r2.Text
  Remove-Item -LiteralPath $out, $pubFix -Force
  }

  if ($SkipS9 -or -not (Test-Path -LiteralPath $S9)) { $script:skipped += 'S9 D1 section'; Write-Host '  SKIP  S9 D1 section' }
  else {
    Write-Host 'Friends S9 D1 staging - a second disc: rip its door, prove identity and sync against the raw clip'
    $dir9 = [ordered]@{ episode = 'S9D1-00062'; title = 'S9 D1 clip 00062'; clip = '00062.m2ts'; doorPlaylist = '00201.mpls'; doorSeconds = 1919
                      doorAudio = @{ count = 4; channels = 2; lang = 'eng' }; fallbackPlaylist = '00401.mpls'; fallbackAudio = @{ count = 2; channels = 2; lang = 'eng' }
                      mainPlaylist = '00076.mpls'; publishedName = 'n/a.mkv'; nasPath = '(test)'; localPath = ($lib + 'n/a.mkv') }
    $dp9 = Directive 'T9' @($dir9)
    $o = @(& pwsh -NoProfile -File "$B/rip-recovery-titles.ps1" -Directive $dp9 -Folder $S9 -OutRoot $rroot 2>&1 | ForEach-Object { "$_" })
    Check 'S9 D1: door 00201 ripped and verified' ($LASTEXITCODE -eq 0) ($o -join "`n")
    $clip9 = "$S9/BDMV/STREAM/00062.m2ts"
    # The episodes are not published yet, so the raw clip stands in for the published file: identity
    # and sync are proven against it and nothing is built (-ProveOnly).
    $r = Recover 'T9' @('-ProveOnly', "-PublishedOverride @{ 'S9D1-00062' = '$clip9' }")
    $x = Result 'T9' 'S9D1-00062'
    Check 'S9 D1: status proven (identity + sync), nothing built' ($x.status -eq 'proven' -and -not (Test-Path -LiteralPath "$rroot/T9/S9D1-00062/built")) ($r.Text + ' ' + (@($x.reasons) -join ' | '))
    Check 'S9 D1 identity: ONE commentary, the rest copies of it' ($x.steps.identity.roles -eq 'a:0=primary, a:1=commentary, a:2=redundant(of a:1), a:3=redundant(of a:1), a:4=redundant(of a:1)') $x.steps.identity.roles
    Check 'S9 D1: the first pass was UNSURE and the 5-offset second pass confirmed it (recorded)' ("$($x.steps.identityFirstPass.roles)" -match 'a:1=commentary\?') "$($x.steps.identityFirstPass.roles)"
    Check 'S9 D1 sync against the raw clip: ok, within one frame' ($x.steps.sync.ok -and [math]::Abs([int]$x.steps.sync.offsetMs) -le 42) ($x.steps.sync | ConvertTo-Json -Compress)
    Check 'the raw clip used in place is untouched' (Test-Path -LiteralPath $clip9)

    # THE FULL BUILD ON S9 D1, in the exact shape of 11 of the 16 real cases: the "published" episode
    # is a MakeMKV rip of the MAIN playlist (00076 over clip 00062), which cannot contain the
    # commentary. Known-negative: the episode on clip 00064 (main 00078) offered clip 00062's door.
    $mk = 'C:/Program Files (x86)/MakeMKV/makemkvcon64.exe'
    $info = @(& $mk -r --minlength=10 info "file:$S9" 2>&1 | ForEach-Object { "$_" })
    $tOf = { param($pl) $l = @($info | Where-Object { $_ -match ('^TINFO:(\d+),16,0,"' + [regex]::Escape($pl) + '"') }); if ($l.Count) { [int]($l[0] -replace '^TINFO:(\d+),.*', '$1') } else { -1 } }
    foreach ($m in @(@('00076.mpls', 'main62'), @('00078.mpls', 'main64'))) {
      New-Item -ItemType Directory -Force -Path "$root/$($m[1])" | Out-Null
      & $mk -r --minlength=10 mkv "file:$S9" (& $tOf $m[0]) "$root/$($m[1])" *> "$root/$($m[1]).log"
    }
    $main62 = @(Get-ChildItem -LiteralPath "$root/main62" -Filter *.mkv)[0].FullName
    $main64 = @(Get-ChildItem -LiteralPath "$root/main64" -Filter *.mkv)[0].FullName
    Check 'main-playlist rips made (the published stand-ins)' ($main62 -and $main64)
    $doorFile = "$rroot/T9/rip/$($rip9.episodes[0].file)"
    $d62 = [ordered]@{ episode = 'S9-62'; title = 'clip 00062'; clip = '00062.m2ts'; doorPlaylist = '00201.mpls'; doorSeconds = 1919; doorAudio = @{ count = 4; channels = 2; lang = 'eng' }
                       publishedName = 'S9-62.mkv'; nasPath = '(test)'; localPath = ($lib + 'Season 09/S9-62.mkv') }
    $d64 = [ordered]@{ episode = 'S9-64'; title = 'clip 00064'; clip = '00064.m2ts'; doorPlaylist = '00202.mpls'; doorSeconds = 1516; doorAudio = @{ count = 4; channels = 2; lang = 'eng' }
                       publishedName = 'S9-64.mkv'; nasPath = '(test)'; localPath = ($lib + 'Season 09/S9-64.mkv') }
    [void](Directive 'T9B' @($d62, $d64))
    $before64 = (Get-Item -LiteralPath $main64).Length
    $r = Recover 'T9B' @('-Publish', "-PublishedOverride @{ 'S9-62' = '$main62'; 'S9-64' = '$main64' }", "-DoorOverride @{ 'S9-62' = '$doorFile'; 'S9-64' = '$doorFile' }")
    $x62 = Result 'T9B' 'S9-62'; $x64 = Result 'T9B' 'S9-64'
    $out62 = $lib + 'Season 09/S9-62.mkv'
    Check 'S9 full build: status handed-over' ($x62.status -eq 'handed-over' -and (Test-Path -LiteralPath $out62)) ($r.Text + ' ' + (@($x62.reasons) -join ' | '))
    $pa = @((& $ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 $main62) | Where-Object { $_ }).Count
    $bj = (& $ffprobe -v error -show_entries 'stream=codec_type,codec_name,channels:stream_tags=language,title:stream_disposition=default,comment' -of json $out62) -join "`n" | ConvertFrom-Json
    $ba = @($bj.streams | Where-Object { $_.codec_type -eq 'audio' })
    Check 'S9 full build: the rip''s audio tracks, then ONE commentary (eng, titled, flagged, not default)' ($ba.Count -eq $pa + 1 -and $ba[-1].tags.title -eq 'Audio Commentary' -and $ba[-1].disposition.comment -eq 1 -and $ba[-1].disposition.default -eq 0 -and $ba[-1].tags.language -eq 'eng') (($ba | ForEach-Object { "$($_.codec_name)/$($_.channels)/$($_.tags.title)" }) -join ',')
    Check 'S9 full build: video packets identical' ($x62.steps.verify.videoPackets -and [string]$x62.steps.verify.videoPackets -eq [string]$x62.steps.verify.publishedVideoPackets)
    # the built commentary against the commentary on the RAW CLIP (a:5 there): same audio, same time
    $gt = @(700, 1500 | ForEach-Object { Env-Corr $out62 ($ba.Count - 1) $clip9 5 $_ })
    Check 'S9 GROUND TRUTH: built commentary = the raw clip''s commentary stream, lag 0, r >= 0.9' (@($gt | Where-Object { $_.r -ge 0.9 -and $_.lagMs -eq 0 }).Count -eq 2) (($gt | ForEach-Object { "r=$($_.r) lag=$($_.lagMs)" }) -join '; ')
    Check 'S9 KNOWN-NEGATIVE: the other episode offered this door STOPS on sync' ($x64.status -eq 'stopped' -and (@($x64.reasons) -join ' ') -match 'sync NOT proven') (@($x64.reasons) -join ' | ')
    Check 'S9 KNOWN-NEGATIVE: nothing handed over, its "published" file untouched' (-not (Test-Path -LiteralPath ($lib + 'Season 09/S9-64.mkv')) -and (Get-Item -LiteralPath $main64).Length -eq $before64)
    Check 'exit 2 overall (one episode stopped)' ($r.Code -eq 2) "$($r.Code)"
  }
}
finally {
  if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
}
Write-Host ("{0} passed, {1} failed, {2} section(s) skipped{3}" -f $pass, $fail, $skipped.Count, $(if ($skipped.Count) { ': ' + ($skipped -join '; ') } else { '' }))
if ($fail) { exit 1 }
if ($skipped.Count) { Write-Host 'NOT all passed - sections were skipped'; exit 4 }
Write-Host 'all tests passed'
exit 0
