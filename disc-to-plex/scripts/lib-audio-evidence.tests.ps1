<#
  Tests for lib-audio-evidence.ps1 and, through it, assert-tracks-analysed.ps1's two new verdicts.
  Run: pwsh -File lib-audio-evidence.tests.ps1     (exit 0 = all passed)

  THE TWO CASES THAT ACTUALLY BIT, both on bladerunner-d1.json (2026-09-04):

    * `00004.m2ts` carries exactly ONE audio stream and the manifest claims `audioTracks: [0]`,
      which the gate exempts. It did not fire, because a raw Blu-ray stream is an MPEG-TS and
      ffprobe prints every TS stream TWICE in csv mode - once under `programs`, once under
      `streams`. One stream counted as three. Test 5 counts it both ways and asserts they differ,
      so the test fails if anyone "simplifies" the json read back to csv.

    * `00047.m2ts` had no evidence and nothing on the machine would ever write any, so the gate
      returned exit 4 - "wait and retry" - and lane-runner circled the manifest for hours. Tests
      10-13 fix the boundary: absent-but-possible stays a WAIT (4), absent-and-impossible becomes a
      REFUSAL (2) that names the reason.

  THE NEGATIVES CARRY THE WEIGHT. Anything Test-AudioSourceAnalysable calls unanalysable is refused
  outright, so a false negative would fail a healthy manifest that merely needed to wait a minute
  longer. Tests 6-9 assert every *analysable* shape as well as the impossible ones, and tests 15-16
  prove the contradiction checks the gate already had are untouched.
#>
. "$PSScriptRoot/lib-audio-evidence.ps1"
foreach ($fn in @('Get-AudioEvidencePath', 'Test-AudioSourceAnalysable', 'Get-ManifestAudioWork',
                  'Get-AudioStreamCount')) {
  if (-not (Get-Command $fn -ErrorAction SilentlyContinue)) {
    Write-Output "FAIL: lib-audio-evidence.ps1 did not load ($fn missing)"   # dot-source failures do not throw
    exit 1
  }
}

$fails = 0
function Check($name, $got, $want) {
  if ("$got" -eq "$want") { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - got '$got', want '$want'"; $script:fails++ }
}
function CheckMatch($name, $got, $rx) {
  if ("$got" -match $rx) { Write-Output "  ok   $name" }
  else { Write-Output "  FAIL $name - '$got' does not match /$rx/"; $script:fails++ }
}

$gate = "$PSScriptRoot/assert-tracks-analysed.ps1"
$tmp  = Join-Path ([IO.Path]::GetTempPath()) ('audioev-tests-' + [guid]::NewGuid().ToString('N'))

# REAL MPEG-TS SOURCES, because the defect these tests exist for cannot be faked: ffprobe's
# duplicate csv listing only happens in a real transport stream. Skipped, never faked, when the
# disc is not staged.
#
# DELIBERATELY NOT the streams bladerunner-d1.json names. A test asserting exit 4 ("no evidence
# yet") against a source that is about to ACQUIRE evidence passes today and fails tomorrow for a
# reason that has nothing to do with the code. 00001 (one audio stream) and 00003 (none) are on the
# same disc, in no manifest, and the gate-exit assertions below are additionally guarded on the
# evidence still being absent.
$tsOne  = 'D:/video/_stage/Bladerunner Disk 1/BDMV/STREAM/00001.m2ts'   # exactly ONE audio stream
$tsMany = 'D:/video/_stage/Bladerunner Disk 1/BDMV/STREAM/00047.m2ts'   # ten
$ffprobe = $null
try {
  $tp = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
  $ffprobe = Join-Path (Split-Path $tp.ffmpeg) 'ffprobe.exe'
} catch {}

function Manifest([string]$name, $items) {
  $p = Join-Path $tmp $name
  ($items | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath $p -Encoding UTF8
  $p
}
function HaveTs([string]$p) {
  # usable AND still unmeasured - see the note on $tsOne above
  return ($ffprobe -and (Test-Path -LiteralPath $ffprobe) -and (Test-Path -LiteralPath $p) -and
          -not (Test-Path -LiteralPath "$p.tracks.json"))
}
function GateExit([string]$manifest) {
  # NEVER READ AN EXIT CODE THROUGH A PIPE - a pipeline reports the LAST element's status. Capture
  # into a variable, read $LASTEXITCODE immediately, filter afterwards.
  $script:gateOut = & pwsh -NoProfile -File $gate -Manifest $manifest 2>&1
  $LASTEXITCODE
}

try {
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null
  $dvd = Join-Path $tmp 'Some Disc'
  New-Item -ItemType Directory -Path (Join-Path $dvd 'VIDEO_TS') -Force | Out-Null
  $plainDir = Join-Path $tmp 'not-a-disc'
  New-Item -ItemType Directory -Path $plainDir -Force | Out-Null
  $file = Join-Path $tmp 'title_t00.mkv'
  Set-Content -LiteralPath $file -Value 'not really an mkv' -Encoding ASCII
  $list = Join-Path $tmp 'segments.txt'
  Set-Content -LiteralPath $list -Value "file 'a.m2ts'" -Encoding ASCII

  Write-Output '1. evidence path: a DVD folder with a title is TITLE-AWARE, a file is not'
  Check 'dvd'  (Get-AudioEvidencePath -Src $dvd -Title 7) "$dvd.title7.tracks.json"
  Check 'file' (Get-AudioEvidencePath -Src $file -Title $null) "$file.tracks.json"

  Write-Output '2. evidence path: a title on a FILE src is ignored (only a folder is title-keyed)'
  #    analyze-tracks.py only writes .title<N>. under --dvd-title, which only applies to a folder.
  Check 'file+title' (Get-AudioEvidencePath -Src $file -Title 3) "$file.tracks.json"

  Write-Output '3. NEGATIVE: the four permanently unanalysable shapes, each with a reason'
  Check 'no src'        (Test-AudioSourceAnalysable -Src '' ).Analysable            'False'
  Check 'missing file'  (Test-AudioSourceAnalysable -Src (Join-Path $tmp 'ghost.mkv')).Analysable 'False'
  Check 'plain folder'  (Test-AudioSourceAnalysable -Src $plainDir).Analysable      'False'
  Check 'dvd, no title' (Test-AudioSourceAnalysable -Src $dvd).Analysable           'False'
  Check 'concat list'   (Test-AudioSourceAnalysable -Src $list).Analysable          'False'
  CheckMatch 'missing file names the cause' (Test-AudioSourceAnalysable -Src (Join-Path $tmp 'ghost.mkv')).Reason 'does not exist on disk'
  CheckMatch 'concat list names the cause'  (Test-AudioSourceAnalysable -Src $list).Reason 'concat list'

  Write-Output '4. POSITIVE: the shapes that CAN be measured are not refused'
  Check 'dvd + title' (Test-AudioSourceAnalysable -Src $dvd -Title 7).Analysable 'True'
  Check 'media file'  (Test-AudioSourceAnalysable -Src $file).Analysable         'True'
  Check 'm2ts'        (Test-AudioSourceAnalysable -Src (Join-Path $tmp 'x.m2ts')).Analysable 'False'   # absent
  Copy-Item -LiteralPath $file -Destination (Join-Path $tmp 'x.m2ts')
  Check 'm2ts present' (Test-AudioSourceAnalysable -Src (Join-Path $tmp 'x.m2ts')).Analysable 'True'

  Write-Output '5. THE MPEG-TS DOUBLE COUNT: json says 1 stream, csv says 3 - they must differ'
  if (HaveTs $tsOne) {
    Check 'json count' (Get-AudioStreamCount -Ffprobe $ffprobe -Src $tsOne).Count 1
    Check 'probed'     (Get-AudioStreamCount -Ffprobe $ffprobe -Src $tsOne).Probed 'True'
    $csv = @(& $ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 -i $tsOne 2>$null).Count
    if ($csv -eq 1) {
      Write-Output "  FAIL csv/json divergence - csv also returned 1, so this test no longer proves anything"
      $script:fails++
    } else { Write-Output "  ok   csv returns $csv for a ONE-stream TS (this is the defect)" }
  } else {
    Write-Output '  SKIP - Bladerunner Disk 1 is not staged; nothing to measure a real TS against'
  }

  Write-Output '6. work list: only items that MAKE an audio claim are work'
  $m = Manifest 'claims.json' @(
    @{ out = 'a.mkv'; src = $file },                       # no claim at all
    @{ out = 'b.mkv'; src = $file; audioTracks = @(0, 1) },
    @{ out = 'c.mkv'; src = $dvd;  title = 7; commentary = @(3) }
  )
  Check 'rows' @(Get-ManifestAudioWork -Manifest $m).Count 2
  Check 'srcs' ((@(Get-ManifestAudioWork -Manifest $m) | ForEach-Object { Split-Path $_.Src -Leaf }) -join ',') "title_t00.mkv,Some Disc"

  Write-Output '7. THE CALLER''S FORM: @(...).Count must be right at 0, 1 and N'
  #    A function returning `,$rows` reports 1 for every non-empty result, and the loop iterates
  #    exactly this form. Both shapes are asserted and must agree.
  $m0 = Manifest 'none.json' @(@{ out = 'a.mkv'; src = $file })
  Check 'wrapped 0' @(Get-ManifestAudioWork -Manifest $m0).Count 0
  Check 'wrapped 2' @(Get-ManifestAudioWork -Manifest $m).Count 2
  $m1 = Manifest 'one.json' @(@{ out = 'b.mkv'; src = $file; audioTracks = @(0, 1) })
  Check 'wrapped 1' @(Get-ManifestAudioWork -Manifest $m1).Count 1
  Check 'bare 1'    (Get-ManifestAudioWork -Manifest $m1).Count 1

  Write-Output '8. work list: FRESH evidence is not work; STALE evidence is'
  '{}' | Set-Content -LiteralPath "$file.tracks.json" -Encoding UTF8
  Check 'fresh dropped' @(Get-ManifestAudioWork -Manifest $m1).Count 0
  (Get-Item -LiteralPath "$file.tracks.json").LastWriteTime = (Get-Item -LiteralPath $file).LastWriteTime.AddMinutes(-5)
  Check 'stale kept'    @(Get-ManifestAudioWork -Manifest $m1).Count 1
  Remove-Item -LiteralPath "$file.tracks.json" -Force

  Write-Output '9. work list: an unanalysable item is RETURNED (with a reason), never silently dropped'
  $m2 = Manifest 'dead.json' @(@{ out = 'd.mkv'; src = (Join-Path $tmp 'ghost.mkv'); audioTracks = @(0, 1) })
  $row = @(Get-ManifestAudioWork -Manifest $m2)[0]
  Check 'returned'  @(Get-ManifestAudioWork -Manifest $m2).Count 1
  Check 'flagged'   $row.Analysable 'False'
  CheckMatch 'reason' $row.Reason 'does not exist'

  Write-Output '10. GATE: absent evidence, source that CAN be measured -> exit 4 (wait), as before'
  $g1 = Manifest 'g-wait.json' @(@{ out = "$tmp/w.mkv"; src = $file; audioTracks = @(0, 1); audioLangs = @('eng', 'eng') })
  Check 'exit' (GateExit $g1) 4
  CheckMatch 'says NO EVIDENCE yet' ($gateOut -join ' ') 'NO EVIDENCE yet'

  Write-Output '11. GATE: absent evidence, source that can NEVER be measured -> exit 2, named'
  $g2 = Manifest 'g-dead.json' @(@{ out = "$tmp/d.mkv"; src = (Join-Path $tmp 'ghost.mkv'); audioTracks = @(0, 1); audioLangs = @('eng', 'eng') })
  Check 'exit' (GateExit $g2) 2
  CheckMatch 'names the cause' ($gateOut -join ' ') 'NONE IS POSSIBLE'
  CheckMatch 'explains why'    ($gateOut -join ' ') 'does not exist on disk'

  Write-Output '12. GATE: a concat-list src is the same dead end, not a wait'
  $g3 = Manifest 'g-list.json' @(@{ out = "$tmp/l.mkv"; src = $list; audioTracks = @(0, 1); audioLangs = @('eng', 'eng') })
  Check 'exit' (GateExit $g3) 2
  CheckMatch 'names the cause' ($gateOut -join ' ') 'NONE IS POSSIBLE'

  Write-Output '13. GATE: a folder with no VIDEO_TS is a dead end; a DVD folder with a title WAITS'
  $g4 = Manifest 'g-dir.json' @(@{ out = "$tmp/n.mkv"; src = $plainDir; audioTracks = @(0, 1); audioLangs = @('eng', 'eng') })
  Check 'plain folder exit' (GateExit $g4) 2
  $g5 = Manifest 'g-dvd.json' @(@{ out = "$tmp/v.mkv"; src = $dvd; title = 7; audioTracks = @(0, 1); audioLangs = @('eng', 'eng') })
  Check 'dvd folder exit'   (GateExit $g5) 4

  Write-Output '14. GATE: the SINGLE-STREAM exemption now fires on a raw Blu-ray stream'
  #    This is the whole of item 2 of bladerunner-d1.json. Before the json stream count it was
  #    exit 4 - waiting for evidence a single-stream source never needed.
  if (HaveTs $tsOne) {
    $g6 = Manifest 'g-ts1.json' @(@{ out = "$tmp/i.mkv"; src = $tsOne; audioTracks = @(0); audioLangs = @('eng') })
    Check 'exit' (GateExit $g6) 0
    Write-Output '   ...and a MULTI-track claim on that same source is still not exempt'
    $g7 = Manifest 'g-ts2.json' @(@{ out = "$tmp/j.mkv"; src = $tsOne; audioTracks = @(0, 1); audioLangs = @('eng', 'eng') })
    Check 'exit' (GateExit $g7) 4
  } else {
    Write-Output '  SKIP - Bladerunner Disk 1 is not staged'
  }

  Write-Output '15. GATE, UNCHANGED: a commentary claim the evidence contradicts is still REFUSED'
  $ev = @{
    src = $file; duration = 100; offsets = @(1, 2)
    streams = @(
      @{ a = 0; codec = 'truehd'; channels = 6; langTag = 'eng'; role = 'primary';  spokenLang = 'en'; langProb = 0.95; langReliable = $true; tagMismatch = $false },
      @{ a = 7; codec = 'ac3';    channels = 2; langTag = 'eng'; role = 'dub';      spokenLang = 'en'; langProb = 0.95; langReliable = $true; tagMismatch = $false }
    )
    proposal = @{ audioTracks = @(0) }; warnings = @()
  }
  ($ev | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath "$file.tracks.json" -Encoding UTF8
  $g8 = Manifest 'g-bad.json' @(@{ out = "$tmp/x.mkv"; src = $file; audioTracks = @(0, 7); audioLangs = @('eng', 'eng'); commentary = @(, @(7, 'Audio Commentary')) })
  Check 'exit' (GateExit $g8) 2
  CheckMatch 'names the role' ($gateOut -join ' ') "calls it 'dub'"

  Write-Output '16. GATE, UNCHANGED: the same claim PASSES when the evidence supports it'
  $ev.streams[1].role = 'commentary'
  ($ev | ConvertTo-Json -Depth 8) | Set-Content -LiteralPath "$file.tracks.json" -Encoding UTF8
  Check 'exit' (GateExit $g8) 0

  Write-Output '17. GATE, UNCHANGED: audioTracks [] against a source that HAS audio is a refusal'
  if (HaveTs $tsOne) {
    $g9 = Manifest 'g-empty.json' @(@{ out = "$tmp/e.mkv"; src = $tsOne; audioTracks = @() })
    Check 'exit' (GateExit $g9) 2
    CheckMatch 'names the drop' ($gateOut -join ' ') 'claims this title has NO audio'
  } else {
    Write-Output '  SKIP - Bladerunner Disk 1 is not staged'
  }

  Write-Output '18. the loop''s skip rule must AGREE with the gate''s exemption, not approximate it'
  #    Both are measured against the same real MPEG-TS. If they ever disagree, one of two bad
  #    things happens: the loop skips a source the gate then waits for (deadlock again), or the
  #    loop analyses a source the gate never reads (wasted whisper).
  if ((HaveTs $tsOne) -and (Test-Path -LiteralPath $tsMany)) {
    $mt = Manifest 'trivia.json' @(
      @{ out = 'p.mkv'; src = $tsOne; audioTracks = @(0) },                               # exempt
      @{ out = 'q.mkv'; src = $tsOne; audioTracks = @(0, 1) },                            # two claimed
      @{ out = 'r.mkv'; src = $tsOne; audioTracks = @(0); commentary = @(1) }             # claims a commentary
    )
    $rows = @(Get-ManifestAudioWork -Manifest $mt)
    Check 'rows' $rows.Count 3
    Check 'one-stream [0]   -> skip'     (Test-AudioClaimTrivial -Ffprobe $ffprobe -Row $rows[0]) 'True'
    Check 'one-stream [0,1] -> analyse'  (Test-AudioClaimTrivial -Ffprobe $ffprobe -Row $rows[1]) 'False'
    Check 'commentary claim -> analyse'  (Test-AudioClaimTrivial -Ffprobe $ffprobe -Row $rows[2]) 'False'
    # THE TEN-STREAM CASE IS BUILT BY HAND, and that is not laziness. `$tsMany` now carries its
    # evidence, so Get-ManifestAudioWork correctly DROPS it from the work list - which is the right
    # behaviour and made an index-based test blow up the first time the analysis landed. The
    # predicate under test here is the exemption, not the work list; feed it the row shape directly
    # so the assertion stays true whatever has or has not been measured.
    $manyRow = [pscustomobject]@{ Src = $tsMany; Title = $null; AudioTracks = @(0)
                                  HasCommentary = $false; HasAudioDescr = $false }
    Check 'ten-stream [0]   -> analyse'  (Test-AudioClaimTrivial -Ffprobe $ffprobe -Row $manyRow) 'False'
    Write-Output '    ...and the GATE agrees on each of those four, item for item'
    Check 'gate one-stream [0]'    (GateExit (Manifest 't1.json' @(@{ out = 'p.mkv'; src = $tsOne;  audioTracks = @(0) }))) 0
    Check 'gate one-stream [0,1]'  (GateExit (Manifest 't2.json' @(@{ out = 'q.mkv'; src = $tsOne;  audioTracks = @(0, 1) }))) 4
    Check 'gate commentary claim'  (GateExit (Manifest 't3.json' @(@{ out = 'r.mkv'; src = $tsOne;  audioTracks = @(0); commentary = @(1) }))) 4
  } else {
    Write-Output '  SKIP - Bladerunner Disk 1 is not staged'
  }

  $script:reachedEnd = $true
}
catch {
  # A THROW MUST FAIL THE RUN, NOT SILENTLY TRUNCATE IT. A terminating error inside the suite once
  # skipped half the tests while the tail still printed "all tests passed" and exited 0.
  Write-Output "  FAIL exception in the suite: $($_.Exception.Message)"
  Write-Output "       at $($_.InvocationInfo.PositionMessage)"
  $script:fails++
}
finally {
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output ''
if (-not $reachedEnd) { Write-Output 'the suite did not reach its end - treating as FAILED'; $fails++ }
if ($fails) { Write-Output "$fails test(s) FAILED"; exit 1 }
Write-Output 'all tests passed'
exit 0
