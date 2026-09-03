#!/usr/bin/env python3
"""Turn a set of carved DVD still cells into ONE video-only library item.

WHY THIS EXISTS
---------------
`dvd-still-cells.py` carves a still set out of the VOBs, one `.vob` per cell. What it leaves you
with is N single-frame files, and the library rule (`references/naming.md`, "Gallery stills: ship
ONE item, not N fragments") says those must ship as a single extra. Doing that by hand went wrong
in three specific ways, and each of them is now a refusal in here rather than a thing to remember:

  1. **DUPLICATE PAGES.** A disc often re-authors the same still set several times over - one
     re-authoring per entry point into it. The League of Gentlemen Series 1 (2026-09-03) carries
     its 35 character-biography pages TWICE: menu PGCs 23-57, and again across PGCs 111-181 with
     individual pages repeated up to ELEVEN times. Carving the whole run ships 71 pages for 35
     stills and every structural check passes. So: render, SHA-256 every frame, and ABORT on a
     repeat unless the caller says what to do about it.
  2. **A TERMINATOR CELL.** On Farscape S5 D2 the last cell of all eighteen sets repeated the
     penultimate picture byte-for-byte. `--drop-terminator` removes exactly that shape (a final
     frame equal to its immediate predecessor, nothing else) and refuses if the set is not that
     shape - never a blind drop.
  3. **THE MENU'S BUTTON-HIGHLIGHT SUBPICTURE.** Every menu cell carries `dvd_subtitle` streams
     that are the highlight overlay, not subtitles. Ship them and the library gains a bitmap
     "English subtitle" that routes the file into the OCR queue to OCR a menu button. This encodes
     `-an -sn`, unconditionally: a still set has nothing else to carry.

The per-still DWELL is not a taste decision - measure the library's existing galleries and pass
what you measure (`--dwell`). There is no default, deliberately.

The source SAR is read from the cells and re-applied to the output, because a PNG round-trip
loses it and a 16:9 menu written as 4:3 is a wrong-shaped picture that still passes every check.

USAGE
    python build-still-slideshow.py <cells dir> <out .mkv> --pgcs 23-57 --dwell 5.0
        [--fps 25] [--drop-terminator] [--allow-duplicates] [--keep-frames DIR] [--dry-run]

    <cells dir>   the directory `dvd-still-cells.py` wrote: one `pgcNN/cell001.vob` per still.
    --pgcs        inclusive ranges and/or singletons, e.g. `23-57` or `12,14,16-20`. Order is
                  the order given, which is the order the disc's NEXT button walks.

Exit codes: 0 = OK, 2 = refused (structure, duplicate, or a post-encode count mismatch).
"""
import hashlib
import json
import os
import subprocess
import sys


def tools():
    """ffmpeg/ffprobe from the pipeline's own pinned build, never whatever is on PATH."""
    cfg = 'D:/video/.transcode-tools/tool-paths.json'
    if os.path.exists(cfg):
        ff = json.load(open(cfg))['ffmpeg'].replace('\\', '/')
        return ff, os.path.join(os.path.dirname(ff), 'ffprobe.exe').replace('\\', '/')
    return 'ffmpeg', 'ffprobe'


FF, FP = tools()


def parse_pgcs(spec):
    out = []
    for part in spec.split(','):
        part = part.strip()
        if '-' in part:
            a, b = part.split('-')
            out.extend(range(int(a), int(b) + 1))
        elif part:
            out.append(int(part))
    return out


def cell_path(cells_dir, pgc):
    d = os.path.join(cells_dir, 'pgc%02d' % pgc)
    p = os.path.join(d, 'cell001.vob')
    if not os.path.exists(p):
        raise SystemExit('ERROR: %s not found - carve it with dvd-still-cells.py first (exit 2)' % p)
    extra = [f for f in sorted(os.listdir(d)) if f.endswith('.vob') and f != 'cell001.vob']
    if extra:
        # A still page is one cell. More than one means this PGC is not a still page at all,
        # and taking only its first cell would silently ship a fragment of something else.
        raise SystemExit('ERROR: PGC %d has %d cells (%s) - not a single-cell still page; '
                         'refusing (exit 2)' % (pgc, len(extra) + 1, ', '.join(extra[:3])))
    return p


def probe_sar(path):
    out = subprocess.run([FP, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                          'stream=sample_aspect_ratio,width,height,field_order',
                          '-of', 'default=noprint_wrappers=1:nokey=0', path],
                         capture_output=True, text=True).stdout
    d = dict(l.split('=', 1) for l in out.strip().splitlines() if '=' in l)
    return d


def render(vob, png):
    r = subprocess.run([FF, '-v', 'error', '-y', '-i', vob, '-fps_mode', 'passthrough',
                        '-frames:v', '1', png], capture_output=True, text=True)
    if r.returncode != 0 or not os.path.exists(png):
        raise SystemExit('ERROR: could not render a frame from %s: %s (exit 2)' % (vob, r.stderr[:300]))


def main():
    a = sys.argv[1:]
    if len(a) < 2:
        raise SystemExit(__doc__.strip().rsplit('USAGE', 1)[-1].strip())
    cells_dir, out = a[0], a[1]
    spec = dwell = None
    fps = 25.0
    drop_term = allow_dup = dry = False
    keep = None
    i = 2
    while i < len(a):
        if a[i] == '--pgcs':
            spec = a[i + 1]; i += 2
        elif a[i] == '--dwell':
            dwell = float(a[i + 1]); i += 2
        elif a[i] == '--fps':
            fps = float(a[i + 1]); i += 2
        elif a[i] == '--keep-frames':
            keep = a[i + 1]; i += 2
        elif a[i] == '--drop-terminator':
            drop_term = True; i += 1
        elif a[i] == '--allow-duplicates':
            allow_dup = True; i += 1
        elif a[i] == '--dry-run':
            dry = True; i += 1
        else:
            raise SystemExit('unknown argument %r' % a[i])
    if not spec or dwell is None:
        raise SystemExit('--pgcs and --dwell are both required (--dwell has no default on purpose)')

    pgcs = parse_pgcs(spec)
    work = keep or (os.path.splitext(out)[0] + '.frames')
    os.makedirs(work, exist_ok=True)

    sar = None
    frames, hashes = [], []
    for pgc in pgcs:
        vob = cell_path(cells_dir, pgc)
        info = probe_sar(vob)
        if sar is None:
            sar = info.get('sample_aspect_ratio', '1:1')
            geom = (info.get('width'), info.get('height'))
        elif info.get('sample_aspect_ratio') != sar or (info.get('width'), info.get('height')) != geom:
            raise SystemExit('ERROR: PGC %d is %sx%s SAR %s, the set is %sx%s SAR %s - refusing '
                             'to mix geometries (exit 2)'
                             % (pgc, info.get('width'), info.get('height'),
                                info.get('sample_aspect_ratio'), geom[0], geom[1], sar))
        # ABSOLUTE: the concat demuxer resolves a relative `file` against the LIST's directory,
        # so a relative path here silently becomes <work>/<work>/p023.png.
        png = os.path.abspath(os.path.join(work, 'p%03d.png' % pgc)).replace('\\', '/')
        render(vob, png)
        frames.append((pgc, png))
        hashes.append(hashlib.sha256(open(png, 'rb').read()).hexdigest())

    # --- duplicate / terminator gates -------------------------------------------------
    if drop_term:
        if len(hashes) >= 2 and hashes[-1] == hashes[-2]:
            print('  terminator: PGC %d repeats PGC %d - dropped' % (frames[-1][0], frames[-2][0]))
            frames, hashes = frames[:-1], hashes[:-1]
        else:
            raise SystemExit('ERROR: --drop-terminator given but the last frame does not repeat '
                             'the one before it - refusing to drop blind (exit 2)')
    seen = {}
    dups = []
    for (pgc, _), h in zip(frames, hashes):
        if h in seen:
            dups.append((pgc, seen[h]))
        else:
            seen[h] = pgc
    if dups and not allow_dup:
        raise SystemExit('ERROR: %d of %d pages are pixel-duplicates of earlier ones '
                         '(e.g. PGC %d == PGC %d). A disc often re-authors a still set several '
                         'times; carve the FIRST run only, or pass --allow-duplicates if the '
                         'repeat is really part of the item (exit 2)'
                         % (len(dups), len(frames), dups[0][0], dups[0][1]))
    if dups:
        print('  NOTE: %d duplicate page(s) kept at the caller\'s request' % len(dups))

    n = len(frames)
    per = int(round(dwell * fps))
    total = n * per
    print('%d still(s), %s SAR %s, dwell %.4f s = %d frame(s) at %g fps -> %d frames / %.3f s'
          % (n, 'x'.join(geom), sar, per / fps, per, fps, total, total / fps))
    print('  pages: %s' % ','.join(str(p) for p, _ in frames))
    if dry:
        return 0

    listfile = os.path.join(work, 'concat.txt')
    with open(listfile, 'w', encoding='utf-8') as fh:
        for _, png in frames:
            fh.write("file '%s'\nduration %.6f\n" % (png, per / fps))
        # The concat demuxer ignores the LAST entry's duration; repeating the file gives the
        # final still its full dwell instead of a single frame.
        fh.write("file '%s'\n" % frames[-1][1])

    sar_f = sar.replace(':', '/')
    os.makedirs(os.path.dirname(os.path.abspath(out)) or '.', exist_ok=True)
    cmd = [FF, '-v', 'error', '-y', '-f', 'concat', '-safe', '0', '-i', listfile,
           '-vf', 'fps=%g,setsar=%s,format=yuv420p' % (fps, sar_f),
           '-frames:v', str(total),
           '-c:v', 'h264_nvenc', '-preset', 'medium', '-rc', 'vbr', '-cq', '20', '-b:v', '0',
           '-an', '-sn', '-map_metadata', '-1', out]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        raise SystemExit('ERROR: encode failed: %s (exit 2)' % r.stderr[-800:])

    # --- post-encode verification: COUNT, never read the declaration ------------------
    got = subprocess.run([FP, '-v', 'error', '-select_streams', 'v:0', '-count_packets',
                          '-show_entries', 'stream=nb_read_packets,width,height,'
                          'sample_aspect_ratio,display_aspect_ratio',
                          '-show_entries', 'format=duration', '-of',
                          'default=noprint_wrappers=1', out], capture_output=True, text=True).stdout
    d = dict(l.split('=', 1) for l in got.strip().splitlines() if '=' in l)
    packets = int(d.get('nb_read_packets', -1))
    streams = subprocess.run([FP, '-v', 'error', '-show_entries', 'stream=codec_type',
                              '-of', 'csv=p=0', out], capture_output=True, text=True).stdout.split()
    print('  -> %s' % out)
    print('     packets %d (expected %d), duration %s s, %sx%s SAR %s DAR %s, streams: %s'
          % (packets, total, d.get('duration'), d.get('width'), d.get('height'),
             d.get('sample_aspect_ratio'), d.get('display_aspect_ratio'), ','.join(streams)))
    if packets != total:
        raise SystemExit('ERROR: packet count %d != expected %d - refusing (exit 2)' % (packets, total))
    if [s for s in streams if s.strip(',') != 'video']:
        raise SystemExit('ERROR: output is not video-only: %s (exit 2)' % streams)
    print('  self-check OK: frame-exact, video-only')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except SystemExit as e:
        # `raise SystemExit('message')` exits 1, which is indistinguishable from a crash. Every
        # refusal in here is a deliberate one, so map it to the documented 2.
        if isinstance(e.code, str):
            sys.stderr.write(e.code + '\n')
            sys.exit(2)
        raise
