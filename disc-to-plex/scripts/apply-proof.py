#!/usr/bin/env python3
"""Rewrite a catalogue.json onto the mapping proved by prove-dvd-mapping.py.

catalogue-dvd.ps1 pairs MakeMKV titles to dvdvideo titles by DURATION. On a TV disc the
runtimes cluster within seconds and that pairing is routinely wrong. The evidence (frames,
head strip, speech) is captured through `-f dvdvideo -title N`, so it belongs to the dvdvideo
title named in its own speechFrom string -- NOT to the tNN row it is filed under. Re-labelling
the mapping without moving the evidence would leave a citation quoting the wrong episode.

This script therefore:
  1. takes the proven makemkvTitle -> dvdvideoTitle map from prove-dvd-mapping.py --json
  2. lifts each row's evidence bundle and re-homes it on the row whose PROVEN dvdvideoTitle
     equals the dvdvideo title the bundle was actually captured from
  3. records mappingProvenBy in the prover's own wording (machine-verifiable)

Usage: apply-proof.py "D:/video/_stage/<disc>" [--catalogue-dir D:/video/_catalogue] [--dry-run]
"""
import argparse
import contextlib
import json
import os
import re
import shutil
import subprocess
import sys
import uuid

import cat_lock          # beside this script; sys.path[0] is the script's own directory

PROVER = 'D:/video/.claude/skills/disc-to-plex/scripts/prove-dvd-mapping.py'
# speechSamplesExtra MUST travel with its bundle (added 2026-09-02): each entry is a transcript
# extracted through a specific dvdvideo title, and assert-accounted.ps1 searches the ROW's extras
# when verifying a speech: quote. While this key was left out, a re-home moved speechSample to the
# proven row but stranded the extras on the old one - leaving text from ANOTHER title searchable
# there, i.e. a quote could verify against the wrong episode. Rare while extras were hand-written;
# capture-evidence.py --speech now writes them routinely, so the hole would only widen.
EVIDENCE_KEYS = ('frames', 'headStrip', 'speechSample', 'speechStatus', 'speechFrom',
                 'speechSamplesExtra')


def evidence_source_title(row):
    """Which dvdvideo title was this row's evidence actually captured from?"""
    sf = row.get('speechFrom')
    if sf:
        m = re.search(r'dvdvideoTitle=(\d+)', sf)
        if m:
            return int(m.group(1))
    # No speechFrom (silent title): the frames were still grabbed through the dvdvideo title the
    # catalogue believed in at capture time, so that stale value is the provenance.
    return row.get('dvdvideoTitle')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('disc')
    ap.add_argument('--catalogue-dir', default='D:/video/_catalogue')
    ap.add_argument('--dry-run', action='store_true')
    args = ap.parse_args()

    disc_name = os.path.basename(args.disc.rstrip('/\\'))
    cat_path = os.path.join(args.catalogue_dir, disc_name + '.catalogue.json')
    if not os.path.exists(cat_path):
        sys.exit('no catalogue: ' + cat_path)

    # exit 2 = some titles unproven; that is a reportable state, not a failure to read.
    run = subprocess.run([sys.executable, PROVER, args.disc, '--json'],
                         capture_output=True, text=True)
    if not run.stdout.strip():
        sys.exit('prover produced nothing (exit %d):\n%s' % (run.returncode, run.stderr))
    proof = json.loads(run.stdout)

    proven = {m['makemkvTitle']: m for m in proof['mapping'] if m.get('dvdvideoTitle') is not None}

    # READ-MODIFY-WRITE UNDER THE PER-CATALOGUE LOCK (shared with capture-evidence.py). This
    # script rewrites the WHOLE catalogue from its own read; run while a capture-evidence
    # registration lands on the same disc, one of the two writes would silently erase the other -
    # the exact lost-update that cost Danger Man Disk 6 three transcripts (2026-09-02). The lock
    # is taken BEFORE the read and released after the write; it is held for milliseconds (the
    # prover already ran, above). A dry run never writes, so it does not take the lock.
    lock = contextlib.ExitStack()
    if not args.dry_run:
        lock.enter_context(cat_lock.locked(cat_path))

    with open(cat_path, encoding='utf-8') as fh:
        cat = json.load(fh)

    # Bank every evidence bundle against the dvdvideo title it was captured from.
    bank = {}
    for row in cat['titles']:
        src = evidence_source_title(row)
        if src is None:
            continue
        if any(row.get(k) for k in EVIDENCE_KEYS):
            bank[src] = {k: row.get(k) for k in EVIDENCE_KEYS}

    changed, moved, unproven, missing = [], [], [], []
    for row in cat['titles']:
        t = row['title']
        old_dvd = row.get('dvdvideoTitle')
        m = proven.get(t)
        if m is None:
            unproven.append(t)
            row['mappingProvenBy'] = None
            continue
        new_dvd = m['dvdvideoTitle']
        if old_dvd != new_dvd:
            changed.append((t, old_dvd, new_dvd))
        row['dvdvideoTitle'] = new_dvd
        row['mappingAmbiguous'] = False
        row['mappingProvenBy'] = m['provenBy']
        row['sizeBytes'] = m['sizeBytes']

        bundle = bank.get(new_dvd)
        if bundle is None:
            for k in EVIDENCE_KEYS:
                row[k] = [] if k == 'frames' else None
            row['evidenceNote'] = ('dvdvideo title %d was never probed by the catalogue - '
                                   'evidence must be captured fresh' % new_dvd)
            missing.append((t, new_dvd))
        else:
            src_of_old = evidence_source_title({'speechFrom': row.get('speechFrom'),
                                                'dvdvideoTitle': old_dvd})
            for k in EVIDENCE_KEYS:
                row[k] = bundle[k]
            if src_of_old != new_dvd:
                moved.append((t, src_of_old, new_dvd))
                row['evidenceNote'] = ('evidence re-homed: this bundle was captured from dvdvideo '
                                       'title %d, which is this row\'s PROVEN title' % new_dvd)

    print('=== %s ===' % disc_name)
    print('mapping corrections (t, catalogue-said, proven): %s' % (changed or 'none'))
    print('evidence bundles re-homed (t, from-dvd, to-dvd): %s' % (moved or 'none'))
    print('rows now needing FRESH evidence (t, dvd): %s' % (missing or 'none'))
    print('rows left UNPROVEN by byte size (need content corroboration): %s' % (unproven or 'none'))
    if proof.get('declaredButUnaccounted'):
        print('DECLARED BUT NOT ENUMERATED: %s' % proof['declaredButUnaccounted'])

    if args.dry_run:
        return
    bak = cat_path + '.pre-proof.bak'
    if not os.path.exists(bak):
        shutil.copy2(cat_path, bak)
    cat['titleNumbering'] = ('dvdvideoTitle PROVEN by prove-dvd-mapping.py from TT_SRPT + VTS byte '
                             'totals; duration was not consulted. Evidence permuted with the mapping.')
    # Atomic replace, never an in-place truncate-and-write: assert-accounted.ps1 and disposition
    # agents read this file while discs are in flight, and a torn JSON reads as a short catalogue.
    tmp_path = '%s.tmp-%d-%s' % (cat_path, os.getpid(), uuid.uuid4().hex[:8])
    with open(tmp_path, 'w', encoding='utf-8') as fh:
        json.dump(cat, fh, indent=2)
    os.replace(tmp_path, cat_path)
    lock.close()
    print('rewritten: %s  (backup %s)' % (cat_path, os.path.basename(bak)))


if __name__ == '__main__':
    main()
