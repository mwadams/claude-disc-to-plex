#!/usr/bin/env python3
"""Remove near-blank frames from a catalogue's evidence lists, and delete the files.

A `card:`/`frame:` citation is verified by assert-accounted.ps1 only to the extent that the
catalogue HOLDS frames for that title - it does not look at them. So a black frame satisfies the
gate while proving nothing, which is the "passes every structural check and is empty" failure this
pipeline keeps paying for. This sweeps them out.

Usage: drop-blank-frames.py "<disc name or path>" [minBytes]
"""
import json
import os
import sys

CAT_DIR = 'D:/video/_catalogue'
DEFAULT_MIN = 8000       # a 720x576 PNG of near-solid black lands around 1-2 KB


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    disc_name = os.path.basename(sys.argv[1].rstrip('/\\'))
    min_bytes = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_MIN
    cat_path = os.path.join(CAT_DIR, disc_name + '.catalogue.json')
    with open(cat_path, encoding='utf-8') as fh:
        cat = json.load(fh)

    removed = 0
    for row in cat['titles']:
        keep = []
        for f in (row.get('frames') or []):
            # A DANGLING reference is worse than a blank frame: the file is gone, so nothing can be
            # looked at, yet the catalogue still counts it as evidence held for this title.
            if not os.path.exists(f):
                print('  t%02d: dropping %s (listed but MISSING from disk)'
                      % (row['title'], os.path.basename(f)))
                removed += 1
                continue
            if os.path.getsize(f) < min_bytes:
                print('  t%02d: dropping %s (%d bytes - near-blank)'
                      % (row['title'], os.path.basename(f), os.path.getsize(f)))
                os.remove(f)
                removed += 1
                continue
            keep.append(f)
        row['frames'] = keep
        if not keep and row.get('disposition') is None:
            print('  t%02d: NOW HOLDS NO FRAMES - a card:/frame: citation here would be unverifiable'
                  % row['title'])

    with open(cat_path, 'w', encoding='utf-8') as fh:
        json.dump(cat, fh, indent=2)
    print('%s: removed %d near-blank frame(s)' % (disc_name, removed))


if __name__ == '__main__':
    main()
