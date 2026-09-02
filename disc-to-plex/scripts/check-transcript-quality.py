#!/usr/bin/env python3
"""Find machine transcripts that are BAD IN PLACES, which the whole-file gates cannot.

WHY THIS EXISTS
---------------
On 2026-09-01 a viewer found this in a published Danger Man episode:

    "morning sir all the morning coffee and eggs for two fuck too sad for a"

The line is "Coffee and eggs for two. / For two, sir? / For two." The file had passed every check
the pipeline had: coverage 0.999, englishFraction 0.975, 331 cues, no warnings. It passed because
EIGHT BAD CUES IN 331 DO NOT MOVE AN AVERAGE. A whole-file score is structurally blind to a
localised failure - the same defect as confirming a rip from a grep that only matches success.

So this looks for the SHAPE of the failure instead of its size. When faster-whisper loses the
thread over a stretch of difficult audio it stops emitting sentence punctuation and capitals, and
its cues get much longer as it runs words together:

    normal   1.6s mean cue, "Tell me, does the name Hans Vogler mean anything to you?"
    degraded 5.6s mean cue, "morning sir all the morning coffee and eggs for two ..."

A cue that starts lower-case AND contains no sentence punctuation at all is the marker. Two
consecutive such cues is a stretch worth re-transcribing; one alone is usually just a continuation.

It also flags PROFANITY, which is worth its own check rather than being folded into the above:
invented obscenity is the most damaging thing a transcript can put on screen, it is trivially
greppable, and in most of this library's material its presence is itself the evidence of an error.
Nine hits were found across 67 Danger Man transcripts, in a 1960s ITC series that contains none.

  python check-transcript-quality.py <root> [--redo-list out.txt] [--want-model medium]

Exit 0 always: this REPORTS, it does not gate. The gate is the model default in
transcribe-subtitles.py, which this evidence is what set.
"""
import argparse
import io
import json
import os
import re
import sys

# Deliberately narrow, and deliberately including mild British profanity: the point is not
# censorship, it is that these words are strong evidence of a mis-hearing in this library's
# material. Widen it for a programme that genuinely swears, or ignore the hits there.
PROFANITY = re.compile(
    r"\b(fuck\w*|shit(e|ty)?|cunt\w*|wank\w*|bollocks|piss(ed|ing)?|arsehole|bastard)\b", re.I)


def parse_srt(path):
    """-> [(index, start_seconds, duration_seconds, text)]"""
    try:
        raw = io.open(path, encoding='utf-8', errors='replace').read().replace('\r', '')
    except Exception:
        return []
    out = []
    for blk in raw.split('\n\n'):
        lines = [l for l in blk.split('\n') if l.strip()]
        if len(lines) < 3 or '-->' not in lines[1]:
            continue
        try:
            a, b = lines[1].split(' --> ')
            out.append((int(lines[0]), _sec(a), _sec(b) - _sec(a), ' '.join(lines[2:])))
        except Exception:
            continue
    return out


def _sec(t):
    h, m, s = t.strip().split(':')
    return int(h) * 3600 + int(m) * 60 + float(s.replace(',', '.'))


def is_degraded(text):
    """Lower-case opening AND no sentence punctuation anywhere. Both conditions matter: plenty of
    correct cues open lower-case as a continuation, and they still carry a comma or full stop."""
    return bool(text[:1].islower()) and not re.search(r'[.,?!]', text)


def runs_of(flags, minimum=2):
    """Index ranges where `flags` is True for at least `minimum` consecutive entries."""
    out, start = [], None
    for i, f in enumerate(flags + [False]):
        if f and start is None:
            start = i
        elif not f and start is not None:
            if i - start >= minimum:
                out.append((start, i - 1))
            start = None
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('root')
    ap.add_argument('--redo-list', help='write the media paths needing re-transcription here')
    ap.add_argument('--want-model', default='medium',
                    help='transcripts made with a different model are listed for redo')
    ap.add_argument('--quiet', action='store_true', help='only print the summary and the offenders')
    a = ap.parse_args()

    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding='utf-8', errors='replace')
        except Exception:
            pass

    files = []
    for dirpath, _dirs, names in os.walk(a.root):
        for n in names:
            if not n.endswith('.eng.srt'):
                continue
            prov = os.path.join(dirpath, n.replace('.eng.srt', '.eng.provenance.json'))
            if os.path.exists(prov):
                files.append((os.path.join(dirpath, n), prov))

    redo, rows, profane = [], [], []
    for srt, prov in sorted(files):
        try:
            p = json.load(io.open(prov, encoding='utf-8'))
        except Exception:
            continue
        if p.get('method') != 'audio-transcription':
            continue                      # an OCR sidecar is not ours to judge on these grounds
        model = str(p.get('model', '?'))
        cues = parse_srt(srt)
        if not cues:
            continue
        flags = [is_degraded(c[3]) for c in cues]
        stretches = runs_of(flags)
        bad = sum(1 for f in flags if f)
        hits = [(c[0], int(c[1]), c[3][:80]) for c in cues if PROFANITY.search(c[3])]
        profane.extend((os.path.basename(srt), h) for h in hits)
        why = []
        if model != a.want_model:
            why.append('model=%s' % model)
        if stretches:
            why.append('%d degraded stretch(es)' % len(stretches))
        if hits:
            why.append('%d profanity' % len(hits))
        rows.append((srt, model, len(cues), bad, len(stretches), len(hits), why))
        if why:
            redo.append(p.get('source') or srt.replace('.eng.srt', '.mkv'))

    print('%d machine transcript(s) under %s' % (len(rows), a.root))
    if not rows:
        return 0
    worst = sorted(rows, key=lambda r: (-r[4], -r[3]))
    print('\n%-56s %-7s %5s %5s %6s %5s' % ('file', 'model', 'cues', 'bad', 'runs', 'prof'))
    for srt, model, n, bad, runs, hits, why in (worst if not a.quiet else worst[:20]):
        if not why:
            continue
        print('%-56s %-7s %5d %5d %6d %5d' % (os.path.basename(srt)[:54], model, n, bad, runs, hits))
    print('\n%d of %d transcript(s) need re-doing' % (len(redo), len(rows)))
    tot_bad = sum(r[3] for r in rows)
    tot_run = sum(r[4] for r in rows)
    print('degraded cues %d across %d stretch(es); profanity hits %d'
          % (tot_bad, tot_run, len(profane)))
    if profane:
        print('\nPROFANITY - in most of this library its presence IS the error:')
        for name, (cue, at, text) in profane[:30]:
            print('   %-46s cue %-5d @%5ds  %s' % (name[:44], cue, at, text))
    if a.redo_list:
        io.open(a.redo_list, 'w', encoding='utf-8', newline='\n').write('\n'.join(redo) + '\n')
        print('\nredo list -> %s' % a.redo_list)
    return 0


if __name__ == '__main__':
    sys.exit(main())
