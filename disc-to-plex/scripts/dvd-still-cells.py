#!/usr/bin/env python3
"""Carve a DVD still-set's cells straight out of the VTS VOB set, one .vob per cell.

WHY THIS EXISTS
---------------
A DVD still-set - a gallery, a character biography, an infopod page - is authored as a PGC whose
programs are cells of ~0.40 s each, advanced by the remote. Neither of the pipeline's two readers
can deliver one:

  * ffmpeg's dvdvideo demuxer REFUSES the title outright ("Title N, PGC N looks empty (may consist
    of padding cells), if you want to try anyway, disable the -trim option"), and with `-trim false`
    it opens the title but returns only its FIRST CELL - measured on Farscape S5 D2 (Peacekeeper
    Wars, 2026-08-30): titles 10, 12 and 13 each yielded exactly ONE frame, 0.04 s, against 20, 18
    and 23 cells declared. That is the first-cell truncation this project already documents for the
    demuxer, and no flag fixes it.
  * MakeMKV skips them as sub-floor (MSG:3025). No enumeration floor would ever surface them: they
    are short BY CONSTRUCTION.

But the disc STATES where every cell is. The IFO's cell playback table gives each cell's first and
last sector, and the cells are ordinary MPEG-PS inside the numbered VOBs, so the whole chain can be
read by sector arithmetic with no demuxer involved. That is what this does.

  ⚠ THE CELLS ARE IN THE TITLE DOMAIN, NOT THE MENU DOMAIN. Title-domain cell sectors are numbered
  from the first sector of VTS_xx_1.VOB, and VTS_xx_0.VOB (the menu domain) is NOT part of that
  space. Including it shifts every offset by the whole menu VOB and yields plausible garbage.

The IFO arithmetic is the SAME as prove-dvd-mapping.py's vts_title_ranges(); this adds the
sector -> (file, offset) mapping across the numbered VOBs, and indexes PGCs directly rather than
through VTS_PTT_SRPT (a still-set PGC is often not any title's entry PGC).

ONE CELL DECODES TO EXACTLY ONE FRAME, so the still count IS the cell count and cannot drift:

  ffmpeg -v error -i cell001.vob -fps_mode passthrough -frames:v 1 \
         -vf "scale=1024:576:flags=lanczos,setsar=1" s001.png

  ⚠ CHECK FOR A TERMINATOR before shipping. On Farscape S5 D2 the LAST cell of all eighteen sets
  repeated the penultimate picture byte-for-byte. Hash the frames per set; drop a trailing
  duplicate, but ABORT rather than drop blind if a set does not have that shape.

USAGE
    python dvd-still-cells.py <VIDEO_TS dir> <vts number> <out dir> <pgc,pgc,...>
    python dvd-still-cells.py <VIDEO_TS dir> <vts number> --list
"""
import os
import struct
import sys

SECTOR = 2048          # DVD-Video logical sector size


def pgc_cells(ifo_path):
    """{pgc_number: [(first_sector, last_sector), ...]} for one VTS's title domain."""
    with open(ifo_path, 'rb') as fh:
        b = fh.read()
    if b[:12] != b'DVDVIDEO-VTS':
        raise SystemExit('%s is not a VTS IFO' % ifo_path)
    pgcit = struct.unpack_from('>I', b, 0xCC)[0] * SECTOR
    nr_pgc = struct.unpack_from('>H', b, pgcit)[0]
    out = {}
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
                raise SystemExit('PGC %d cell %d: last sector < first' % (i + 1, c + 1))
            cells.append((first, last))
        out[i + 1] = cells
    return out


def title_vob_map(video_ts_dir, vtsn):
    """[(path, start_sector, n_sectors)] for VTS_<vtsn>_1..9.VOB, in order.

    VTS_xx_0.VOB is deliberately excluded - see the module docstring.
    """
    parts, at = [], 0
    for n in range(1, 10):
        p = os.path.join(video_ts_dir, 'VTS_%02d_%d.VOB' % (vtsn, n))
        if not os.path.exists(p):
            continue
        size = os.path.getsize(p)
        if size % SECTOR:
            raise SystemExit('%s is not a whole number of %d-byte sectors' % (p, SECTOR))
        parts.append((p, at, size // SECTOR))
        at += size // SECTOR
    if not parts:
        raise SystemExit('no VTS_%02d_n.VOB in %s' % (vtsn, video_ts_dir))
    return parts


def read_sectors(parts, first, last):
    """Bytes of sectors [first..last] inclusive, spanning VOB file boundaries."""
    buf = bytearray()
    for path, start, n in parts:
        end = start + n
        if last + 1 <= start or first >= end:
            continue
        a, z = max(first, start), min(last + 1, end)
        with open(path, 'rb') as fh:
            fh.seek((a - start) * SECTOR)
            chunk = fh.read((z - a) * SECTOR)
        if len(chunk) != (z - a) * SECTOR:
            raise SystemExit('short read in %s at sector %d' % (path, a))
        buf += chunk
    want = (last - first + 1) * SECTOR
    if len(buf) != want:
        # Never emit a partial cell: it would decode to a plausible-looking frame.
        raise SystemExit('sectors %d-%d fall outside the VTS_%s title VOB set'
                         % (first, last, os.path.basename(parts[0][0])[4:6]))
    return bytes(buf)


def main():
    if len(sys.argv) < 4:
        raise SystemExit(__doc__.strip().rsplit('USAGE', 1)[-1].strip())
    video_ts, vtsn, third = sys.argv[1], int(sys.argv[2]), sys.argv[3]
    cells = pgc_cells(os.path.join(video_ts, 'VTS_%02d_0.IFO' % vtsn))
    parts = title_vob_map(video_ts, vtsn)
    total = sum(n for _, _, n in parts)
    print('VTS_%02d title VOB set: %d sectors (%d bytes) across %d file(s)'
          % (vtsn, total, total * SECTOR, len(parts)))

    if third == '--list':
        for pgc in sorted(cells):
            cl = cells[pgc]
            print('  PGC %-3d %3d cell(s)  sectors %d..%d' % (pgc, len(cl), cl[0][0], cl[-1][1]))
        return

    outdir = third
    for pgc in [int(x) for x in sys.argv[4].split(',')]:
        cl = cells.get(pgc)
        if cl is None:
            raise SystemExit('PGC %d is not declared by VTS_%02d' % (pgc, vtsn))
        d = os.path.join(outdir, 'pgc%02d' % pgc)
        os.makedirs(d, exist_ok=True)
        print('PGC %-3d %3d cell(s)  sectors %d..%d' % (pgc, len(cl), cl[0][0], cl[-1][1]))
        for i, (f, l) in enumerate(cl, start=1):
            with open(os.path.join(d, 'cell%03d.vob' % i), 'wb') as fh:
                fh.write(read_sectors(parts, f, l))


if __name__ == '__main__':
    main()
