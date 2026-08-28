#!/usr/bin/env python3
"""Prove the MakeMKV-title -> dvdvideo-title mapping for a DVD, WITHOUT using duration.

WHY THIS EXISTS
---------------
`catalogue-dvd.ps1` pairs MakeMKV titles to dvdvideo titles by DURATION, because that is the only
signal both enumerators publish. When episode runtimes cluster - and on a TV disc they always do -
duration cannot separate them. Its swap-check correctly marks such titles `mappingAmbiguous`, so
nothing ships silently wrong; but resolving the ambiguity then falls to a human or an agent, who
must rediscover the same fallback from first principles every time:

  Out D1          2026-08-26  MakeMKV 0:50:31 / 0:50:30 vs dvdvideo 3035 s / 3032 s. The greedy
                              pairing and its swap have IDENTICAL total error. Resolved by hand
                              from MakeMKV's per-title sizes (2.13 / 1.88 / 2.06 GiB).
  Jensen Code D1  2026-08-28  titles 4 and 5 run 1456.6 s and 1455.0 s - 1.6 s apart. The greedy
                              pairing landed WRONG. Because frames, head strips and speech are all
                              captured through `-f dvdvideo -title <n>`, every piece of captured
                              evidence for those two titles was crossed with the other's.

Twice in three days is a script, not a note. The disc already states the answer exactly:

  * VIDEO_TS.IFO's TT_SRPT table declares, for each dvdvideo title, which title set (VTS) holds it
    and which title WITHIN that set it is. That is the authoritative title -> VTS map.
  * MakeMKV's `TINFO:<id>,11` is the title's source byte size, which equals the total bytes of the
    VOBs of the VTS it came from - to the byte - whenever that VTS holds exactly one title.

So where a VTS holds exactly one title AND its VOB total matches exactly one MakeMKV title's size,
the pairing is PROVEN arithmetic, not an inference from two clocks that disagree.

WHAT IT DELIBERATELY WILL NOT DO
--------------------------------
It proves what it can and says so; it never guesses the rest. A VTS holding several titles (a
one-VTS disc split by chapters, the `chapterStart`/`chapterEnd` case) cannot be resolved by size,
because every title in it shares one VOB set. Those are reported UNPROVEN and left to duration and
corroboration from content. Reporting a guess here would be worse than reporting nothing: the whole
value of this script is that its answers need no second opinion.

USAGE
  python prove-dvd-mapping.py "D:/video/_stage/<disc>"
  python prove-dvd-mapping.py "D:/video/_stage/<disc>" --info-file makemkv-info.txt
  python prove-dvd-mapping.py "D:/video/_stage/<disc>" --json

Exit 0 = every MakeMKV title proven. Exit 2 = some unproven (details printed). Exit 1 = error.
"""

import argparse
import json
import os
import re
import struct
import subprocess
import sys


# --------------------------------------------------------------------------------------- IFO

def read_tt_srpt(video_ts_dir):
    """Return [{'title': 1-based dvdvideo title, 'vtsn': int, 'vts_ttn': int, 'nr_of_ptts': int}].

    Layout is the DVD-Video spec's VMGI: a 4-byte big-endian SECTOR pointer at 0xC4 locates
    TT_SRPT; its header is 2 bytes count, 2 reserved, 4 end-address; then 12 bytes per title with
    the title set number at byte 6 and the title-within-set at byte 7.
    """
    ifo = os.path.join(video_ts_dir, 'VIDEO_TS.IFO')
    if not os.path.isfile(ifo):
        raise SystemExit(f'no VIDEO_TS.IFO under {video_ts_dir}')
    with open(ifo, 'rb') as fh:
        data = fh.read()
    if data[:12] != b'DVDVIDEO-VMG':
        raise SystemExit(f'{ifo} is not a VMG (header was {data[:12]!r})')

    sector = struct.unpack('>I', data[0xC4:0xC8])[0]
    off = sector * 2048
    if off + 8 > len(data):
        raise SystemExit(f'TT_SRPT sector {sector} lies past the end of {ifo}')

    count = struct.unpack('>H', data[off:off + 2])[0]
    out = []
    for i in range(count):
        e = off + 8 + i * 12
        if e + 12 > len(data):
            break
        # byte 0 playback type, 1 angles, 2-3 nr_of_ptts, 4-5 parental, 6 vtsn, 7 vts_ttn
        nr_of_ptts = struct.unpack('>H', data[e + 2:e + 4])[0]
        out.append({'title': i + 1, 'vtsn': data[e + 6], 'vts_ttn': data[e + 7],
                    'nr_of_ptts': nr_of_ptts})
    return out


def vts_vob_bytes(video_ts_dir):
    """VTS number -> total bytes of its TITLE VOBs.

    VTS_nn_0.VOB is the title set's MENU and is NOT part of the title's source size; including it
    puts every total out by however large the menu is and matches nothing.
    """
    totals = {}
    for name in os.listdir(video_ts_dir):
        m = re.fullmatch(r'VTS_(\d\d)_(\d)\.VOB', name, re.IGNORECASE)
        if not m:
            continue
        vtsn, part = int(m.group(1)), int(m.group(2))
        if part == 0:
            continue
        totals[vtsn] = totals.get(vtsn, 0) + os.path.getsize(os.path.join(video_ts_dir, name))
    return totals


# ----------------------------------------------------------------------------------- MakeMKV

def parse_makemkv_info(text):
    """MakeMKV title id -> source byte size, from `TINFO:<id>,11,0,"<bytes>"`."""
    sizes = {}
    for m in re.finditer(r'^TINFO:(\d+),11,\d+,"([\d ,]+)"', text, re.MULTILINE):
        raw = m.group(2).replace(',', '').replace(' ', '')
        if raw.isdigit():
            sizes[int(m.group(1))] = int(raw)
    return sizes


def run_makemkv(disc_dir, minlength):
    """Enumerate the disc. MINLENGTH IS NOT COSMETIC - IT RENUMBERS THE TITLES.

    MakeMKV assigns title ids to the titles it decides to SHOW. Raise the floor, a short title
    disappears, and every id after it shifts down by one. This script's whole output is title ids,
    so a floor that differs from the catalogue's silently produces an off-by-one mapping that looks
    entirely self-consistent - which is the exact failure shape it was written to prevent.

    Caught on the first run against The Jensen Code D1: at MakeMKV's default 120 s floor the 24.9 s
    boilerplate title vanished and the prover reported t00->2, t01->3, ... - correct arithmetic,
    wrong labels, and it agreed with the hand-derived mapping only after shifting by one.
    `catalogue-dvd.ps1` enumerates at 10, so 10 is the default here and must stay matched to it.
    """
    exe = None
    cfg = 'D:/video/.transcode-tools/tool-paths.json'
    if os.path.isfile(cfg):
        try:
            with open(cfg, encoding='utf-8') as fh:
                exe = json.load(fh).get('makemkvcon')
        except Exception:
            exe = None
    for cand in [exe, r'C:\Program Files (x86)\MakeMKV\makemkvcon64.exe',
                 r'C:\Program Files\MakeMKV\makemkvcon64.exe']:
        if cand and os.path.isfile(cand):
            exe = cand
            break
    else:
        raise SystemExit('makemkvcon not found - pass --info-file with a saved `info` dump instead')

    # LIST ARGS, NEVER A SHELL STRING. A `file:D:\...` argument handed to a shell (Git Bash in
    # particular) gets rewritten, MakeMKV then sees no source, falls back to "can't find any usable
    # optical drives" and EXITS 0 having written nothing. subprocess with a list bypasses the shell.
    cmd = [exe, '-r', '--cache=1', f'--minlength={minlength}', 'info',
           'file:' + os.path.abspath(disc_dir)]
    p = subprocess.run(cmd, capture_output=True, text=True, errors='replace')
    if 'TINFO:' not in p.stdout:
        raise SystemExit('makemkvcon produced no TINFO records; stderr tail:\n' +
                         '\n'.join(p.stderr.splitlines()[-10:]))
    return p.stdout


# -------------------------------------------------------------------------------------- main

def prove(disc_dir, info_text):
    video_ts = disc_dir
    if os.path.isdir(os.path.join(disc_dir, 'VIDEO_TS')):
        video_ts = os.path.join(disc_dir, 'VIDEO_TS')

    srpt = read_tt_srpt(video_ts)
    vob = vts_vob_bytes(video_ts)
    sizes = parse_makemkv_info(info_text)

    # How many dvdvideo titles live in each VTS. Only a VTS with exactly ONE is separable by size.
    per_vts = {}
    for e in srpt:
        per_vts.setdefault(e['vtsn'], []).append(e)

    rows, unproven = [], []
    for mkv_id in sorted(sizes):
        want = sizes[mkv_id]
        hits = [v for v, total in vob.items() if total == want]
        row = {'makemkvTitle': mkv_id, 'sizeBytes': want, 'vts': None,
               'dvdvideoTitle': None, 'provenBy': None, 'note': None}

        if len(hits) == 1:
            v = hits[0]
            row['vts'] = v
            titles = per_vts.get(v, [])
            if len(titles) == 1:
                row['dvdvideoTitle'] = titles[0]['title']
                row['provenBy'] = (f"VTS_{v:02d} title VOBs total {want} bytes, matching MakeMKV "
                                   f"t{mkv_id:02d} exactly; TT_SRPT declares one title in that VTS "
                                   f"(VTSN={v}, VTS_TTN={titles[0]['vts_ttn']})")
            else:
                row['note'] = (f'VTS_{v:02d} holds {len(titles)} titles '
                               f'({", ".join(str(t["title"]) for t in titles)}) - they share one VOB '
                               f'set, so size cannot separate them')
                unproven.append(row)
        elif len(hits) > 1:
            row['note'] = f'byte total {want} matches {len(hits)} title sets ({sorted(hits)})'
            unproven.append(row)
        else:
            near = sorted(vob.items(), key=lambda kv: abs(kv[1] - want))[:1]
            hint = f'; nearest VTS_{near[0][0]:02d} off by {near[0][1] - want:+d}' if near else ''
            row['note'] = f'byte total {want} matches no title set exactly{hint}'
            unproven.append(row)
        rows.append(row)

    # WHICH DECLARED TITLES DID NOBODY CLAIM?
    #
    # Proving the mapping for the titles MakeMKV found says NOTHING about the titles it did not.
    # First run against DIE_MUMINS_3 printed "all titles proven" and exited 0 for a disc whose
    # TT_SRPT declares 27 titles and whose folder holds 10 - the known-truncated rip whose missing
    # title sets are its ENTIRE English branch. A report shaped only like success cannot describe
    # that, which is the same defect as an OCR gate crowded out by error records and a rip
    # "confirmed" from a grep of anticipated outcomes.
    #
    # So: account for every title the DISC declares, not merely every title MakeMKV offered, and
    # separate "the VTS is not on disk" (an incomplete copy - escalate) from "the VTS is here but
    # was not enumerated" (usually below the minlength floor - benign, but say so).
    claimed = {r['dvdvideoTitle'] for r in rows if r['dvdvideoTitle'] is not None}
    missing = []
    for e in srpt:
        if e['title'] in claimed:
            continue
        on_disk = e['vtsn'] in vob
        missing.append({'title': e['title'], 'vts': e['vtsn'], 'vtsOnDisk': on_disk,
                        'why': ('VTS present but not enumerated (below the minlength floor?)'
                                if on_disk else
                                'VTS HAS NO TITLE VOBs ON DISK - the copy is incomplete')})
    return rows, unproven, srpt, missing


def verify_claims(disc_dir, catalogue_path):
    """Check every `mappingProvenBy` that CITES THIS SCRIPT against the disc itself.

    WHY. `assert-accounted.ps1` honours `mappingProvenBy` when it is non-empty - and non-empty is
    the whole test. Every other citation class is verified mechanically (`speech:` must be exact
    recorded text, `mymovies:` must appear verbatim), so this is the one field where writing a
    plausible sentence defeats the check. Demonstrated 2026-08-28: a catalogue with KNOWN-CROSSED
    dvdvideoTitle values, with a proof string bolted on, passed the gate at exit 0.

    The field is deliberately free text, because a legitimate proof can be "I pulled frames from
    dvdvideo title 3 and read the card" - not machine-checkable, and it should stay allowed. But a
    claim in THIS script's own words is entirely checkable, and it is the form most likely to be
    copied or fabricated convincingly. So: claims naming a VTS and a byte total are re-derived from
    the disc; anything else is reported as an unverified human claim and left alone.

    Returns (verified, unverifiable, failures).
    """
    video_ts = disc_dir
    if os.path.isdir(os.path.join(disc_dir, 'VIDEO_TS')):
        video_ts = os.path.join(disc_dir, 'VIDEO_TS')
    srpt = {e['title']: e for e in read_tt_srpt(video_ts)}
    vob = vts_vob_bytes(video_ts)
    per_vts = {}
    for e in srpt.values():
        per_vts.setdefault(e['vtsn'], []).append(e['title'])

    with open(catalogue_path, encoding='utf-8') as fh:
        cat = json.load(fh)

    verified, unverifiable, failures = [], [], []
    for t in cat.get('titles', []):
        claim = (t.get('mappingProvenBy') or '').strip()
        if not claim:
            continue
        label = 't%02d' % t.get('title', -1)
        dv = t.get('dvdvideoTitle')
        m = re.search(r'VTS_(\d+)\s+title VOBs total\s+(\d+)\s+bytes', claim)
        if not m:
            unverifiable.append((label, claim))
            continue
        vtsn, stated = int(m.group(1)), int(m.group(2))
        actual = vob.get(vtsn)
        if actual is None:
            failures.append((label, f'claim names VTS_{vtsn:02d}, which has no title VOBs on disk'))
        elif actual != stated:
            failures.append((label, f'claim says VTS_{vtsn:02d} totals {stated:,} bytes; the disc '
                                    f'says {actual:,}'))
        elif dv not in srpt:
            failures.append((label, f'dvdvideoTitle {dv} is not declared in TT_SRPT'))
        elif srpt[dv]['vtsn'] != vtsn:
            failures.append((label, f'claim places dvdvideo {dv} in VTS_{vtsn:02d}, but TT_SRPT '
                                    f'puts it in VTS_{srpt[dv]["vtsn"]:02d}'))
        elif len(per_vts.get(vtsn, [])) != 1:
            failures.append((label, f'VTS_{vtsn:02d} holds {len(per_vts[vtsn])} titles, so a byte '
                                    f'total cannot single out dvdvideo {dv}'))
        else:
            verified.append((label, dv, vtsn))
    return verified, unverifiable, failures


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('disc')
    ap.add_argument('--verify-claims', metavar='CATALOGUE_JSON',
                    help="re-derive every mappingProvenBy that cites this script against the disc; "
                         "exit 3 if any claim does not check out")
    ap.add_argument('--info-file', help='saved `makemkvcon -r info` output, instead of running it')
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--minlength', type=int, default=10,
                    help='MakeMKV title floor in seconds. MUST match the catalogue (10); a '
                         'different floor renumbers the titles and shifts the whole mapping.')
    a = ap.parse_args()

    if not os.path.isdir(a.disc):
        raise SystemExit(f'not a directory: {a.disc}')

    if a.verify_claims:
        ok, unver, bad = verify_claims(a.disc, a.verify_claims)
        for label, dv, vtsn in ok:
            print(f'    {label}  VERIFIED  dvdvideo {dv} in VTS_{vtsn:02d} - byte total and '
                  f'TT_SRPT placement both re-derived from the disc')
        for label, claim in unver:
            print(f'    {label}  unverified human claim (not this script\'s wording): {claim[:90]}')
        for label, why in bad:
            print(f'    {label}  *** CLAIM DOES NOT CHECK OUT *** {why}')
        print(f'\n{len(ok)} verified, {len(unver)} unverifiable, {len(bad)} FAILED')
        if bad:
            print('A recorded proof that is not true is worse than no proof: the gate honours it.')
        return 3 if bad else 0

    if a.info_file:
        with open(a.info_file, encoding='utf-8', errors='replace') as fh:
            info_text = fh.read()
    else:
        info_text = run_makemkv(a.disc, a.minlength)

    rows, unproven, srpt, missing = prove(a.disc, info_text)

    if a.json:
        print(json.dumps({'disc': os.path.basename(os.path.normpath(a.disc)),
                          'ttSrpt': srpt, 'mapping': rows,
                          'declaredButUnaccounted': missing}, indent=2))
    else:
        print(f'{os.path.basename(os.path.normpath(a.disc))} - {len(srpt)} dvdvideo title(s) in TT_SRPT')
        # LABEL EVERY NUMBER IN THE ROW. Three bare right-aligned integers next to each other read
        # as a sequence, not as fields: "t08  9  6" was misread as "dvdvideo 6" when it means
        # dvdvideo 9, in VTS_06. This script exists to stop exactly one class of mistake - a title
        # attributed to the wrong number - so its own output must not be capable of causing it.
        for r in rows:
            dv = f'dvdvideo {r["dvdvideoTitle"]}' if r['dvdvideoTitle'] is not None else 'dvdvideo ?'
            vt = f'VTS_{r["vts"]:02d}' if r['vts'] is not None else 'VTS ?'
            print(f'    t{r["makemkvTitle"]:02d} -> {dv:<13} in {vt:<7} '
                  f'{r["sizeBytes"]:>14,} bytes  '
                  f'{r["provenBy"] or "UNPROVEN: " + (r["note"] or "")}')
        if unproven:
            print(f'\n{len(unproven)} title(s) UNPROVEN - these still rest on duration and need '
                  f'corroboration from content (menu, adjacency, on-screen card).')
        else:
            print(f'\nall {len(rows)} enumerated title(s) proven by byte size; duration was not '
                  f'consulted.')

        if missing:
            absent = [m for m in missing if not m['vtsOnDisk']]
            print(f'\n*** {len(missing)} of {len(srpt)} DECLARED title(s) were never enumerated ***')
            for m in missing:
                print(f'    dvdvideo {m["title"]:>3}  VTS_{m["vts"]:02d}  {m["why"]}')
            if absent:
                print(f'\n    {len(absent)} of these have NO title VOBs on disk. This is an '
                      f'INCOMPLETE COPY, not merely a')
                print('    disc with short titles - re-fetch it before dispositioning anything.')

    return 2 if (unproven or missing) else 0


if __name__ == '__main__':
    sys.exit(main())
