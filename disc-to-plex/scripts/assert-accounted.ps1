<#
.SYNOPSIS
  Refuse to release a disc's raw staging until EVERY catalogued title has a recorded disposition.

.WHY THIS EXISTS
  The per-unit gate's check #1 - "every title accounted for" - was prose, so it was signed off by
  recalling that the rips looked fine. Twice that was wrong in a way that cost a re-fetch:

  - **Colonel Blimp** (2026-08-21): staging freed having ripped 4 of 7 titles. Duration-verifying
    the rips you took proves those rips are good; it says NOTHING about titles you never looked at.
  - **The Man with the Golden Gun** (2026-08-22): enumerated at MakeMKV's default 120 s floor, so
    29 of its 42 titles were never listed at all. Encoded, published and confirmed in Plex before
    anyone noticed.

  A disposition is a WRITTEN decision per title. Not a count, not a spot check - if a title has no
  line here, nobody looked at it, and the disc is not finished.

.DISPOSITIONS FILE
  <OutDir>\<disc>.dispositions.txt, pipe-delimited, one line per title, '#' comments ignored:

    t05|feature|Moonraker (1979)|speech:this is where we keep the gadgets
    t33|extra|Inside The Man with the Golden Gun|card:head strip reads the title at 95s
    t14|episode|S01E03 The Sea Devils|menu:episode selection screen names it in slot 3
    t02|extra|Welcome to Japan Mr Bond|mymovies
    t01|exclude|copyright warning card
    t40|exclude|textless master of t33 - same audio md5, caption absent

  `exclude` REQUIRES a reason, and the reason must identify what the title IS. "too short",
  "duplicate" and "not needed" are rejected: every expensive loss in this project was a real extra
  dropped for looking like the wrong length or a duplicate.

.EVIDENCE (4th field)
  A NAME with no evidence is an assertion, and invented titles have reached the NAS unchallenged -
  nothing between the dispositions file and Plex ever asked "how do you know?". So every
  feature/extra/episode disposition should CITE its evidence as `class:detail`:

    speech:<quote>   a phrase that appears in the title's catalogued speechSample. VERIFIED here -
                     a quote the transcript does not contain is rejected, which makes this the
                     strongest citation: it can only be written by someone who read the evidence.
    card:<note>      the on-screen title card, read from the captured head strip / frames.
                     Verified to the extent the catalogue HOLDS frames for that title.
    frame:<note>     same as card, for identification from a sampled frame.
    menu:<note>      a rendered disc menu names it (episode-select screens etc).
    mymovies[:name]  the disc's own mymovies.xml extras list names it. Verified against the xml
                     when the staged disc is still present.
    duration:<note>  duration arithmetic (say the arithmetic: "28:55 matches TMDB S1E3").
    plex:<note> / tmdb:<note>   canonical-structure runtime/title match.
    user:<note>      the user identified it in conversation.

  A CITED class that fails verification, or an unknown class, always FAILS the gate - false
  evidence is worse than none. A missing citation warns by default; pass -RequireEvidence to make
  it fail too (new discs should run with it).

.EXAMPLE
  pwsh -File assert-accounted.ps1 -Disc "MAN_GOLDEN_GUN_F1" -RequireEvidence
#>
param(
  [Parameter(Mandatory)][string]$Disc,
  [string]$OutDir = 'D:\video\_catalogue',
  [switch]$RequireEvidence
)
$ErrorActionPreference = 'Stop'
$discName = Split-Path $Disc -Leaf
$catPath  = Join-Path $OutDir "$discName.catalogue.json"
$dispPath = Join-Path $OutDir "$discName.dispositions.txt"

if(-not (Test-Path -LiteralPath $catPath)){
  Write-Output "*** NO CATALOGUE for $discName ***"
  Write-Output "Run: pwsh -File catalogue-disc.ps1 -Disc `"<staged disc path>`""
  exit 2
}
# THE CATALOGUE MUST HAVE BEEN SWEPT FROM A VERIFIED COPY.
#
# This gate can only check that every CATALOGUED title has a decision. It cannot know the catalogue
# itself is short - and a catalogue swept while the disc was still copying IS short.
#
# 2026-08-23, Back to the Future 1: swept mid-copy, enumerated 26 titles, 26 dispositions written,
# and this gate PASSED it. The complete disc has 51. Title numbering shifts with the title set, so
# the dispositions did not merely omit 25 titles - they pointed at the WRONG ONES. Ripping the
# title the dispositions called the 1:56:00 feature produced 10:20 of something else.
#
# TIMESTAMPS CANNOT DETECT THIS. robocopy preserves source mtimes on files AND directories, so a
# freshly staged 2017 disc reads as 2017. The only reliable signal is what the sweep itself knew,
# so catalogue-disc.ps1 records `sourceVerified` - whether the unit was in _fetch-done.txt when it
# ran. Absent (older catalogue) is tolerated; explicitly false is refused.
$catRaw = Get-Content -LiteralPath $catPath -Raw | ConvertFrom-Json
if ($catRaw.PSObject.Properties.Name -contains 'sourceVerified' -and -not $catRaw.sourceVerified) {
  Write-Warning "CATALOGUE WAS SWEPT FROM AN UNVERIFIED COPY - '$discName' was not in _fetch-done.txt"
  Write-Warning "when catalogue-disc.ps1 ran, so the disc may still have been copying. A short"
  Write-Warning "enumeration shifts TITLE NUMBERING, making every disposition point at the wrong title."
  Write-Warning "Re-run catalogue-disc.ps1 now the copy is verified, and rewrite the dispositions."
  exit 2
}

$cat = Get-Content -LiteralPath $catPath -Raw | ConvertFrom-Json

# A catalogue taken at a high floor cannot answer the question at all.
if($cat.minLength -gt 10){
  Write-Output ("*** CATALOGUE FLOOR TOO HIGH: minlength={0} ***" -f $cat.minLength)
  Write-Output "Titles shorter than that were never enumerated, so completeness is unknowable. Re-catalogue at 10."
  exit 2
}

$disp = @{}
$badReason = @()
$unresolved = @()
if(Test-Path -LiteralPath $dispPath){
  foreach($line in (Get-Content -LiteralPath $dispPath)){
    $l = $line.Trim()
    if(-not $l -or $l.StartsWith('#')){ continue }
    $p = $l -split '\|', 4
    if($p.Count -lt 2){ continue }
    if($p[0] -notmatch '^t(\d+)$'){ continue }
    $id = [int]$Matches[1]
    $kind = $p[1].Trim().ToLower()
    $note = if($p.Count -ge 3){ $p[2].Trim() } else { '' }
    $evid = if($p.Count -ge 4){ $p[3].Trim() } else { '' }
    $disp[$id] = @{ kind = $kind; note = $note; evidence = $evid }
    # A DISPOSITION MUST BE A DECISION. '?' and friends are the ABSENCE of one, and this gate
    # accepted them as "accounted for" because it only checked that the line existed: When Harry
    # Met Sally passed with TEN titles marked '?', and Witness with six. That is the one gate whose
    # entire job is to stop a half-known disc, so it must reject a non-answer as loudly as a
    # missing line.
    if($kind -in @('?', 'unknown', 'tbd', 'todo', 'unidentified', '')){
      $unresolved += ("t{0:D2}  disposition is '{1}' - that is not a decision: {2}" -f $id, $kind, $note)
    }
    if($kind -eq 'exclude'){
      # An exclusion must name what the thing IS. Non-identifications are how real extras get lost.
      if(-not $note -or $note.Length -lt 8 -or $note -match '^(too short|short|duplicate|dupe|not needed|n/?a|junk|skip)\.?$'){
        $badReason += ("t{0:D2}  exclude reason does not identify the title: '{1}'" -f $id, $note)
      }
    }
  }
}

$missing = @()
foreach($t in $cat.titles){ if(-not $disp.ContainsKey([int]$t.title)){ $missing += $t } }

Write-Output ("$discName - {0} title(s) catalogued at minlength={1}, {2} with a disposition" -f $cat.titleCount, $cat.minLength, $disp.Count)

if($missing){
  Write-Output ""
  Write-Output ("*** {0} TITLE(S) HAVE NO DISPOSITION - THE DISC IS NOT ACCOUNTED FOR ***" -f $missing.Count)
  Write-Output ""
  Write-Output ("{0,-5} {1,9} {2,10} {3,-14} {4}" -f 'id','duration','size','source','video')
  foreach($t in $missing){
    $vid = if($t.width){ "{0}x{1}" -f $t.width, $t.height } else { '-' }
    Write-Output ("t{0:D2}   {1,9} {2,10} {3,-14} {4}" -f $t.title, $t.duration, $t.sizeText, $t.source, $vid)
  }
  Write-Output ""
  Write-Output "Look at each (frames are in $OutDir\$discName-frames), then add a line to:"
  Write-Output "  $dispPath"
  Write-Output "DO NOT release the raw staging."
  exit 2
}
if($badReason){
  Write-Output ""
  Write-Output "*** EXCLUSIONS THAT DO NOT IDENTIFY THE TITLE ***"
  $badReason | ForEach-Object { Write-Output "  $_" }
  Write-Output ""
  Write-Output "Say what it IS (copyright card, textless master of tNN, promo for another title)."
  exit 2
}

# ---- EVIDENCE: is each NAME evidenced, and does the cited evidence actually check out? -------
#
# WHY. Until this existed, NOTHING between the dispositions file and the NAS asked how a name was
# known - an invented or misremembered title passed every gate, because every gate checked that a
# decision was WRITTEN, not that it was EARNED. The catalogue already captures the raw evidence
# (speech samples, head strips, frames), so a citation can be checked against it mechanically:
# a speech: quote must appear in the title's own transcript, a card:/frame: citation requires the
# catalogue to actually hold frames for that title. False evidence ALWAYS fails; absent evidence
# warns (or fails under -RequireEvidence), so in-flight discs keep moving while new ones tighten.
$catById = @{}
foreach($t in $cat.titles){ $catById[[int]$t.title] = $t }
function Normalize-Quote([string]$s){ ((($s).ToLower() -replace '[^a-z0-9]+',' ').Trim()) }

# Thresholds for "can this frame actually be looked at?" - see the card/frame branch below.
$EvidenceMinBytes    = 8000   # a 720x576 PNG of near-solid black lands around 1-2 KB
$EvidenceMinLumaRange = 24    # measured: blank frame 0, real title card 207
$ffmpegForEvidence = $null
$tpForEvidence = 'D:/video/.transcode-tools/tool-paths.json'
if(Test-Path -LiteralPath $tpForEvidence){
  $ffmpegForEvidence = (Get-Content $tpForEvidence -Raw | ConvertFrom-Json).ffmpeg
}
function Get-LumaRange([string]$path){
  # No ffmpeg = no measurement. Return $null rather than a verdict: the caller reports
  # "unmeasurable", which is honest, instead of silently passing or silently failing every frame.
  if(-not $ffmpegForEvidence -or -not (Test-Path -LiteralPath $ffmpegForEvidence)){ return $null }
  $out = & $ffmpegForEvidence -hide_banner -loglevel error -i $path -vf 'signalstats,metadata=print:file=-' -f null - 2>$null
  $min = $null; $max = $null
  foreach($l in $out){
    if("$l" -match 'YMIN=([\d.]+)'){ $min = [double]$Matches[1] }
    if("$l" -match 'YMAX=([\d.]+)'){ $max = [double]$Matches[1] }
  }
  if($null -eq $min -or $null -eq $max){ return $null }
  return $max - $min
}

$evFalse = @()      # cited evidence that FAILED verification, or an unknown class -> always fatal
$evMissing = @()    # named titles with no citation at all -> warn, fatal under -RequireEvidence
$evBlind = @()      # named titles for which the catalogue captured NOTHING -> always shown
$evNote  = @()      # ambiguous mappings ACCEPTED on a recorded proof -> always shown, never silent
foreach($id in ($disp.Keys | Sort-Object)){
  $d0 = $disp[$id]
  if($d0.kind -notin @('feature','extra','episode')){ continue }
  $ev = "$($d0.evidence)"
  $title = $catById[[int]$id]
  # A title whose catalogue record holds NO captured evidence (no frames, no head strip, no
  # transcript) was ENUMERATED, never SEEN - Witness t07 sat in the catalogue exactly like its
  # fifteen swept siblings with every evidence field empty. A name written against such a title
  # cannot rest on the sweep, so say so here, where the disposition is being accepted.
  $blind = (-not $title) -or
           (((@($title.frames) | Where-Object { $_ }).Count -eq 0) -and -not $title.headStrip -and -not $title.speechSample)
  if(-not $ev){
    $evMissing += ("t{0:D2}  '{1}' - named with NO evidence citation{2}" -f $id, $d0.note,
                   $(if($blind){ ' (and the catalogue captured NO evidence for this title)' } else { '' }))
    continue
  }
  $cls, $arg = ($ev -split ':', 2 | ForEach-Object { $_.Trim() })
  # AMBIGUOUSLY-MAPPED titles (DVD catalogues: several equal-duration titles matched to dvdvideo
  # titles BY ORDER - see Resolve-DvdTitleMapping) carry evidence that is POSITIONAL, not proven:
  # the frames/speech recorded against tNN may belong to an equal-length sibling. Disc-derived
  # citations against them are refused; name such a title from a rip, a menu render, or the user
  # (a speech: quote matching a possibly-foreign transcript is exactly the confident-wrong-
  # evidence trap this gate exists to close).
  # ...UNLESS THE MAPPING HAS SINCE BEEN PROVEN FROM CONTENT.
  #
  # The refusal above assumes the only evidence available is what the catalogue captured. That is
  # not always so: the ambiguity can be resolved directly, by opening the mapped dvdvideo title
  # itself and reading what it contains, which is not a positional claim at all.
  #
  # Without an outlet for that, the gate pushes toward two bad moves - relabel a `card:` citation
  # as `user:` to satisfy the checker (recording false evidence, the exact thing this gate exists
  # to stop), or bypass the gate. So a title may carry `mappingProvenBy`: free text saying HOW the
  # pairing was established. It is only honoured when non-empty, and what it says is a claim the
  # reader can check against the disc.
  #
  # Set on 2026-08-27 for Sword Divided d7 t00/t02 and d8 t01: frames pulled straight from
  # dvdvideo titles 1/2/3 with `-f dvdvideo -title N` showed FATEFUL DAYS / FORLORN HOPE /
  # THE MAILED FIST / RESTORATION, matching the catalogue's tNN head strips - so the by-order
  # pairing was correct, and now demonstrably so rather than presumptively.
  $proven = $title -and $title.PSObject.Properties.Name -contains 'mappingProvenBy' -and
            "$($title.mappingProvenBy)".Trim()
  if($title -and $title.mappingAmbiguous -and -not $proven -and $cls.ToLower() -in @('card','frame','speech')){
    $evFalse += ("t{0:D2}  '{1}' cited, but this title's dvdvideo mapping is AMBIGUOUS (tie of {2} equal-duration titles, matched by order) - its captured evidence is positional. Corroborate from a rip, or cite menu:/user:/duration: instead, or record how you proved the mapping in the title's 'mappingProvenBy' field" -f $id, $cls, $title.mappingTieSize)
    continue
  }
  if($title -and $title.mappingAmbiguous -and $proven){
    $evNote += ("t{0:D2}  mapping was ambiguous; accepted because mappingProvenBy says: {1}" -f $id, "$($title.mappingProvenBy)".Trim())
  }
  if($blind -and $cls.ToLower() -notin @('card','frame','speech')){
    # card/frame/speech citations on a blind title fail hard in the switch below; external
    # classes (menu, user, mymovies, duration) are legitimate - but the reader must see that the
    # sweep itself contributed nothing.
    $evBlind += ("t{0:D2}  '{1}' - catalogue captured NOTHING{2}; the name rests entirely on '{3}'" -f `
                 $id, $d0.note, $(if($title -and $title.evidenceNote){ " ($($title.evidenceNote))" } else { '' }), $ev)
  }
  switch($cls.ToLower()){
    'speech' {
      if(-not $arg -or $arg.Length -lt 8){
        $evFalse += ("t{0:D2}  speech citation needs the actual quote (>=8 chars): '{1}'" -f $id, $ev)
      } else {
        # SEARCH THE DEEPER SAMPLES TOO, NOT JUST THE CATALOGUE'S ONE SNIPPET.
        #
        # The catalogue transcribes ONE window per title (90 s in), which is enough for a show that
        # states its own name but useless for one that never does. The Bill captions no episode
        # titles at all - its head strip is only the Thames ident and the series titles - so every
        # episode there has to be matched on plot detail, and the distinguishing line ("It's a toy!
        # It's a bloody toy!", "you suspect Domen is the nonce") is minutes deep, nowhere near 90 s.
        #
        # Refusing those quotes was correct while the transcripts were not recorded: an unverifiable
        # quote is exactly the confident-wrong evidence this gate exists to stop. The fix is to
        # RECORD the deeper transcripts rather than to relax the check - so a title may carry
        # `speechSamplesExtra`, a list of {offsetSec, lang, prob, text, capturedBy}, and a quote is
        # accepted if it appears in ANY recorded transcript. Every quote still has to be in a
        # transcript that lives in the catalogue and names how it was captured.
        $texts = @("$(if($title){ $title.speechSample })")
        if($title -and $title.speechSamplesExtra){
          $texts += @($title.speechSamplesExtra | ForEach-Object { "$($_.text)" })
        }
        $sample = Normalize-Quote (($texts | Where-Object { $_ }) -join ' ')
        if(-not $sample){
          $evFalse += ("t{0:D2}  speech cited but the catalogue holds NO transcript for this title (speechStatus={1})" -f $id, $(if($title){ $title.speechStatus } else { '?' }))
        } elseif(-not $sample.Contains((Normalize-Quote $arg))){
          $evFalse += ("t{0:D2}  speech quote NOT FOUND in the title's transcript: '{1}'" -f $id, $arg)
        }
      }
    }
    { $_ -in 'card','frame' } {
      $hasArt = $title -and ((@($title.frames) | Where-Object { $_ }).Count -gt 0 -or $title.headStrip)
      if(-not $hasArt){
        $evFalse += ("t{0:D2}  {1} cited but the catalogue captured NO frames or head strip for this title" -f $id, $cls)
      }
      else {
        # ...AND THE ART MUST BE SOMETHING YOU CAN ACTUALLY LOOK AT.
        #
        # Counting frames is a SHAPE check, and this file already records what shape checks are
        # worth: `mappingProvenBy` was honoured whenever it was non-empty until a plausible
        # sentence defeated it. The same hole was open here - a solid-black PNG (measured: 1,383
        # bytes, luma range ZERO) satisfied "the catalogue holds frames" while proving nothing,
        # and a DANGLING reference (listed here, deleted from disk) was worse still, because the
        # evidence looks present right up until somebody opens it.
        #
        # This is not a rare accident: title cards are FADED IN, so the second an OCR pass reports
        # is routinely the black gap beside the card. On The Saint Monochrome D2 dvdvideo 4 the
        # card OCRs at 82s and the frame at 82.0s is solid black; 83s carries it.
        #
        # Byte size alone is too crude - a dark but real frame can be small - so the discriminator
        # is the LUMA RANGE from ffmpeg's signalstats:
        #     blank.png   1,383 B   YMIN=16 YMAX=16   -> range   0
        #     card.png  205,260 B   YMIN=16 YMAX=223  -> range 207
        # YMIN is 16 on BOTH (broadcast black), so the absolute level says nothing and only the
        # range separates them. A title may legitimately hold some dark frames, so this refuses
        # only when NOTHING held for the title carries picture.
        $legible = 0; $why = @()
        foreach($art in (@($title.frames | Where-Object { $_ }) + @($title.headStrip | Where-Object { $_ }))){
          if(-not (Test-Path -LiteralPath $art)){ $why += "$(Split-Path $art -Leaf): missing from disk"; continue }
          if((Get-Item -LiteralPath $art).Length -lt $EvidenceMinBytes){ $why += "$(Split-Path $art -Leaf): blank"; continue }
          $range = Get-LumaRange $art
          if($null -eq $range){ $why += "$(Split-Path $art -Leaf): unmeasurable"; continue }
          if($range -lt $EvidenceMinLumaRange){ $why += ("{0}: featureless (luma range {1})" -f (Split-Path $art -Leaf), [int]$range); continue }
          $legible++
        }
        if($legible -eq 0){
          $evFalse += ("t{0:D2}  {1} cited, but NONE of the catalogued art for this title can be looked at ({2}) - a frame that exists but shows nothing is not evidence. Capture a frame that SHOWS the card; it is faded in, so try a second either side" -f `
                       $id, $cls, (($why | Sort-Object -Unique) -join '; '))
        }
      }
    }
    'mymovies' {
      $mmPath = Join-Path "$($cat.discPath)" 'mymovies.xml'
      if(Test-Path -LiteralPath $mmPath){
        $mmText = Get-Content -LiteralPath $mmPath -Raw -Encoding UTF8
        $needle = if($arg){ $arg } else { $d0.note }
        if($mmText -notmatch [regex]::Escape($needle)){
          $evFalse += ("t{0:D2}  mymovies cited but '{1}' does not appear in the disc's mymovies.xml" -f $id, $needle)
        }
      }
      # staged disc already gone: the xml cannot be re-read, accept the citation as recorded
    }
    { $_ -in 'menu','duration','plex','tmdb','user' } {
      if(-not $arg -or $arg.Length -lt 4){
        $evFalse += ("t{0:D2}  {1} citation needs a detail saying WHAT was seen/computed: '{2}'" -f $id, $cls, $ev)
      }
    }
    default {
      $evFalse += ("t{0:D2}  unknown evidence class '{1}' (know: speech card frame menu mymovies duration plex tmdb user)" -f $id, $cls)
    }
  }
}

# RE-DERIVE ANY `mappingProvenBy` THAT CITES THE PROVER. NON-EMPTY IS NOT A PROOF.
#
# The waiver above is honoured whenever the field is non-empty - and that WAS the entire test.
# Every other citation class is checked mechanically (`speech:` must be exact recorded text,
# `mymovies:` must appear verbatim in the disc's own metadata), so this was the one field where a
# plausible sentence defeated the gate. Demonstrated 2026-08-28 on The Saint Colour D5: a catalogue
# whose dvdvideoTitle values were KNOWN to be crossed, with the correct-sounding proof strings left
# in place, passed at exit 0.
#
# The field stays FREE TEXT on purpose - a legitimate proof can be "I pulled frames from dvdvideo
# title 3 and read the card", which no script can check. But a claim written in
# prove-dvd-mapping.py's own words names a VTS and a byte total, and those are re-derivable from
# the disc. So verify exactly those, and leave human prose alone (reported, not trusted).
#
# MATCH BOTH PROOF FORMS. The prover writes two: the VTS-total one below, and a per-title
# cell-sector one ("VTS_05 title 3 totals N bytes across its PGC's cell sectors") used wherever a
# VTS holds several titles. Only the first was listed here, so on exactly the discs where the
# mapping is hardest - multi-title VTSs, PLAY ALLs, two doors - the machine proof was filed as
# unverifiable human prose and never re-derived, and a hand-written imitation of that wording
# would have been waived unchecked. `--verify-claims` has always understood both.
$proverClaims = @($cat.titles | Where-Object {
  $_.PSObject.Properties.Name -contains 'mappingProvenBy' -and
  ("$($_.mappingProvenBy)" -match 'VTS_\d+\s+title VOBs total\s+\d+\s+bytes' -or
   "$($_.mappingProvenBy)" -match 'VTS_\d+\s+title\s+\d+\s+totals\s+\d+\s+bytes across')
})
if ($proverClaims.Count) {
  $prover = Join-Path $PSScriptRoot 'prove-dvd-mapping.py'
  if (-not (Test-Path -LiteralPath $prover)) {
    $evFalse += "prove-dvd-mapping.py is missing, so $($proverClaims.Count) recorded mapping proof(s) cannot be re-derived - refusing rather than trusting them"
  } else {
    # RESOLVE THE DISC TO A DIRECTORY FIRST.
    #
    # `-Disc` has always accepted a BARE DISC NAME - SKILL.md's own example is
    # `-Disc "MAN_GOLDEN_GUN_F1"` - because everything else here only needs it to name the
    # catalogue file, via Split-Path -Leaf. The re-derivation added on 2026-08-28 was the first
    # thing to need an actual PATH, and it broke the bare-name form with `not a directory`.
    # A regression introduced by a guard is still a regression: accept both forms.
    $discDir = $Disc
    if (-not (Test-Path -LiteralPath $discDir -PathType Container)) {
      $candidate = Join-Path 'D:/video/_stage' $discName
      if (Test-Path -LiteralPath $candidate -PathType Container) { $discDir = $candidate }
    }
    if (-not (Test-Path -LiteralPath $discDir -PathType Container)) {
      # The staged disc is gone (already reclaimed). The claims cannot be re-derived against a disc
      # that is not there - say so rather than passing silently OR failing the whole gate, because
      # a reclaimed disc is a normal state, not a fault.
      $evNote += "$($proverClaims.Count) mapping proof(s) NOT re-derived - the staged disc is no longer on disk"
      $proverClaims = @()
    }
    if ($proverClaims.Count) {
      $vOut = & python $prover $discDir --verify-claims $catPath 2>&1
      if ($LASTEXITCODE -ne 0) {
        foreach ($line in @($vOut | Where-Object { "$_" -match 'DOES NOT CHECK OUT' })) {
          $evFalse += ("mappingProvenBy re-derivation: " + ("$line".Trim()))
        }
        if (-not ($vOut | Where-Object { "$_" -match 'DOES NOT CHECK OUT' })) {
          $evFalse += "mappingProvenBy re-derivation failed (exit $LASTEXITCODE): $(($vOut | Select-Object -Last 3) -join ' / ')"
        }
      } else {
        $evNote += "$($proverClaims.Count) mapping proof(s) RE-DERIVED from the disc's own VTS byte totals and TT_SRPT"
      }
      # SURFACE TITLES THE DISC DECLARES THAT THE CATALOGUE NEVER LISTED.
      #
      # This gate can only check that every CATALOGUED title has a disposition. A title MakeMKV
      # never enumerated has no row, so it has no MISSING disposition and the gate passes - the
      # completeness claim is vacuous exactly where it matters. The Zoo Gang D2 (2026-08-29):
      # MakeMKV called dvdvideo 5 "9 seconds" and skipped it; it is really 12:41, a whole extra,
      # and nothing here could have said so.
      #
      # TT_SRPT is the disc's own declaration and owes nothing to MakeMKV, so report the difference.
      # NOT a failure - navigation stubs and padding titles are legitimate and common - but it must
      # be visible, because the reader is the only thing that can judge it.
      foreach ($line in @($vOut | Where-Object { "$_" -match 'DECLARED BY THE DISC|^\s+dvdvideo\s+\d+\s+VTS_' })) {
        $evNote += ("declared-vs-catalogued: " + ("$line".Trim()))
      }
    }
  }
}

if($evFalse){
  Write-Output ""
  Write-Output "*** EVIDENCE CITATIONS THAT DO NOT CHECK OUT ***"
  $evFalse | ForEach-Object { Write-Output "  $_" }
  Write-Output ""
  Write-Output "False evidence is worse than none: fix the citation, or look at the title again."
  exit 2
}
# An ambiguity waived on a proof must be VISIBLE. A gate that quietly stops objecting is
# indistinguishable from a gate that was removed, and the whole value of `mappingProvenBy` is that
# a reader can go and check the claim it carries.
if($evNote){
  Write-Output ("{0} ambiguous mapping(s) accepted on a recorded proof - verify these claims if anything downstream looks wrong:" -f $evNote.Count)
  $evNote | ForEach-Object { Write-Output "   $_" }
}
if($evBlind){
  Write-Warning ("{0} named title(s) have NO captured evidence in the catalogue - external citations only:" -f $evBlind.Count)
  $evBlind | ForEach-Object { Write-Warning "   $_" }
}
if($evMissing){
  if($RequireEvidence){
    Write-Output ""
    Write-Output "*** NAMED TITLES WITH NO EVIDENCE (-RequireEvidence) ***"
    $evMissing | ForEach-Object { Write-Output "  $_" }
    Write-Output ""
    Write-Output "Cite how each name is known: |speech:<quote> |card:<note> |menu:<note> |mymovies ..."
    exit 2
  }
  Write-Warning ("{0} named title(s) carry NO evidence citation - the name is an assertion, not a finding:" -f $evMissing.Count)
  $evMissing | ForEach-Object { Write-Warning "   $_" }
  Write-Warning "Add |speech:<quote> / |card:<note> / |menu:<note> / |mymovies citations (see the header), or run with -RequireEvidence to enforce."
}

$byKind = $disp.Values | Group-Object { $_.kind } | Sort-Object Name
Write-Output ""
foreach($g in $byKind){ Write-Output ("  {0,-9} {1}" -f $g.Name, $g.Count) }
Write-Output ""
if($unresolved.Count -gt 0){
  Write-Warning ("NOT ACCOUNTED FOR - {0} title(s) carry a placeholder, not a decision:" -f $unresolved.Count)
  $unresolved | ForEach-Object { Write-Warning "   $_" }
  Write-Warning "Identify them, or record an exclusion that says what the title IS."
  exit 2
}
Write-Output "ACCOUNTED FOR - every catalogued title has a written disposition."
Write-Output "Raw staging may be released once the encoded outputs are byte-verified on the NAS."
exit 0
