#!/usr/bin/env python3
"""Capture fresh frames for a catalogued title and register them in the catalogue.

Needed because rewriting a catalogue onto the PROVEN mapping can leave a row with no evidence at
all: catalogue-dvd.ps1 only probes the dvdvideo title its duration-pairing believed in, so when the
pairing was wrong, some dvdvideo title was never opened. assert-accounted.ps1 verifies a `card:` or
`frame:` citation by checking the catalogue HOLDS frames for that title, so such a row cannot carry
one until the frames actually exist.

Frames are read through `-f dvdvideo -title N` using the row's PROVEN dvdvideoTitle - the same path
transcode.ps1 uses - so what is captured belongs to the title the row will be encoded from.

Usage: capture-evidence.py "D:/video/_stage/<disc>" <makemkvTitle> <sec> [<sec> ...]
"""
import json
import os
import subprocess
import sys

CAT_DIR = 'D:/video/_catalogue'
FFMPEG = ('D:/video/.transcode-tools/ffmpeg-n7.1/'
          'ffmpeg-n7.1-latest-win64-gpl-7.1/bin/ffmpeg.exe')


# A title card is usually FADED in and out, so the exact second the OCR reported can land in the
# black gap either side of it. On D2 dvdvideo 4 the card OCR'd at 82s but the frame grabbed at
# 82.0s is solid black, 1,383 bytes. That matters more than it looks: assert-accounted.ps1 verifies
# a `card:` citation by checking the catalogue HOLDS frames for the title, not by looking at them -
# so a black frame satisfies the gate while proving nothing. Grab a neighbourhood and keep the
# frame that actually carries picture.
BLANK_BYTES = 8000          # a 720x576 PNG of near-solid black lands around 1-2 KB
NEIGHBOURHOOD = (0, 1, -1, 2, -2, 3)


def grab_non_blank(disc, dvd, mk_title, sec, frame_dir):
    best = None
    for delta in NEIGHBOURHOOD:
        at = sec + delta
        if at < 0:
            continue
        out = os.path.join(frame_dir, 't%03d-%04d.png' % (mk_title, at))
        subprocess.run([FFMPEG, '-hide_banner', '-loglevel', 'error',
                        '-f', 'dvdvideo', '-title', str(dvd), '-i', disc,
                        '-ss', str(at), '-frames:v', '1', out, '-y'],
                       capture_output=True)
        if not os.path.exists(out):
            continue
        size = os.path.getsize(out)
        if size >= BLANK_BYTES:
            note = '' if delta == 0 else '  (asked for %ds; that frame was blank)' % sec
            print('captured dvdvideo %d @ %ds -> %s (%d bytes)%s'
                  % (dvd, at, os.path.basename(out), size, note))
            return out
        if best is None or size > best[1]:
            best = (out, size)
        os.remove(out)
    if best:
        print('WARNING dvdvideo %d near %ds: every frame in the neighbourhood is near-blank '
              '(best %d bytes) - do NOT cite a card here without looking at it'
              % (dvd, sec, best[1]))
    return None


def main():
    if len(sys.argv) < 4:
        sys.exit(__doc__)
    disc, mk_title = sys.argv[1], int(sys.argv[2])
    seconds = [int(s) for s in sys.argv[3:]]

    disc_name = os.path.basename(disc.rstrip('/\\'))
    cat_path = os.path.join(CAT_DIR, disc_name + '.catalogue.json')
    with open(cat_path, encoding='utf-8') as fh:
        cat = json.load(fh)

    row = next((r for r in cat['titles'] if int(r['title']) == mk_title), None)
    if row is None:
        sys.exit('no such MakeMKV title %d in %s' % (mk_title, cat_path))
    dvd = row.get('dvdvideoTitle')
    if dvd is None:
        sys.exit('t%02d has no dvdvideoTitle - prove the mapping first' % mk_title)

    frame_dir = os.path.join(CAT_DIR, disc_name + '-frames')
    os.makedirs(frame_dir, exist_ok=True)

    added = []
    for sec in seconds:
        got = grab_non_blank(disc, dvd, mk_title, sec, frame_dir)
        if got:
            added.append(got)
        else:
            print('FAILED dvdvideo %d near %ds - every candidate frame was blank' % (dvd, sec))

    if not added:
        sys.exit('nothing captured - catalogue not touched')

    frames = list(row.get('frames') or [])
    for p in added:
        p = p.replace('/', '\\')
        if p not in frames:
            frames.append(p)
    row['frames'] = frames
    note = ('frames captured directly from dvdvideo title %d (the PROVEN title for t%02d) at %s; '
            'the catalogue sweep never opened this dvdvideo title because its duration-pairing '
            'named a different one' % (dvd, mk_title, ', '.join('%ds' % s for s in seconds)))
    row['evidenceNote'] = note
    with open(cat_path, 'w', encoding='utf-8') as fh:
        json.dump(cat, fh, indent=2)
    print('registered %d frame(s) on t%02d in %s' % (len(added), mk_title, cat_path))


if __name__ == '__main__':
    main()
