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

  * Where a VTS holds SEVERAL titles, that total proves only group membership - so the same
    arithmetic is applied one level finer, from the VTS's own IFO. VTS_PTT_SRPT gives each VTS
    title its entry PGC, and that PGC's cell table gives every cell's first/last sector, i.e. an
    exact per-title byte size. It is used only where those titles' cells, UNIONED, cover the whole
    VTS - the union and not the sum, because a PLAY ALL replays its episodes' cells and a two-door
    VTS counts the same cells twice. See vts_covered_bytes().

WHAT IT DELIBERATELY WILL NOT DO
--------------------------------
It proves what it can and says so; it never guesses the rest. Where neither the VTS total nor the
per-title cell-sector total singles out one title - a VTS whose IFO will not parse, or one title
split across PGCs by chapters (the `chapterStart`/`chapterEnd` case) - the row is reported UNPROVEN
and left to duration and corroboration from content. Reporting a guess here would be worse than
reporting nothing: the whole value of this script is that its answers need no second opinion.

Both proof forms are re-derivable by --verify-claims, which is the point: a claim written in this
script's own words must be checkable against the disc, or it becomes the one field where a
plausible sentence defeats the gate.

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


# DVD-Video logical sector size. MUST be module level, because `vts_title_ranges()` reads it.
#
# It was a function local until the union refactor below deleted it along with the byte arithmetic
# that had been its only other use - leaving two live references and a NameError on every VTS. The
# bare `except Exception: continue` then swallowed it, so the function returned {} and the run came
# back "7 of 8 DECLARED title(s) were never enumerated": a report that reads like a half-copied
# disc, produced by a one-line typo. That is why the handler below is now narrow. It was caught in
# minutes only because the run happened to be a test against a disc with a KNOWN answer.
#
# (An earlier note here blamed this for the hand-mapping of the Farscape series-2 discs. It cannot
# have been: those runs predate this refactor and reached the sum-vs-union check that
# vts_covered_bytes documents, which is a different fault in the caller.)
SECTOR = 2048


# THE ONE-SECTOR SHORTFALL, MECHANICALLY EXPLAINED (Survivors Series 3 Disk 2, 2026-09-03).
#
# t01 and t04 each came back exactly 2048 bytes (one sector) short of their VTS's title-VOB total.
# Read the actual bytes: the LAST sector of VTS_01_2.VOB and of VTS_04_2.VOB is not audio/video
# payload. It opens with a pack header (00 00 01 BA) immediately followed by a private_stream_2 PES
# pair (00 00 01 BF, 00 00 01 BF) whose declared lengths are 0x3D4 and 0x3FA - 980 and 1018 bytes -
# which are exactly PCI and DSI, the two navigation records every VOBU carries, zero-padded to fill
# the sector. Every ordinary sector nearby opens with an audio (0xBD) or video (0xE0) PES packet;
# only this final sector is NAV-only, with nothing to demux.
#
# So the authoring software closed the title with a trailing navigation pack that has no VOBU
# payload after it. The IFO's cell table (C_PBI last_sector) and the physical VOB file both include
# that sector, because it is bytes that are really on the disc; MakeMKV's TINFO,11 - the demuxed
# title's SOURCE size - does not, because there is no source content in it. Both numbers are correct
# about different things. The shortfall is exactly one sector, never more, because there is only
# ever one such closing pack per title.
#
# TOLERANCE, NOT A FUDGE FACTOR. A MakeMKV total may be accepted up to this many sectors SHORT of a
# candidate's total - never the reverse, because MakeMKV cannot invent bytes the disc doesn't have.
# 1 sector is the number this mechanism can ever produce; a shortfall of 2+ sectors is NOT this
# artifact and must not be swallowed by widening this constant.
TRAILING_NAV_PACK_MAX_SECTORS = 1
TRAILING_NAV_PACK_MAX_BYTES = TRAILING_NAV_PACK_MAX_SECTORS * SECTOR

# THE SEPARATION-RATIO SAFEGUARD. A tolerance window alone is not proof - it just widens the target
# a wrong candidate could fall into. What actually makes Survivors S3D2's match safe is that the
# next-nearest OTHER candidate sits nowhere near it: 1,164x and 2,369x TRAILING_NAV_PACK_MAX_BYTES
# away for t04 and t01 respectively. 100x is comfortably below both of those real separations and
# comfortably above 1x, so a genuine near-collision (two titles a few sectors apart in size) FAILS
# this guard and is correctly left UNPROVEN rather than silently accepted. See match_by_size().
MIN_SEPARATION_RATIO = 100


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


def vts_title_ranges(video_ts_dir):
    """(vtsn, vts_ttn) -> [(first_sector, last_sector), ...], the cells of that title's entry PGC.

    WHY THIS EXISTS. The VTS VOB total below is exact only when the VTS holds ONE title; where it
    holds several, the total proves group membership and nothing more. But the disc states the
    finer answer too, in the same arithmetic style:

      * VTS_PTT_SRPT (sector pointer at 0xC8) gives each VTS title its entry PGC number.
      * VTS_PGCIT (0xCC) locates that PGC, whose cell playback table (C_PBKT, offset at PGC+0xE8)
        lists every cell's first and last sector. At 2048 bytes/sector that is an exact byte size.

    On The Saint D8, VTS_05 holds dvdvideo 5/6/7 and VTS_06 holds 8/9 - five titles the VTS-total
    method could only report UNPROVEN, and which it additionally listed as "declared but never
    enumerated" when they had in fact been enumerated perfectly well. Each per-title size matches
    one MakeMKV title exactly, so all nine titles prove one-to-one with duration never consulted.

    SECTORS, NOT BYTES, because titles within one VTS OVERLAP and a byte figure cannot say so.
    A PLAY ALL replays its constituent episodes' cells; a second "door" PGC entered from another
    menu button covers the same cells again. Only the ranges distinguish coverage from
    double-counting - see vts_covered_bytes(), which is what the caller must test against.

    Returns {} for any VTS whose IFO cannot be parsed - the caller then falls back to the VTS
    total, i.e. to the previous behaviour, rather than to a guess.
    """
    out = {}
    for name in sorted(os.listdir(video_ts_dir)):
        m = re.fullmatch(r'VTS_(\d\d)_0\.IFO', name, re.IGNORECASE)
        if not m:
            continue
        vtsn = int(m.group(1))
        try:
            b = open(os.path.join(video_ts_dir, name), 'rb').read()
            if b[:12] != b'DVDVIDEO-VTS':
                continue
            ptt_srpt = struct.unpack_from('>I', b, 0xC8)[0] * SECTOR
            pgcit = struct.unpack_from('>I', b, 0xCC)[0] * SECTOR
            nr_titles = struct.unpack_from('>H', b, ptt_srpt)[0]
            entry_pgc = []
            for i in range(nr_titles):
                off = struct.unpack_from('>I', b, ptt_srpt + 8 + 4 * i)[0]
                entry_pgc.append(struct.unpack_from('>H', b, ptt_srpt + off)[0])
            nr_pgc = struct.unpack_from('>H', b, pgcit)[0]
            pgc_cells = {}
            for i in range(nr_pgc):
                off = struct.unpack_from('>I', b, pgcit + 8 + 8 * i + 4)[0]
                p = pgcit + off
                nr_cells = b[p + 3]
                cpbkt = struct.unpack_from('>H', b, p + 0xE8)[0]
                cells = []
                for c in range(nr_cells):
                    cp = p + cpbkt + 24 * c
                    first = struct.unpack_from('>I', b, cp + 8)[0]
                    last = struct.unpack_from('>I', b, cp + 20)[0]
                    if last < first:
                        raise ValueError('cell %d of PGC %d has last < first sector' % (c, i + 1))
                    cells.append((first, last))
                pgc_cells[i + 1] = cells
            for ttn, pgcn in enumerate(entry_pgc, start=1):
                if pgcn in pgc_cells:
                    out[(vtsn, ttn)] = pgc_cells[pgcn]
        except (struct.error, ValueError, IndexError, OSError) as exc:
            # A VTS we cannot parse simply contributes nothing; never a guess. Two rules, both
            # learned from the NameError described at SECTOR:
            #
            # NARROW, so a fault in THIS CODE is never disguised as a fault in the disc. NameError,
            # AttributeError and TypeError are always our bug and must crash loudly; only the
            # errors a malformed IFO can actually raise are caught here.
            #
            # And SAY SO on stderr even then: a silent skip is indistinguishable from "this disc is
            # genuinely unprovable", which is how one typo produced a full page of UNPROVEN rows
            # and a "never enumerated" warning about a disc that was perfectly intact.
            print('WARNING: %s could not be parsed for per-title cell ranges (%s: %s) - '
                  'falling back to VTS totals for that title set'
                  % (name, type(exc).__name__, exc), file=sys.stderr)
            continue
    return out


def vts_title_bytes(video_ts_dir):
    """(vtsn, vts_ttn) -> exact bytes of that ONE title. See vts_title_ranges()."""
    return {k: sum((last - first + 1) * 2048 for first, last in cells)
            for k, cells in vts_title_ranges(video_ts_dir).items()}


def vts_covered_bytes(ranges):
    """vtsn -> bytes covered by the UNION of that VTS's declared titles' cells.

    THE SUM WAS THE WRONG MEASURE, and it made a whole common disc shape unprovable. The caller
    only trusts per-title sizes where the VTS is fully accounted for; that test was written as
    "the per-title sizes sum to the VTS total with no remainder", which holds only when no two
    titles share a cell. Both Farscape series-2 shapes break it - a PLAY ALL replays its episodes'
    cells, and a two-door VTS counts the same cells under both doors - so the sum overshoots, every
    row went UNPROVEN, and the script additionally warned "8 of 9 declared titles never
    enumerated", which reads exactly like a half-copied disc. Nothing was wrong with the disc or
    the rip. Six discs were mapped by hand as a result.

    The union is the measure that was meant: it asks whether the declared titles COVER the VTS,
    which is the real question, and is unchanged on the one-title-per-VTS discs where the sum
    happened to be right.
    """
    per_vts = {}
    for (vtsn, _), cells in ranges.items():
        per_vts.setdefault(vtsn, []).extend(cells)
    out = {}
    for vtsn, cells in per_vts.items():
        total, covered_to = 0, -1
        for first, last in sorted(cells):
            if last <= covered_to:
                continue                      # wholly inside a range already counted
            total += (last - max(first, covered_to + 1) + 1) * 2048
            covered_to = last
        out[vtsn] = total
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


# ------------------------------------------------------------------------------------ matching

def match_by_size(want, candidates):
    """Match MakeMKV's `want` bytes against `candidates` (key -> byte total), exactly or within
    the documented one-sector trailing-NAV-pack tolerance (see TRAILING_NAV_PACK_MAX_BYTES).

    Returns (hits, tolerance_bytes, ambiguous):
      hits             matching key(s) - length 0 (no match), 1 (a proof), or >1 (real ambiguity,
                        handled by the caller exactly like today's exact-match ambiguity)
      tolerance_bytes   0 for an exact match; otherwise the bytes short (a positive multiple of
                        SECTOR - currently always exactly SECTOR, since MAX_SECTORS is 1)
      ambiguous         True only when >1 keys were found WITHIN TOLERANCE (as opposed to exactly) -
                        lets the caller word the ambiguity note correctly

    An exact match always wins outright - a disc that already proved cleanly takes an identical path
    through this function today, so there is no regression risk for it.

    A tolerant match is returned ONLY when exactly one candidate falls in the window AND the
    next-nearest OTHER candidate clears MIN_SEPARATION_RATIO. Failing that guard returns ([], 0,
    False) - i.e. behaves as "no match", so the caller's existing UNPROVEN fallbacks apply. A
    tolerance nobody can fail is a fudge factor; this one can, and does, on the truncation test
    below.
    """
    exact = [k for k, total in candidates.items() if total == want]
    if exact:
        return exact, 0, False

    within = sorted(
        ((k, total - want) for k, total in candidates.items()
         if 0 < total - want <= TRAILING_NAV_PACK_MAX_BYTES and (total - want) % SECTOR == 0),
        key=lambda kv: kv[1])
    if not within:
        return [], 0, False
    if len(within) > 1:
        return [k for k, _ in within], 0, True

    key, delta = within[0]
    others = [abs(total - want) for k, total in candidates.items() if k != key]
    nearest_other = min(others) if others else None
    if nearest_other is None or nearest_other < MIN_SEPARATION_RATIO * TRAILING_NAV_PACK_MAX_BYTES:
        # Either nothing else to compare against, or the next-nearest candidate is not far enough
        # away to trust the window - stay unmatched rather than guess.
        return [], 0, False
    return [key], delta, False


def sizes_matching(target, sizes_values):
    """Which MakeMKV-reported sizes are consistent with `target` (an expected VTS or per-title
    byte total), exactly or within the trailing-NAV-pack shortfall?

    DIAGNOSTIC ONLY. This says "MakeMKV plainly saw something this size", not "this proves the
    mapping" - it has none of match_by_size's separation-ratio guard, because it is not used to
    accept a proof. It is used only to stop the 'declared but not enumerated' report from calling a
    title 'never enumerated' when MakeMKV's own output plainly contains its size.
    """
    return [s for s in sizes_values
            if 0 <= target - s <= TRAILING_NAV_PACK_MAX_BYTES and (target - s) % SECTOR == 0]


# -------------------------------------------------------------------------------------- main

def prove(disc_dir, info_text):
    video_ts = disc_dir
    if os.path.isdir(os.path.join(disc_dir, 'VIDEO_TS')):
        video_ts = os.path.join(disc_dir, 'VIDEO_TS')

    srpt = read_tt_srpt(video_ts)
    vob = vts_vob_bytes(video_ts)
    title_ranges = vts_title_ranges(video_ts)
    title_bytes = {k: sum((b - a + 1) * 2048 for a, b in v) for k, v in title_ranges.items()}
    covered = vts_covered_bytes(title_ranges)
    sizes = parse_makemkv_info(info_text)

    # How many dvdvideo titles live in each VTS. Only a VTS with exactly ONE is separable by size.
    per_vts = {}
    for e in srpt:
        per_vts.setdefault(e['vtsn'], []).append(e)

    rows, unproven = [], []
    for mkv_id in sorted(sizes):
        want = sizes[mkv_id]
        hits, tol_bytes, hits_ambiguous = match_by_size(want, vob)
        row = {'makemkvTitle': mkv_id, 'sizeBytes': want, 'vts': None,
               'dvdvideoTitle': None, 'provenBy': None, 'note': None, 'toleranceBytes': 0}

        # A TOLERANCE-ACCEPTED PROOF USES THE DISC'S TRUE TOTAL IN ITS PROSE, NOT MAKEMKV'S SHORT
        # ONE. `verify_claims()` re-derives the number that follows "title VOBs total" against the
        # disc's own vob total - so the claim must state that true figure, or a perfectly good proof
        # would fail its own re-derivation. The tolerance-accepted tag says how it was reached; the
        # cited number says what is actually true of the disc.
        tol_tag = ('' if not tol_bytes else
                   f' [TOLERANCE-ACCEPTED: MakeMKV reports {want} bytes, {tol_bytes} short '
                   f'({tol_bytes // SECTOR} sector) - see TRAILING_NAV_PACK_MAX_BYTES]')

        if len(hits) == 1:
            v = hits[0]
            row['vts'] = v
            row['toleranceBytes'] = tol_bytes
            titles = per_vts.get(v, [])
            if len(titles) == 1:
                row['dvdvideoTitle'] = titles[0]['title']
                row['provenBy'] = (f"VTS_{v:02d} title VOBs total {vob[v]} bytes, matching MakeMKV "
                                   f"t{mkv_id:02d}{tol_tag}; TT_SRPT declares one title in that "
                                   f"VTS (VTSN={v}, VTS_TTN={titles[0]['vts_ttn']})")
            else:
                # THE VTS TOTAL MATCHED, AND SEVERAL TITLES ARE DECLARED IN IT. Before giving up,
                # ask whether those titles cover IDENTICAL cells. If they do, this is the two-door
                # shape and the question "which door did MakeMKV enumerate?" has no consequences -
                # both address the same sectors, so the rip is the same bytes either way. Reporting
                # that as a flat UNPROVEN sent an author away to measure a distinction that does
                # not exist; reporting the containment is the answer they actually needed.
                same = [t for t in titles
                        if title_ranges.get((v, t['vts_ttn'])) ==
                        title_ranges.get((v, titles[0]['vts_ttn']))]
                if len(same) == len(titles) and title_ranges.get((v, titles[0]['vts_ttn'])):
                    row['dvdvideoTitle'] = titles[0]['title']
                    row['provenBy'] = (
                        f"VTS_{v:02d} title VOBs total {vob[v]} bytes, matching MakeMKV "
                        f"t{mkv_id:02d}{tol_tag}; TT_SRPT declares {len(titles)} titles in that "
                        f"VTS ({', '.join(str(t['title']) for t in titles)}) but their PGCs cover "
                        f"IDENTICAL cell sectors - one item behind two doors, so every one of them "
                        f"is the same material and title {titles[0]['title']} is its lowest entry")
                else:
                    row['note'] = (f'VTS_{v:02d} holds {len(titles)} titles '
                                   f'({", ".join(str(t["title"]) for t in titles)}) over DIFFERENT '
                                   f'cells - they share one VOB set, so size cannot separate them')
                    unproven.append(row)
        elif len(hits) == 0 and title_bytes:
            # NO VTS TOTAL MATCHES - which is the SHAPE a title inside a multi-title VTS takes:
            # its own size is a fraction of the set it lives in. Go one level finer and match
            # against the per-title cell-sector totals, but only where that VTS's per-title sizes
            # ACCOUNT FOR THE WHOLE VTS with no remainder - otherwise the IFO reading is not
            # trustworthy enough to prove anything with, and it stays unproven. Tolerant the same
            # way as the VTS-level match above, and for the same reason: the trailing NAV-pack
            # shortfall applies just as well to a title that happens to be the last one physically
            # laid out in its VTS.
            candidates = {k: nb for k, nb in title_bytes.items()
                         if covered.get(k[0]) == vob.get(k[0])}
            cand, cand_tol, cand_ambig = match_by_size(want, candidates)
            cand_tag = ('' if not cand_tol else
                       f' [TOLERANCE-ACCEPTED: MakeMKV reports {want} bytes, {cand_tol} short '
                       f'({cand_tol // SECTOR} sector) - see TRAILING_NAV_PACK_MAX_BYTES]')
            if len(cand) == 1:
                vtsn, ttn = cand[0]
                nb = title_bytes[(vtsn, ttn)]
                match = [t for t in per_vts.get(vtsn, []) if t['vts_ttn'] == ttn]
                if len(match) == 1:
                    row['vts'] = vtsn
                    row['toleranceBytes'] = cand_tol
                    row['dvdvideoTitle'] = match[0]['title']
                    row['provenBy'] = (
                        f"VTS_{vtsn:02d} title {ttn} totals {nb} bytes across its PGC's cell "
                        f"sectors, matching MakeMKV t{mkv_id:02d}{cand_tag}; that VTS holds "
                        f"{len(per_vts[vtsn])} title(s) whose cells, unioned, cover the VTS total "
                        f"exactly (VTSN={vtsn}, VTS_TTN={ttn})")
                else:
                    row['note'] = (f'per-title size matches VTS_{vtsn:02d} title {ttn}, but TT_SRPT '
                                   f'does not declare exactly one title at that position')
                    unproven.append(row)
            elif len(cand) > 1:
                # THE TWO-DOOR SIGNATURE. Two PGCs entered from different menu buttons over the
                # SAME cells are the same bytes, so size cannot separate them and must not pretend
                # to. Say which doors they are - that is the useful answer, and it is what tells
                # the reader this is one item with two entries rather than a mapping failure.
                #
                # RESOLVE IT when the candidates are doors onto ONE item: same VTS, and identical
                # cell ranges. Then "which door" has no consequences - every one addresses the same
                # sectors - and the lowest entry is the answer, exactly as the whole-VTS door case
                # above already concludes. Leaving it UNPROVEN sent the author away to settle a
                # distinction that does not exist, and the honest per-title claim they then had to
                # write by hand is the one generated here.
                #
                # NOT resolved when the candidates span different VTSs or carry different cells:
                # equal sizes across genuinely different material is real ambiguity, and collapsing
                # it would be the fabrication this script exists to prevent. (Farscape S3 D3:
                # VTS_01 declares six titles, of which 2 and 5 play identical cells.)
                same_vts = {c[0] for c in cand}
                cells0 = title_ranges.get(cand[0])
                doors = (len(same_vts) == 1 and cells0 and
                         all(title_ranges.get(c) == cells0 for c in cand))
                if doors:
                    vtsn = cand[0][0]
                    ttns = sorted(c[1] for c in cand)
                    entries = sorted(t['title'] for t in per_vts.get(vtsn, [])
                                     if t['vts_ttn'] in ttns)
                    ttn = next(t['vts_ttn'] for t in per_vts[vtsn] if t['title'] == entries[0])
                    nb = title_bytes[cand[0]]   # identical for every door - `doors` proved that
                    row['vts'] = vtsn
                    row['toleranceBytes'] = cand_tol
                    row['dvdvideoTitle'] = entries[0]
                    row['provenBy'] = (
                        f"VTS_{vtsn:02d} title {ttn} totals {nb} bytes across its PGC's cell "
                        f"sectors, matching MakeMKV t{mkv_id:02d}{cand_tag}; that VTS holds "
                        f"{len(per_vts[vtsn])} title(s) whose cells, unioned, cover the VTS total "
                        f"exactly (VTSN={vtsn}, VTS_TTN={ttn}). NOTE this size is shared by "
                        f"dvdvideo {', '.join(str(e) for e in entries)}, whose PGCs play IDENTICAL "
                        f"cell sectors - one item behind several doors, so the size does not single "
                        f"one out and does not need to: every door is the same material, and "
                        f"{entries[0]} is its lowest entry")
                else:
                    # THIS IS THE PATH THAT JUST FAILED THE `doors` TEST, so it must NOT reuse the
                    # doors wording. It did, and said the candidates played "identical cells" and
                    # "are the same material" - the exact opposite of what had been established.
                    # On Babylon 5 Season 5 Disk 2 it printed that for two previews whose cells are
                    # DISJOINT (sectors 9363-18739 vs 18740-28116). A reader who believed it would
                    # have shipped THREE previews instead of four.
                    #
                    # A tool that fails is recoverable; a tool that asserts the opposite of its own
                    # evidence, in confident language, on the one question it exists to answer, is
                    # not. Say which of the two genuine reasons applies and leave it unproven.
                    why = ('they lie in different VTSs' if len({c[0] for c in cand}) > 1
                           else 'their PGCs play DIFFERENT cell sectors')
                    basis = 'within the trailing-NAV-pack tolerance' if cand_ambig else 'exactly'
                    listed = ', '.join('VTS_%02d title %d' % c for c in sorted(cand))
                    row['note'] = (f'byte total {want} matches {len(cand)} declared titles {basis} '
                                   f'({listed}) and {why}, so this is REAL ambiguity between '
                                   f'different material - not the two-door shape. Size cannot '
                                   f'separate them; settle it from content or from proven neighbours '
                                   f'in TT_SRPT order')
                    unproven.append(row)
            else:
                near = sorted(vob.items(), key=lambda kv: abs(kv[1] - want))[:1]
                hint = (f'; nearest VTS_{near[0][0]:02d} off by {near[0][1] - want:+d}'
                        if near else '')
                row['note'] = (f'byte total {want} matches no title set exactly{hint}, and no '
                               f'single per-title cell-sector total either')
                unproven.append(row)
        elif len(hits) > 1:
            basis = 'within the trailing-NAV-pack tolerance' if hits_ambiguous else 'exactly'
            row['note'] = (f'byte total {want} matches {len(hits)} title sets {basis} '
                           f'({sorted(hits)})')
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
    #
    # A THIRD CLASS, and on a TV disc the commonest: a declared title whose cells are ALREADY
    # COVERED by a title that was claimed. That is a second door - another menu button entering the
    # same material - not absent content, and it is not a missing episode however much the wording
    # "never enumerated" suggests one. Farscape S2 D1 declares 8 titles and enumerates 6; every one
    # of the shortfall is a door onto bytes already accounted for, and the disc is intact. Saying
    # so is the whole point: a warning that cannot tell a duplicate entry from a truncated rip
    # trains the reader to ignore it, and DIE_MUMINS_3 is why the warning must survive to be read.
    claimed = {r['dvdvideoTitle'] for r in rows if r['dvdvideoTitle'] is not None}
    claimed_cells = {}
    for e in srpt:
        if e['title'] in claimed:
            claimed_cells.setdefault(e['vtsn'], []).extend(
                title_ranges.get((e['vtsn'], e['vts_ttn']), []))
    missing = []
    for e in srpt:
        if e['title'] in claimed:
            continue
        on_disk = e['vtsn'] in vob
        own = title_ranges.get((e['vtsn'], e['vts_ttn']))
        covered_elsewhere = bool(own) and all(
            any(a <= first and last <= b for a, b in claimed_cells.get(e['vtsn'], []))
            for first, last in own)
        # THE EXPECTED SIZE OF THIS DECLARED TITLE, so it can be checked against what MakeMKV
        # actually reported - own per-title cells where the IFO parses, else the whole VTS total.
        nb = sum((last - first + 1) * SECTOR for first, last in own) if own else vob.get(e['vtsn'])
        seen = sizes_matching(nb, sizes.values()) if nb is not None else []
        if covered_elsewhere:
            why = ('its cells are wholly covered by an enumerated title - a second door onto the '
                   'same material, not missing content')
            present_unprovable = False
        elif seen:
            # MAKEMKV PLAINLY SAW THIS TITLE. Some enumerated title's byte size matches this
            # declared title's own expected size - exactly, or within the same one-sector
            # trailing-NAV-pack window match_by_size() uses to PROVE a mapping (this check carries
            # none of that function's separation-ratio guard, because it isn't proving one - only
            # reporting that MakeMKV's output is not empty here). Calling this "not enumerated ...
            # below the minlength floor?" would be false and exactly the alarm this fix exists to
            # remove: the title is plainly above the floor and plainly present in MakeMKV's own
            # numbers. What is actually missing is a PROVEN mapping, not the content - see the
            # UNPROVEN row(s) in `rows` above for why the byte-matching stopped short of proof.
            why = (f'VTS present AND ENUMERATED (expected {nb:,} bytes; MakeMKV reported '
                   f'{", ".join(f"{s:,}" for s in seen)}) but the byte-proof could not map it to '
                   f'this specific dvdvideo title - see the UNPROVEN row(s) above. This is a '
                   f'mapping gap, not missing content')
            present_unprovable = True
        elif on_disk:
            # STATE ITS SIZE. "Not enumerated" alone cannot be acted on - the reader must know
            # whether they are looking at a missing 44-minute episode or a stub. Farscape S2 D1's
            # dvdvideo 1 is five sectors, 10,240 bytes, and no amount of investigation was going to
            # make it interesting; without the number it looked exactly like the other case.
            why = ('VTS present but not enumerated (%s - below the minlength floor?)'
                   % (f'{nb:,} bytes' if own else 'size unknown, IFO unparsed'))
            present_unprovable = False
        else:
            why = 'VTS HAS NO TITLE VOBs ON DISK - the copy is incomplete'
            present_unprovable = False
        missing.append({'title': e['title'], 'vts': e['vtsn'], 'vtsOnDisk': on_disk,
                        'secondDoor': covered_elsewhere, 'presentButUnprovable': present_unprovable,
                        'why': why})
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
    title_ranges = vts_title_ranges(video_ts)
    title_bytes = {k: sum((b - a + 1) * 2048 for a, b in v) for k, v in title_ranges.items()}
    covered = vts_covered_bytes(title_ranges)
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
        # A per-title claim (multi-title VTS) is re-derived against the IFO's own cell-sector
        # totals; the VTS-total claim below is re-derived against the VOB sizes. Both are this
        # script's own wording, so both must be checkable - a proof form that verify-claims could
        # only shrug at would be exactly the fabrication-shaped gap this function exists to close.
        mt = re.search(r'VTS_(\d+)\s+title\s+(\d+)\s+totals\s+(\d+)\s+bytes across', claim)
        if mt:
            vtsn, ttn, stated = int(mt.group(1)), int(mt.group(2)), int(mt.group(3))
            actual = title_bytes.get((vtsn, ttn))
            vts_cov = covered.get(vtsn)
            if actual is None:
                failures.append((label, f'claim names VTS_{vtsn:02d} title {ttn}, which the IFO '
                                        f'does not describe'))
            elif actual != stated:
                failures.append((label, f'claim says VTS_{vtsn:02d} title {ttn} is {stated:,} '
                                        f'bytes; the disc says {actual:,}'))
            elif vts_cov != vob.get(vtsn):
                failures.append((label, f"VTS_{vtsn:02d}'s declared titles cover {vts_cov:,} bytes "
                                        f'but its title VOBs total {vob.get(vtsn):,} - '
                                        f'unaccounted bytes'))
            elif dv not in srpt:
                failures.append((label, f'dvdvideoTitle {dv} is not declared in TT_SRPT'))
            elif srpt[dv]['vtsn'] != vtsn or srpt[dv]['vts_ttn'] != ttn:
                failures.append((label, f'claim places dvdvideo {dv} at VTS_{vtsn:02d} title {ttn}, '
                                        f'but TT_SRPT puts it at VTS_{srpt[dv]["vtsn"]:02d} title '
                                        f'{srpt[dv]["vts_ttn"]}'))
            else:
                verified.append((label, dv, vtsn, claim))
            continue

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
            # SEVERAL TITLES IN THIS VTS. A byte total cannot single one out - UNLESS they are all
            # doors onto identical cells, which is the shape prove() resolves above and describes
            # as "their PGCs cover IDENTICAL cell sectors". That claim was being routed here and
            # then refused by the uniqueness test below it, so the ONE branch that exists to handle
            # multi-door discs emitted a proof this verifier could never accept: every such disc
            # failed assert-accounted.ps1 with "a byte total cannot single out dvdvideo N", and the
            # author's only ways out were to hand-write a different claim or to stop citing the
            # proof at all. (Farscape S3 D2, 2026-08-29: three episodes, doors 2/3/4, 5/6 and
            # 7/8/9.) A guard whose own tooling cannot satisfy it trains people to route around it.
            #
            # So re-derive the door claim properly, from the disc: every declared title in the VTS
            # must play the SAME cell ranges, those cells must account for the VTS's title VOBs, and
            # the claimed title must be the lowest declared entry - which is the one prove() picks.
            # This asserts strictly less than the single-title form: not "the size identifies this
            # door", but "the doors are interchangeable, so the choice cannot change the content".
            # per_vts here maps vtsn -> list of dvdvideo title NUMBERS (not the TT_SRPT dicts that
            # prove() works with), so go through srpt to reach each one's vts_ttn.
            titles_here = per_vts[vtsn]
            ranges_here = [title_ranges.get((vtsn, srpt[t]['vts_ttn'])) for t in titles_here]
            first = ranges_here[0]
            if 'IDENTICAL cell sectors' not in claim:
                failures.append((label, f'VTS_{vtsn:02d} holds {len(titles_here)} titles, so a byte '
                                        f'total cannot single out dvdvideo {dv}'))
            elif not first or any(r != first for r in ranges_here):
                failures.append((label, f'claim says VTS_{vtsn:02d}\'s titles cover IDENTICAL cell '
                                        f'sectors, but the IFO gives them DIFFERENT ranges'))
            elif covered.get(vtsn) != vob.get(vtsn):
                failures.append((label, f"VTS_{vtsn:02d}'s declared titles cover "
                                        f'{covered.get(vtsn):,} bytes but its title VOBs total '
                                        f'{vob.get(vtsn):,} - unaccounted bytes'))
            elif dv != min(titles_here):
                failures.append((label, f'claim takes dvdvideo {dv} as the lowest entry of '
                                        f'VTS_{vtsn:02d}, but that is dvdvideo '
                                        f'{min(titles_here)}'))
            else:
                verified.append((label, dv, vtsn, claim))
        else:
            verified.append((label, dv, vtsn, claim))
    # WHICH TITLES DOES THE DISC DECLARE THAT THE CATALOGUE NEVER MENTIONS?
    #
    # `assert-accounted.ps1` checks that every CATALOGUED title has a disposition. If MakeMKV never
    # enumerated a title there is no row, so "every title accounted for" is vacuously true and the
    # gate passes a disc with content nobody looked at.
    #
    # The Zoo Gang D2, 2026-08-29: MakeMKV reported dvdvideo 5 as "9 seconds" and skipped it, so it
    # had NO CATALOGUE ROW AT ALL. It is really 12:41 - a whole extra. Both readers stop at the end
    # of chapter 1, so neither duration nor their agreement could reveal it.
    #
    # TT_SRPT is the disc's own declaration and owes nothing to either reader, so compare against
    # that. This needs no MakeMKV run - the catalogue already records each row's dvdvideoTitle.
    claimed_dv = {t.get('dvdvideoTitle') for t in cat.get('titles', [])
                  if t.get('dvdvideoTitle') is not None}
    uncatalogued = []
    for e in sorted(srpt.values(), key=lambda x: x['title']):
        if e['title'] in claimed_dv:
            continue
        on_disk = e['vtsn'] in vob
        uncatalogued.append({
            'title': e['title'], 'vts': e['vtsn'], 'vtsOnDisk': on_disk,
            'chapters': e.get('nr_of_ptts'),
            'why': ('VTS present - a title the catalogue never lists (MakeMKV may have skipped it)'
                    if on_disk else 'VTS has no title VOBs on disk')})
    return verified, unverifiable, failures, uncatalogued


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
        ok, unver, bad, uncat = verify_claims(a.disc, a.verify_claims)
        for label, dv, vtsn, claim in ok:
            tag = ' [TOLERANCE-ACCEPTED PROOF]' if 'TOLERANCE-ACCEPTED' in claim else ''
            print(f'    {label}  VERIFIED{tag}  dvdvideo {dv} in VTS_{vtsn:02d} - byte total and '
                  f'TT_SRPT placement both re-derived from the disc')
        for label, claim in unver:
            print(f'    {label}  unverified human claim (not this script\'s wording): {claim[:90]}')
        for label, why in bad:
            print(f'    {label}  *** CLAIM DOES NOT CHECK OUT *** {why}')
        print(f'\n{len(ok)} verified, {len(unver)} unverifiable, {len(bad)} FAILED')
        if bad:
            print('A recorded proof that is not true is worse than no proof: the gate honours it.')

        # Report titles the DISC declares that the CATALOGUE never lists. Not a failure - a disc can
        # legitimately declare navigation stubs - but it must be SEEN, because the accounting gate
        # cannot: no row means no missing disposition. The Zoo Gang D2's 12:41 extra was invisible
        # exactly this way.
        if uncat:
            present = [u for u in uncat if u['vtsOnDisk']]
            print(f'\n*** {len(uncat)} title(s) DECLARED BY THE DISC BUT NOT IN THE CATALOGUE ***')
            for u in uncat:
                ch = f", {u['chapters']} chapter(s)" if u.get('chapters') else ''
                print(f'    dvdvideo {u["title"]:>3}  VTS_{u["vts"]:02d}{ch}  {u["why"]}')
            if present:
                print(f'\n    {len(present)} of these sit in a VTS that IS on disk. The accounting')
                print('    gate cannot flag them - a title with no catalogue row has no missing')
                print('    disposition. Decode each and account for it, or record why it is empty.')
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
            # A TOLERANCE-ACCEPTED PROOF MUST BE VISIBLY DIFFERENT FROM AN EXACT ONE even in this
            # compact line, not only in the prose - a reader scanning the column of rows must be
            # able to tell without reading every provenBy sentence.
            tag = f'[TOLERANCE -{r["toleranceBytes"]}B] ' if r.get('toleranceBytes') else ''
            print(f'    t{r["makemkvTitle"]:02d} -> {dv:<13} in {vt:<7} '
                  f'{r["sizeBytes"]:>14,} bytes  '
                  f'{tag}{r["provenBy"] or "UNPROVEN: " + (r["note"] or "")}')
        if unproven:
            print(f'\n{len(unproven)} title(s) UNPROVEN - these still rest on duration and need '
                  f'corroboration from content (menu, adjacency, on-screen card).')
        else:
            tol_n = sum(1 for r in rows if r.get('toleranceBytes'))
            extra = (f' ({tol_n} within the documented 1-sector trailing-NAV-pack tolerance, '
                    f'flagged [TOLERANCE] above)' if tol_n else '')
            print(f'\nall {len(rows)} enumerated title(s) proven by byte size{extra}; duration was '
                  f'not consulted.')

        if missing:
            absent = [m for m in missing if not m['vtsOnDisk']]
            doors = [m for m in missing if m.get('secondDoor')]
            unprovable = [m for m in missing if m.get('presentButUnprovable')]
            # HEADLINE THE NUMBER THAT MATTERS. Counting second doors - or a title MakeMKV plainly
            # enumerated but couldn't be mapped by byte size - in the alarm is what made this line
            # read like a half-copied disc on a disc that was complete (second doors), and what made
            # it read that way for two 49-minute episodes that were sitting right there in MakeMKV's
            # own output, just short one sector (Survivors Series 3 Disk 2, 2026-09-03). Both are
            # real states worth reporting, but neither is "never enumerated", so neither belongs in
            # the number that triggers *** stars.
            real = len(missing) - len(doors) - len(unprovable)
            parts = []
            if doors:
                parts.append(f'{len(doors)} are second doors onto material already claimed')
            if unprovable:
                parts.append(f'{len(unprovable)} were enumerated but not mapped by byte size (see '
                             f'UNPROVEN rows above)')
            head = (f'{real} of {len(srpt)} DECLARED title(s) were never enumerated'
                    if real else
                    f'all {len(srpt)} declared title(s) accounted for; ' + '; '.join(parts))
            print(f'\n*** {head} ***' if real else f'\n{head}:')
            for m in missing:
                print(f'    dvdvideo {m["title"]:>3}  VTS_{m["vts"]:02d}  {m["why"]}')
            if absent:
                print(f'\n    {len(absent)} of these have NO title VOBs on disk. This is an '
                      f'INCOMPLETE COPY, not merely a')
                print('    disc with short titles - re-fetch it before dispositioning anything.')

    return 2 if (unproven or missing) else 0


if __name__ == '__main__':
    sys.exit(main())
