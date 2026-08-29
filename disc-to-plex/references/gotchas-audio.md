# Audio gotchas

Identifying tracks, commentaries, duplicates, and broken streams.

Part of the `disc-to-plex` gotchas set — see [gotchas.md](gotchas.md) for the full index.

## Contents

- [`mymovies.xml` `<AudioTracks>` names the commentary — don't guess it from loudness](#mymoviesxml-audiotracks-names-the-commentary-dont-guess-it-from-loudness)
- [No-audio titles](#no-audio-titles)
- [Phantom/corrupt audio stream (menu artifacts)](#phantomcorrupt-audio-stream-menu-artifacts)
- [IDENTIFY AUDIO TRACKS BY TRANSCRIBING THEM — never by metadata order](#identify-audio-tracks-by-transcribing-them-never-by-metadata-order)
- [Duplicate audio tracks hide an UNLABELLED commentary — sweep the whole batch](#duplicate-audio-tracks-hide-an-unlabelled-commentary-sweep-the-whole-batch)

## `mymovies.xml` `<AudioTracks>` names the commentary — don't guess it from loudness

Blu-ray audio streams usually carry **no language tags**, so a commentary is indistinguishable
from the film mix by probing alone. Waveform and spectrogram comparisons are inconclusive
(a commentary is mixed *over* ducked film audio, so it tracks the film's envelope), and mean
volume is only a weak hint. The disc's own `mymovies.xml` lists them in stream order:

```xml
<AudioTrack Language="English"    Type="DTS-HD Master" Channels="7.1" />
<AudioTrack Language="English"    Type="Dolby Digital" Channels="2.0" />
<AudioTrack Language="Commentary" Type="Dolby Digital" Channels="2.0" />
<AudioTrack Language="Other"      Type="Dolby Digital" Channels="2.0" />
```

Read it first: the `Commentary` entry's ordinal position is the 0-based `commentary` index for the
manifest (here: 2). `Language="Other"` is typically an audio-description track — real content,
worth keeping, but not the commentary.

## No-audio titles

Textless material, some behind-the-scenes reels, and image galleries can have **zero** audio.
The audio-map loop must be skipped entirely — mapping `0:a:0` on a source with no audio fails
with "matches no streams" (a 0-second failure). Map video (and subs) only.

## Phantom/corrupt audio stream (menu artifacts)

Some tiny DVD titles carry an AC3 stream with `sample_rate=0, channels=0`. The AAC encoder then
dies with "sample rate not set", and even passthru fails. These are menu/navigation artifacts —
**exclude them** (see `identification.md`), don't try to encode them.

## IDENTIFY AUDIO TRACKS BY TRANSCRIBING THEM — never by metadata order

Disc metadata tells you which languages EXIST, never which ffprobe ordinal each one is. The two
orderings do not correspond: The Italian Job's CLPI lists eight audio entries against ffmpeg's
seven exposed streams, so any mapping from one to the other is a guess. Guessing it produced two
confident, wrong answers on the same disc — first keeping the Italian dub as "the commentary" and
dropping a real track, then labelling the French and Italian dubs as "Audio Commentary 1 and 2".
`volumedetect` did not resolve it either: a 2.0 downmix simply reads louder than a 5.1 mix, so
spot checks at different timestamps contradicted each other.

Transcribe the tracks instead. `scripts/identify-audio.py` (needs `pip install faster-whisper`)
samples 40 s of each and reports the detected language plus the text:

```
a:0  en (0.93)  dialogue      "There are a quarter of a million Italians in Britain..."
a:3  de (0.95)                "In England leben meine Viertelmillion Italiener..."
a:5  fr (0.87)                "Il y a 250 000 italien en Grande-Bretagne..."
a:6  it (0.96)                "In Gran Bretagne, ci sono 250.000 italiani..."
```

Unambiguous in one run: every track speaking the same line of the film is a DUB. It also separates
an English commentary from English dialogue by vocabulary ("we shot this", "the scene where"),
which no signal-level measurement can do.

**Also note what this revealed:** the disc DECLARES two commentaries and CLPI lists two extra
English entries, but ffmpeg exposes neither — they are Blu-ray secondary audio. If a declared
commentary cannot be found in the main clip, it is not necessarily missing; try MakeMKV rather
than concluding the disc lied.

## Duplicate audio tracks hide an UNLABELLED commentary — sweep the whole batch

Zulu shipped **three** audio tracks where MakeMKV reports two on the disc: `a:0` and `a:1` were the
same dialogue mix twice, and `a:2` — the commentary — carried no title. In Plex that means picking
"English" can land a viewer in the commentary.

It is not a one-off. A sweep of batch 4 found untitled audio on **nine of eleven films**:

| film | tracks | finding |
|---|---|---|
| King Lear | 4 | all four are the SAME dialogue — two pure duplicates |
| The Men Who Stare At Goats | 5 | `a:3`/`a:4` are the two commentaries, both untitled |
| The Ipcress File | 4 | all four the same dialogue |
| Run Lola Run | 4 | correctly labelled incl. the English dub — no action |

The cause is structural, so expect it on any disc: the source ships one mix in several formats
(5.1 / stereo / TrueHD), we transcode them **all to AAC**, which makes them genuinely redundant —
and the one track that differs, the commentary, ends up unlabelled among them.

`transcode.ps1` now reports untitled and duplicate-signature tracks after every manifest
(`volumedetect` mean+peak over the same 30 s window; two encodes of one mix agree to ~0.1 dB).
Treat it as a **prompt to check, never proof** — confirm with `identify-audio.py` before dropping
anything, then fix by **remux** (stream copy, no re-encode, minutes not hours).


## A DVD's IFO "commentary" flag is a TITLE-level lie - measure every episode

On a multi-episode DVD title, the IFO can flag audio stream 0x81 as `(comment)`. ffmpeg reports
that faithfully, so **every chapter range decoded from that title comes out labelled a commentary** -
including the ones where the second stream is bit-for-bit identical to the programme audio.

Goodnight Sweetheart, Series 1-6 (11 discs, 2026-08-25). Of **36 episodes carrying a second audio
stream, only 10 were genuine commentaries.** The other 26 were exact duplicates of a:0. The flag
belongs to the TITLE; the answer is per-EPISODE, and the flag is wrong far more often than right.

Two discs (Series 2 Disk 2, Series 4 Disk 2) had **no second stream at all** - verified at
`-probesize 500M`, only 0x80 present. The set's advertised commentaries do not extend to the second
disk of those series. Both are second disks; every FIRST disk in series 2-6 carries the stream.

### The test

Whole-stream MD5 of the exact chapter range, one demux, two outputs:

    ffmpeg -f dvdvideo -title 2 -chapter_start N -chapter_end M -i "<disc>" -map 0:a:0 -f md5 -
    ffmpeg -f dvdvideo -title 2 -chapter_start N -chapter_end M -i "<disc>" -map 0:a:1 -f md5 -

Identical -> a duplicate, do NOT ship and do NOT claim `commentary`. Different -> transcribe it and
confirm it is people DISCUSSING the show rather than an alternate mix, then name the speakers from
what you hear.

**Spot-sampling is not enough for an "identical" verdict**, because that verdict is what causes a
track to be dropped. Confirm those with the whole stream. Validate the method in both directions
first - it should return DIFF on a disc known to carry real commentaries.

The same shape appears wherever one DVD title holds many episodes: a per-title flag cannot describe
a per-episode fact, and the pipeline's `.tracks.json` evidence has the same limitation - it is
per-SOURCE, so for chapter-split episodes the MD5 table is the evidence, not the tracks.json.

## A lossy CORE and a COMMENTARY score the same on any correlation test (2026-08-27)

`analyze-tracks.py`'s pairwise subtraction is sample-aligned and gain-naive, so it cannot see a
TrueHD track beside its own AC-3 core: they differ by a ~13 ms decoder delay plus a dialnorm gain
offset, the residual sits *above* the signal, and the pair reads as independent content. Both ship.
That is a fail-OPEN on the exact class the check was built for — Thunderball's `a:1` was a lossy
core, and on Sunrise (1927) the analyzer proposed keeping all five streams, two of which were cores.

Correcting for lag and gain does recover the delay (−13.2 ms, matching the decoder). **But it does
not separate a core from a commentary.** Measured on Sunrise t00, 30 s @ 1800 s:

| pair | naive | aligned | what it actually is |
|---|---|---|---|
| a:0 vs a:1 | −3.5 dB | **16.5 dB** | genuine lossy core |
| a:2 vs a:3 | −3.4 dB | **21.3 dB** | genuine lossy core |
| a:0 vs a:2 | −6.5 dB | 0.0 dB | two different scores — correctly rejected |
| a:0 vs a:4 | −9.0 dB | **15.9 dB** | **the COMMENTARY** |

The commentary lands level with a real core because it carries the film's score *underneath* the
speech, so the shared music bed correlates. **There is no threshold that catches the cores and
spares the commentary.** A raw correlation coefficient looks more decisive (0.99 vs 0.02 on the
pairs someone happens to test) but has the same blind spot — it is the same statistic renormalised.

So the check is **report-only** (`CORE_SUSPECT_DB`), and must stay that way. Shipping a redundant
core wastes a few GB; dropping a commentary destroys content the disc carried and nobody notices
until a viewer goes looking for it. Confirm any reported pair with `identify-audio.py` — a core is
the same audio, a commentary has someone talking over it, and transcription tells them apart in one
pass.

**General form of this trap:** a similarity measure between two tracks answers "do these share
content", never "is one of them redundant". Any track mixed OVER the programme audio — commentary,
audio description, an isolated-score-plus-narration — shares content by construction.

## Ordinals from the SOURCE do not survive the RIP — MakeMKV emits MA *and* core (2026-08-28)

The lossy core above is not only a dedup problem. It **renumbers the audio streams**, so an ordinal
established on the source `.m2ts` points at different content in the MakeMKV `.mkv` you encode from.

The Ladykillers (1955), BD. Content analysis of the source was settled and correct — `a:0` English
dialogue, `a:1` French, `a:2` German, `a:3` Spanish, `a:4` the Philip Kemp commentary. MakeMKV's rip
of the same title carries **10** audio tracks, not 5, because each DTS-HD MA track is paired with its
own DTS core:

```
rip:  0 eng MA   1 eng core   2 fra MA   3 fra core   4 deu MA   5 deu core
      6 spa MA   7 spa core   8 eng MA (commentary)   9 eng core
```

`audioTracks: [0, 4]` — right for the source — selects the English mix and the **German dub** in the
rip. The commentary is `a:8`. Nothing about the resulting file looks wrong: correct track count,
correct languages present, plausible sizes.

**The tell was SIZE**: the rip came out 30.0 GB against a 25.5 GB source `.m2ts`. A rip materially
larger than its source means extra streams, and on a DTS-HD/TrueHD disc that means cores.

So: **derive audio ordinals from the FILE THE MANIFEST READS, never from the file you analysed.**
When those differ — and for any `kind: "BD"` item reading a MakeMKV rip they almost always do —
re-derive against the rip and its `.tracks.json`. `assert-tracks-analysed.ps1` is what forces this;
it refuses an item whose tracks were never analysed, which is why the manifest waits on
`_analyse-loop` rather than shipping on the source's numbering.

## analyze-tracks.py's ROLE ELECTION IS UNRELIABLE — read the samples, never the proposal (2026-08-27)

Twice in one day, on two different discs, and in OPPOSITE directions:

| disc | a:0 | a:1 | analyser said | its proposal would have shipped |
|---|---|---|---|---|
| The Dirty Dozen (1967) | English original | French dub | a:0 `commentary`, a:1 `primary` | the film's English dialogue **tagged as a commentary**, French as the main audio |
| The Edge of the World (1937) | the film | the commentary | a:0 `commentary?`, a:1 `primary` | `audioTracks [1]` — **the commentary AS the soundtrack**, film audio dropped entirely |

**Root cause on the 1937 disc, which is the general case:** whisper scored the noisy optical track at
`langProb 0.49`, under the reliability floor, so `langReliable=false` removed it from the primary
election — and the commentary, being clean modern studio speech at 0.90, won unopposed. *A low
language confidence on an old or damaged soundtrack is a property of the RECORDING, not evidence
that it is not the film.* Any election that gates on transcription confidence will prefer a
commentary or a modern dub over an archival original, which is exactly backwards.

**So: the `role` field and the `proposal` are a starting point, never an answer.** Read the
`samples` text. It is unambiguous in seconds - film dialogue is characters talking to each other
("Good lad, Andrew. I ordered you to help"), commentary is someone talking *about* the film
("this is the point at which the film really joins another quite important current in 30s
filmmaking ... Emeric Pressburger, who still had not met Michael Powell at this point").

**When the election is wrong, correct the EVIDENCE, don't work around it.** Set `role` on the
affected streams, keep the original in `roleAnalyser`, put the reasoning in `roleCorrectedBy`, and
move the old proposal to `proposalAnalyser`. `assert-tracks-analysed.ps1` then passes the truthful
manifest. The alternative that suggests itself - shipping the commentary as an `{edition-...}` -
looks reasonable but is worse: on a film WITH local extras the edition must go in its own top-level
folder (see naming.md), so a commentary track becomes a second movie in the library.

Worth noting the guard behaved correctly throughout in both cases: it refused the unevidenced claim
on the Dirty Dozen, and refused the truthful manifest on Edge of the World *because the evidence it
was checking against was wrong*. The gate is only ever as good as the analysis behind it - which is
the argument for reading the samples yourself rather than trusting a role label.

## WHY the role election inverts: a music-only sample EXCLUDES the film's own track (2026-08-29)

`analyze-tracks.py`'s role election has been recorded as "unreliable, inverted twice". Here is the
mechanism, diagnosed on Withnail and I (1987):

**The election only considers streams whose spoken language is reliable across BOTH offsets.** Sample
the feature at a point where the film's own audio is music rather than speech, and the film mixes are
excluded as unreliable — leaving the **commentary as the only candidate**, which then wins and is
elected `primary`. The roles invert, and the gate correctly refuses a `commentary` tag on a track the
evidence calls primary.

On that disc t=100 s is nearly wall-to-wall King Curtis saxophone. Re-sampling at 2700 s and 3300 s —
continuous film dialogue, free of the production vocabulary that trips the commentary-hint test — let
the DTS-HD MA 5.1 film mix win on channel count.

So: **choose offsets where the FEATURE is talking.** A title card, a montage, an overture or a music
cue makes the primary track look unreliable, and "unreliable" is removed from the election rather
than penalised in it. If the roles come back inverted, re-sample before doubting the tracks — and
never hand-write the evidence file to match what you believe. Both commentaries here introduce
themselves on-record, which is what settles it independently of the analyser.
