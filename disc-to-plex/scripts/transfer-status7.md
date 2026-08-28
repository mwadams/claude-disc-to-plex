
---

## 2026-08-28 (early hours) — Jensen Code, Rivals, Shakespeare, Ladykillers

Four agents run in parallel. **`prove-dvd-mapping.py` written and immediately earned itself.**

| Unit | State |
|---|---|
| The Jensen Code (1973) | **COMPLETE, 13 eps + colour fragment, verified 14/14, Plex 13/13 OK** — awaiting confirmation |
| The Rivals of Sherlock Holmes (1971) S1 | **9 eps + gallery, published 10/10** — E10-13 are on D4 (partial by design) — awaiting confirmation |
| BBC Television Shakespeare | Merchant S03E02 (2 stacked parts) + Merry Wives S05E02 encoded; publish blocked on OCR |
| The Ladykillers (1955) | manifest held pending `_analyse-loop`; audio ordinals corrected |

### The new prover caught three crossed mappings in one night

`catalogue-dvd.ps1` pairs MakeMKV titles to dvdvideo titles by DURATION. On **Jensen D1**, **Jensen D2**
and **Rivals D1** that pairing was wrong — episodes 2 and 3 of Rivals would have shipped SWAPPED, and
because frames/head-strips/speech are captured through `-f dvdvideo -title <n>`, the crossed evidence
made each catalogue perfectly self-consistent. Confirmed independently three ways on Rivals D1: the
prover's byte arithmetic, MakeMKV `TINFO,24`, and the catalogue's OWN head-strips (t002 shows the
*Dorrington* card, t003 the *Max Carrados* card — crossed exactly as predicted).

Two traps the prover exposed about ITSELF, both now guarded:
- **`--minlength` renumbers titles.** At MakeMKV's default 120 s floor a 24.9 s boilerplate title
  vanishes and every id shifts — a self-consistent mapping that was off by one throughout.
- **A success-shaped report can't describe a truncated disc.** It printed "all titles proven", exit 0,
  for DIE_MUMINS_3 — 27 titles declared, 10 present. Now accounts for every TT_SRPT-declared title and
  separates "below the floor" from "no VOBs on disk".

### Audio ordinals do not survive the rip (The Ladykillers)

MakeMKV emits each DTS-HD MA track AND its lossy DTS core, so the rip has **10** audio tracks where the
source `.m2ts` has 5. `audioTracks: [0, 4]` — correct for the source — selects the **German dub** in the
rip; the commentary is `a:8`. The tell was the rip at 30.0 GB against a 25.5 GB source. Written up in
`gotchas-audio.md`: the lossy core was documented as a DEDUP hazard, not as an ORDINAL-SHIFTING one.

### My own errors this stretch

- **Called a slow mkvextract "hung"** on 1 s CPU over 40 min, then ran a second extraction of the SAME
  file to test it — adding a third concurrent reader to a box already running two encodes and whisper.
  It was progressing (3%/6 min) and completed. Measure throughput before concluding a stall.
- **Compared the wrong episodes** when duration-checking the three multi-segment Rivals titles: the
  agent's "t02" is a MakeMKV id, and t00↔dvdvideo 1 makes it dvdvideo 3 = E02, not E01. First pass
  reported all three suspect. The tell was one coming out LONGER — no truncation does that. Correct
  answer: E02 +5.4 s, E05 +6.6 s, both inside this disc's 3-7 s header over-report. No truncation.
- **Edited `prove-dvd-mapping.py` while an agent was using it** (added a return value before updating
  its caller), crashing it mid-run. It worked around me.

### For the user — NAS deletions (Friday list grows)

- `Movies\The Ladykillers` — superseded 1.6 GB PAL DVD rip, will coexist with the new `(1955)` folder.
- `BBC Television Shakespeare\Season 01\` — **S01E15 All's Well**, **S01E18 Antony and Cleopatra**,
  **S01E21 A Midsummer Night's Dream**. Canonical S1 has SIX episodes; these numbers cannot exist, and
  each matches a correctly-numbered copy to the byte (S03E03 / S03E06 / S04E03). Leftovers of the old
  flat 1-37 scheme. Verified independently before listing.

### Next

52 discs remain, fetch parked at 55 GB against its 120 GB floor. Confirming Jensen Code and Rivals
releases their staging and restarts the source track.
