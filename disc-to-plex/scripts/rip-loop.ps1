# RIP track: rip every title a disc's dispositions mark as KEEP, and stop.
#
# WHY THIS EXISTS
# ---------------
# Rip was the last trigger still pulled by a human, and on 2026-08-23 it failed twice in one
# evening for that reason alone:
#
#   1. A manifest subagent was told to run the rip. The rip was a CHILD of that agent's task and
#      died with it at 24.78 GB of 27.7 GB, leaving a fragment with a 77-hour duration header that
#      then wedged the analyse loop for half an hour.
#   2. The main session "took the rip over" by hand to make it detached, did not tell the agent,
#      and the agent's armed monitor fired on schedule - TWO MakeMKV processes ripping the same
#      title off the same spindle, each slowing the other.
#
# Both failures are the same failure: WHO OWNS THE RIP was a judgement call. Made data-driven, it
# stops being one. The dispositions file already says exactly which titles to keep, so no operator
# and no agent needs to decide anything.
#
# WHAT IT RIPS. Any title whose disposition is `feature` or `extra`. Exclusions are never ripped -
# that is the whole point of writing dispositions before ripping.
#
# WHAT IT WILL NOT DO. It never deletes, never publishes, never picks titles itself, and never
# runs without a dispositions file. A disc with no dispositions is NOT its problem - that is the
# operator's one manual job, and _stallwatch.ps1 already reports it.

param(
  # 30, NOT 20. The reserve is what rip-titles.ps1 leaves free ON TOP of the rip it is about to
  # make, and it must cover ONE ITEM OF EVERY LATER STAGE - here, an encode.
  #
  # transcode.ps1's space preflight needs 0.75 x source + 6 GB, which for a ~28 GB feature is
  # ~27 GB. With a 20 GB reserve the rip track could take the volume below what the encode needs,
  # and then nothing progresses: the encode is refused for space, so nothing publishes, so nothing
  # is reclaimed, so the space never comes back. Ripping the NEXT disc would starve the encode of
  # the PREVIOUS one - and encoding is the only thing that frees anything.
  [int]$Reserve = 30,
  [string]$Stage = 'D:/video/_stage',
  [string]$Catalogue = 'D:/video/_catalogue'
)

# SINGLE INSTANCE, and it must FAIL CLOSED. Build the name first: inline,
# `New-Object System.Threading.Mutex($false, 'Global' + [char]92 + 'name')` parses the arguments
# as a four-element ARRAY (comma binds tighter than +), no constructor matches, New-Object returns
# $null, and the null-method error is NON-TERMINATING - so the loop runs on unguarded. That
# happened to _fetch-loop.ps1 on its first launch today. Two rip loops would be the duplicate-rip
# incident all over again, in a script written to prevent it.
$mutexName = 'Global' + [char]92 + 'video-rip-loop'
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if ($null -eq $mutex) { Write-Output 'could not create the single-instance mutex - refusing to run unguarded'; exit 1 }
if (-not $mutex.WaitOne(0)) { Write-Output 'another _rip-loop.ps1 holds the lock - exiting (the guard working)'; exit 0 }

$ripper = 'D:/video/.claude/skills/disc-to-plex/scripts/rip-titles.ps1'
$tp = Get-Content 'D:/video/.transcode-tools/tool-paths.json' -Raw | ConvertFrom-Json
$ffprobe = Join-Path (Split-Path $tp.ffmpeg) 'ffprobe.exe'

while ($true) {
  $did = $false

  foreach ($disp in Get-ChildItem "$Catalogue/*.dispositions.txt" -ErrorAction SilentlyContinue) {
    $disc = $disp.Name -replace '\.dispositions\.txt$', ''
    $discDir = Join-Path $Stage $disc
    if (-not (Test-Path -LiteralPath $discDir)) { continue }      # staging already released
    if (Test-Path -LiteralPath (Join-Path $discDir '.HOLD')) { continue }

    # DONE MEANS DONE. If the unit's work is published and confirmed, there is nothing to rip -
    # even though its dispositions still exist and its rips are (correctly) gone. Without this,
    # a completed disc that gets re-staged for any reason is ripped again from scratch.
    $completeList = @(Get-Content -LiteralPath 'D:/video/_completed.txt' -ErrorAction SilentlyContinue |
                      Where-Object { $_ -and $_.Trim() -and -not $_.Trim().StartsWith('#') } |
                      ForEach-Object { $_.Trim() })
    if ($completeList -contains $disc) { continue }

    # KEEP = feature or extra. Anything with an unresolved '?' means the dispositions are not
    # finished, and ripping against a half-written file would rip the wrong titles.
    $lines = @(Get-Content -LiteralPath $disp.FullName -ErrorAction SilentlyContinue)
    if ($lines | Where-Object { $_ -match '^t\d+\|\?\|' }) { continue }
    # KEEP-TITLE VOCABULARY: feature | extra | episode.
    #
    # `episode` is used for TV discs. It is deliberately NOT ripped on a DVD: a DVD manifest reads
    # the disc folder directly through the dvdvideo demuxer with a `title` number, so ripping first
    # would be pure waste. That is how the three BBC Shakespeare plays shipped - no rip at all.
    #
    # On a BLU-RAY there is no such direct path: the manifest must read a MakeMKV .mkv. An
    # `episode` disposition on a BD therefore has to be ripped, and until now it was invisible here
    # - the disc would have sat with "0 keep-titles" and NOTHING would have reported it. That is
    # the silent "N-1 of N" shape this file already warns about.
    $isDvd = Test-Path -LiteralPath (Join-Path $discDir 'VIDEO_TS')
    $keepTokens = if ($isDvd) { 'feature|extra' } else { 'feature|extra|episode' }
    $keep = @()
    foreach ($l in $lines) {
      if ($l -match ('^t(\d+)\|(' + $keepTokens + ')\|')) { $keep += [int]$Matches[1] }
    }
    if ($keep.Count -eq 0) { continue }

    # THE RIP FOLDER IS DERIVED FROM THE DISC NAME - NEVER FOUND BY SEARCHING FOR A FILENAME.
    #
    # This used to locate the folder by scanning ALL of _stage for the catalogue's `outName`. That
    # is only safe if outName is unique, and it is NOT: MakeMKV names its output from the disc's
    # VOLUME LABEL, and a disc with no label yields the generic `title_t00.mkv`. Three discs in
    # this batch alone collide on it - Battle of Britain, City Girl and STRAVINSKY_BELAIR.
    #
    # The consequence on 2026-08-24 was cross-disc contamination: City Girl's rip was directed into
    # `battleofbritain-rip` because that folder already held a `title_t00.mkv`. Battle of Britain
    # then measured City Girl's 1:28:25 against its own declared 2:12:10, called itself INCOMPLETE,
    # and re-ripped - six times, because an in-memory attempt counter resets whenever the loop is
    # restarted. Same defect class as the speech-sample temp files that cross-contaminated three
    # concurrent catalogues: A FILENAME IS NOT AN IDENTITY.
    #
    # The folder is now a pure function of the disc name, and only that folder is inspected.
    $cat = Join-Path $Catalogue "$disc.catalogue.json"
    $outNames = @{}
    if (Test-Path -LiteralPath $cat) {
      $cj = Get-Content -LiteralPath $cat -Raw | ConvertFrom-Json
      foreach ($t in $cj.titles) { if ($t.outName) { $outNames[[int]$t.title] = "$($t.outName)" } }
    }

    $dest = Join-Path $Stage ($disc.ToLower().Replace(' ', '') + '-rip')
    $have = @()
    foreach ($k in $keep) {
      # MATCH BY TITLE-NUMBER SUFFIX WHEN THE CATALOGUE HAS NO outName.
      #
      # catalogue-dvd.ps1 records no `outName`, so for every DVD this lookup returned nothing, the
      # loop concluded "not ripped yet", re-ripped, and MakeMKV refused to overwrite its own output
      # (FILES PRODUCED: 0). After two such attempts the retry cap wrote the title off permanently.
      # On 2026-08-24 that marked ALL FOUR keep-titles of Battle of the Bulge as unfixable problems
      # while the rips sat there, correct and duration-verified. The disc would have shipped
      # NOTHING, and every loop would have looked healthy.
      #
      # MakeMKV always ends its output with `_t<NN>.mkv` whatever it prefixes (B1_t02.mkv,
      # C1_t00.mkv, title_t00.mkv, "Back to the Future Part III_t19.mkv"), so the suffix is the
      # reliable part. Look inside THIS disc's folder only - never across _stage, which is what
      # collided three unlabelled discs on the generic name `title_t00.mkv`.
      $nm = $outNames[$k]
      $f0 = $null
      if ($nm) {
        $cand = Join-Path $dest $nm
        if (Test-Path -LiteralPath $cand) { $f0 = Get-Item -LiteralPath $cand }
      }
      if (-not $f0) {
        $suffix = '_t{0:00}.mkv' -f $k
        $f0 = @(Get-ChildItem -LiteralPath $dest -File -Filter "*$suffix" -ErrorAction SilentlyContinue |
                Select-Object -First 1)[0]
      }
      if (-not $f0) { continue }

      # A FILE EXISTING IS NOT A COMPLETED RIP. A killed rip leaves a large file with a nonsense
      # or absent duration; accepting it ships a truncated title that passes every other check.
      $want = $null
      foreach ($t in $cj.titles) {
        if ([int]$t.title -eq $k -and $t.duration) {
          $pp = "$($t.duration)" -split ':'
          if ($pp.Count -eq 3) { $want = [int]$pp[0]*3600 + [int]$pp[1]*60 + [int]$pp[2] }
        }
      }
      $got = 0.0
      $probe = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $f0.FullName 2>$null)".Trim()
      [void][double]::TryParse($probe, [ref]$got)

      if ($want -and $got -gt 0) {
        $tol = [Math]::Max(5, $want * 0.005)
        if ([Math]::Abs($got - $want) -le $tol) { $have += $k }
        else {
          # A STILLS REEL IS COMPLETE AT THE WRONG DURATION - identify it, do not re-rip it.
          # Signature: NO audio streams at all, and a frame count far below duration x fps. A
          # truncated feature always carries audio, so the two cannot be confused. The per-still
          # hold is declared / frames, computed per title - never carried across from a sibling.
          $isGallery = $false
          $frames = 0
          if ($f0.Length -lt 500MB) {     # never -count_frames a feature; it decodes the file
            $na = @(& $ffprobe -v error -select_streams a -show_entries stream=index -of csv=p=0 $f0.FullName 2>$null).Count
            if ($na -eq 0) {
              $fr = "$(& $ffprobe -v error -count_frames -select_streams v:0 -show_entries stream=nb_read_frames -of csv=p=0 $f0.FullName 2>$null)".Trim().TrimEnd(',')
              [void][int]::TryParse($fr, [ref]$frames)
              if ($frames -gt 0 -and $frames -le 500) { $isGallery = $true }
            }
          }
          if ($isGallery) {
            $have += $k
            Write-Output ("    {0} t{1:00}: STILLS REEL - {2} frames, no audio, declared {3}s. Complete. Encode must hold each still {4:N1}s." -f `
                          $disc, $k, $frames, $want, ($want / $frames))
          } elseif ($got -gt $want) {
            # LONGER THAN DECLARED IS NOT INCOMPLETE - and re-ripping it is pure waste.
            #
            # The two enumerators disagree about long titles: libdvdnav counts the full cell chain,
            # MakeMKV trims. Out of the Clouds ripped 4576s against 4570s declared and ffprobe put
            # the truth at 4576.480 - the RIP was right and the DECLARATION was short. Goodnight
            # Sweetheart S6D1 t02 hit the same thing at 1302s vs 1291s and was re-ripped on every
            # pass, logging "INCOMPLETE" each time for a title that was complete.
            #
            # Accept it and say why. A truncated rip is SHORTER; that branch is below and unchanged.
            $have += $k
            Write-Output ("    {0} t{1:00}: rip is {2:N0}s vs {3}s declared - LONGER, so not truncated (MakeMKV trims long titles). Accepted." -f `
                          $disc, $k, $got, $want)
          } else {
            Write-Output ("    {0} t{1:00}: existing rip is {2:N0}s but the disc says {3}s - SHORT by {4:N0}s, INCOMPLETE, will re-rip" -f `
                          $disc, $k, $got, $want, ($want - $got))
          }
        }
      } elseif ($got -gt 0 -and -not $want) {
        $have += $k      # no catalogued duration to check against; presence is all we have
      }
    }

    # GIVE UP AFTER TWO ATTEMPTS, AND SAY SO. Without this the loop retries the first incomplete
    # title forever and every title behind it STARVES - t13 of Back to the Future was attempted
    # SEVEN times in four minutes while sixteen other extras waited.
    #
    # It could never have succeeded: MakeMKV will not overwrite an existing output file, so each
    # retry reported `FILES PRODUCED: 0` and left the original stub in place. A retry that cannot
    # change the outcome is not a retry.
    #
    # The underlying case is real and NOT a fault: rip-titles.ps1 names it in its own output -
    # "a looping playlist whose declared duration counts repeats". A stills gallery declares 125s
    # because the playlist loops one image; the content genuinely is about a second. Deciding
    # whether that is a bad rip or a correct one is a JUDGEMENT call about disc content, which is
    # the manifest author's job, not a loop's. So record it and move on - never silently drop it.
    $problemFile = Join-Path $Catalogue "$disc.rip-problems.txt"
    $problems = @{}
    if (Test-Path -LiteralPath $problemFile) {
      foreach ($l in Get-Content -LiteralPath $problemFile -ErrorAction SilentlyContinue) {
        if ($l -match '^t(\d+)\|') { $problems[[int]$Matches[1]] = $true }
      }
    }

    $todo = @($keep | Where-Object { $have -notcontains $_ -and -not $problems.ContainsKey($_) })
    if ($todo.Count -eq 0) { continue }

    # Never start a second MakeMKV. rip-titles.ps1 is space-gated but not concurrency-gated, and
    # two rips off one disc contend on the same spindle - measured today, both ran slower than
    # either alone would have.
    if (@(Get-Process makemkvcon64 -ErrorAction SilentlyContinue).Count -gt 0) { break }

    $one = $todo[0]
    Write-Output ("[{0}] {1}: ripping t{2:00} ({3} title(s) still to rip)" -f `
                  (Get-Date -Format 'HH:mm:ss'), $disc, $one, $todo.Count)
    $attemptKey = "$disc|$one"
    if (-not $script:attempts) { $script:attempts = @{} }
    $script:attempts[$attemptKey] = 1 + [int]$script:attempts[$attemptKey]

    try {
      # CAPTURE the output: a TRANSIENT refusal must not count as an attempt.
      $ripOut = & $ripper -Disc $discDir -Titles @($one) -Dest $dest -Reserve $Reserve 2>&1
      $ripOut | ForEach-Object { "$_" }
      $did = $true

      # A SPACE REFUSAL IS NOT A FAILED RIP - IT IS "NOT YET".
      #
      # rip-titles.ps1 exits 2 with "REFUSING: not enough free space" BEFORE running MakeMKV, so
      # nothing was attempted and nothing is wrong with the title. The retry cap below used to
      # count those refusals, and after two of them wrote the title off permanently into
      # <disc>.rip-problems.txt - which this loop then skips forever.
      #
      # That stranded Back to the Future Part II's FEATURE on 2026-08-24: it was refused twice
      # while the volume was down at ~20 GB, recorded as a permanent problem, and was still being
      # skipped hours later with 99 GB free. The disc would have shipped its extras and no film.
      #
      # Same distinction the OCR loop had to learn: a POSITIVE finding of impossibility is
      # permanent; an absence of capacity is temporary. Only the former is worth recording.
      if ("$ripOut" -match 'not enough free space') {
        Write-Output ("    {0} t{1:00}: deferred - not enough free space right now (not a failure)" -f $disc, $one)
        $script:attempts[$attemptKey] = [Math]::Max(0, [int]$script:attempts[$attemptKey] - 1)
        Start-Sleep -Seconds 60
        break
      }

      # Did this attempt actually produce a COMPLETE title? If not, and we have now tried twice,
      # stop - and write down what we saw, so the manifest author can rule on it.
      $nm2 = $outNames[$one]
      $ok = $false
      if ($nm2) {
        $ff = @(Get-ChildItem -LiteralPath $dest -File -Filter $nm2 -ErrorAction SilentlyContinue)
        if ($ff.Count) {
          $g = 0.0
          $pr = "$(& $ffprobe -v error -show_entries format=duration -of csv=p=0 $ff[0].FullName 2>$null)".Trim()
          [void][double]::TryParse($pr, [ref]$g)
          $w2 = $null
          foreach ($t in $cj.titles) {
            if ([int]$t.title -eq $one -and $t.duration) {
              $q = "$($t.duration)" -split ':'
              if ($q.Count -eq 3) { $w2 = [int]$q[0]*3600 + [int]$q[1]*60 + [int]$q[2] }
            }
          }
          if ($w2 -and $g -gt 0 -and [Math]::Abs($g - $w2) -le [Math]::Max(5, $w2*0.005)) { $ok = $true }
        }
      }
      if (-not $ok -and $script:attempts[$attemptKey] -ge 2) {
        $note = "t{0:00}|rip did not verify after {1} attempts - MakeMKV will not overwrite the existing output, so retrying cannot change this. Likely a LOOPING PLAYLIST (a stills gallery declares a duration counting its repeats) rather than a truncated rip. DECIDE: keep the short rip as the extra, or drop the title. Do not leave it unresolved." -f $one, $script:attempts[$attemptKey]
        Add-Content -LiteralPath $problemFile -Value $note
        Write-Output ("    {0} t{1:00}: GIVING UP after {2} attempts - recorded in {3}" -f `
                      $disc, $one, $script:attempts[$attemptKey], (Split-Path $problemFile -Leaf))
      }
    } catch {
      Write-Output ("    rip FAILED for {0} t{1:00}: {2}" -f $disc, $one, $_.Exception.Message)
      Start-Sleep -Seconds 60
    }
    break    # one title per pass - re-read the dispositions before choosing the next
  }

  if (-not $did) { Start-Sleep -Seconds 90 }
}
