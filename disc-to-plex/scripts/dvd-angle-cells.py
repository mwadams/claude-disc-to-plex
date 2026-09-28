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

THE CARVE LOSES THE SUBTITLE PALETTE, SO THIS WRITES IT BESIDE THE CARVE.
A DVD subpicture is 2-bit indices into a 16-colour CLUT that lives in the PGC (IFO, PGC+0xA4),
not in the VOB. The dvdvideo demuxer reads it and hands it on as the stream's extradata, so a
normal DVD encode carries it; a carved .vob is read by the plain mpegps demuxer, which has no IFO,
so the encode's dvd_subtitle stream shipped with NO palette and OCR rendered it against a default
one. The Invisible Enemy S00E346-349 (2026-09-28): subtitle packets byte-identical to the
primary-angle S15E08, palette absent - S00E349 failed the dictionary gate 49 times at 94.7%.
So a carve also writes `<out>.palette.txt`: the palette line EXACTLY as ffmpeg's dvdvideo demuxer
builds it (libavformat/dvdclut.c - measured byte-identical, MD5 e663151d..., against S15E08).
retime-vob-cells.py carries it to the retimed file and transcode.ps1 injects it (lib-vobsub-palette).
`--palette` prints the line alone, for repairs and for a hand-built carve.

USAGE
    python dvd-angle-cells.py <VIDEO_TS dir> <vts> <pgc> --list
    python dvd-angle-cells.py <VIDEO_TS dir> <vts> <pgc> --palette
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


def pgc_palette_line(ifo_path, pgc_no):
    """The PGC's subpicture CLUT as the idx/extradata line ffmpeg's dvdvideo demuxer writes.

    Conversion copied from libavformat/dvdclut.c (ff_dvdclut_yuv_to_rgb): each entry is 0,Y,Cr,Cb;
    CCIR range -> RGB in 10-bit fixed point, WITH the demuxer's `- 1024` bias (one step darker than
    the plain colorspace.h macro - without it 3 of 16 entries differ by 1, fe vs fd). No trailing
    newline; the caller adds one where it writes extradata.
    """
    b = open(ifo_path, 'rb').read()
    if b[:12] != b'DVDVIDEO-VTS':
        raise SystemExit('%s is not a VTS IFO (exit 2)' % ifo_path)
    pgcit = struct.unpack_from('>I', b, 0xCC)[0] * SECTOR
    nr = struct.unpack_from('>H', b, pgcit)[0]
    if not 1 <= pgc_no <= nr:
        raise SystemExit('VTS declares %d title PGC(s); %d asked for (exit 2)' % (nr, pgc_no))
    q = pgcit + struct.unpack_from('>I', b, pgcit + 8 + 8 * (pgc_no - 1) + 4)[0]

    def fix(x):
        return int(x * (1 << 10) + 0.5)

    def clip(v):
        return 0 if v < 0 else 255 if v > 255 else v

    out = []
    for i in range(16):
        y, cr, cb = b[q + 0xA4 + 4 * i + 1:q + 0xA4 + 4 * i + 4]
        cb -= 128
        cr -= 128
        r_add = fix(1.40200 * 255.0 / 224.0) * cr + (1 << 9)
        g_add = -fix(0.34414 * 255.0 / 224.0) * cb - fix(0.71414 * 255.0 / 224.0) * cr + (1 << 9)
        b_add = fix(1.77200 * 255.0 / 224.0) * cb + (1 << 9)
        yy = (y - 16) * fix(255.0 / 219.0)
        out.append('%02x%02x%02x' % (clip((yy + r_add - 1024) >> 10), clip((yy + g_add - 1024) >> 10),
                                     clip((yy + b_add - 1024) >> 10)))
    return 'palette: ' + ', '.join(out)


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

    ⚠ A NAV PACK IS NOT ALWAYS JUST PCI+DSI. The first pack of every VOB (every VOB_ID, not just
    every .VOB file) additionally carries a SYSTEM HEADER, stream id 0xBB - required by the
    DVD-Video spec. This walk used to `return None` on any id that was not 0xBF, so it declared
    the first pack of each VOB "not a NAV pack" and aborted with "lost VOBU sync" before emitting
    a single sector. Measured on The League of Gentlemen Series 2 Disk 1 VTS_07 (2026-09-03):
    sector 0 is `pack | 0xBB len 18 | 0xBF sub 0x00 (PCI) | 0xBF sub 0x01 (DSI)`, and the walk
    failed at sector 0 for angle 1 and at sector 372 for angle 2 - which are exactly where VOB_ID
    1 and VOB_ID 2 begin. So SKIP the ids that legally precede the DSI and bail only on a real
    media stream, which is what actually proves a pack is not a NAV pack.
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
        # 0xBB system header (first pack of a VOB), 0xBF sub 0x00 (the PCI that precedes the DSI),
        # 0xBE padding - all legal ahead of the DSI. Anything else is video/audio/subpicture data,
        # so this pack really is not a NAV pack.
        if sid not in (0xBB, 0xBE, 0xBF):
            return None
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
    ifo = os.path.join(video_ts, 'VTS_%02d_0.IFO' % vtsn)
    if '--palette' in a:
        print(pgc_palette_line(ifo, pgcn))
        return 0
    cells, pgc_secs, fps = pgc_table(ifo, pgcn)
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
    # The carve cannot carry the PGC's subtitle palette (see the header); its sidecar does.
    pal = pgc_palette_line(ifo, pgcn)
    with open(out + '.palette.txt', 'w', newline='\n') as fp:
        fp.write(pal + '\n')
    print('  -> %s.palette.txt  (VTS_%02d PGC %d subtitle palette)' % (out, vtsn, pgcn))
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except SystemExit as e:
        if isinstance(e.code, str):
            sys.stderr.write(e.code + '\n')
            sys.exit(2)
        raise
