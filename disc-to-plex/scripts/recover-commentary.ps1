<#
.SYNOPSIS
  Add a missing audio commentary to an ALREADY-PUBLISHED episode, from a commentary-door rip, with
  no re-encode - and only after proving it is a commentary, that it is the one stream (not a copy),
  and that it is in sync with the published file. Unproven = STOP for that episode, recorded.

REACH FOR THIS WHEN: rip-recovery-titles.ps1 has ripped a directive's door titles into
  D:/video/_recovery/<unit>/rip/ and the published episodes need their commentary muxed in. The
  optical track starts this after a targeted rip; by hand it is:

  pwsh -NoProfile -File recover-commentary.ps1 -Unit "FRIENDS_S7_D2-f9933942"            # build + verify, REPORT only
  pwsh -NoProfile -File recover-commentary.ps1 -Unit "FRIENDS_S7_D2-f9933942" -Publish   # ...and hand over to the publish loop
  pwsh -NoProfile -File recover-commentary.ps1 -Pending -Publish                          # every unit with a rip and work left

.WHY THIS EXISTS
  16 Friends episodes shipped without their cast commentary (D:/video/_reviews/2026-09-19-manifest-
  derivation.md). The commentary lives on a separate "door" playlist over the same clip; re-encoding
  the episode to add one audio track would spend GPU time and replace a verified picture. So the
  PUBLISHED file is copied back (read-only robocopy), the commentary is muxed in with mkvmerge, and
  the result goes back to the same NAS path as an in-place replacement.

.PER EPISODE - every step is a measurement, and every failure stops that episode
  1. The door rip exists, was verified by the ripper, and carries the directive's audio count, all 2.0.
  2. The published file is copied from the NAS into the work folder (robocopy, via PowerShell), size
     checked. If it ALREADY carries a stream flagged commentary: status already-has-commentary, stop.
  3. IDENTITY, by analyze-tracks.py - reused, not reimplemented. A probe .mka is muxed from the
     published programme track + every door stream and analysed: the programme must be `primary`,
     exactly ONE door stream `commentary`, every other door stream `redundant` WITH that one. A lone
     `commentary?` earns ONE second analysis at five spread offsets and passes only if that pass
     CONFIRMS it (S9 D1 clip 00062 needed this); any remaining `commentary?`, a dub, music, silence
     or a second distinct commentary = STOP (a human decides).
  4. SYNC, by commentary-sync-proof.py: whole-file video cut-correlation door-vs-published (decisive)
     and the commentary's envelope against the published programme (corroboration, with a
     wrong-stretch control). ok=false, or a video offset beyond one frame = STOP. No offset is ever
     applied: the build is approved only for timelines that already agree.
  5. BUILD, mkvmerge: every track of the published file unchanged, plus the commentary copied
     bit-for-bit (AC-3 2.0), language eng, title "Audio Commentary", commentary flag on, default off.
  6. VERIFY the build: same video, same subtitles, the published audio tracks identical in order and
     attributes, the video packet count unchanged, exactly one more audio track with the right
     flags, the new track's end within 1.5 s of the video's, and the container = the longer of the
     published file and the commentary (it may grow by the commentary's tail, never shrink).
  7. HAND OVER (-Publish only): move the build to the episode's local library path. _publish-loop.ps1
     sees a local file whose NAS copy differs in size and republishes the work with -Overwrite - the
     same in-place route Man In A Suitcase S01E14 took on 09-18 (a manifest `out` equal to the
     existing NAS name, no `supersedes`). The existing .eng.srt stays valid: the video is the same
     bytes. The owner confirms in Plex; approve-confirmed.ps1 then lets the reclaim release the copy.
     Refused if a file already sits at the local path.

  Results: <root>/<unit>/<episode>/result.json (status: handed-over | recovered | stopped |
  already-has-commentary | not-yet), and <root>/_status.json across all units.

.EXIT CODES  0 = every episode attempted is handed over / recovered / already had one
             2 = at least one episode STOPPED (see its result.json)
             3 = not yet (NAS hold, nothing ripped, another instance would not yield)
#>
param(
  [string]$Unit = '',
  [switch]$Pending,
  [string]$RecoveryRoot = 'D:/video/_recovery',
  [switch]$Publish,
  # Stop after the identity and sync proofs (status 'proven'): nothing is built. For testing a disc
  # whose episodes are not published yet, against its raw clip.
  [switch]$ProveOnly,
  [string[]]$Episode = @(),
  # TEST SEAM: episode -> local file standing in for the NAS copy. Never used by the line.
  [hashtable]$PublishedOverride = @{},
  # TEST SEAM: episode -> door .mkv, bypassing _rip.json (the known-negative uses a WRONG door).
  [hashtable]$DoorOverride = @{},
  [string]$NasHold = 'D:/video/_nas-hold',
  # Hand-over is refused outside this prefix. A parameter only so the tests can hand over into a
  # scratch "library" instead of the real one - which the publish loop would ship to the NAS.
  [string]$LibraryPrefix = 'D:/video/Television Shows/',
  [int]$MutexWaitMinutes = 180
)
$ErrorActionPreference = 'Stop'
$scripts = $PSScriptRoot
. 'D:/video/.claude/skills/disc-backup/scripts/lib-recovery.ps1'
if (-not (Get-Command Get-RecoveryRipState -ErrorAction SilentlyContinue)) { Write-Host 'lib-recovery.ps1 did not load - refusing'; exit 3 }
$tools = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
$ffmpeg = $tools.ffmpeg
$ffprobe = Join-Path (Split-Path $ffmpeg) 'ffprobe.exe'
$mkvmerge = Join-Path (Split-Path $tools.mkvextract) 'mkvmerge.exe'
function Say([string]$m) { Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $m) }

# ONE AT A TIME. The optical track starts this after every targeted rip; a second start WAITS for the
# first rather than exiting, so a rip finishing just as the first run ends is never left unprocessed.
$mutex = New-Object System.Threading.Mutex($false, ('Global' + [char]92 + 'video-commentary-recovery'))
if ($null -eq $mutex) { Write-Host 'no mutex - refusing to run unguarded'; exit 3 }
try { $got = $mutex.WaitOne([TimeSpan]::FromMinutes($MutexWaitMinutes)) } catch [System.Threading.AbandonedMutexException] { $got = $true }
if (-not $got) { Say 'another recovery run held the lock for too long - giving up this start'; exit 3 }

function Probe-Streams([string]$path) {
  $j = (& $ffprobe -v error -show_entries 'format=duration:stream=index,codec_type,codec_name,channels:stream_tags=language,title:stream_disposition=default,comment' -of json $path 2>$null) -join "`n" | ConvertFrom-Json
  return $j
}
function Get-StreamEnd([string]$path, [string]$sel, [double]$dur) {
  $pts = @(& $ffprobe -v error -select_streams $sel -read_intervals ("{0}%+#100000" -f [int][math]::Max(0, $dur - 60)) -show_entries packet=pts_time,duration_time -of csv=p=0 $path 2>$null |
           Where-Object { $_ -match '^[0-9.]+,[0-9.]+' })
  if (-not $pts.Count) { return 0.0 }
  $l = $pts[-1] -split ','; return [double]$l[0] + [double]$l[1]
}
function Write-Result($dir, [hashtable]$r) {
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $r['when'] = Get-Date -Format 's'
  ([pscustomobject]$r) | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $dir 'result.json') -Encoding UTF8
}

function Invoke-EpisodeRecovery($d, $e) {
  $ep = "$($e.episode)"
  $work = Join-Path (Join-Path $RecoveryRoot "$($d.unit)") $ep
  New-Item -ItemType Directory -Force -Path $work | Out-Null
  $r = [ordered]@{ unit = "$($d.unit)"; episode = $ep; title = "$($e.title)"; nasPath = "$($e.nasPath)"; localPath = "$($e.localPath)"; status = 'stopped'; reasons = @(); steps = [ordered]@{} }
  $stop = { param($why) $r.reasons += $why; Say ("*** {0} STOPPED: {1}" -f $ep, $why); Write-Result $work $r; return [pscustomobject]$r }

  # ---- 1. the door rip ----------------------------------------------------------------------------
  $door = $null
  if ($DoorOverride.ContainsKey($ep)) { $door = $DoorOverride[$ep] }
  else {
    $rj = Join-Path (Join-Path (Join-Path $RecoveryRoot "$($d.unit)") 'rip') '_rip.json'
    if (Test-Path -LiteralPath $rj) {
      $x = @((Get-Content -LiteralPath $rj -Raw | ConvertFrom-Json).episodes | Where-Object { "$($_.episode)" -eq $ep -and $_.verified }) | Select-Object -First 1
      if ($x) { $door = Join-Path (Split-Path $rj) $x.file }
    }
  }
  if (-not $door -or -not (Test-Path -LiteralPath $door)) { $r.status = 'not-yet'; $r.reasons += 'no verified door rip for this episode yet'; Write-Result $work $r; return [pscustomobject]$r }
  $dj = Probe-Streams $door
  $dAud = @($dj.streams | Where-Object { $_.codec_type -eq 'audio' })
  $wantN = [int]$e.doorAudio.count
  $r.steps['door'] = [ordered]@{ file = $door; audio = $dAud.Count; seconds = [double]$dj.format.duration }
  if ($dAud.Count -notin @($wantN, [int]("0$($e.fallbackAudio.count)")) -or @($dAud | Where-Object { [int]$_.channels -ne 2 }).Count) {
    return & $stop ("door rip carries {0} audio stream(s) ({1}) - the directive expects {2} English 2.0" -f $dAud.Count, (($dAud | ForEach-Object { "$($_.codec_name)/$($_.channels)" }) -join ','), $wantN)
  }

  # ---- 2. the published file, copied back read-only -------------------------------------------
  $pubDir = Join-Path $work 'published'
  New-Item -ItemType Directory -Force -Path $pubDir | Out-Null
  $pub = Join-Path $pubDir "$($e.publishedName)"
  if ($PublishedOverride.ContainsKey($ep)) {
    # Used IN PLACE, read-only - never copied (a 2.6-3.9 GB copy per test) and never deleted: the
    # cleanup below removes $pub only when it lies inside this episode's work folder.
    $pub = $PublishedOverride[$ep]
    $r.steps['published'] = [ordered]@{ from = $PublishedOverride[$ep]; note = 'TEST SEAM: local stand-in, not the NAS' }
  } else {
    if (Test-Path -LiteralPath $NasHold) { $r.status = 'not-yet'; $r.reasons += 'NAS hold is on - not reading the NAS'; Write-Result $work $r; return [pscustomobject]$r }
    $nasDir = Split-Path "$($e.nasPath)" -Parent
    $nasItem = Get-Item -LiteralPath "$($e.nasPath)" -ErrorAction SilentlyContinue
    if (-not $nasItem) { return & $stop ("the published file is not at {0}" -f $e.nasPath) }
    if (-not (Test-Path -LiteralPath $pub) -or (Get-Item -LiteralPath $pub).Length -ne $nasItem.Length) {
      $rc = & robocopy $nasDir $pubDir "$($e.publishedName)" /R:2 /W:5 /NP /NFL /NDL /NJH /NJS
      if ($LASTEXITCODE -ge 8) { return & $stop ("robocopy of the published file failed (exit {0})" -f $LASTEXITCODE) }
    }
    if (-not (Test-Path -LiteralPath $pub) -or (Get-Item -LiteralPath $pub).Length -ne $nasItem.Length) { return & $stop 'the copied published file does not match the NAS size' }
    $r.steps['published'] = [ordered]@{ from = "$($e.nasPath)"; bytes = $nasItem.Length; lastWrite = $nasItem.LastWriteTime.ToString('s') }
  }
  $pj = Probe-Streams $pub
  $pAud = @($pj.streams | Where-Object { $_.codec_type -eq 'audio' })
  if (@($pAud | Where-Object { $_.disposition.comment -eq 1 }).Count) {
    $r.status = 'already-has-commentary'; $r.reasons += 'the published file already carries a stream flagged commentary - nothing to do'
    Say ("{0}: already has a commentary - nothing to do" -f $ep); Write-Result $work $r; return [pscustomobject]$r
  }

  # ---- 3. identity: analyze-tracks.py over programme + every door stream ----------------------
  $pm = & $mkvmerge -J $pub | ConvertFrom-Json
  $pubAudioIds = @($pm.tracks | Where-Object { $_.type -eq 'audio' } | ForEach-Object { $_.id })
  $probe = Join-Path $work 'probe.mka'
  & $mkvmerge -q -o $probe --no-video --no-subtitles --no-chapters --no-attachments -a $pubAudioIds[0] $pub --no-video --no-subtitles --no-chapters --no-attachments $door
  if ($LASTEXITCODE -ge 2) { return & $stop "mkvmerge could not build the analysis probe (exit $LASTEXITCODE)" }
  $tj = Join-Path $work 'probe.tracks.json'
  & python (Join-Path $scripts 'analyze-tracks.py') $probe --out $tj *> (Join-Path $work 'analyze.log')
  if (-not (Test-Path -LiteralPath $tj)) { return & $stop 'analyze-tracks.py wrote no evidence (see analyze.log)' }
  $ev = Get-Content -LiteralPath $tj -Raw | ConvertFrom-Json
  $st = @($ev.streams)
  # ONE MORE LOOK FOR AN UNCERTAIN COMMENTARY - the analyzer's own tool, with more evidence.
  # Two 75 s samples are enough for a KEEP and not always for a label: S9 D1's door over clip 00062
  # (31:59) came back `commentary?` at the default offsets and `commentary` at five spread ones, where
  # every sample is plainly production talk ("the comedy of the scene is between the two guys...").
  # Only this exact shape earns the second pass - ONE `commentary?` door stream, no confirmed one,
  # every other door stream a copy of it - and only a CONFIRMED result counts; anything else stops.
  $unsure = @($st | Where-Object { [int]$_.a -ge 1 -and $_.role -eq 'commentary?' })
  $sure = @($st | Where-Object { [int]$_.a -ge 1 -and $_.role -eq 'commentary' })
  if ($unsure.Count -eq 1 -and $sure.Count -eq 0) {
    $dur = [double]$ev.duration
    $offs = @(0.15, 0.35, 0.55, 0.75, 0.9 | ForEach-Object { [int]($dur * $_) })
    $tj2 = Join-Path $work 'probe.5offsets.tracks.json'
    & python (Join-Path $scripts 'analyze-tracks.py') $probe --offsets @offs --out $tj2 *> (Join-Path $work 'analyze-5offsets.log')
    if (Test-Path -LiteralPath $tj2) {
      $r.steps['identityFirstPass'] = [ordered]@{ evidence = $tj; roles = (($st | ForEach-Object { "a:$($_.a)=$($_.role)" }) -join ', ') }
      $tj = $tj2; $ev = Get-Content -LiteralPath $tj -Raw | ConvertFrom-Json; $st = @($ev.streams)
    }
  }
  $roles = ($st | ForEach-Object { "a:$($_.a)=$($_.role)" + $(if ($null -ne $_.redundantWith) { "(of a:$($_.redundantWith))" } else { '' }) }) -join ', '
  $r.steps['identity'] = [ordered]@{ evidence = $tj; roles = $roles }
  if ($st.Count -ne 1 + $dAud.Count) { return & $stop ("analysis saw {0} stream(s), expected {1}: {2}" -f $st.Count, (1 + $dAud.Count), $roles) }
  if ($st[0].role -ne 'primary') { return & $stop ("the published programme is not 'primary' in the analysis ({0})" -f $roles) }
  $comms = @($st | Where-Object { [int]$_.a -ge 1 -and $_.role -eq 'commentary' })
  # A HUMAN VERDICT, RECORDED IN THE DIRECTIVE, for the one shape the analyser cannot settle alone:
  # the episode directive carries confirmedCommentary (the probe ordinal) + confirmedBy (who read the
  # transcripts, and what they heard). It promotes ONLY a stream the analysis already calls
  # `commentary?` - never a dub, music, silence or the programme - and every later check (copies,
  # sync, build) still applies. S08E03 (2026-09-19): the commentary opens under the episode's own
  # dialogue, so both analyses said `commentary?`; its samples are production talk throughout.
  if ($comms.Count -eq 0 -and $e.PSObject.Properties.Name -contains 'confirmedCommentary' -and "$($e.confirmedBy)") {
    $hc = @($st | Where-Object { [int]$_.a -eq [int]$e.confirmedCommentary -and $_.role -eq 'commentary?' })
    if ($hc.Count -eq 1) {
      $comms = $hc
      $r.steps['humanVerdict'] = [ordered]@{ stream = [int]$e.confirmedCommentary; by = "$($e.confirmedBy)" }
      Say ("{0}: a:{1} taken as the commentary on a recorded human verdict - {2}" -f $ep, $e.confirmedCommentary, $e.confirmedBy)
    }
  }
  if ($comms.Count -ne 1) { return & $stop ("{0} door stream(s) measured as commentary, need exactly 1: {1}" -f $comms.Count, $roles) }
  $c = [int]$comms[0].a
  $others = @($st | Where-Object { [int]$_.a -ge 1 -and [int]$_.a -ne $c })
  $notCopies = @($others | Where-Object { $_.role -ne 'redundant' -or [int]$_.redundantWith -ne $c })
  if ($notCopies.Count) { return & $stop ("door stream(s) that are not copies of the commentary: {0}" -f $roles) }
  if ([int]$comms[0].channels -gt [int]$st[0].channels) { return & $stop 'the commentary is wider than the programme - inverted evidence' }
  $doorOrdinal = $c - 1
  $r.steps['identity']['commentaryDoorOrdinal'] = $doorOrdinal
  $r.steps['identity']['similarityToProgramme'] = $comms[0].similarityToPrimary
  $r.steps['identity']['sample'] = (@($comms[0].samples) | Select-Object -First 1 | ForEach-Object { "$_".Substring(0, [math]::Min(200, "$_".Length)) })

  # ---- 4. sync ----------------------------------------------------------------------------------
  $sj = Join-Path $work 'sync.json'
  & python (Join-Path $scripts 'commentary-sync-proof.py') --door $door --door-audio $doorOrdinal --published $pub --json $sj *> (Join-Path $work 'sync.log')
  $sp = if (Test-Path -LiteralPath $sj) { Get-Content -LiteralPath $sj -Raw | ConvertFrom-Json } else { $null }
  if (-not $sp) { return & $stop 'the sync proof wrote nothing (see sync.log)' }
  $r.steps['sync'] = [ordered]@{ ok = $sp.ok; offsetMs = $sp.offsetMs; videoMatchedWindows = $sp.videoMatchedWindows; audioMedianR = $sp.audioMedianR; audioMedianControlR = $sp.audioMedianControlR; reasons = @($sp.reasons); evidence = $sj }
  if (-not $sp.ok) { return & $stop ("sync NOT proven: {0}" -f (@($sp.reasons) -join ' | ')) }

  if ($ProveOnly) {
    $r.status = 'proven'; Say ("{0}: identity and sync PROVEN (-ProveOnly: nothing built)" -f $ep)
    Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
    Write-Result $work $r; return [pscustomobject]$r
  }

  # ---- 5. build ---------------------------------------------------------------------------------
  $dm = & $mkvmerge -J $door | ConvertFrom-Json
  $tid = @($dm.tracks | Where-Object { $_.type -eq 'audio' })[$doorOrdinal].id
  $built = Join-Path (Join-Path $work 'built') "$($e.publishedName)"
  New-Item -ItemType Directory -Force -Path (Split-Path $built) | Out-Null
  if (Test-Path -LiteralPath $built) { Remove-Item -LiteralPath $built -Force }
  & $mkvmerge -q -o $built $pub --no-video --no-subtitles --no-chapters --no-attachments --no-global-tags --no-track-tags -a $tid `
      --language "${tid}:en" --track-name "${tid}:Audio Commentary" --default-track-flag "${tid}:0" --commentary-flag "${tid}:1" $door
  $mmExit = $LASTEXITCODE
  if ($mmExit -ge 2 -or -not (Test-Path -LiteralPath $built)) { return & $stop "mkvmerge build failed (exit $mmExit)" }

  # ---- 6. verify the build ------------------------------------------------------------------------
  $bj = Probe-Streams $built
  $sig = { param($s) "{0}|{1}|{2}|{3}|{4}|{5}" -f $s.codec_type, $s.codec_name, $s.channels, $s.tags.language, $s.tags.title, $s.disposition.default }
  $pS = @($pj.streams); $bS = @($bj.streams)
  $why = @()
  foreach ($kind in 'video', 'subtitle') {
    $a = @($pS | Where-Object { $_.codec_type -eq $kind } | ForEach-Object { & $sig $_ }) -join ';'
    $b = @($bS | Where-Object { $_.codec_type -eq $kind } | ForEach-Object { & $sig $_ }) -join ';'
    if ($a -ne $b) { $why += "$kind streams differ: [$a] vs [$b]" }
  }
  $pA = @($pS | Where-Object { $_.codec_type -eq 'audio' }); $bA = @($bS | Where-Object { $_.codec_type -eq 'audio' })
  if ($bA.Count -ne $pA.Count + 1) { $why += ("{0} audio track(s) built, expected {1}" -f $bA.Count, ($pA.Count + 1)) }
  else {
    for ($i = 0; $i -lt $pA.Count; $i++) { if ((& $sig $pA[$i]) -ne (& $sig $bA[$i])) { $why += ("published audio {0} changed: {1} -> {2}" -f $i, (& $sig $pA[$i]), (& $sig $bA[$i])) } }
    $n = $bA[-1]
    if ($n.codec_name -ne 'ac3' -or [int]$n.channels -ne 2) { $why += "new track is $($n.codec_name)/$($n.channels), expected ac3/2" }
    if ($n.tags.language -ne 'eng') { $why += "new track language '$($n.tags.language)'" }
    if ($n.tags.title -ne 'Audio Commentary') { $why += "new track title '$($n.tags.title)'" }
    if ($n.disposition.comment -ne 1) { $why += 'new track is not flagged commentary' }
    if ($n.disposition.default -ne 0) { $why += 'new track is flagged default' }
  }
  $pd = [double]$pj.format.duration; $bd = [double]$bj.format.duration
  $vEnd = Get-StreamEnd $built 'v:0' $bd
  $cEnd = Get-StreamEnd $built ("a:{0}" -f ($bA.Count - 1)) $bd
  # THE TWO ENDS ARE NOT SYMMETRIC, AND THIS TEST TREATED THEM AS IF THEY WERE.
  #   ends EARLY  - the commentary stops before the picture does: coverage is missing, and no
  #                 amount of proven sync makes that acceptable. Still 1.5 s.
  #   ends LATE   - the disc's commentary clip simply runs on past the last frame of the episode.
  #                 The container check below already assumes exactly this ($wantEnd takes the
  #                 LONGER of the two), so refusing it here contradicted the line underneath.
  # The overhang is not unbounded: it can be no longer than the door clip itself, which is measured.
  # Friends S06E15 (2026-09-20) stopped at 2.94 s over, with identity proven, sync offset 42 ms and
  # 6 of 6 luma windows matched - and its door clip is 1,321.31 s against a 1,318.40 s episode, so
  # every millisecond of the overhang was accounted for by the clip's own length.
  $doorEnd = [double]$r.steps['door']['seconds']
  $lateAllowed = [math]::Max(1.5, ($doorEnd - $vEnd) + 0.5)
  if ($vEnd -le 0 -or $cEnd -le 0 -or ($cEnd -lt $vEnd - 1.5) -or ($cEnd -gt $vEnd + $lateAllowed)) {
    $why += ("commentary ends {0:N2}s, video {1:N2}s (door clip {2:N2}s, so at most {3:N2}s of overhang is explained)" -f $cEnd, $vEnd, $doorEnd, $lateAllowed)
  }
  # The container may GROW to the commentary's own end - the disc's commentary runs ~1.3 s past the
  # last frame, exactly as the one transcode.ps1 shipped for S08E23 from the raw clip (1318.752 s).
  # It must never shrink, and must not grow past the longer of the two.
  $wantEnd = [math]::Max($pd, $cEnd)
  if ($bd -lt $pd - 0.05 -or [math]::Abs($bd - $wantEnd) -gt 0.1) { $why += ("container {0:N3}s; published {1:N3}s, commentary end {2:N3}s" -f $bd, $pd, $cEnd) }
  # The picture must be the published picture, packet for packet.
  $vp = { param($f) "$(& $ffprobe -v error -count_packets -select_streams v:0 -show_entries stream=nb_read_packets -of csv=p=0 $f 2>$null)".Trim().TrimEnd(',') }
  $pvp = & $vp $pub; $bvp = & $vp $built
  if (-not $pvp -or $pvp -ne $bvp) { $why += ("video packets {0} built vs {1} published" -f $bvp, $pvp) }
  $r.steps["verify"] = [ordered]@{ built = $built; bytes = (Get-Item -LiteralPath $built).Length; publishedSeconds = $pd; builtSeconds = $bd; videoEnd = $vEnd; commentaryEnd = $cEnd; videoPackets = $bvp; publishedVideoPackets = $pvp; mkvmergeExit = $mmExit; problems = $why }
  if ($why.Count) { return & $stop ("the build did not verify: {0}" -f ($why -join '; ')) }

  # ---- 7. hand over -----------------------------------------------------------------------------
  $r.status = 'recovered'
  if ($Publish) {
    $target = "$($e.localPath)"
    if (-not ($target.Replace([char]92, '/')).StartsWith($LibraryPrefix.Replace([char]92, '/'))) { return & $stop "refusing a hand-over path outside $LibraryPrefix : $target" }
    if (Test-Path -LiteralPath $target) { return & $stop ("a file already sits at {0} - not overwriting a local copy the reclaim has not released" -f $target) }
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    Move-Item -LiteralPath $built -Destination $target
    $r.status = 'handed-over'; $r.steps['handover'] = [ordered]@{ to = $target; route = '_publish-loop.ps1 republishes the work with -Overwrite (NAS copy differs in size); owner confirms in Plex; approve-confirmed.ps1 then reclaims' }
    Say ("{0}: HANDED OVER - {1} (the publish loop replaces the NAS copy in place)" -f $ep, $target)
  } else {
    Say ("{0}: RECOVERED and verified - {1} (report mode: not handed over; re-run with -Publish)" -f $ep, $built)
  }
  # the working copies of the published file and the probe are no longer needed
  Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue
  if ([IO.Path]::GetFullPath($pub).StartsWith([IO.Path]::GetFullPath($work))) { Remove-Item -LiteralPath $pub -Force -ErrorAction SilentlyContinue }
  Write-Result $work $r
  return [pscustomobject]$r
}

try {
  $dirs = @(Get-RecoveryDirectives -Dir $RecoveryRoot)
  if ($Unit) { $dirs = @($dirs | Where-Object { "$($_.Directive.unit)" -eq $Unit }) }
  elseif (-not $Pending) { Say 'give -Unit <unit> or -Pending'; exit 3 }
  if (-not $dirs.Count) { Say 'no matching recovery directive'; exit 3 }
  $results = @()
  foreach ($x in $dirs) {
    $d = $x.Directive
    $st = Get-RecoveryRipState -Dir $RecoveryRoot -Directive $d
    foreach ($e in @($d.episodes)) {
      if ($Episode.Count -and $Episode -notcontains "$($e.episode)") { continue }
      $prev = Join-Path (Join-Path (Join-Path $RecoveryRoot "$($d.unit)") "$($e.episode)") 'result.json'
      if (Test-Path -LiteralPath $prev) {
        $p = Get-Content -LiteralPath $prev -Raw | ConvertFrom-Json
        if ("$($p.status)" -in 'handed-over', 'already-has-commentary' -or ("$($p.status)" -eq 'recovered' -and -not $Publish)) { $results += $p; continue }
      }
      if (-not $DoorOverride.ContainsKey("$($e.episode)") -and $st.Ripped -notcontains "$($e.episode)") { continue }
      Say ("--- {0} {1} ({2})" -f $d.unit, $e.episode, $e.title)
      try { $results += Invoke-EpisodeRecovery $d $e }
      catch { $results += [pscustomobject]@{ unit = "$($d.unit)"; episode = "$($e.episode)"; status = 'stopped'; reasons = @("threw: $($_.Exception.Message)") }; Say ("*** {0} threw: {1}" -f $e.episode, $_.Exception.Message) }
    }
    # A UNIT WHOSE EVERY EPISODE IS DONE NO LONGER NEEDS ITS DOOR RIPS (D: only, ~2.6 GB each).
    $allDone = $true
    foreach ($e in @($d.episodes)) {
      $rp = Join-Path (Join-Path (Join-Path $RecoveryRoot "$($d.unit)") "$($e.episode)") 'result.json'
      $s = if (Test-Path -LiteralPath $rp) { "$((Get-Content -LiteralPath $rp -Raw | ConvertFrom-Json).status)" } else { '' }
      if ($s -notin 'handed-over', 'already-has-commentary') { $allDone = $false }
    }
    if ($allDone) {
      $ripDir = Join-Path (Join-Path $RecoveryRoot "$($d.unit)") 'rip'
      foreach ($f in @(Get-ChildItem -LiteralPath $ripDir -Filter '*.mkv' -File -ErrorAction SilentlyContinue)) {
        if ($f.FullName.StartsWith([IO.Path]::GetFullPath($RecoveryRoot))) { Remove-Item -LiteralPath $f.FullName -Force }
      }
      Say ("{0}: every episode handed over - door rips released" -f $d.unit)
      # CLOSE THE DISC'S OWN RECORD. The optical loop writes `<unit>.inserted.json` when the disc
      # goes in; leaving it open makes a finished disc look like one still in the drive, and the
      # `.recovered` marker is what tells the next session this unit is settled. Both were being
      # written by hand after every disc - a manual step in an otherwise self-draining lane.
      $eps = @(@($d.episodes) | ForEach-Object { "$($_.episode)" }) -join ' + '
      $doneNote = "$eps handed over $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
      Set-Content -LiteralPath (Join-Path $RecoveryRoot "$($d.unit).recovered") -Value $doneNote -Encoding UTF8
      $ins = Join-Path $RecoveryRoot "$($d.unit).inserted.json"
      if (Test-Path -LiteralPath $ins) {
        try { Move-Item -LiteralPath $ins -Destination (Join-Path $RecoveryRoot "$($d.unit).inserted.done.json") -Force } catch { }
      }
    }
  }
  # board-readable summary across every unit
  $all = @()
  foreach ($x in @(Get-RecoveryDirectives -Dir $RecoveryRoot)) {
    foreach ($e in @($x.Directive.episodes)) {
      $rp = Join-Path (Join-Path (Join-Path $RecoveryRoot "$($x.Directive.unit)") "$($e.episode)") 'result.json'
      $s = if (Test-Path -LiteralPath $rp) { Get-Content -LiteralPath $rp -Raw | ConvertFrom-Json } else { $null }
      $all += [ordered]@{ unit = "$($x.Directive.unit)"; disc = "$($x.Directive.discName)"; episode = "$($e.episode)"; status = $(if ($s) { "$($s.status)" } else { 'awaiting-disc' }); reasons = $(if ($s) { @($s.reasons) } else { @() }) }
    }
  }
  if (-not $PublishedOverride.Count -and -not $DoorOverride.Count) {
    [ordered]@{ updated = (Get-Date -Format 's'); episodes = $all } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $RecoveryRoot '_status.json') -Encoding UTF8
  }
  foreach ($x in $results) { Say ("  {0} {1}: {2}{3}" -f $x.unit, $x.episode, $x.status, $(if (@($x.reasons).Count) { ' - ' + (@($x.reasons) -join ' | ') } else { '' })) }
  if (@($results | Where-Object { $_.status -eq 'stopped' }).Count) { exit 2 }
  exit 0
} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }
