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
     penultimate picture byte-for-byte. On Fight Club Disk 2 (2026-09-04) all 21 title-domain sets
     instead end in a BLACK cell after a picture page - a genuine 10,240-byte VOB carrying one
     video packet that decodes to a 720x576 rgb24 PNG, so it is a real decode being correctly
     excluded, not an empty file. `--drop-terminator` removes EITHER of those two shapes and
     nothing else - a final frame equal to its immediate predecessor, or a final frame that is
     UNIFORM BLACK - and refuses if the set is neither shape. Never a blind drop.
  3. **THE MENU'S BUTTON-HIGHLIGHT SUBPICTURE.** Every menu cell carries `dvd_subtitle` streams
     that are the highlight overlay, not subtitles. Ship them and the library gains a bitmap
     "English subtitle" that routes the file into the OCR queue to OCR a menu button. This encodes
     `-an -sn`, unconditionally: a still set has nothing else to carry.

The per-still DWELL is not a taste decision - measure the library's existing galleries and pass
what you measure (`--dwell`). There is no default, deliberately.

The source SAR is read from the cells and re-applied to the output, because a PNG round-trip
loses it and a 16:9 menu written as 4:3 is a wrong-shaped picture that still passes every check.

  ⚠ THE CELLS ARE NOT ALWAYS RIGHT ABOUT IT, AND THE TITLE DOMAIN IS WHERE THEY LIE. A DVD player
  takes a title's aspect from the IFO's VTS video attribute, never from the elementary stream, so
  an authoring tool can leave the MPEG sequence header saying 4:3 in a 16:9 title and no player
  ever notices. Fight Club Disk 2 (2026-09-04) is exactly that: VTS_38..58 declare 0x5d00 = 16:9
  in the IFO while every carved cell's sequence header says 4:3 (SAR 16:15) - measured on all 21.
  Built from the cells, a storyboard sheet came out 0.57 wide-to-tall against US Letter's 0.773,
  and a production still came out nearly square. Its MENU cells, by contrast, declare 64:45 = 16:9
  correctly, so this is not a reader problem. Pass `--dar 16:9` to state the IFO's answer; the
  build then prints both figures so the override is on the record rather than silent.

THE TWO DOMAINS AUTHOR A STILL SET IN OPPOSITE SHAPES - `--pgcs` vs `--title-set`
---------------------------------------------------------------------------------
  * MENU domain (`--pgcs`): each page is its OWN PGC carrying exactly ONE cell, advanced by the
    remote's NEXT button. Survivors S2 D4, League of Gentlemen S1, Fight Club Disk 2's cast
    biographies are all this shape.
  * TITLE domain (`--title-set`): the whole set is ONE PGC whose N CELLS are the N pages. Fight
    Club Disk 2's 21 galleries are 8..99 cells inside a single PGC 1 apiece, and `dvd-still-cells.py`
    writes them as `pgc01/cell001.vob .. cell099.vob`.

They are not interchangeable, and taking only `cell001.vob` of a title-domain PGC ships ONE page
of a 99-page gallery at the right geometry - so `cell_path()` REFUSES a multi-cell PGC dir under
`--pgcs`, and `--title-set` is the deliberate, separate way in. Neither mode ever guesses.

USAGE
    python build-still-slideshow.py <cells dir> <out .mkv> --pgcs 23-57 --dwell 5.0
        [--fps 25] [--drop-terminator] [--allow-duplicates] [--keep-frames DIR] [--dry-run]
    python build-still-slideshow.py <cells dir> <out .mkv> --title-set 1 --dwell 3.4 ...

    <cells dir>   the directory `dvd-still-cells.py` wrote: `pgcNN/cellNNN.vob`.
    --pgcs        MENU-domain shape: inclusive ranges and/or singletons, e.g. `23-57` or
                  `12,14,16-20`. ONE page per PGC, and a PGC dir holding more than one cell is
                  refused. Order is the order given, which is the order the NEXT button walks.
    --title-set   TITLE-domain shape: the same range/singleton syntax, but each entry names a PGC
                  dir whose CELLS are the pages, taken in cell order. Several PGC dirs may be
                  given (`--title-set 38,39,40`) when the disc splits one gallery across several
                  title sets; the pages of each follow the pages of the last, in the order given.
    --dar         the DISPLAY aspect the disc's IFO declares for this set, e.g. `16:9`. The output
                  SAR is computed from it and the measured geometry, INSTEAD of the SAR the cells
                  declare. Use it only when the IFO and the cells disagree and the IFO is right -
                  which is checkable by eye on any page holding a known-shaped object.
    --keep-frames keep the rendered pages in DIR (for looking at them). WITHOUT it the pages go
                  to a temp dir that is removed - deliberately NOT a directory derived from
                  `out`, because that lands inside the work folder and publish-work.ps1 copies
                  the whole folder to the NAS, which this pipeline may never clean up.

Exit codes: 0 = OK, 2 = refused (structure, duplicate, or a post-encode count mismatch).
"""
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile


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
    """MENU-domain page: PGC `pgc` must hold exactly one cell, and that cell IS the page."""
    d = os.path.join(cells_dir, 'pgc%02d' % pgc)
    p = os.path.join(d, 'cell001.vob')
    if not os.path.exists(p):
        raise SystemExit('ERROR: %s not found - carve it with dvd-still-cells.py first (exit 2)' % p)
    extra = [f for f in sorted(os.listdir(d)) if f.endswith('.vob') and f != 'cell001.vob']
    if extra:
        # A MENU-domain still page is one cell. More than one means this PGC is not a menu still
        # page at all, and taking only its first cell would silently ship a fragment of something
        # else. If the set is a TITLE-domain one PGC / N cells gallery, say so with --title-set:
        # that is a different authoring shape, not a laxer reading of this one.
        raise SystemExit('ERROR: PGC %d has %d cells (%s) - not a single-cell still page. If this '
                         'is a TITLE-domain set (one PGC whose cells are the pages), pass '
                         '--title-set %d instead of --pgcs; refusing (exit 2)'
                         % (pgc, len(extra) + 1, ', '.join(extra[:3]), pgc))
    return p


CELL_RE = re.compile(r'^cell(\d{3})\.vob$')


def title_set_pages(cells_dir, pgc):
    """TITLE-domain set: EVERY cell of PGC `pgc`, in cell order - each cell is one page.

    Returns [(label, vob path)]. The label carries both the PGC and the cell so the printed page
    list, the duplicate report and the terminator message all name a page the caller can go and
    look at, exactly as the menu mode's PGC number does.
    """
    d = os.path.join(cells_dir, 'pgc%02d' % pgc)
    if not os.path.isdir(d):
        raise SystemExit('ERROR: %s not found - carve it with dvd-still-cells.py first (exit 2)' % d)
    cells = sorted(f for f in os.listdir(d) if CELL_RE.match(f))
    if not cells:
        raise SystemExit('ERROR: %s holds no cellNNN.vob - nothing to build (exit 2)' % d)
    # Zero-padded to 3 digits by dvd-still-cells.py, so lexical order IS cell order; assert it
    # rather than trust it, because a re-numbered or hand-copied dir would sort wrong in silence.
    nums = [int(CELL_RE.match(f).group(1)) for f in cells]
    if nums != list(range(1, len(nums) + 1)):
        raise SystemExit('ERROR: %s cells are not the contiguous run 1..%d (found %s) - the page '
                         'order would be a guess; refusing (exit 2)'
                         % (d, len(nums), ','.join(str(n) for n in nums[:6])))
    return [('pgc%d/cell%03d' % (pgc, n), os.path.join(d, f)) for n, f in zip(nums, cells)]


def gray_bytes(png):
    """The rendered page decoded to raw gray8.

    ffmpeg rather than a Python imaging library: ffmpeg is already this pipeline's pinned
    dependency and no other script here needs PIL.
    """
    r = subprocess.run([FF, '-v', 'error', '-i', png, '-vf', 'format=gray',
                        '-f', 'rawvideo', '-'], capture_output=True)
    if r.returncode != 0 or not r.stdout:
        raise SystemExit('ERROR: could not decode %s to gray: %s (exit 2)'
                         % (png, r.stderr.decode('utf-8', 'replace')[:300]))
    return r.stdout


def black_probe(png):
    """(is_uniform_black, lo, hi, nbytes) for one rendered page.

    Uniform black = every luma <= 16 with a spread of <= 2. Deliberately strict: a DARK PICTURE is
    not a terminator, and "the last page looked black" is exactly the blind drop --drop-terminator
    exists to prevent. The byte count comes back with it and is asserted, so an EMPTY decode can
    never be read as a black page.
    """
    b = gray_bytes(png)
    lo, hi = min(b), max(b)
    return (len(b) > 0 and hi <= 16 and hi - lo <= 2), lo, hi, len(b)


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
    spec = tspec = dwell = dar = None
    fps = 25.0
    drop_term = allow_dup = dry = False
    keep = None
    i = 2
    while i < len(a):
        if a[i] == '--pgcs':
            spec = a[i + 1]; i += 2
        elif a[i] == '--title-set':
            tspec = a[i + 1]; i += 2
        elif a[i] == '--dwell':
            dwell = float(a[i + 1]); i += 2
        elif a[i] == '--fps':
            fps = float(a[i + 1]); i += 2
        elif a[i] == '--dar':
            dar = a[i + 1]; i += 2
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
    if spec and tspec:
        raise SystemExit('--pgcs and --title-set are the two AUTHORING SHAPES a still set can have '
                         '(one cell per PGC vs one PGC of N cells) - give exactly one (exit 2)')
    if not (spec or tspec) or dwell is None:
        raise SystemExit('one of --pgcs / --title-set, and --dwell, are required '
                         '(--dwell has no default on purpose)')

    pgcs = parse_pgcs(tspec if tspec else spec)
    if not pgcs:
        raise SystemExit('%s %r selected no page at all (exit 2)'
                         % ('--title-set' if tspec else '--pgcs', tspec or spec))

    # Resolve the pages HERE as a list of CHAINS, so `build()` below is identical for both shapes
    # and there is exactly one code path from "pages" to "encode".
    #
    # A CHAIN is one separately-authored run of pages, and it is what `--drop-terminator` examines.
    # `--pgcs` walks ONE chain (the disc's NEXT button runs the whole PGC range end to end), so it
    # yields a single chain and the old behaviour is unchanged. `--title-set` yields one chain PER
    # TITLE SET, because each title set is its own authored chain WITH ITS OWN TERMINATOR: Fight
    # Club Disk 2's storyboard gallery is three title sets of 99/99/72 cells and all THREE end in a
    # black cell. Treating the combination as one chain would drop only the last of the three and
    # ship two black pages in the middle of the gallery.
    chains = []
    for pgc in pgcs:
        if tspec:
            chains.append(title_set_pages(cells_dir, pgc))
        else:
            chains.append([('pgc%d' % pgc, cell_path(cells_dir, pgc))])
    if not tspec:
        chains = [[p for c in chains for p in c]]

    # THE FRAME SCRATCH MUST NOT BE DERIVED FROM `out`. It used to default to
    # `os.path.splitext(out)[0] + '.frames'`, i.e. a directory INSIDE the work folder - and
    # `publish-work.ps1` copies the WHOLE work folder with robocopy /E, while `.png` is an
    # allowed library artefact (lib-artefact-types.ps1). So every page of every set would have
    # been published into the NAS Season 00 folder alongside the .mkv, and nothing in this
    # pipeline may delete from the NAS: each one becomes a hand-removal chore for the user.
    # That is exactly the trap CLAUDE.md names - a derived path written from an OUTPUT path.
    # Default to a real temp dir and remove it; `--keep-frames DIR` opts back in explicitly.
    work = keep or tempfile.mkdtemp(prefix='stills-')
    os.makedirs(work, exist_ok=True)
    try:
        return build(out, chains, dwell, fps, dar, drop_term, allow_dup, dry, work)
    finally:
        if not keep:
            shutil.rmtree(work, ignore_errors=True)


def drop_terminator(chain, hashes):
    """Remove the terminator page of ONE chain, or refuse. Returns (chain, hashes).

    The only two shapes accepted are the two that have been MEASURED on real discs: a final frame
    byte-identical to its predecessor (Farscape S5 D2), and a final frame that is uniform black
    (Fight Club Disk 2). Anything else is a page, and dropping it would lose content silently.
    """
    if len(chain) < 2:
        raise SystemExit('ERROR: --drop-terminator given but chain %s has %d page(s) - dropping '
                         'would leave nothing; refusing (exit 2)'
                         % (chain[0][0] if chain else '<empty>', len(chain)))
    blk, lo, hi, nb = black_probe(chain[-1][1])
    if hashes[-1] == hashes[-2]:
        why = 'repeats %s' % chain[-2][0]
    elif blk:
        # Report the measured luma range and the decoded byte count, so the record shows a real
        # decode was examined rather than a missing or empty one.
        why = 'uniform black (luma %d..%d over %d decoded bytes)' % (lo, hi, nb)
    else:
        raise SystemExit('ERROR: --drop-terminator given but the last page of this chain (%s) is '
                         'neither a repeat of the one before it nor uniform black (luma %d..%d '
                         'over %d decoded bytes) - refusing to drop blind (exit 2)'
                         % (chain[-1][0], lo, hi, nb))
    print('  terminator: %s %s - dropped' % (chain[-1][0], why))
    return chain[:-1], hashes[:-1]


def sar_for_dar(dar, width, height):
    """The SAR that makes `width`x`height` display at `dar`, as an exact reduced fraction."""
    try:
        dw, dh = (int(x) for x in dar.replace('/', ':').split(':'))
    except ValueError:
        raise SystemExit('ERROR: --dar %r is not W:H (exit 2)' % dar)
    if dw <= 0 or dh <= 0:
        raise SystemExit('ERROR: --dar %r must be positive (exit 2)' % dar)
    from fractions import Fraction
    f = Fraction(dw * int(height), dh * int(width))
    return '%d:%d' % (f.numerator, f.denominator)


def build(out, chains, dwell, fps, dar, drop_term, allow_dup, dry, work):

    sar = None
    geom = None
    rendered = []          # one (chain, hashes) pair per chain, in order
    seq = 0
    for chain in chains:
        cf, ch = [], []
        for label, vob in chain:
            info = probe_sar(vob)
            if sar is None:
                sar = info.get('sample_aspect_ratio', '1:1')
                geom = (info.get('width'), info.get('height'))
            elif info.get('sample_aspect_ratio') != sar or (info.get('width'), info.get('height')) != geom:
                raise SystemExit('ERROR: %s is %sx%s SAR %s, the set is %sx%s SAR %s - refusing '
                                 'to mix geometries (exit 2)'
                                 % (label, info.get('width'), info.get('height'),
                                    info.get('sample_aspect_ratio'), geom[0], geom[1], sar))
            # ABSOLUTE: the concat demuxer resolves a relative `file` against the LIST's directory,
            # so a relative path here silently becomes <work>/<work>/p023.png.
            # Numbered by POSITION, not by PGC: a title set contributes many pages from one PGC,
            # and two combined title sets both start at cell001 - either would collide on a
            # PGC-derived name and silently overwrite one page with another.
            png = os.path.abspath(os.path.join(work, 'p%05d.png' % seq)).replace('\\', '/')
            seq += 1
            render(vob, png)
            cf.append((label, png))
            ch.append(hashlib.sha256(open(png, 'rb').read()).hexdigest())
        rendered.append((cf, ch))

    # --- terminator gate, PER CHAIN ---------------------------------------------------
    if drop_term:
        rendered = [drop_terminator(cf, ch) for cf, ch in rendered]
    frames = [p for cf, _ in rendered for p in cf]
    hashes = [h for _, ch in rendered for h in ch]

    # --- duplicate gate, across the WHOLE item ----------------------------------------
    seen = {}
    dups = []
    for (label, _), h in zip(frames, hashes):
        if h in seen:
            dups.append((label, seen[h]))
        else:
            seen[h] = label
    if dups and not allow_dup:
        raise SystemExit('ERROR: %d of %d pages are pixel-duplicates of earlier ones '
                         '(e.g. %s == %s). A disc often re-authors a still set several '
                         'times; carve the FIRST run only, or pass --allow-duplicates if the '
                         'repeat is really part of the item (exit 2)'
                         % (len(dups), len(frames), dups[0][0], dups[0][1]))
    if dups:
        print('  NOTE: %d duplicate page(s) kept at the caller\'s request' % len(dups))

    # --- aspect: the cells' own answer, or the IFO's if the caller states it -----------
    if dar:
        want = sar_for_dar(dar, geom[0], geom[1])
        if want == sar:
            print('  --dar %s = SAR %s, which is what the cells already declare' % (dar, want))
        else:
            # Loud on purpose. This is the pipeline overruling the source's own metadata, and the
            # record has to show what was overruled, not just what was written.
            print('  --dar %s OVERRIDES the cells: they declare SAR %s, the output is written '
                  'SAR %s' % (dar, sar, want))
        sar = want

    n = len(frames)
    per = int(round(dwell * fps))
    total = n * per
    print('%d still(s), %s SAR %s, dwell %.4f s = %d frame(s) at %g fps -> %d frames / %.3f s'
          % (n, 'x'.join(geom), sar, per / fps, per, fps, total, total / fps))
    print('  pages: %s' % ','.join(str(p) for p, _ in frames))
    if n == 0:
        raise SystemExit('ERROR: no page left to build (exit 2)')
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
