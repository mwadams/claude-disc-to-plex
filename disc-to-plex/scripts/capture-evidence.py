#!/usr/bin/env python3
"""Capture fresh frames for a catalogued title and register them in the catalogue.

Needed because rewriting a catalogue onto the PROVEN mapping can leave a row with no evidence at
all: catalogue-dvd.ps1 only probes the dvdvideo title its duration-pairing believed in, so when the
pairing was wrong, some dvdvideo title was never opened. assert-accounted.ps1 verifies a `card:` or
`frame:` citation by checking the catalogue HOLDS frames for that title, so such a row cannot carry
one until the frames actually exist.

Frames are read through `-f dvdvideo -title N` using the row's PROVEN dvdvideoTitle - the same path
transcode.ps1 uses - so what is captured belongs to the title the row will be encoded from.

SPEECH, and why it is here rather than in the sweep. assert-accounted.ps1 verifies a `speech:`
citation by looking for the quote IN THE CATALOGUE'S OWN TRANSCRIPT, which is the right test - it is
what stops an author citing a line they believed rather than one the disc says. But the sweep records
exactly ONE sample per title, at a fixed early offset, and that leaves two ways for a true
identification to be uncitable:

  1. The row was never opened at all (the same wrong-mapping case that motivates the frames above),
     so it holds NO transcript and every citation against it fails.
  2. The one sample landed somewhere with no intelligible speech - a screaming scene, a music cue,
     an action beat. Farscape S3 D2's Eat Me sampled onto screaming; the row then had no content for
     any word-list to judge, and the primary-audio election silently dropped the programme track.

In both cases the fix is the same and it is NOT to loosen the gate: re-sample at an offset where
people are talking, register THAT, and cite it. So `--speech` extracts audio through the row's PROVEN
dvdvideo title - the same path the frames take and the same path transcode.ps1 will use - transcribes
it, and APPENDS it to the row with its own provenance. Appending, never replacing: the sweep's
original sample is evidence too, including when it is the evidence that the first offset was a bad
one, and a tool that overwrites its own inputs cannot be audited afterwards.

LANDMARK WINDOWS GO THROUGH HERE TOO - THIS IS NOT ONLY A REPAIR TOOL. The two-landmark
identification method takes a second window deep in the title (~600-700 s) to confirm an identity.
Doing that with ad-hoc ffmpeg + transcribe-wav.py produces a transcript that lives only in the
agent's context: assert-accounted.ps1 verifies a `speech:` quote against the CATALOGUE, so a quote
from an unrecorded window is refused even when the identification is right - which punishes exactly
the agent who cited the stronger evidence. Measured 2026-09-02: 32 refused citations across 7 discs
(Boston Legal S3 D4/D6, Danger Man S1 D1-D5), every one a correct identification quoting an
unrecorded landmark. So: take the landmark window WITH `--speech <sec>` and it is recorded in the
same act, both as an inline `[re-sampled @Ns]` append to `speechSample` and as a structured
`speechSamplesExtra` entry that keeps the offset and provenance machine-readable. The gate has read
`speechSamplesExtra` since before it was ever written; this tool is now its writer (2026-09-02).

There is deliberately NO way to register a transcript you produced elsewhere. The recording is
trustworthy only because extraction, transcription and registration happen in one act, through the
row's proven dvdvideo title - accepting outside text would let a mistaken (or invented) transcript
into the exact field the gate trusts. NAS-side comparison windows never belong in the catalogue at
all: the catalogue records what the DISC says; cite the disc-side window.

Usage: capture-evidence.py "D:/video/_stage/<disc>" <makemkvTitle> <sec> [<sec> ...]
                           [--speech <sec>[,<sec>...]] [--cat-dir <dir>]

`--cat-dir` overrides where the catalogue is read and written (default D:/video/_catalogue).
It exists so tests can run against a SCRATCH COPY of a catalogue instead of the live one.
"""
import json
import os
import re
import subprocess
import sys
import uuid

import cat_lock          # beside this script; sys.path[0] is the script's own directory

CAT_DIR = 'D:/video/_catalogue'
FFMPEG = ('D:/video/.transcode-tools/ffmpeg-n7.1/'
          'ffmpeg-n7.1-latest-win64-gpl-7.1/bin/ffmpeg.exe')
WHISPER = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'transcribe-wav.py')
SPEECH_SECONDS = 55


# A title card is usually FADED in and out, so the exact second the OCR reported can land in the
# black gap either side of it. On D2 dvdvideo 4 the card OCR'd at 82s but the frame grabbed at
# 82.0s is solid black, 1,383 bytes. That matters more than it looks: assert-accounted.ps1 verifies
# a `card:` citation by checking the catalogue HOLDS frames for the title, not by looking at them -
# so a black frame satisfies the gate while proving nothing. Grab a neighbourhood and keep the
# frame that actually carries picture.
BLANK_BYTES = 8000          # a 720x576 PNG of near-solid black lands around 1-2 KB
NEIGHBOURHOOD = (0, 1, -1, 2, -2, 3)


def grab_non_blank(disc, dvd, mk_title, sec, frame_dir):
    best = None
    for delta in NEIGHBOURHOOD:
        at = sec + delta
        if at < 0:
            continue
        # NAME THE FRAME AFTER WHAT IT IS, NOT AFTER WHO CITED IT.
        #
        # This used the MakeMKV title id (`t%03d`). That id is the ROW the frame was captured for,
        # not the thing the frame shows - and `apply-proof.py` re-homes evidence bundles BETWEEN
        # rows when the prover corrects a mapping. After a re-home, row t02 can legitimately cite a
        # file called `t003-*.png`; capturing fresh evidence for t03 then wrote that exact filename
        # and SILENTLY OVERWROTE the frames t02 was citing. `assert-accounted.ps1` still passed:
        # the file existed and carried picture, it was just a different title's picture.
        #
        # Found on Farscape S1 D2 (2026-08-29). The dvdvideo title is what the frame is actually OF,
        # it is 1:1 with the row after a proof, and it cannot collide across a re-home. Existing
        # `tNNN-` frames stay valid and are not touched - the two schemes simply cannot clobber
        # each other, which is the point.
        out = os.path.join(frame_dir, 'dv%02d-%04d.png' % (dvd, at))
        subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error',
                        '-f', 'dvdvideo', '-title', str(dvd), '-i', disc,
                        '-ss', str(at), '-frames:v', '1', out, '-y'],
                       capture_output=True)
        if not os.path.exists(out):
            continue
        size = os.path.getsize(out)
        if size >= BLANK_BYTES:
            note = '' if delta == 0 else '  (asked for %ds; that frame was blank)' % sec
            print('captured dvdvideo %d @ %ds -> %s (%d bytes)%s'
                  % (dvd, at, os.path.basename(out), size, note))
            return out
        if best is None or size > best[1]:
            best = (out, size)
        os.remove(out)
    if best:
        print('WARNING dvdvideo %d near %ds: every frame in the neighbourhood is near-blank '
              '(best %d bytes) - do NOT cite a card here without looking at it'
              % (dvd, sec, best[1]))
    return None


def grab_speech(disc, dvd, mk_title, sec, scratch):
    """Transcribe SPEECH_SECONDS of audio at `sec`. Returns (status, text, wav_path)."""
    # UNIQUE PER RUN. The sweep's scratch wav was once keyed on the title number alone, and three
    # concurrent catalogues transcribed each other's audio into each other's catalogues - confident
    # wrong evidence in the exact field used to NAME titles. Same rule here: PID + a fresh GUID.
    wav = os.path.join(scratch, 'ev-t%03d-%04d.wav' % (mk_title, sec))
    subprocess.run([FFMPEG, '-v', 'error',
                    '-f', 'dvdvideo', '-title', str(dvd), '-i', disc,
                    '-ss', str(sec), '-t', str(SPEECH_SECONDS),
                    '-map', '0:a:0?', '-ac', '1', '-ar', '16000', '-y', wav],
                   capture_output=True)
    if not os.path.exists(wav) or os.path.getsize(wav) < 1024:
        # NOT "no speech". A missing wav means the extraction failed or the title has no audio;
        # recording that as silence would turn a tool failure into a finding about the disc.
        return 'no-wav', None, wav
    proc = subprocess.run([sys.executable, WHISPER, wav], capture_output=True, text=True)
    out = (proc.stdout or '').strip()
    if proc.returncode != 0 or not out:
        detail = (proc.stderr or '').strip().splitlines()
        return 'failed', (detail[0] if detail else 'transcriber produced nothing'), wav
    return 'ok', out, wav


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    argv = sys.argv[1:]
    speech_at = []
    if '--speech' in argv:
        i = argv.index('--speech')
        if i + 1 >= len(argv):
            sys.exit('--speech needs at least one offset in seconds')
        speech_at = [int(s) for s in argv[i + 1].replace(',', ' ').split()]
        argv = argv[:i] + argv[i + 2:]
    cat_dir = CAT_DIR
    if '--cat-dir' in argv:
        i = argv.index('--cat-dir')
        if i + 1 >= len(argv):
            sys.exit('--cat-dir needs a directory')
        cat_dir = argv[i + 1]
        argv = argv[:i] + argv[i + 2:]
    disc, mk_title = argv[0], int(argv[1])
    seconds = [int(s) for s in argv[2:]]

    disc_name = os.path.basename(disc.rstrip('/\\'))
    cat_path = os.path.join(cat_dir, disc_name + '.catalogue.json')
    with open(cat_path, encoding='utf-8') as fh:
        cat = json.load(fh)

    row = next((r for r in cat['titles'] if int(r['title']) == mk_title), None)
    if row is None:
        sys.exit('no such MakeMKV title %d in %s' % (mk_title, cat_path))
    dvd = row.get('dvdvideoTitle')
    if dvd is None:
        sys.exit('t%02d has no dvdvideoTitle - prove the mapping first' % mk_title)

    frame_dir = os.path.join(cat_dir, disc_name + '-frames')
    os.makedirs(frame_dir, exist_ok=True)

    added = []
    for sec in seconds:
        got = grab_non_blank(disc, dvd, mk_title, sec, frame_dir)
        if got:
            added.append(got)
        else:
            print('FAILED dvdvideo %d near %ds - every candidate frame was blank' % (dvd, sec))

    spoke = []
    if speech_at:
        scratch = os.path.join(os.environ.get('TEMP', '.'),
                               'capture-evidence-%d-%s' % (os.getpid(), uuid.uuid4().hex[:8]))
        os.makedirs(scratch, exist_ok=True)
        for sec in speech_at:
            status, text, wav = grab_speech(disc, dvd, mk_title, sec, scratch)
            if status == 'ok':
                spoke.append((sec, text, wav))
                print('transcribed dvdvideo %d @ %ds -> %d chars' % (dvd, sec, len(text)))
            else:
                # Loud, and NOT written to the catalogue as an empty sample. A failed transcription
                # recorded as "no speech" is how a tool failure becomes a claim about the disc.
                print('SPEECH %s dvdvideo %d @ %ds - this is NOT "no speech"; do not treat the gap '
                      'as evidence. %s' % (status.upper(), dvd, sec, text or ''))

    if not added and not spoke:
        sys.exit('nothing captured - catalogue not touched')

    # REGISTER UNDER A CROSS-PROCESS LOCK, AGAINST A FRESH READ. The read at the top of main()
    # is only for finding the proven dvdvideoTitle; by the time the captures finish (minutes of
    # ffmpeg + whisper), that copy is STALE whenever anything else wrote the catalogue meanwhile.
    # This tool used to mutate that stale copy and write the whole file back: run concurrently on
    # several titles of ONE disc, every process based its write on version N and the last writer
    # won. Danger Man 1964-1968 Disk 6 (2026-09-02): four parallel captures, three silently
    # vanished, all four printed "registered". The atomic os.replace below is NOT that fix - it
    # only protects a concurrent reader from a torn file - so:
    #   1. take the per-catalogue lock (held for the milliseconds of read+write, never for the
    #      capture work, so N discs in parallel never queue and N titles of one disc queue
    #      briefly);
    #   2. RE-READ the catalogue inside it and mutate that fresh copy;
    #   3. after writing, VERIFY OUR OWN ENTRIES ARE IN THE FILE before saying "registered" -
    #      so even a writer that bypasses the lock (an old copy of this script, a hand edit)
    #      can lose the update but can never make this tool report the loss as success.
    with cat_lock.locked(cat_path):
        with open(cat_path, encoding='utf-8') as fh:
            cat = json.load(fh)
        row = next((r for r in cat['titles'] if int(r['title']) == mk_title), None)
        if row is None:
            sys.exit('REGISTRATION FAILED: t%02d is no longer in %s - the catalogue changed '
                     'between capture and registration; nothing was written' % (mk_title, cat_path))
        if row.get('dvdvideoTitle') != dvd:
            sys.exit('REGISTRATION REFUSED: t%02d was dvdvideo title %d when this evidence was '
                     'captured, but the catalogue now maps it to %s (apply-proof.py ran '
                     'mid-capture?). The frames/audio came through the OLD title, so registering '
                     'them on this row would attach another title\'s evidence. Nothing was '
                     'written - re-run the capture.' % (mk_title, dvd, row.get('dvdvideoTitle')))
        expect = apply_registration(row, disc, dvd, mk_title, added, spoke, seconds)
        # ATOMIC REPLACE, never an in-place truncate-and-write. assert-accounted.ps1,
        # apply-proof.py and disposition agents all read this file while discs are in flight; a
        # reader that catches a half-written JSON sees a parse error at best and a short
        # catalogue at worst. Write beside the target (same volume, so os.replace is atomic).
        tmp_path = '%s.tmp-%d-%s' % (cat_path, os.getpid(), uuid.uuid4().hex[:8])
        with open(tmp_path, 'w', encoding='utf-8') as fh:
            json.dump(cat, fh, indent=2)
        os.replace(tmp_path, cat_path)

    # "registered" MUST MEAN REGISTERED. Re-read the file we just wrote (outside the lock - if
    # anything clobbered us even in this window, that too must surface) and refuse to report
    # success unless every entry is actually present.
    problems = verify_registration(cat_path, mk_title, expect)
    if problems:
        for p in problems:
            print('LOST UPDATE: %s' % p)
        sys.exit('REGISTRATION FAILED: wrote %s but the entries above are NOT in it - another '
                 'writer clobbered this update. The evidence was NOT recorded; re-run this '
                 'capture and find the concurrent writer.' % cat_path)
    print('registered %d frame(s) and %d transcript(s) on t%02d in %s'
          % (len(added), len(spoke), mk_title, cat_path))


def apply_registration(row, disc, dvd, mk_title, added, spoke, seconds):
    """Mutate `row` in place with everything this run captured.

    Returns the exact values verify_registration() must later find in the file - built HERE, from
    what was actually written, so the verification cannot drift from the write.
    """
    expect = {'seams': [], 'extras': [], 'frames': []}
    if spoke:
        # APPEND with a visible seam. The row may already hold the sweep's sample from a different
        # offset; a reader (and assert-accounted's quote search) must see one continuous text, but
        # an auditor must still be able to tell which offset produced which words.
        parts = []
        if row.get('speechSample'):
            parts.append(row['speechSample'].rstrip())
        for sec, text, _ in spoke:
            seam = '[re-sampled @%ds] %s' % (sec, text)
            parts.append(seam)
            expect['seams'].append(seam)
        row['speechSample'] = '\n'.join(parts)
        row['speechStatus'] = 'ok'
        prior = row.get('speechFrom')
        stamps = ['disc=%s|dvdvideoTitle=%d|offset=%ds|wav=%s' % (disc, dvd, sec, wav)
                  for sec, _, wav in spoke]
        row['speechFrom'] = ' ;; '.join(([prior] if prior else []) + stamps)
        # ...AND STRUCTURED, so the offset and provenance stay machine-readable per sample.
        # assert-accounted.ps1 reads `speechSamplesExtra` (each entry's .text), and until
        # 2026-09-02 the only writers were agents HAND-EDITING catalogue JSON (The Bill S1-S4,
        # Farscape, capturedBy "assistant 2026-08-27: ffmpeg ..."); when that practice lapsed,
        # landmark transcripts stopped being recorded and 32 correct citations across 7 discs were
        # refused as unverifiable. This tool is now the writer, in the same entry shape the hand
        # edits established: {offsetSec, lang, prob, text, capturedBy}. The inline append above is
        # kept unchanged - readers of `speechSample` see exactly what they always saw - so this is
        # additive, not a migration. The entry lives ON THE ROW it was extracted from, through
        # that row's proven dvdvideoTitle: that is what ties a landmark transcript to its title,
        # and why a quote can never verify against another title's window.
        extra = list(row.get('speechSamplesExtra') or [])
        for sec, text, _ in spoke:
            entry = {
                'offsetSec': sec,
                'windowSec': SPEECH_SECONDS,
                'dvdvideoTitle': dvd,
                'capturedBy': 'capture-evidence.py --speech',
            }
            # transcribe-wav.py prefixes every transcript with its positive marker '[<lang> <prob>]'.
            # Lift it into fields, matching the hand-written entries already in the data.
            m = re.match(r'^\[(\w{2,3}) ([\d.]+)\]\s*', text)
            if m:
                entry['lang'] = m.group(1)
                entry['prob'] = float(m.group(2))
                entry['text'] = text[m.end():]
            else:
                entry['text'] = text
            extra.append(entry)
            expect['extras'].append(entry)
        row['speechSamplesExtra'] = extra

    frames = list(row.get('frames') or [])
    for p in added:
        p = p.replace('/', '\\')
        if p not in frames:
            frames.append(p)
        expect['frames'].append(p)
    row['frames'] = frames
    # Say what was ACTUALLY captured. This note used to describe frames unconditionally, so a
    # speech-only run would have claimed frames it never took and listed an empty offset list.
    what = []
    if added:
        what.append('frames at %s' % ', '.join('%ds' % s for s in seconds))
    if spoke:
        what.append('speech at %s' % ', '.join('%ds' % s for s, _, _ in spoke))
    row['evidenceNote'] = (
        '%s captured directly from dvdvideo title %d (the PROVEN title for t%02d); the catalogue '
        'sweep either never opened this dvdvideo title, because its duration-pairing named a '
        'different one, or sampled it where there was nothing intelligible to hear'
        % (' and '.join(what).capitalize(), dvd, mk_title))
    return expect


def verify_registration(cat_path, mk_title, expect):
    """Re-read cat_path FROM DISK and report every expected entry that is not in it.

    Presence, not equality: another (locked) writer may legitimately have added MORE entries
    after ours - only OUR entries missing is a failure.
    """
    problems = []
    try:
        with open(cat_path, encoding='utf-8') as fh:
            cat = json.load(fh)
    except (OSError, ValueError) as e:
        return ['could not re-read %s after writing it: %s' % (cat_path, e)]
    row = next((r for r in cat['titles'] if int(r['title']) == mk_title), None)
    if row is None:
        return ['t%02d is not in the file just written' % mk_title]
    sample = row.get('speechSample') or ''
    for seam in expect['seams']:
        if seam not in sample:
            problems.append('t%02d speechSample is missing the appended window %r'
                            % (mk_title, seam[:80]))
    extras = row.get('speechSamplesExtra') or []
    for e in expect['extras']:
        if not any(x.get('offsetSec') == e['offsetSec']
                   and x.get('text') == e.get('text')
                   and x.get('capturedBy') == e.get('capturedBy') for x in extras):
            problems.append('t%02d speechSamplesExtra is missing the entry for offset %ds'
                            % (mk_title, e['offsetSec']))
    frames = set(row.get('frames') or [])
    for p in expect['frames']:
        if p not in frames:
            problems.append('t%02d frames is missing %s' % (mk_title, p))
    return problems


if __name__ == '__main__':
    main()
