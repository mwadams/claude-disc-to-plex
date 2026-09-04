# WHERE A MANIFEST ITEM'S AUDIO EVIDENCE LIVES, AND WHETHER ANYTHING CAN EVER WRITE IT.
#
# WHY THIS EXISTS. `assert-tracks-analysed.ps1` demands `<src>.tracks.json` for every item that
# makes an audio claim, and returns exit 4 ("wait and retry") when it is absent. That is right
# whenever something is going to write the file. It is a SILENT DEADLOCK when nothing is:
# lane-runner defers the manifest, the queue circles, and the only symptom for four hours is a
# manifest that never runs. Two instances of that shape are already recorded in the gate's own
# header (`audioTracks: []` galleries, DVD folders it could not probe); on 2026-09-04
# `bladerunner-d1.json` reached it by a third door - its sources are RAW BLU-RAY STREAMS
# (`.../BDMV/STREAM/00047.m2ts`) and `_analyse-loop.ps1` only ever analysed `.mkv` files inside
# rip folders, so no process on the machine would ever have written that evidence.
#
# The fix has two halves and they must agree with each other, which is why they live here rather
# than in two files that would drift:
#
#   Test-AudioSourceAnalysable  - the GATE asks "could anything ever measure this source?" and
#                                 turns a permanent absence into a NAMED REFUSAL instead of
#                                 patience. It never softens a refusal; it only converts a silent
#                                 wait into a loud one.
#   Get-ManifestAudioWork       - the LOOP asks "what does a queued manifest still need measured?"
#                                 and analyses exactly that, whatever shape the source takes.
#
# DECIDED WITHOUT PROBING, DELIBERATELY. The gate runs on every deferral pass (~20 s), and a
# 26-episode DVD manifest would otherwise pay 26 dvdvideo probes each time. Every "permanent"
# verdict below is decidable from the path alone - a source that is NOT ON DISK, a folder that is
# not a DVD, a concat list no demuxer opens as a plain file. Anything that exists and could be
# opened is reported analysable WITHOUT a probe, so an unreadable-but-present file still falls
# through to the old patient behaviour rather than being refused on a guess. Refuse only what is
# provably unsatisfiable; wait for everything else.

# CONCAT LISTS ARE NOT MEDIA. `transcode.ps1` accepts a `.txt` of clip paths for a
# seamless-branching disc and feeds it to ffmpeg's concat demuxer. `analyze-tracks.py` opens its
# source as a plain file, so `<list>.txt.tracks.json` is evidence nothing can produce.
$script:NotMediaExtensions = @('.txt', '.json', '.md', '.csv', '.xml')


function Get-AudioEvidencePath {
  <#
    The `.tracks.json` an item's claim must be backed by. Mirrors what analyze-tracks.py writes:
      DVD folder + title  ->  <src>.title<N>.tracks.json   (--dvd-title N)
      anything else       ->  <src>.tracks.json
  #>
  param(
    [Parameter(Mandatory)][AllowEmptyString()][string]$Src,
    $Title = $null
  )
  if ($null -ne $Title -and "$Title" -ne '' -and (Test-Path -LiteralPath $Src -PathType Container)) {
    return "$Src.title$Title.tracks.json"
  }
  return "$Src.tracks.json"
}


function Test-AudioSourceAnalysable {
  <#
    Can `analyze-tracks.py` EVER produce evidence for this source?

    Returns an object with .Analysable ([bool]) and .Reason (a sentence naming what to do about
    it). $false is a POSITIVE FINDING - the caller should refuse, not wait.

    The four permanent cases, all decidable from the path:
      1. no src at all
      2. the src does not exist on disk
      3. the src is a directory that is not a DVD (no VIDEO_TS), or is a DVD with no `title`
      4. the src is a list/config file, not media (see $NotMediaExtensions)
  #>
  param(
    [AllowEmptyString()][AllowNull()][string]$Src,
    $Title = $null
  )
  $r = [pscustomobject]@{ Analysable = $true; Reason = '' }

  if (-not "$Src".Trim()) {
    $r.Analysable = $false
    $r.Reason = "the item has no 'src', so there is nothing any analyser could measure"
    return $r
  }

  if (Test-Path -LiteralPath $Src -PathType Container) {
    if (Test-Path -LiteralPath (Join-Path $Src 'VIDEO_TS')) {
      if ($null -eq $Title -or "$Title" -eq '') {
        $r.Analysable = $false
        $r.Reason = "src is a DVD folder but the item sets no 'title' - analyze-tracks.py reads a " +
                    "DVD through '-f dvdvideo -title N' and cannot open a directory without one"
        return $r
      }
      return $r      # a DVD title: _analyse-loop.ps1 analyses it (catalogue arm or queued-manifest arm)
    }
    $r.Analysable = $false
    $r.Reason = "src is a FOLDER with no VIDEO_TS in it - analyze-tracks.py can open a media file " +
                "or a DVD folder, and this is neither. Point src at the file to be encoded"
    return $r
  }

  if (-not (Test-Path -LiteralPath $Src -PathType Leaf)) {
    $r.Analysable = $false
    $r.Reason = "the source does not exist on disk, so no analysis of it can ever be written. " +
                "Its staging was probably released, or the path is wrong"
    return $r
  }

  $ext = [IO.Path]::GetExtension($Src).ToLowerInvariant()
  if ($script:NotMediaExtensions -contains $ext) {
    $r.Analysable = $false
    $r.Reason = "src is a '$ext' list, not a media file (a concat list for a seamless-branching " +
                "disc). analyze-tracks.py opens its source directly, so no '.tracks.json' can " +
                "ever be produced for it - analyse the clips it names, or state the audio claim " +
                "against one of them"
    return $r
  }

  return $r          # an ordinary media file: _analyse-loop.ps1's queued-manifest arm measures it
}


function Get-ManifestAudioWork {
  <#
    What a manifest still needs MEASURED - one row per gated item whose evidence is missing.

    This is the loop's work list, and it is derived from the manifest rather than from folder
    naming ON PURPOSE. `_analyse-loop.ps1`'s rip arm matches folders by suffix (`-x`, `-main`,
    `-mkv`, `-rip`), which its own header calls "a liability, not a convention" - 70 already-shipped
    manifest items read `.mkv` files from folders that list does NOT match (`dh2-extras`,
    `fyeo-extras`, `goldfinger-rest`, `ser-feat`, ...), and every one of them needed a hand-run.
    A queued manifest states exactly which sources are about to be encoded, so driving from it
    needs no convention at all and cannot miss a shape nobody thought of.

    Each row: Out, Src, Title, Evidence, Analysable, Reason, AnalyzerArgs.
    Rows already carrying fresh evidence are omitted; a row that CANNOT be analysed is returned
    with .Analysable = $false so the caller can report it rather than loop on it.
  #>
  param([Parameter(Mandatory)][string]$Manifest)

  $rows = @()
  try {
    $items = Get-Content -LiteralPath $Manifest -Raw -ErrorAction Stop | ConvertFrom-Json
  } catch {
    return @()          # unreadable/half-written manifest: not this function's business to judge
  }
  if ($null -eq $items) { return @() }
  if ($items -isnot [array]) { $items = @($items) }

  foreach ($it in $items) {
    $names = $it.PSObject.Properties.Name
    if (-not ($names -contains 'audioTracks' -or $names -contains 'commentary' -or
              $names -contains 'audioDescription')) { continue }

    $src   = "$($it.src)"
    $title = if ($names -contains 'title') { $it.title } else { $null }
    $ev    = Get-AudioEvidencePath -Src $src -Title $title
    $ok    = Test-AudioSourceAnalysable -Src $src -Title $title

    # ALREADY MEASURED? For a FILE source the evidence must also POSTDATE it - a re-rip under the
    # same name leaves stale evidence describing different streams (the rip arm applies the same
    # rule). A DVD folder's mtime says nothing about its titles, so only existence is required.
    if (Test-Path -LiteralPath $ev) {
      if (Test-Path -LiteralPath $src -PathType Leaf) {
        if ((Get-Item -LiteralPath $ev).LastWriteTime -gt (Get-Item -LiteralPath $src).LastWriteTime) { continue }
      } else { continue }
    }

    $argv = @($src)
    if ($ok.Analysable -and (Test-Path -LiteralPath $src -PathType Container)) {
      $argv = @($src, '--dvd-title', "$title")
    }

    $rows += [pscustomobject]@{
      Out          = "$($it.out)"
      Src          = $src
      Title        = $title
      Evidence     = $ev
      Analysable   = $ok.Analysable
      Reason       = $ok.Reason
      AnalyzerArgs = $argv
      # The manifest's claim, so a caller can ask Test-AudioClaimTrivial whether measuring it
      # would buy anything. Kept as data rather than a verdict: the probe that decides it costs a
      # process, and only the loop needs to pay for it.
      AudioTracks    = @($it.audioTracks)
      HasCommentary  = ($names -contains 'commentary')
      HasAudioDescr  = ($names -contains 'audioDescription')
    }
  }
  # ,$rows would make @(...).Count report 1 for every non-empty result - the exact defect
  # lib-publish-state.tests.ps1 documents. Emit the array normally and let @() do its job.
  return $rows
}


function Test-AudioClaimTrivial {
  <#
    Would measuring this item's audio buy anything at all?

    TRUE only for the one shape assert-tracks-analysed.ps1 exempts on measurement: a source with
    exactly ONE audio stream, claimed as `audioTracks: [0]`, with no commentary and no audio
    description. "Keep the only track" cannot be wrong - every failure the evidence exists to catch
    (a lossy core picked over its parent, a dub tagged commentary, a duplicate mix) needs at least
    two streams to be possible.

    THIS FUNCTION ONLY EVER SAYS "SKIP", NEVER "REFUSE". The gate's mirror of it can refuse - an
    `audioTracks: []` claim against a source that HAS audio is a positive refusal, because it would
    silently drop real audio - and that half deliberately stays in the gate, where refusals belong.
    Here a wrong answer costs at most one needless whisper run.

    It exists so the loop does not spend two whisper minutes each on 37 short single-audio extras
    to produce evidence the gate will never look at. `_analyse-loop.ps1`'s DVD arm has always done
    this (`if ($na -le 1) { continue }`); this is the same rule for every other source shape.
  #>
  param(
    [Parameter(Mandatory)][string]$Ffprobe,
    [Parameter(Mandatory)]$Row
  )
  if ($Row.HasCommentary -or $Row.HasAudioDescr) { return $false }
  $claimed = @($Row.AudioTracks)
  if ($claimed.Count -ne 1 -or [int]$claimed[0] -ne 0) { return $false }
  $p = Get-AudioStreamCount -Ffprobe $Ffprobe -Src $Row.Src -Title $Row.Title
  return ([bool]$p.Probed -and [int]$p.Count -eq 1)
}


function Get-AudioStreamCount {
  <#
    How many AUDIO streams does this source carry? Returns .Count and .Probed.

    READ THE JSON, NEVER THE CSV. On an MPEG-TS - which is what every raw Blu-ray `.m2ts` is -
    ffprobe emits each stream TWICE in csv mode, once under `programs` and once under `streams`,
    separated by a blank line. `00004.m2ts` (the Ridley Scott introduction, ONE audio stream)
    counted as 3 lines, so assert-tracks-analysed.ps1's single-stream exemption could never fire
    for a Blu-ray extra and the item was sent to wait for evidence it did not need. `-of json`
    has a single top-level `streams` array and is immune.
  #>
  param(
    [Parameter(Mandatory)][string]$Ffprobe,
    [Parameter(Mandatory)][string]$Src,
    $Title = $null
  )
  $a = @('-v', 'error', '-select_streams', 'a', '-show_entries', 'stream=index', '-of', 'json')
  if ($null -ne $Title -and "$Title" -ne '' -and (Test-Path -LiteralPath $Src -PathType Container)) {
    $a += @('-f', 'dvdvideo', '-title', "$Title")
  }
  $a += @('-i', $Src)
  $raw = (& $Ffprobe @a 2>$null) -join "`n"
  $rc  = $LASTEXITCODE
  if ($rc -ne 0 -or -not "$raw".Trim()) {
    return [pscustomobject]@{ Count = 0; Probed = $false }
  }
  try { $j = "$raw" | ConvertFrom-Json }
  catch { return [pscustomobject]@{ Count = 0; Probed = $false } }
  # `@($null).Count` is 1, not 0 - a missing `streams` property would otherwise report one stream
  # and could fire the single-stream exemption on a source nothing was measured from.
  if ($null -eq $j -or -not ($j.PSObject.Properties.Name -contains 'streams')) {
    return [pscustomobject]@{ Count = 0; Probed = $false }
  }
  return [pscustomobject]@{ Count = @($j.streams).Count; Probed = $true }
}
