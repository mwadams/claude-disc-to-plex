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
