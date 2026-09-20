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

  ⚠ THE TWO DOMAINS HAVE SEPARATE SECTOR SPACES, AND MIXING THEM YIELDS PLAUSIBLE GARBAGE.
  Title-domain cell sectors are numbered from the first sector of VTS_xx_1.VOB, and VTS_xx_0.VOB
  (the menu domain) is NOT part of that space. Menu-domain cell sectors are numbered from the first
  sector of VTS_xx_0.VOB, and the numbered VOBs are NOT part of THAT space. `--menu` switches both
  the PGC table that is read and the VOB set the sectors are resolved against, together — they are
  never independently selectable, because either half alone is wrong.

The IFO arithmetic is the SAME as prove-dvd-mapping.py's vts_title_ranges(); this adds the
sector -> (file, offset) mapping across the numbered VOBs, and indexes PGCs directly rather than
through VTS_PTT_SRPT (a still-set PGC is often not any title's entry PGC).

MENU-DOMAIN STILL SETS (`--menu`) — A GALLERY NO TITLE-LEVEL SWEEP CAN SEE
-------------------------------------------------------------------------
A gallery is sometimes authored not as a title at all but as N still MENUS: consecutive PGCs in
VTSM_PGCI_UT, one program / one cell each, advanced by the remote's NEXT button, with the
navigation captions ("BACK / EXTRAS MENU / NEXT") burned into the picture. Such a set is absent
from TT_SRPT entirely, so:

  * MakeMKV cannot see it at ANY --minlength - it is not a title, so no floor reaches it;
  * `ffmpeg -f dvdvideo -title N` cannot address it - there is no N;
  * scan-disc.ps1, audit-bd-titles.ps1 and the per-unit gate's "every title accounted for" all
    pass with the gallery missing, because every TITLE really is accounted for.

The only witness is the disc's own EXTRAS menu naming it. Survivors Series 2 Disk 4 (2026-09-03)
is the first: VTS_01 menu PGCs 12..31, sectors 47060..48982, 20 stills, and the disc's gate was
otherwise green. When a menu names an extra you cannot find as a title, look here.

SUCH A SET IS SELF-DELIMITING, AND THAT IS THE COMPLETENESS PROOF. The first page has no BACK
button and the last has no NEXT; the pages between have both. So the extent of the set is stated
by the source pixels, not inferred from where the PGC numbers happen to stop - run `--list` to
find the consecutive run, then read the first and last frames and confirm the buttons.

ONE CELL DECODES TO EXACTLY ONE FRAME, so the still count IS the cell count and cannot drift:

  ffmpeg -v error -i cell001.vob -fps_mode passthrough -frames:v 1 \
         -vf "scale=1024:576:flags=lanczos,setsar=1" s001.png

  ⚠ CHECK FOR A TERMINATOR before shipping. On Farscape S5 D2 the LAST cell of all eighteen sets
  repeated the penultimate picture byte-for-byte. Hash the frames per set; drop a trailing
  duplicate, but ABORT rather than drop blind if a set does not have that shape.

THE VIDEO-MANAGER MENU DOMAIN (`--vmgm`) — THE THIRD SECTOR SPACE
-----------------------------------------------------------------
There is a third place a gallery can live, and it defeats `--menu` as thoroughly as `--menu`
defeats a title sweep: the VIDEO MANAGER's own menu domain. Its PGCs are in VIDEO_TS.IFO's
VMGM_PGCI_UT and its cells are addressed against VIDEO_TS.VOB, so a disc can carry galleries while
its title sets have no VTSM_VOB at all - `--menu vts=1` then fails with "no VTS_01_0.VOB", which
reads like "no such content" and is not.

The Water Margin's 13-disc box set is authored this way throughout (2026-09-20): 26 per-disc
picture galleries and a shared 55-page Character Profiles / Episode Synopses / Production Notes
compendium, none reachable, and so 51.3 GB of staging that could not be released - an unbuilt
gallery must refuse the source delete, because the staging may be the only place it can be built
from. Taxi Driver's 297-page interactive screenplay is the same shape.

USAGE
    python dvd-still-cells.py [--menu] <VIDEO_TS dir> <vts number> <out dir> <pgc,pgc,...>
    python dvd-still-cells.py [--menu] <VIDEO_TS dir> <vts number> --list
    python dvd-still-cells.py --vmgm   <VIDEO_TS dir> <out dir> <pgc,pgc,...>
    python dvd-still-cells.py --vmgm   <VIDEO_TS dir> --list

    --menu   read VTSM_PGCI_UT (the VTS MENU domain) instead of VTS_PGCIT (the TITLE domain), and
             resolve cell sectors against VTS_xx_0.VOB instead of VTS_xx_1..9.VOB.
    --vmgm   read VMGM_PGCI_UT (the VIDEO MANAGER menu domain) out of VIDEO_TS.IFO, and resolve
             cell sectors against VIDEO_TS.VOB. Takes NO vts number - there isn't one.
"""
import os
import re
import struct
import sys

SECTOR = 2048          # DVD-Video logical sector size


def _read_ifo(ifo_path, magic=b'DVDVIDEO-VTS'):
    with open(ifo_path, 'rb') as fh:
        b = fh.read()
    if b[:12] != magic:
        raise SystemExit('%s is not a %s IFO (magic %r)'
                         % (ifo_path, magic.decode('latin-1')[9:], b[:12]))
    return b


def _cells_from_pgcit(b, pgcit, label):
    """{pgc_number: [(first_sector,last_sector), ...]} from ONE PGCIT at byte offset `pgcit`.

    The PGCIT layout is identical in both domains - only where you find it differs - so the two
    public functions below share this and cannot drift apart in their cell arithmetic.
    """
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
                raise SystemExit('%s PGC %d cell %d: last sector < first' % (label, i + 1, c + 1))
            cells.append((first, last))
        out[i + 1] = cells
    return out


def pgc_cells(ifo_path):
    """{pgc_number: [(first_sector, last_sector), ...]} for one VTS's TITLE domain."""
    b = _read_ifo(ifo_path)
    return _cells_from_pgcit(b, struct.unpack_from('>I', b, 0xCC)[0] * SECTOR, 'title')


def _cells_from_pgci_ut(b, ut_sec, table, label, where):
    """Cells out of a PGCI_UT - a LANGUAGE UNIT TABLE wrapping an ordinary PGCIT.

    VTSM_PGCI_UT and VMGM_PGCI_UT have the SAME shape; only the pointer's offset in the IFO's
    header and the VOB set the sectors resolve against differ. Shared so the two domains cannot
    drift apart in their language-unit arithmetic, exactly as _cells_from_pgcit is shared for the
    cell arithmetic beneath it.

    Only the FIRST language unit is read. A multi-language disc repeats the same menu PGCs per
    language, so silently merging the units would double every still; refusing is the safe default
    and no disc met so far needs the second unit.
    """
    if ut_sec == 0:
        raise SystemExit('%s declares no %s - it has no %s domain' % (where, table, label))
    ut = ut_sec * SECTOR
    nr_lu = struct.unpack_from('>H', b, ut)[0]
    if nr_lu < 1:
        raise SystemExit('%s: %s declares %d language units' % (where, table, nr_lu))
    lang = b[ut + 8:ut + 10].decode('latin-1')
    lu = ut + struct.unpack_from('>I', b, ut + 8 + 4)[0]
    if nr_lu > 1:
        print('  note: %d %s language units; reading unit 1 (%r) only' % (nr_lu, label, lang))
    return _cells_from_pgcit(b, lu, label)


def menu_pgc_cells(ifo_path):
    """{pgc_number: [(first_sector, last_sector), ...]} for one VTS's MENU domain.

    VTSI_MAT+0xD0 is the VTSM_PGCI_UT sector pointer. Sectors are relative to VTSM_VOBS, i.e.
    VTS_xx_0.VOB.
    """
    b = _read_ifo(ifo_path)
    return _cells_from_pgci_ut(b, struct.unpack_from('>I', b, 0xD0)[0],
                               'VTSM_PGCI_UT', 'menu', ifo_path)


def vmgm_pgc_cells(ifo_path):
    """{pgc_number: [(first_sector, last_sector), ...]} for the disc's VMGM domain.

    THE THIRD DOMAIN, AND THE ONE THAT HAD NO READER. A gallery is sometimes authored not in a
    title set's menu domain but in the VIDEO MANAGER's - PGCs in VIDEO_TS.IFO's VMGM_PGCI_UT, with
    cells addressed against VIDEO_TS.VOB. The Water Margin's 13-disc box set is authored this way
    throughout: its VTS 1-5 have no VTSM_VOB at all, so `--menu` cannot even open them, and all 26
    per-disc picture galleries plus the shared 55-page compendium were unreachable. Taxi Driver's
    297-page interactive screenplay is the same shape. Before this, three works' staging could not
    be released, because an unbuilt gallery must refuse the source delete and there was no way to
    build it.

    VMGI_MAT+0xC8 is the VMGM_PGCI_UT sector pointer - the direct analogue of VTSI_MAT+0xD0. The
    table it points at is a language-unit table wrapping an ordinary PGCIT, identical in shape to
    the VTS menu domain's, which is why both go through _cells_from_pgci_ut.
    """
    b = _read_ifo(ifo_path, b'DVDVIDEO-VMG')
    return _cells_from_pgci_ut(b, struct.unpack_from('>I', b, 0xC8)[0],
                               'VMGM_PGCI_UT', 'vmgm', ifo_path)


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


def menu_vob_map(video_ts_dir, vtsn):
    """[(path, start_sector, n_sectors)] for the MENU domain: VTS_<vtsn>_0.VOB alone.

    VTSM_VOBS is exactly that one file, and it starts the menu sector space at 0. The numbered
    VOBs are deliberately excluded - see the module docstring.
    """
    p = os.path.join(video_ts_dir, 'VTS_%02d_0.VOB' % vtsn)
    if not os.path.exists(p):
        # SAY WHERE ELSE TO LOOK. This message reads like "there is no such content", and on The
        # Water Margin it was taken that way: the manifest agent concluded the galleries were
        # unreachable and marked the unit low-confidence, when they were sitting in the VIDEO
        # MANAGER's menu domain all along. A disc whose title sets have no menu VOB is exactly the
        # disc most likely to keep its menus in VMGM.
        extra = ''
        if os.path.exists(os.path.join(video_ts_dir, 'VIDEO_TS.VOB')):
            extra = ' - but VIDEO_TS.VOB exists, so try --vmgm (the video-manager menu domain)'
        raise SystemExit('no VTS_%02d_0.VOB in %s - this VTS has no menu VOB%s'
                         % (vtsn, video_ts_dir, extra))
    size = os.path.getsize(p)
    if size % SECTOR:
        raise SystemExit('%s is not a whole number of %d-byte sectors' % (p, SECTOR))
    return [(p, 0, size // SECTOR)]


def vmgm_vob_map(video_ts_dir):
    """[(path, start_sector, n_sectors)] for the VMGM domain: VIDEO_TS.VOB alone.

    VMGM_VOBS is exactly that one file and it starts the VMGM sector space at 0. A disc with no
    video manager menu has no VIDEO_TS.VOB at all, and then there is nothing here to carve - say
    so rather than resolving VMGM sectors against some other domain's VOBs, which is the mistake
    the module docstring's domain warning is about.
    """
    p = os.path.join(video_ts_dir, 'VIDEO_TS.VOB')
    if not os.path.exists(p):
        raise SystemExit('no VIDEO_TS.VOB in %s - this disc has no video-manager menu VOB'
                         % video_ts_dir)
    size = os.path.getsize(p)
    if size % SECTOR:
        raise SystemExit('%s is not a whole number of %d-byte sectors' % (p, SECTOR))
    return [(p, 0, size // SECTOR)]


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
    argv = sys.argv[1:]
    menu = vmgm = False
    if argv and argv[0] == '--menu':
        menu, argv = True, argv[1:]
    elif argv and argv[0] == '--vmgm':
        vmgm, argv = True, argv[1:]
    # THE VMGM DOMAIN HAS NO VTS NUMBER, so it does not take one. Requiring a placeholder would
    # invite passing a real VTS number that is then silently ignored - and a number that looks
    # honoured but is not is exactly how the two sector spaces get mixed.
    need = 2 if vmgm else 3
    if len(argv) < need:
        raise SystemExit(__doc__.strip().rsplit('USAGE', 1)[-1].strip())
    if vmgm:
        video_ts, vtsn, third = argv[0], None, argv[1]
    else:
        video_ts, vtsn, third = argv[0], int(argv[1]), argv[2]
    # The PGC table and the VOB set are chosen together - see the docstring's domain warning.
    if vmgm:
        ifo = os.path.join(video_ts, 'VIDEO_TS.IFO')
        cells = vmgm_pgc_cells(ifo)
        parts = vmgm_vob_map(video_ts)
        domain = 'vmgm'
    else:
        ifo = os.path.join(video_ts, 'VTS_%02d_0.IFO' % vtsn)
        cells = menu_pgc_cells(ifo) if menu else pgc_cells(ifo)
        parts = (menu_vob_map if menu else title_vob_map)(video_ts, vtsn)
        domain = 'menu' if menu else 'title'
    total = sum(n for _, _, n in parts)
    where = 'VIDEO_TS' if vmgm else ('VTS_%02d' % vtsn)
    print('%s %s VOB set: %d sectors (%d bytes) across %d file(s)'
          % (where, domain, total, total * SECTOR, len(parts)))

    if third == '--list':
        for pgc in sorted(cells):
            cl = cells[pgc]
            if not cl:
                # Legal and common in the menu domain: a pure navigation/command PGC with no
                # cells at all. Show it rather than skipping, so the run of still PGCs is visibly
                # a run and not an artefact of what the listing chose to print.
                print('  PGC %-3d   0 cell(s)  (no cells - navigation/command PGC)' % pgc)
                continue
            print('  PGC %-3d %3d cell(s)  sectors %d..%d' % (pgc, len(cl), cl[0][0], cl[-1][1]))
        return

    if len(argv) < need + 1:
        raise SystemExit(__doc__.strip().rsplit('USAGE', 1)[-1].strip())
    outdir = third
    pgcspec = argv[need]
    # PGCs may be written as a list, a RANGE, or both: "3", "1,2,5", "1-26", "1-3,7,10-12".
    # A gallery's PGCs are contiguous and a manifest author writes them the obvious way; without this,
    # "1-26" died as ValueError: invalid literal for int() with base 10 - Robin of Sherwood Series 3
    # Disk 2 (2026-09-17) failed both its photo galleries that way, after the encode had already run.
    def parse_pgcs(spec):
        out = []
        for part in [p.strip() for p in spec.split(',') if p.strip()]:
            m = re.fullmatch(r'(\d+)\s*-\s*(\d+)', part)
            if m:
                lo, hi = int(m.group(1)), int(m.group(2))
                if hi < lo:
                    raise SystemExit('PGC range %s runs backwards' % part)
                out.extend(range(lo, hi + 1))
            elif part.isdigit():
                out.append(int(part))
            else:
                raise SystemExit('cannot read PGC list %r - use "3", "1,2,5", "1-26" or "1-3,7"' % spec)
        if not out:
            raise SystemExit('no PGCs given')
        return out

    for pgc in parse_pgcs(pgcspec):
        cl = cells.get(pgc)
        if cl is None:
            raise SystemExit('PGC %d is not declared by the %s %s domain' % (pgc, where, domain))
        d = os.path.join(outdir, 'pgc%02d' % pgc)
        os.makedirs(d, exist_ok=True)
        print('PGC %-3d %3d cell(s)  sectors %d..%d' % (pgc, len(cl), cl[0][0], cl[-1][1]))
        for i, (f, l) in enumerate(cl, start=1):
            with open(os.path.join(d, 'cell%03d.vob' % i), 'wb') as fh:
                fh.write(read_sectors(parts, f, l))


if __name__ == '__main__':
    main()
