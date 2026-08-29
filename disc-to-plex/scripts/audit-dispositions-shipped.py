#!/usr/bin/env python3
"""Find titles that were DISPOSITIONED but never SHIPPED.

WHY THIS EXISTS
---------------
`assert-accounted.ps1` asks "does every catalogued title carry a written disposition?" and gates the
SOURCE RELEASE on the answer. Nothing asked the next question: did each of those dispositions
actually become a file? A disposition records what a title IS. It never records that it shipped.

The World's Fastest Indian (found 2026-08-29, batch 7) is the case that proves the gap. Its
dispositions file names three titles, all identified from content:

    t00|feature|The World's Fastest Indian (2005)
    t01|extra|Theatrical Trailer
    t02|extra|Making Of Documentary

Only the feature was ever encoded. Both extras sat in staging for weeks, the unit read as finished
because the feature was on the NAS, and the raw rip stayed held with nobody asking why. It surfaced
by ACCIDENT, while accounting for disk pressure - not from any check. That is the same failure as
Sherlock Holmes' ~20 missed featurettes: the job feels done once the feature is found.

WHAT IT COMPARES
----------------
Per disc: the number of dispositions that SHOULD produce an output (anything not `exclude`) against
the number of manifest items whose `src` points at that disc. Both sides are local, so this is cheap
and can sweep every batch at once.

A shortfall is a REPORT, not a verdict. Legitimate causes exist - several dispositions combining
into one output is the documented gallery case (see gallery-stills-ship-as-one), and a disc split
across manifests is normal. The point is to make the shortfall VISIBLE so it gets a reason, because
right now nothing prints it at all.

USAGE
  python audit-dispositions-shipped.py
  python audit-dispositions-shipped.py --disc "The World's Fastest Indian"
"""

import argparse
import glob
import json
import os
import re

CATALOGUE = 'D:/video/_catalogue'
MANIFEST_DIRS = ['D:/video/_queue/done', 'D:/video/_queue', 'D:/video/_queue/running',
                 'D:/video/_manifests']

# A disposition kind that is expected to yield a file. `exclude` deliberately does not; anything
# else - feature, episode, extra, and any kind added later - does. Listing what DOESN'T ship rather
# than what does means a new kind is reported by default instead of silently ignored.
NON_SHIPPING = {'exclude', 'excluded', 'skip'}


def read_dispositions(path):
    """[(tNN, kind, name)] from a dispositions file, comments and blanks dropped."""
    out = []
    with open(path, encoding='utf-8', errors='replace') as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = [p.strip() for p in line.split('|')]
            if len(parts) < 2 or not re.fullmatch(r't\d+', parts[0], re.I):
                continue
            out.append((parts[0], parts[1].lower(), parts[2] if len(parts) > 2 else ''))
    return out


def load_manifest_items():
    """Every manifest item across the queue and the manifest folder, deduped by (src, out)."""
    seen, items = set(), []
    for d in MANIFEST_DIRS:
        for p in glob.glob(os.path.join(d, '*.json')):
            try:
                with open(p, encoding='utf-8') as fh:
                    data = json.load(fh)
            except Exception:
                continue
            if isinstance(data, dict):
                data = [data]
            if not isinstance(data, list):
                continue
            for it in data:
                if not isinstance(it, dict) or 'src' not in it:
                    continue
                key = (str(it.get('src')), str(it.get('out')))
                if key in seen:
                    continue
                seen.add(key)
                items.append((str(it.get('src', '')).replace('\\', '/').lower(),
                              str(it.get('out', '')), os.path.basename(p)))
    return items


def disc_key(catalogue_path):
    """The folder name a manifest's `src` would contain for this disc.

    Prefer the catalogue's own discPath - the dispositions FILENAME is not always the staged folder
    name ("The World's Fastest Indian" vs "theworld'sfastestindian-rip"), and matching on the
    filename alone reports every such disc as shipping nothing, which is noise that would get the
    whole report ignored.
    """
    cat = catalogue_path.replace('.dispositions.txt', '.catalogue.json')
    if os.path.isfile(cat):
        try:
            with open(cat, encoding='utf-8') as fh:
                dp = json.load(fh).get('discPath')
            if dp:
                return os.path.basename(str(dp).replace('\\', '/').rstrip('/')).lower()
        except Exception:
            pass
    return os.path.basename(catalogue_path).replace('.dispositions.txt', '').lower()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--disc', help='only audit discs whose name contains this')
    a = ap.parse_args()

    items = load_manifest_items()
    rows, unlinkable, shortfalls = [], [], 0
    for dp in sorted(glob.glob(os.path.join(CATALOGUE, '*.dispositions.txt'))):
        name = os.path.basename(dp).replace('.dispositions.txt', '')
        if a.disc and a.disc.lower() not in name.lower():
            continue
        disps = read_dispositions(dp)
        if not disps:
            continue
        expected = [d for d in disps if d[1] not in NON_SHIPPING]
        key = disc_key(dp)
        shipped = [it for it in items if key and key in it[0]]
        # ZERO MATCHES IS NOT A SHORTFALL - IT IS AN UNKNOWN, AND THE TWO MUST NOT SHARE A LIST.
        #
        # A disc-direct unit's manifest `src` IS the staged folder, so it matches. A MakeMKV-rip
        # unit's `src` is a file inside a rip folder whose name is an abbreviation nobody records:
        # discPath `_stage/Back to the Future 1` against src `_stage/bttf1-rip/Back to the
        # Future_t11.mkv`. No catalogue carries a rip path (checked: 0 of 214), so for those units
        # the disposition->output link does not exist in the data and CANNOT be derived here.
        #
        # Reporting them as shortfalls put 32 discs in the alarm, nearly all of them false -
        # including Back to the Future 1, which shipped all 19. A guard that cries wolf is a guard
        # that gets ignored, which this project has already paid for once. So: only a PARTIAL match
        # is evidence of a gap. No match at all is reported separately, as an audit blind spot.
        if not shipped:
            unlinkable.append((name, len(expected), key))
        elif len(shipped) < len(expected):
            shortfalls += 1
            rows.append((name, len(expected), len(shipped), key,
                         [f'{t}|{k}|{n}' for t, k, n in expected]))

    if unlinkable:
        print('%d disc(s) COULD NOT BE AUDITED - no manifest item references the staged path.' %
              len(unlinkable))
        print('These are MakeMKV-rip units: the rip folder name is recorded nowhere, so the')
        print('disposition->output link is absent from the data. This is a BLIND SPOT, not a pass.')
        print('Fix upstream: record the rip folder in the catalogue when the rip is made.')
        print('')

    if not rows:
        print('no disc has a PARTIAL shortfall (some items shipped, others missing)')
        return 0

    print('%d disc(s) with FEWER manifest items than shipping dispositions\n' % shortfalls)
    for name, exp, got, key, detail in rows:
        print('  %-46s %d dispositioned -> %d manifest item(s)' % (name[:46], exp, got))
        print('       staged as: %s' % key)
        for d in detail:
            print('         %s' % d)
        print()
    print('A shortfall is a REPORT, not a verdict - several dispositions can legitimately combine')
    print('into one output (galleries), and a disc can be split across manifests. Give each a')
    print('reason; do not assume the count is the fault.')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
