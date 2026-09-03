#!/usr/bin/env python3
"""Read ONE ANGLE of a DVD multi-angle (ILVU-interleaved) title out of the VOBs.

WHY THIS EXISTS
---------------
`ffmpeg -f dvdvideo -title N` has no angle selector and SILENTLY RETURNS ANGLE 1. `transcode.ps1`
has no angle field either. So an angle-2 extra - "as shot" footage, an alternate performance, a
behind-the-camera view - reads out as angle 1, which is very often a programme segment ALREADY
PUBLISHED. The result ships a duplicate of an existing library item under a new name, and every
structural check (duration, frame count, packet count, size) passes, because angle 1 and angle 2
are the same length by construction.

The League of Gentlemen Series 2 Disk 1 (2026-09-03) is the case that prompted this: VTS_07's one
PGC declares 119.28 s while its cells sum to 237.56 s, and that excess IS the second angle. Angle 1
was already the library's `S00E33`; angle 2 - the un-graded, still-interlaced camera original the
extra exists to demonstrate - was reachable by nothing in the pipeline.

HOW AN ANGLE BLOCK IS LAID OUT, AND WHY SECTOR ARITHMETIC ALONE IS NOT ENOUGH
-----------------------------------------------------------------------------
An angle block is N consecutive cells sharing ONE OVERLAPPING sector range: the angles' VOBUs are
INTERLEAVED on disc (ILVU) so a player can switch angles without seeking. The cell table's
first/last sector therefore does NOT delimit one angle - carving that range gives you every angle
shuffled together, which decodes to a jumping, over-long mess.

What separates them is stated in the stream itself. Every VOBU opens with a NAV pack, whose DSI
carries `vobu_vob_idn` (DSI_GI+24) and `vobu_c_idn` (DSI_GI+27); the PGC's cell-position table
(C_POSI) gives each cell its VOB_ID/CELL_ID. So angle k's stream is exactly the VOBUs whose
(VOB_ID, CELL_ID) equal cell k's - read in sector order, no re-timing needed within the angle.
That is what a hardware player does, and it is deterministic rather than heuristic.

`vobu_ea` (DSI_GI+8) gives each VOBU's length in sectors, so the walk never has to guess where the
next VOBU starts.

THIS EMITS A WHOLE PGC AT ONE ANGLE, not just the block: non-interleaved cells (the lead-in, the
tail card) belong to every angle and are emitted in cell order, so the output is what a viewer
would actually see having pressed ANGLE-2. Cross-cell timestamp resets are the job of
`retime-vob-cells.py`, exactly as for any other multi-cell carve.

VERIFY THE ANGLE FROM THE PICTURE, NOT FROM THE INDEX. On the disc above, angle 1 is the BRIGHTER
image despite the menu card promising the un-graded angle would look "dark and brooding" - so luma
picks the wrong one. What separated them was `idet`: angle 1 Progressive 2919/2982 (a de-interlaced
broadcast master), angle 2 TFF 2971/2982 (the interlaced camera original).

USAGE
    python dvd-angle-cells.py <VIDEO_TS dir> <vts> <pgc> --list
    python dvd-angle-cells.py <VIDEO_TS dir> <vts> <pgc> --angle <n> <out.vob>

Exit codes: 0 = OK, 2 = refused (structure, or a short/absent angle).
"""
import os
import struct
import sys

SECTOR = 2048


def bcd(x):
    return (x >> 4) * 10 + (x & 0x0F)


def pgc_table(ifo_path, pgc_no):
    """Cells of one TITLE-domain PGC: dicts with sectors, category, VOB_ID/CELL_ID and time."""
    b = open(ifo_path, 'rb').read()
    if b[:12] != b'DVDVIDEO-VTS':
        raise SystemExit('%s is not a VTS IFO (exit 2)' % ifo_path)
    pgcit = struct.unpack_from('>I', b, 0xCC)[0] * SECTOR
    nr = struct.unpack_from('>H', b, pgcit)[0]
    if not 1 <= pgc_no <= nr:
        raise SystemExit('VTS declares %d title PGC(s); %d asked for (exit 2)' % (nr, pgc_no))
    q = pgcit + struct.unpack_from('>I', b, pgcit + 8 + 8 * (pgc_no - 1) + 4)[0]
    ncells = b[q + 3]
    t = b[q + 4:q + 8]
    fps = 25.0 if (t[3] >> 6) == 1 else 30000 / 1001.0
    pgc_secs = bcd(t[0]) * 3600 + bcd(t[1]) * 60 + bcd(t[2]) + bcd(t[3] & 0x3F) / fps
    cpbkt = struct.unpack_from('>H', b, q + 0xE8)[0]
    cposit = struct.unpack_from('>H', b, q + 0xEA)[0]
    cells = []
    for c in range(ncells):
        cp = q + cpbkt + 24 * c
        cat = struct.unpack_from('>I', b, cp)[0]
        ct = b[cp + 4:cp + 8]
        pos = q + cposit + 4 * c
        cells.append(dict(
            n=c + 1, cat=cat,
            block_mode=(cat >> 30) & 3, block_type=(cat >> 28) & 3,
            interleaved=(cat >> 26) & 1,
            first=struct.unpack_from('>I', b, cp + 8)[0],
            last=struct.unpack_from('>I', b, cp + 20)[0],
            secs=bcd(ct[0]) * 3600 + bcd(ct[1]) * 60 + bcd(ct[2]) + bcd(ct[3] & 0x3F) / fps,
            vob_id=struct.unpack_from('>H', b, pos)[0], cell_id=b[pos + 3]))
    return cells, pgc_secs, fps


def vob_map(video_ts, vtsn):
    parts, at = [], 0
    for n in range(1, 10):
        p = os.path.join(video_ts, 'VTS_%02d_%d.VOB' % (vtsn, n))
        if not os.path.exists(p):
            continue
        size = os.path.getsize(p)
        if size % SECTOR:
            raise SystemExit('%s is not a whole number of sectors (exit 2)' % p)
        parts.append((p, at, size // SECTOR))
        at += size // SECTOR
    if not parts:
        raise SystemExit('no VTS_%02d_n.VOB in %s (exit 2)' % (vtsn, video_ts))
    return parts


def read_sector(parts, lbn):
    for path, start, n in parts:
        if start <= lbn < start + n:
            with open(path, 'rb') as fh:
                fh.seek((lbn - start) * SECTOR)
                d = fh.read(SECTOR)
            if len(d) != SECTOR:
                raise SystemExit('short read at sector %d (exit 2)' % lbn)
            return d
    raise SystemExit('sector %d is outside the VTS VOB set (exit 2)' % lbn)


def nav_info(pack):
    """(vob_id, cell_id, vobu_ea) if this pack is a NAV pack, else None.

    The DSI PES is located by walking the pack's PES packets rather than by a fixed offset, so a
    pack with unusual stuffing cannot yield a plausible wrong VOB id.
    """
    if pack[:4] != b'\x00\x00\x01\xba':
        return None
    off = 14 + (pack[13] & 0x07)
    while off + 6 <= SECTOR:
        if pack[off:off + 3] != b'\x00\x00\x01':
            return None
        sid = pack[off + 3]
        plen = (pack[off + 4] << 8) | pack[off + 5]
        if sid == 0xBF and pack[off + 6] == 0x01:          # private stream 2, substream DSI
            g = off + 7                                    # DSI_GI
            return (struct.unpack_from('>H', pack, g + 24)[0], pack[g + 27],
                    struct.unpack_from('>I', pack, g + 8)[0])
        if sid != 0xBF:
            return None                                    # a NAV pack leads with PCI then DSI
        off += 6 + plen
    return None


def angle_groups(cells):
    """[[cell,...]] - each list is one angle block, in angle order."""
    groups, cur = [], []
    for c in cells:
        if c['block_type'] == 1 and c['block_mode'] in (1, 2, 3):
            cur.append(c)
            if c['block_mode'] == 3:
                groups.append(cur); cur = []
        elif cur:
            raise SystemExit('cell %d ends an angle block without a block_mode 3 cell (exit 2)'
                             % c['n'])
    if cur:
        raise SystemExit('unterminated angle block at cell %d (exit 2)' % cur[-1]['n'])
    return groups


def main():
    a = sys.argv[1:]
    if len(a) < 4:
        raise SystemExit(__doc__.strip().rsplit('USAGE', 1)[-1].strip())
    video_ts, vtsn, pgcn = a[0], int(a[1]), int(a[2])
    cells, pgc_secs, fps = pgc_table(os.path.join(video_ts, 'VTS_%02d_0.IFO' % vtsn), pgcn)
    groups = angle_groups(cells)
    listing = '--list' in a

    print('VTS_%02d PGC %d: %d cell(s), PGC declares %.2f s at %g fps; cells sum to %.2f s'
          % (vtsn, pgcn, len(cells), pgc_secs, fps, sum(c['secs'] for c in cells)))
    for c in cells:
        print('  cell %d cat=0x%08x block_mode=%d block_type=%d ilvu=%d  sectors %d..%d  '
              '%.2f s  VOB_ID=%d CELL_ID=%d'
              % (c['n'], c['cat'], c['block_mode'], c['block_type'], c['interleaved'],
                 c['first'], c['last'], c['secs'], c['vob_id'], c['cell_id']))
    if groups:
        print('  %d angle block(s); %s angle(s) available'
              % (len(groups), '/'.join(str(len(g)) for g in groups)))
    else:
        print('  NO angle block in this PGC - nothing to select')
    if listing:
        return 0

    if '--angle' not in a:
        raise SystemExit('--angle <n> is required unless --list (exit 2)')
    ang = int(a[a.index('--angle') + 1])
    out = a[-1]
    if not groups:
        raise SystemExit('PGC %d has no angle block; use the normal DVD path (exit 2)' % pgcn)
    for g in groups:
        if ang > len(g):
            raise SystemExit('angle %d asked for; the block at cell %d offers %d (exit 2)'
                             % (ang, g[0]['n'], len(g)))

    # A player's own playback order: every non-interleaved cell, plus the chosen angle's cell
    # from each block, in cell order.
    chosen, in_block = [], {c['n']: gi for gi, g in enumerate(groups) for c in g}
    for c in cells:
        if c['n'] in in_block:
            if c is groups[in_block[c['n']]][ang - 1]:
                chosen.append(c)
        else:
            chosen.append(c)
    print('  angle %d plays cells %s = %.2f s'
          % (ang, ','.join(str(c['n']) for c in chosen), sum(c['secs'] for c in chosen)))

    parts = vob_map(video_ts, vtsn)
    total = 0
    with open(out, 'wb') as fo:
        for c in chosen:
            lbn, emitted, vobus = c['first'], 0, 0
            while lbn <= c['last']:
                pack = read_sector(parts, lbn)
                nav = nav_info(pack)
                if nav is None:
                    # Inside an interleaved range every VOBU must start with a NAV pack; if one
                    # does not, the walk has lost sync and everything after it would be garbage.
                    raise SystemExit('cell %d: sector %d is not a NAV pack - lost VOBU sync '
                                     '(exit 2)' % (c['n'], lbn))
                vob_id, cell_id, ea = nav
                nsec = ea + 1
                if ea == 0:
                    raise SystemExit('cell %d: VOBU at %d declares length 0 (exit 2)' % (c['n'], lbn))
                if (vob_id, cell_id) == (c['vob_id'], c['cell_id']):
                    for s in range(lbn, lbn + nsec):
                        fo.write(read_sector(parts, s))
                    emitted += nsec
                    vobus += 1
                lbn += nsec
            print('    cell %d: %d VOBU(s), %d sector(s) = %d bytes'
                  % (c['n'], vobus, emitted, emitted * SECTOR))
            if not vobus:
                raise SystemExit('cell %d emitted NOTHING for VOB_ID=%d CELL_ID=%d (exit 2)'
                                 % (c['n'], c['vob_id'], c['cell_id']))
            total += emitted
    print('  -> %s  %d sectors, %d bytes' % (out, total, total * SECTOR))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except SystemExit as e:
        if isinstance(e.code, str):
            sys.stderr.write(e.code + '\n')
            sys.exit(2)
        raise
