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
import uuid

import cat_lock          # beside this script; sys.path[0] is the script's own directory

CAT_DIR = 'D:/video/_catalogue'
DEFAULT_MIN = 8000       # a 720x576 PNG of near-solid black lands around 1-2 KB


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    disc_name = os.path.basename(sys.argv[1].rstrip('/\\'))
    min_bytes = int(sys.argv[2]) if len(sys.argv) > 2 else DEFAULT_MIN
    cat_path = os.path.join(CAT_DIR, disc_name + '.catalogue.json')
    # Read-modify-write of the whole catalogue -> same per-catalogue lock as capture-evidence.py
    # and apply-proof.py, or a concurrent registration on another title of this disc is silently
    # erased (the Danger Man Disk 6 lost-update, 2026-09-02). Held for the whole (short) sweep:
    # the frame stat/remove work is milliseconds per file.
    with cat_lock.locked(cat_path):
        _drop(cat_path, disc_name, min_bytes)


def _drop(cat_path, disc_name, min_bytes):
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

    # Atomic replace: readers of an in-flight disc must never see a torn JSON.
    tmp_path = '%s.tmp-%d-%s' % (cat_path, os.getpid(), uuid.uuid4().hex[:8])
    with open(tmp_path, 'w', encoding='utf-8') as fh:
        json.dump(cat, fh, indent=2)
    os.replace(tmp_path, cat_path)
    print('%s: removed %d near-blank frame(s)' % (disc_name, removed))


if __name__ == '__main__':
    main()
