#!/usr/bin/env python3
"""Everything a DVD's IFOs DECLARE, as JSON - attribute tables, PGCs, cells, both menu domains,
per-domain sector accounting, and cell-set relations between titles. Optionally carves and
luma-classifies the menu PGCs and sub-floor title PGCs.

REACH FOR THIS WHEN: you need nr_subp / subp_control / audio attributes per VTS, the aspect ratio
the IFO declares (VTSM at 0x100, VTS at 0x200 - never derived from the cells), the VMGM and VTSM
menu-domain inventories with GAP = 0 arithmetic, second doors by identical cell SECTOR sets, or a
padding-vs-content classification of a menu cell. `disposition-evidence.ps1` runs this for you.

WHY THIS EXISTS
---------------
The disposition agents of 2026-09-04 each re-derived these facts by hand, one round-trip at a
time: parsing VMGM_PGCI_UT "directly" because nothing in scripts/ reads it, reading nr_subp at
0x254/0x255 with a note about the off-by-one trap, dumping audio_control words, tiling menu cells
to decide whether a PGC was padding. prove-dvd-mapping.py reads TT_SRPT and the title-domain cell
tables; dvd-still-cells.py reads VTSM_PGCI_UT for carving. Neither reads the attribute tables,
the PGC control words, the VMG menu domain, or the FP_PGC. This is the missing reader, and it
IMPORTS the two existing ones rather than re-implementing their arithmetic, so the sector numbers
here are the same numbers the prover and the carver use.

FACTS ONLY. Nothing here is a verdict. "padding/black" is a measured luma range below the same
threshold assert-accounted.ps1 applies to evidence frames (24), stated alongside the numbers, so
a reader can disagree with the label without re-measuring.

USAGE
    python dvd-ifo-facts.py "<disc or VIDEO_TS dir>"                      # declarations only
    python dvd-ifo-facts.py "<disc>" --classify --out-dir <dir>            # + carve, decode, luma
    python dvd-ifo-facts.py "<disc>" --classify --out-dir <dir> --title-pgcs 2:1,3:1
                                        # also classify these TITLE-domain <vts>:<pgc> PGCs

Output is one JSON document on stdout (or --json-out <file>). --classify writes one PNG of the
first frame per carved PGC and a contact sheet for PGCs longer than 2 s into --out-dir, and
lists them in the JSON. Carved .vob scratch goes to a temp dir and is removed.
"""
import argparse
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
# Same arithmetic as the prover and the carver - imported, not copied.
prove = __import__('prove-dvd-mapping')
carve = __import__('dvd-still-cells')

SECTOR = 2048
LUMA_PADDING_RANGE = 24        # assert-accounted.ps1 $EvidenceMinLumaRange: blank 0, real card 207
TOOL_PATHS = 'D:/video/.transcode-tools/tool-paths.json'
MAX_CLASSIFY_BYTES = 400 * 1024 * 1024   # above this, only the first 60 s of the PGC is decoded

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass


# ------------------------------------------------------------------------------------- decoders

def bcd(b):
    return ((b >> 4) & 0xF) * 10 + (b & 0xF)


def dvd_time(raw):
    """4-byte DVD time -> (seconds, fps, 'h:mm:ss.ff'). Frame byte: top 2 bits = fps code."""
    h, m, s, f = raw[0], raw[1], raw[2], raw[3]
    code = (f >> 6) & 0x3
    fps = {1: 25.0, 3: 29.97}.get(code, 0.0)
    frames = bcd(f & 0x3F)
    hh, mm, ss = bcd(h), bcd(m), bcd(s)
    sec = hh * 3600 + mm * 60 + ss + (frames / fps if fps else 0.0)
    return round(sec, 3), fps, '%d:%02d:%02d.%02d' % (hh, mm, ss, frames)


def video_attr(word):
    mpeg = (word >> 14) & 3
    std = (word >> 12) & 3
    aspect = (word >> 10) & 3
    df = (word >> 8) & 3
    size = (word >> 3) & 7
    letterbox = (word >> 2) & 1
    lines = 576 if std == 1 else 480
    sizes = {0: '720x%d' % lines, 1: '704x%d' % lines, 2: '352x%d' % lines, 3: '352x%d' % (lines // 2)}
    return {
        'raw': '0x%04x' % word,
        'mpeg': {0: 'MPEG-1', 1: 'MPEG-2'}.get(mpeg, 'reserved(%d)' % mpeg),
        'standard': {0: 'NTSC 525/60', 1: 'PAL 625/50'}.get(std, 'reserved(%d)' % std),
        'aspect': {0: '4:3', 3: '16:9'}.get(aspect, 'reserved(%d)' % aspect),
        'permittedDf': {0: 'both', 1: 'pan-scan only', 2: 'letterbox only', 3: 'both'}.get(df),
        'pictureSize': sizes.get(size, 'reserved(%d)' % size),
        'letterboxed': bool(letterbox),
    }


AUDIO_CODING = {0: 'AC3', 2: 'MPEG-1', 3: 'MPEG-2ext', 4: 'LPCM', 6: 'DTS', 7: 'SDDS'}
AUDIO_EXT = {0: 'unspecified', 1: 'normal', 2: 'visually impaired', 3: "director's comments 1",
             4: "director's comments 2"}
SUBP_EXT = {0: 'unspecified', 1: 'normal captions', 2: 'large captions', 3: 'children captions',
            5: 'normal CC', 6: 'large CC', 7: 'children CC', 9: 'forced', 13: "director's comments",
            14: "large director's comments", 15: "children director's comments"}


def lang_code(b2):
    try:
        s = b2.decode('ascii')
    except Exception:
        return None
    return s if re.fullmatch(r'[a-z]{2}', s) else None


def audio_attr(b8):
    coding = (b8[0] >> 5) & 7
    return {
        'raw': ' '.join('%02x' % x for x in b8),
        'coding': AUDIO_CODING.get(coding, 'reserved(%d)' % coding),
        'multichannelExt': bool((b8[0] >> 4) & 1),
        'langTypePresent': ((b8[0] >> 2) & 3) == 1,
        'appMode': (b8[0] & 3),
        'quant': (b8[1] >> 6) & 3,
        'sampleRate': {0: 48000, 1: 96000}.get((b8[1] >> 4) & 3),
        'channels': (b8[1] & 7) + 1,
        'lang': lang_code(b8[2:4]),
        'codeExt': b8[5],
        'codeExtMeaning': AUDIO_EXT.get(b8[5], 'reserved(%d)' % b8[5]),
    }


def subp_attr(b6):
    return {
        'raw': ' '.join('%02x' % x for x in b6),
        'codeMode': (b6[0] >> 5) & 7,
        'langTypePresent': (b6[0] & 3) == 1,
        'lang': lang_code(b6[2:4]),
        'langExt': b6[5],
        'langExtMeaning': SUBP_EXT.get(b6[5], 'reserved(%d)' % b6[5]),
    }


def is_zero(bs):
    return all(x == 0 for x in bs)


def decode_command(c):
    """Minimal VM command decode: JumpTT / JumpSS / CallSS are the ones dispositions cite."""
    hexs = ' '.join('%02x' % x for x in c)
    if c[0] == 0x30 and c[1] == 0x02:
        return hexs, 'JumpTT %d' % c[5]
    if c[0] == 0x30 and c[1] == 0x06:
        return hexs, 'JumpSS (menu %d, vts %d, pgc %d)' % (c[5] & 0xF, c[3], (c[6] << 8) | c[7])
    if c[0] == 0x30 and c[1] == 0x08:
        return hexs, 'CallSS'
    if c[0] == 0x20 and c[1] == 0x04:
        return hexs, 'LinkPGCN %d' % ((c[6] << 8) | c[7])
    if c[0] == 0x71:
        return hexs, 'SetGPRM'
    return hexs, None


# ------------------------------------------------------------------------------------- tables

def parse_pgc(b, p, label):
    nr_programs = b[p + 2]
    nr_cells = b[p + 3]
    sec, fps, hms = dvd_time(b[p + 4:p + 8])
    audio_control = [struct.unpack_from('>H', b, p + 0x0C + 2 * i)[0] for i in range(8)]
    subp_control = [struct.unpack_from('>I', b, p + 0x1C + 4 * i)[0] for i in range(32)]
    next_pgcn = struct.unpack_from('>H', b, p + 0x9C)[0]
    prev_pgcn = struct.unpack_from('>H', b, p + 0x9E)[0]
    goup_pgcn = struct.unpack_from('>H', b, p + 0xA0)[0]
    cmd_off = struct.unpack_from('>H', b, p + 0xE4)[0]
    pgmap_off = struct.unpack_from('>H', b, p + 0xE6)[0]
    cpb_off = struct.unpack_from('>H', b, p + 0xE8)[0]
    cells = []
    for c in range(nr_cells):
        cp = p + cpb_off + 24 * c
        cat = b[cp]
        csec, cfps, chms = dvd_time(b[cp + 4:cp + 8])
        first = struct.unpack_from('>I', b, cp + 8)[0]
        last = struct.unpack_from('>I', b, cp + 20)[0]
        cells.append({
            'cell': c + 1, 'first': first, 'last': last, 'sectors': last - first + 1,
            'bytes': (last - first + 1) * SECTOR,
            'playbackSec': csec, 'playback': chms,
            'stillTime': b[cp + 3],                       # seconds; 0xFF = infinite
            'blockMode': (cat >> 6) & 3,                  # 0 normal, 1 first of block, 2 in block, 3 last
            'blockType': (cat >> 4) & 3,                  # 1 = angle block
            'seamlessPlay': bool((cat >> 3) & 1),
            'interleaved': bool((cat >> 2) & 1),
        })
    program_map = [b[p + pgmap_off + i] for i in range(nr_programs)] if pgmap_off else []
    pre, post = [], []
    if cmd_off:
        t = p + cmd_off
        nr_pre = struct.unpack_from('>H', b, t)[0]
        nr_post = struct.unpack_from('>H', b, t + 2)[0]
        base = t + 8
        for i in range(min(nr_pre, 64)):
            pre.append(decode_command(b[base + 8 * i: base + 8 * i + 8]))
        base2 = base + 8 * nr_pre
        for i in range(min(nr_post, 64)):
            post.append(decode_command(b[base2 + 8 * i: base2 + 8 * i + 8]))
    return {
        'nrPrograms': nr_programs, 'nrCells': nr_cells,
        'playbackSec': sec, 'playback': hms, 'fps': fps,
        'audioControl': ['0x%04x' % w for w in audio_control],
        'audioStreamsEnabled': [i for i, w in enumerate(audio_control) if w & 0x8000],
        'subpControl': ['0x%08x' % w for w in subp_control],
        'subpStreamsEnabled': [i for i, w in enumerate(subp_control) if w & 0x80000000],
        'nextPgcn': next_pgcn, 'prevPgcn': prev_pgcn, 'goUpPgcn': goup_pgcn,
        'programMap': program_map,
        'preCommands': [{'hex': h, 'decoded': d} for h, d in pre],
        'postCommands': [{'hex': h, 'decoded': d} for h, d in post],
        'cells': cells,
        'sectorRange': [cells[0]['first'], max(c['last'] for c in cells)] if cells else None,
        'totalSectors': sum(c['sectors'] for c in cells),
        'totalBytes': sum(c['sectors'] for c in cells) * SECTOR,
        'hasAngleBlock': any(c['blockType'] == 1 for c in cells),
    }


def parse_pgcit(b, pgcit, label):
    nr = struct.unpack_from('>H', b, pgcit)[0]
    out = []
    for i in range(nr):
        cat = struct.unpack_from('>I', b, pgcit + 8 + 8 * i)[0]
        off = struct.unpack_from('>I', b, pgcit + 8 + 8 * i + 4)[0]
        entry = {'pgc': i + 1, 'category': '0x%08x' % cat,
                 'entryPgc': bool(cat & 0x80000000),
                 'menuType': (cat >> 24) & 0xF,
                 'titleNumber': (cat >> 16) & 0xFF}
        entry.update(parse_pgc(b, pgcit + off, label))
        out.append(entry)
    return out


MENU_TYPES = {2: 'title', 3: 'root', 4: 'subpicture', 5: 'audio', 6: 'angle', 7: 'chapter'}


def parse_pgci_ut(b, ut_sector, label):
    """A PGCI_UT (VMGM at VMGI 0xC8, VTSM at VTSI 0xD0): language units, each holding a PGCIT."""
    if ut_sector == 0:
        return None
    ut = ut_sector * SECTOR
    nr_lu = struct.unpack_from('>H', b, ut)[0]
    units = []
    for i in range(nr_lu):
        e = ut + 8 + 8 * i
        lang = b[e:e + 2].decode('latin-1')
        exists = b[e + 3]
        off = struct.unpack_from('>I', b, e + 4)[0]
        pgcs = parse_pgcit(b, ut + off, label) if off else []
        for p in pgcs:
            p['menuTypeName'] = MENU_TYPES.get(p['menuType']) if p['entryPgc'] else None
        units.append({'lang': lang, 'existsFlags': '0x%02x' % exists, 'pgcs': pgcs})
    return {'languageUnits': nr_lu, 'units': units}


def parse_ptt_srpt(b, sector):
    """VTS_PTT_SRPT: per VTS title, its list of (pgcn, pgn) PTTs. Entry PGC = PTT 1's pgcn."""
    if sector == 0:
        return []
    base = sector * SECTOR
    nr = struct.unpack_from('>H', b, base)[0]
    end = struct.unpack_from('>I', b, base + 4)[0]
    offs = [struct.unpack_from('>I', b, base + 8 + 4 * i)[0] for i in range(nr)]
    out = []
    for i in range(nr):
        start = offs[i]
        stop = offs[i + 1] if i + 1 < nr else end + 1
        ptts = []
        o = start
        while o + 4 <= stop:
            pgcn, pgn = struct.unpack_from('>HH', b, base + o)
            ptts.append({'pgcn': pgcn, 'pgn': pgn})
            o += 4
        out.append({'vtsTtn': i + 1, 'entryPgc': ptts[0]['pgcn'] if ptts else None, 'ptts': ptts})
    return out


def vob_info(video_ts, pattern):
    files = []
    for n in sorted(os.listdir(video_ts)):
        if re.fullmatch(pattern, n, re.IGNORECASE):
            p = os.path.join(video_ts, n)
            size = os.path.getsize(p)
            files.append({'name': n, 'bytes': size, 'sectors': size // SECTOR,
                          'wholeSectors': size % SECTOR == 0})
    return files


def union_sectors(ranges):
    """Union of [first,last] ranges -> (covered sector count, list of merged ranges)."""
    rs = sorted((a, b) for a, b in ranges if b >= a)
    merged = []
    for a, b in rs:
        if merged and a <= merged[-1][1] + 1:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b])
    return sum(b - a + 1 for a, b in merged), merged


def domain_gap(pgcs, vob_sectors):
    """Sector accounting for one domain: union of every cell of every PGC vs the VOB set."""
    ranges = [(c['first'], c['last']) for p in pgcs for c in p['cells']]
    covered, merged = union_sectors(ranges)
    summed = sum(b - a + 1 for a, b in ranges)
    beyond = [r for r in ranges if r[1] >= vob_sectors]
    return {
        'vobSectors': vob_sectors, 'vobBytes': vob_sectors * SECTOR,
        'cellSectorsUnion': covered, 'cellSectorsSummed': summed,
        'gapSectors': vob_sectors - covered,
        'overlapSectors': summed - covered,
        'mergedRanges': merged,
        'cellsBeyondVob': beyond,
        'pgcsWithCells': [p['pgc'] for p in pgcs if p['cells']],
        'pgcsWithoutCells': [p['pgc'] for p in pgcs if not p['cells']],
    }


# ----------------------------------------------------------------------------------- the reader

def read_vts(video_ts, vtsn):
    path = os.path.join(video_ts, 'VTS_%02d_0.IFO' % vtsn)
    b = open(path, 'rb').read()
    if b[:12] != b'DVDVIDEO-VTS':
        return {'vts': vtsn, 'error': 'not a VTS IFO'}
    ptt_sec = struct.unpack_from('>I', b, 0xC8)[0]
    pgcit_sec = struct.unpack_from('>I', b, 0xCC)[0]
    vtsm_sec = struct.unpack_from('>I', b, 0xD0)[0]
    out = {'vts': vtsn, 'ifo': path, 'ifoBytes': len(b)}
    out['vtsmVideoAttr'] = video_attr(struct.unpack_from('>H', b, 0x100)[0])
    n_a = struct.unpack_from('>H', b, 0x102)[0]
    out['vtsmAudio'] = {'count': n_a, 'attrs': [audio_attr(b[0x104 + 8 * i:0x104 + 8 * i + 8]) for i in range(min(n_a, 8))]}
    n_s = struct.unpack_from('>H', b, 0x154)[0]
    out['vtsmSubp'] = {'count': n_s, 'attrs': [subp_attr(b[0x156:0x15C])] if n_s else []}
    out['videoAttr'] = video_attr(struct.unpack_from('>H', b, 0x200)[0])
    n_a = struct.unpack_from('>H', b, 0x202)[0]
    out['audio'] = {'count': n_a, 'countOffset': '0x202',
                    'attrs': [audio_attr(b[0x204 + 8 * i:0x204 + 8 * i + 8]) for i in range(min(n_a, 8))],
                    'declaredSlotsNonZero': [i for i in range(8) if not is_zero(b[0x204 + 8 * i:0x204 + 8 * i + 8])]}
    n_s = struct.unpack_from('>H', b, 0x254)[0]
    out['subp'] = {'count': n_s, 'countOffset': '0x254 (2-byte big-endian; the value is in byte 0x255)',
                   'attrs': [subp_attr(b[0x256 + 6 * i:0x256 + 6 * i + 6]) for i in range(min(n_s, 32))],
                   'allAttrsZero': all(is_zero(b[0x256 + 6 * i:0x256 + 6 * i + 6]) for i in range(min(n_s, 32))) if n_s else None,
                   'declaredSlotsNonZero': [i for i in range(32) if not is_zero(b[0x256 + 6 * i:0x256 + 6 * i + 6])]}
    out['pttSrpt'] = parse_ptt_srpt(b, ptt_sec)
    out['pgcit'] = parse_pgcit(b, pgcit_sec * SECTOR, 'VTS_%02d' % vtsn) if pgcit_sec else []
    out['vtsmPgciUt'] = parse_pgci_ut(b, vtsm_sec, 'VTSM_%02d' % vtsn)
    out['titleVobs'] = vob_info(video_ts, r'VTS_%02d_[1-9]\.VOB' % vtsn)
    out['menuVob'] = (vob_info(video_ts, r'VTS_%02d_0\.VOB' % vtsn) or [None])[0]
    tv = sum(f['sectors'] for f in out['titleVobs'])
    out['titleDomain'] = domain_gap(out['pgcit'], tv)
    if out['vtsmPgciUt'] and out['vtsmPgciUt']['units']:
        mv = out['menuVob']['sectors'] if out['menuVob'] else 0
        out['menuDomain'] = domain_gap(out['vtsmPgciUt']['units'][0]['pgcs'], mv)
        out['menuDomain']['menuVobPresent'] = out['menuVob'] is not None
    else:
        out['menuDomain'] = {'declared': False, 'menuVobPresent': out['menuVob'] is not None,
                             'vobSectors': out['menuVob']['sectors'] if out['menuVob'] else 0}
    return out


def read_vmg(video_ts):
    path = os.path.join(video_ts, 'VIDEO_TS.IFO')
    b = open(path, 'rb').read()
    if b[:12] != b'DVDVIDEO-VMG':
        raise SystemExit('%s is not a VMG IFO' % path)
    out = {'ifo': path, 'ifoBytes': len(b)}
    out['nrTitleSets'] = struct.unpack_from('>H', b, 0x3E)[0]
    out['pointers'] = {
        'TT_SRPT': struct.unpack_from('>I', b, 0xC4)[0],
        'VMGM_PGCI_UT': struct.unpack_from('>I', b, 0xC8)[0],
        'PTL_MAIT': struct.unpack_from('>I', b, 0xCC)[0],
        'VTS_ATRT': struct.unpack_from('>I', b, 0xD0)[0],
        'TXTDT_MG': struct.unpack_from('>I', b, 0xD4)[0],
        'VMGM_C_ADT': struct.unpack_from('>I', b, 0xD8)[0],
        'VMGM_VOBU_ADMAP': struct.unpack_from('>I', b, 0xDC)[0],
    }
    out['vmgmVideoAttr'] = video_attr(struct.unpack_from('>H', b, 0x100)[0])
    n_a = struct.unpack_from('>H', b, 0x102)[0]
    out['vmgmAudio'] = {'count': n_a, 'attrs': [audio_attr(b[0x104:0x10C])] if n_a else []}
    n_s = struct.unpack_from('>H', b, 0x154)[0]
    out['vmgmSubp'] = {'count': n_s, 'attrs': [subp_attr(b[0x156:0x15C])] if n_s else []}
    # TT_SRPT: reuse the prover's reader, then add the fields it does not keep.
    srpt = prove.read_tt_srpt(video_ts)
    off = out['pointers']['TT_SRPT'] * SECTOR
    for e in srpt:
        i = e['title'] - 1
        e0 = off + 8 + i * 12
        e['playbackType'] = '0x%02x' % b[e0]
        e['nrOfAngles'] = b[e0 + 1]
        e['parentalMask'] = '0x%04x' % struct.unpack_from('>H', b, e0 + 4)[0]
        e['titleSetSector'] = struct.unpack_from('>I', b, e0 + 8)[0]
    out['ttSrpt'] = srpt
    out['fpPgc'] = parse_pgc(b, 0x400, 'FP_PGC')
    out['vmgmPgciUt'] = parse_pgci_ut(b, out['pointers']['VMGM_PGCI_UT'], 'VMGM')
    out['menuVob'] = (vob_info(video_ts, r'VIDEO_TS\.VOB') or [None])[0]
    mv = out['menuVob']['sectors'] if out['menuVob'] else 0
    pgcs = out['vmgmPgciUt']['units'][0]['pgcs'] if out['vmgmPgciUt'] and out['vmgmPgciUt']['units'] else []
    out['menuDomain'] = domain_gap(pgcs + ([dict(out['fpPgc'], pgc=0)] if out['fpPgc']['cells'] else []), mv)
    out['menuDomain']['menuVobPresent'] = out['menuVob'] is not None
    out['menuDomain']['declared'] = out['vmgmPgciUt'] is not None
    return out


def title_facts(vmg, vts_by_n):
    """One record per TT_SRPT title with its entry PGC's cells and control words."""
    out = []
    for e in vmg['ttSrpt']:
        v = vts_by_n.get(e['vtsn'])
        rec = {'title': e['title'], 'vtsn': e['vtsn'], 'vtsTtn': e['vts_ttn'],
               'nrOfPtts': e['nr_of_ptts'], 'nrOfAngles': e['nrOfAngles'],
               'vtsOnDisk': v is not None and not v.get('error')}
        if v and not v.get('error'):
            ptt = next((t for t in v['pttSrpt'] if t['vtsTtn'] == e['vts_ttn']), None)
            rec['entryPgc'] = ptt['entryPgc'] if ptt else None
            rec['ptts'] = ptt['ptts'] if ptt else []
            rec['pgcsReferencedByPtts'] = sorted({p['pgcn'] for p in rec['ptts']})
            pgc = next((p for p in v['pgcit'] if p['pgc'] == rec['entryPgc']), None) if rec['entryPgc'] else None
            if pgc:
                rec['pgc'] = {k: pgc[k] for k in ('nrPrograms', 'nrCells', 'playbackSec', 'playback', 'fps',
                                                   'audioStreamsEnabled', 'subpStreamsEnabled', 'audioControl',
                                                   'subpControl', 'hasAngleBlock', 'totalSectors', 'totalBytes',
                                                   'sectorRange', 'programMap', 'nextPgcn', 'prevPgcn')}
                rec['cellSet'] = [[c['first'], c['last']] for c in pgc['cells']]
                rec['cellsWithStillTime'] = [c['cell'] for c in pgc['cells'] if c['stillTime']]
            else:
                rec['pgc'] = None
            rec['videoAttr'] = v['videoAttr']
            rec['audioDeclared'] = v['audio']['count']
            rec['subpDeclared'] = v['subp']['count']
        out.append(rec)
    return out


def cell_relations(titles, vts_by_n):
    """Relations between TT_SRPT titles' entry-PGC cell sets, WITHIN a VTS, on sectors."""
    rel = []
    by_vts = {}
    for t in titles:
        if t.get('cellSet'):
            by_vts.setdefault(t['vtsn'], []).append(t)
    for vtsn, ts in by_vts.items():
        for i in range(len(ts)):
            for j in range(i + 1, len(ts)):
                a, b = ts[i], ts[j]
                sa = set()
                for f, l in a['cellSet']:
                    sa.update(range(f, l + 1))
                sb = set()
                for f, l in b['cellSet']:
                    sb.update(range(f, l + 1))
                shared = len(sa & sb)
                if not shared:
                    continue
                if sa == sb:
                    kind = 'IDENTICAL cell sectors (second door)'
                elif sa < sb:
                    kind = 'title %d cells CONTAINED in title %d' % (a['title'], b['title'])
                elif sb < sa:
                    kind = 'title %d cells CONTAINED in title %d' % (b['title'], a['title'])
                else:
                    kind = 'OVERLAP'
                rel.append({'vtsn': vtsn, 'titleA': a['title'], 'titleB': b['title'],
                            'relation': kind, 'sharedSectors': shared,
                            'sectorsA': len(sa), 'sectorsB': len(sb),
                            'sameCellTuples': sorted(map(tuple, a['cellSet'])) == sorted(map(tuple, b['cellSet']))})
        # PGCs in this VTS that no title's PTTs reference (play-all chains, second PGCs)
    unreferenced = []
    for vtsn, v in vts_by_n.items():
        if v.get('error'):
            continue
        referenced = set()
        for t in titles:
            if t['vtsn'] == vtsn:
                referenced.update(t.get('pgcsReferencedByPtts', []))
        title_sets = {t['title']: sorted(map(tuple, t['cellSet'])) for t in titles if t['vtsn'] == vtsn and t.get('cellSet')}
        for p in v['pgcit']:
            if p['pgc'] in referenced:
                continue
            cs = sorted((c['first'], c['last']) for c in p['cells'])
            same_as = [tn for tn, s in title_sets.items() if s == cs and cs]
            unreferenced.append({'vtsn': vtsn, 'pgc': p['pgc'], 'nrCells': p['nrCells'],
                                 'playbackSec': p['playbackSec'], 'cellSet': [list(c) for c in cs],
                                 'identicalToTitle': same_as, 'category': p['category'],
                                 'entryPgc': p['entryPgc']})
    return rel, unreferenced


# ------------------------------------------------------------------------------ classification

def tool_paths():
    with open(TOOL_PATHS, encoding='utf-8') as fh:
        tp = json.load(fh)
    ff = tp['ffmpeg']
    return ff, os.path.join(os.path.dirname(ff), 'ffprobe.exe')


def carve_pgc(parts, cells, dest):
    with open(dest, 'wb') as fh:
        for f, l in cells:
            fh.write(carve.read_sectors(parts, f, l))


def probe_streams(ffprobe, path):
    r = subprocess.run([ffprobe, '-v', 'error', '-count_packets', '-show_entries',
                        'stream=index,codec_type,codec_name,nb_read_packets,width,height,avg_frame_rate,'
                        'sample_aspect_ratio,display_aspect_ratio', '-of', 'json', path],
                       capture_output=True, text=True, encoding='utf-8', errors='replace')
    try:
        js = json.loads(r.stdout or '{}')
    except Exception:
        js = {}
    streams = []
    for s in js.get('streams', []):
        streams.append({'index': s.get('index'), 'type': s.get('codec_type'), 'codec': s.get('codec_name'),
                        'packets': int(s['nb_read_packets']) if str(s.get('nb_read_packets', '')).isdigit() else 0,
                        'geometry': ('%sx%s' % (s['width'], s['height'])) if s.get('width') else None,
                        'sar': s.get('sample_aspect_ratio'), 'dar': s.get('display_aspect_ratio'),
                        'fps': s.get('avg_frame_rate')})
    return streams


def luma_stats(ffmpeg, path, limit_sec=None):
    args = [ffmpeg, '-hide_banner', '-loglevel', 'error', '-i', path]
    if limit_sec:
        args += ['-t', str(limit_sec)]
    args += ['-vf', 'signalstats,metadata=print:file=-', '-f', 'null', '-']
    r = subprocess.run(args, capture_output=True, text=True, encoding='utf-8', errors='replace')
    ymin, ymax, yavg, frames = None, None, [], 0
    for line in r.stdout.splitlines():
        m = re.search(r'lavfi\.signalstats\.YMIN=([\d.]+)', line)
        if m:
            v = float(m.group(1))
            ymin = v if ymin is None else min(ymin, v)
            frames += 1
        m = re.search(r'lavfi\.signalstats\.YMAX=([\d.]+)', line)
        if m:
            v = float(m.group(1))
            ymax = v if ymax is None else max(ymax, v)
        m = re.search(r'lavfi\.signalstats\.YAVG=([\d.]+)', line)
        if m:
            yavg.append(float(m.group(1)))
    if ymin is None or ymax is None:
        return {'frames': frames, 'measured': False}
    rng = ymax - ymin
    return {'frames': frames, 'measured': True, 'yMin': ymin, 'yMax': ymax, 'lumaRange': rng,
            'yAvgMean': round(sum(yavg) / len(yavg), 1) if yavg else None,
            'class': 'padding/black' if rng < LUMA_PADDING_RANGE else 'content',
            'threshold': LUMA_PADDING_RANGE}


def render_frames(ffmpeg, path, out_base, seconds):
    outs = {}
    png = out_base + '-first.png'
    subprocess.run([ffmpeg, '-v', 'error', '-y', '-i', path, '-fps_mode', 'passthrough', '-frames:v', '1', png],
                   capture_output=True)
    if os.path.exists(png):
        outs['firstFrame'] = png
        outs['firstFrameBytes'] = os.path.getsize(png)
    if seconds and seconds > 2:
        sheet = out_base + '-sheet.png'
        step = max(1, int(seconds / 24)) if seconds > 24 else 1
        subprocess.run([ffmpeg, '-v', 'error', '-y', '-i', path, '-vf',
                        'fps=1/%d,scale=360:-1,tile=6x4' % step, '-frames:v', '1', sheet], capture_output=True)
        if os.path.exists(sheet):
            outs['contactSheet'] = sheet
            outs['contactSheetStepSec'] = step
    return outs


def classify(video_ts, vmg, vts_by_n, title_pgcs, out_dir, max_pgcs):
    ffmpeg, ffprobe = tool_paths()
    os.makedirs(out_dir, exist_ok=True)
    scratch = tempfile.mkdtemp(prefix='ifo-facts-')
    results = []
    jobs = []
    # VMGM: cells relative to VIDEO_TS.VOB
    if vmg['menuVob']:
        parts = [(os.path.join(video_ts, 'VIDEO_TS.VOB'), 0, vmg['menuVob']['sectors'])]
        pgcs = vmg['vmgmPgciUt']['units'][0]['pgcs'] if vmg['vmgmPgciUt'] and vmg['vmgmPgciUt']['units'] else []
        for p in pgcs:
            if p['cells']:
                jobs.append(('VMGM', 0, p['pgc'], parts, p))
        if vmg['fpPgc']['cells']:
            jobs.append(('VMGM-FP', 0, 0, parts, vmg['fpPgc']))
    for vtsn, v in sorted(vts_by_n.items()):
        if v.get('error'):
            continue
        if v['menuVob'] and v['vtsmPgciUt'] and v['vtsmPgciUt']['units']:
            parts = [(os.path.join(video_ts, 'VTS_%02d_0.VOB' % vtsn), 0, v['menuVob']['sectors'])]
            for p in v['vtsmPgciUt']['units'][0]['pgcs']:
                if p['cells']:
                    jobs.append(('VTSM', vtsn, p['pgc'], parts, p))
    for vtsn, pgcn in title_pgcs:
        v = vts_by_n.get(vtsn)
        if not v or v.get('error'):
            results.append({'domain': 'TITLE', 'vts': vtsn, 'pgc': pgcn, 'unavailable': 'VTS not on disk'})
            continue
        p = next((x for x in v['pgcit'] if x['pgc'] == pgcn), None)
        if not p or not p['cells']:
            results.append({'domain': 'TITLE', 'vts': vtsn, 'pgc': pgcn, 'unavailable': 'PGC not declared or has no cells'})
            continue
        try:
            parts = carve.title_vob_map(video_ts, vtsn)
        except SystemExit as e:
            results.append({'domain': 'TITLE', 'vts': vtsn, 'pgc': pgcn, 'unavailable': str(e)})
            continue
        jobs.append(('TITLE', vtsn, pgcn, parts, p))
    capped = len(jobs) > max_pgcs
    for domain, vtsn, pgcn, parts, p in jobs[:max_pgcs]:
        rec = {'domain': domain, 'vts': vtsn, 'pgc': pgcn, 'nrCells': p['nrCells'],
               'playbackSec': p['playbackSec'], 'sectorRange': p['sectorRange'],
               'totalBytes': p['totalBytes']}
        cells = [(c['first'], c['last']) for c in p['cells']]
        vob = os.path.join(scratch, '%s-%02d-pgc%03d.vob' % (domain, vtsn, pgcn))
        try:
            carve_pgc(parts, cells, vob)
        except SystemExit as e:
            rec['unavailable'] = 'carve failed: %s' % e
            results.append(rec)
            continue
        rec['streams'] = probe_streams(ffprobe, vob)
        limit = 60 if p['totalBytes'] > MAX_CLASSIFY_BYTES else None
        rec['luma'] = luma_stats(ffmpeg, vob, limit)
        if limit:
            rec['luma']['note'] = 'PGC exceeds %d MB; only the first %d s were decoded' % (MAX_CLASSIFY_BYTES // 1048576, limit)
        base = os.path.join(out_dir, '%s-vts%02d-pgc%03d' % (domain.lower(), vtsn, pgcn))
        rec.update(render_frames(ffmpeg, vob, base, p['playbackSec']))
        results.append(rec)
        try:
            os.remove(vob)
        except OSError:
            pass
    shutil.rmtree(scratch, ignore_errors=True)
    return {'pgcs': results, 'capped': capped, 'maxPgcs': max_pgcs, 'jobsFound': len(jobs),
            'lumaPaddingThreshold': LUMA_PADDING_RANGE, 'outDir': out_dir}


# ------------------------------------------------------------------------------------------ main

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('disc')
    ap.add_argument('--classify', action='store_true')
    ap.add_argument('--out-dir', default=None, help='where PNGs go (required with --classify)')
    ap.add_argument('--title-pgcs', default='', help='comma list of <vts>:<pgc> title-domain PGCs to classify too')
    ap.add_argument('--max-pgcs', type=int, default=80)
    ap.add_argument('--json-out', default=None)
    a = ap.parse_args()

    video_ts = a.disc
    if os.path.isdir(os.path.join(a.disc, 'VIDEO_TS')):
        video_ts = os.path.join(a.disc, 'VIDEO_TS')
    if not os.path.isfile(os.path.join(video_ts, 'VIDEO_TS.IFO')):
        raise SystemExit('no VIDEO_TS.IFO under %s' % video_ts)

    vmg = read_vmg(video_ts)
    vts_by_n = {}
    for n in sorted(os.listdir(video_ts)):
        m = re.fullmatch(r'VTS_(\d\d)_0\.IFO', n, re.IGNORECASE)
        if m:
            vtsn = int(m.group(1))
            try:
                vts_by_n[vtsn] = read_vts(video_ts, vtsn)
            except Exception as e:      # one unparseable VTS must not hide the others
                vts_by_n[vtsn] = {'vts': vtsn, 'error': 'IFO parse failed: %s' % e}
    titles = title_facts(vmg, vts_by_n)
    relations, unreferenced = cell_relations(titles, vts_by_n)

    doc = {
        'schema': 'dvd-ifo-facts/1',
        'videoTs': video_ts,
        'vmg': vmg,
        'vts': {('%02d' % k): v for k, v in sorted(vts_by_n.items())},
        'titles': titles,
        'cellSetRelations': relations,
        'pgcsNotReferencedByAnyTitle': unreferenced,
        'declaredVtsMissingOnDisk': sorted({e['vtsn'] for e in vmg['ttSrpt']} - set(vts_by_n)),
    }
    if a.classify:
        if not a.out_dir:
            raise SystemExit('--classify needs --out-dir')
        tp = []
        for tok in [t for t in a.title_pgcs.split(',') if t.strip()]:
            v, p = tok.split(':')
            tp.append((int(v), int(p)))
        doc['classification'] = classify(video_ts, vmg, vts_by_n, tp, a.out_dir, a.max_pgcs)

    text = json.dumps(doc, indent=1)
    if a.json_out:
        with open(a.json_out, 'w', encoding='utf-8') as fh:
            fh.write(text)
        print('wrote %s (%d bytes)' % (a.json_out, len(text)))
    else:
        sys.stdout.write(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())
