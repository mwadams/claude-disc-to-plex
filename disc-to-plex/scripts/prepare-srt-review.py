#!/usr/bin/env python3
"""Prepare a machine-transcribed .srt for a correction pass, and say what to look for.

Pairs with apply-srt-corrections.py. This half is pure mechanics: it emits the cue text in a
compact numbered form, plus the episode's own cast and terms from the lexicon, plus a shortlist of
lines that carry a hint of trouble. The JUDGEMENT - deciding that "send bag" is "sand bag" - is a
reading task and is done by an agent, exactly as manifests are.

WHY A SHORTLIST IS NOT ENOUGH ON ITS OWN, and why the full text is emitted too:
the errors worth fixing are REAL WORDS in the wrong place. "storks"/"stalks", "chef"/"chief",
"McGoon"/"McGoohan" all pass a dictionary. Any filter tight enough to be short is also tight
enough to miss the whole point, so the shortlist is a hint, never the work item.

  python prepare-srt-review.py <file.eng.srt> [--out review.txt]
"""
import argparse
import io
import json
import os
import re
import sys

# Words that are fine English but very often a mis-hearing in this material. Not a rule - a nudge
# for the reader's eye. Keep it short; a long list becomes noise and gets skimmed.
SUSPECT = [
    'send bag', 'stalks', 'chef', 'memory apartment', 'sees', 'wander', 'weather',
    'grate', 'principal', 'discrete', 'cannon', 'medal', 'moral', 'bare', 'brake',
]


def parse_srt(path):
    raw = io.open(path, encoding='utf-8', errors='replace').read().replace('\r', '')
    out = []
    for blk in raw.split('\n\n'):
        lines = [l for l in blk.split('\n') if l.strip() != '']
        if len(lines) >= 3 and '-->' in lines[1]:
            out.append((lines[0].strip(), lines[1], ' '.join(lines[2:])))
    return out


def load_lexicon(srt_path):
    """The episode's own cast and terms, if build-lexicon.ps1 made one. Grounding matters: a
    reviewer who knows the character is 'Delenn' will not leave 'De Len' in the text."""
    m = re.search(r'[Ss](\d{1,2})[Ee](\d{1,3})', os.path.basename(srt_path))
    if not m:
        return None, []
    ep = 'S%02dE%02d' % (int(m.group(1)), int(m.group(2)))
    # work name: the directory two levels up is the show folder
    show = os.path.basename(os.path.dirname(os.path.dirname(srt_path)))
    p = os.path.join('D:/video/_lexicons', show, ep + '.json')
    if not os.path.exists(p):
        return ep, []
    try:
        d = json.load(io.open(p, encoding='utf-8'))
        names = list(d.get('characters', [])) + list(d.get('terms', []))
        return ep, [n for n in names if len(n) > 2]
    except Exception:
        return ep, []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('srt')
    ap.add_argument('--out')
    a = ap.parse_args()

    cues = parse_srt(a.srt)
    if not cues:
        print('[failed] parsed 0 cues from %s' % a.srt)
        return 2
    ep, names = load_lexicon(a.srt)

    lines = []
    lines.append('CORRECTION REVIEW: %s' % os.path.basename(a.srt))
    lines.append('%d cues%s' % (len(cues), ('   episode %s' % ep) if ep else ''))
    lines.append('')
    if names:
        lines.append('CAST AND TERMS for this episode (spell these correctly):')
        lines.append('  ' + ', '.join(names))
        lines.append('')
    else:
        lines.append('NO LEXICON for this episode - names cannot be checked against a cast list.')
        lines.append('')

    hits = []
    for idx, _t, text in cues:
        low = text.lower()
        for s in SUSPECT:
            if s in low:
                hits.append((idx, s, text))
                break
    if hits:
        lines.append('LINES CONTAINING A COMMONLY MIS-HEARD WORD (a hint, not the work list):')
        for idx, s, text in hits[:40]:
            lines.append('  cue %-5s [%s]  %s' % (idx, s, text[:100]))
        lines.append('')

    lines.append('FULL TEXT - read it for sense. Correct only what is WRONG, not what is')
    lines.append('merely informal; these are transcripts of speech, not prose.')
    lines.append('')
    for idx, _t, text in cues:
        lines.append('%s|%s' % (idx, text))

    body = '\n'.join(lines)
    out = a.out or (os.path.splitext(a.srt)[0] + '.review.txt')
    io.open(out, 'w', encoding='utf-8', newline='\n').write(body + '\n')
    print('%d cues, %d suspect line(s), %d lexicon name(s) -> %s'
          % (len(cues), len(hits), len(names), out))
    return 0


if __name__ == '__main__':
    sys.exit(main())
