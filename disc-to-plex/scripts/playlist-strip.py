"""Build a contact strip spanning a Blu-ray PLAYLIST's WHOLE runtime, across all its clips.

WHY THIS EXISTS
---------------
A playlist title is probed through its FIRST CLIP, so everything the catalogue derives about it -
geometry, fingerprint, sample frames, head strip - describes only the opening. For a short title
that is the same thing. For a long one it is not, and the failure is silent because the frames
that would contradict it are never taken.

You Only Live Twice t02 runs 52:23. Its 30 s frame, its 95 s frame and its 40 s head strip all sit
inside the first two minutes, so the title was about to be named from ~2% of itself - and named
wrongly, since it opens on trailer-style material.

This maps sample points across the FULL playlist duration through the clip list (see
mpls-clips.py), so a segmented programme shows each segment and a single long clip is sampled
end to end. Use it for any playlist title long enough that its opening is not representative.

USAGE
    python playlist-strip.py "<...>/PLAYLIST/00301.mpls" -o strip.png [--points 40] [--label t02]
"""

import argparse, os, subprocess, sys, json, tempfile
from pathlib import Path

# mpls-clips.py has a hyphen in its name, so it cannot be imported normally. Load it by path
# rather than duplicating the parser - two copies of a binary-format reader is how they drift.
import importlib.util as _ilu
_spec = _ilu.spec_from_file_location(
    'mpls_clips', os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mpls-clips.py'))
_mod = _ilu.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
parse_clips = _mod.parse

TOOLS = json.loads(Path(r'D:\video\.transcode-tools\tool-paths.json').read_text())
FFMPEG = TOOLS['ffmpeg']


def build(mpls, out, points=40, label=None, cols=8):
    clips = parse_clips(mpls)
    stream = os.path.join(os.path.dirname(os.path.dirname(mpls)), 'STREAM')
    for c in clips:
        c['path'] = os.path.join(stream, c['clip'] + '.m2ts')

    total = sum(c['durSec'] for c in clips)
    if total <= 0:
        raise SystemExit('playlist has no duration')

    # Global time -> (clip, offset within that clip). The clip's own IN point matters: a playlist
    # routinely starts partway into its m2ts (11.65 s is common on these discs).
    def locate(t):
        acc = 0.0
        for c in clips:
            if t < acc + c['durSec']:
                return c, c['inSec'] + (t - acc)
            acc += c['durSec']
        last = clips[-1]
        return last, last['outSec'] - 1

    rows = (points + cols - 1) // cols
    with tempfile.TemporaryDirectory() as td:
        n = 0
        for i in range(points):
            t = total * (i + 0.5) / points
            c, off = locate(t)
            if not os.path.exists(c['path']):
                continue
            cell = os.path.join(td, 'f%03d.png' % n)
            mm, ss = int(t // 60), int(t % 60)
            # A COLON inside a drawtext value terminates the option and the whole filtergraph
            # fails to parse - ffmpeg then writes no file and the only symptom is "no frames".
            txt = f"{label + ' ' if label else ''}{mm}\:{ss:02d}"
            vf = ("yadif,scale=300:169:force_original_aspect_ratio=decrease,"
                  "pad=300:169:(ow-iw)/2:(oh-ih)/2:black,"
                  f"drawtext=text='{txt}':x=6:y=6:fontsize=18:fontcolor=yellow:"
                  "box=1:boxcolor=black@0.7")
            r = subprocess.run([FFMPEG, '-v', 'error', '-ss', f'{off:.2f}', '-i', c['path'],
                                '-frames:v', '1', '-vf', vf, '-y', cell],
                               capture_output=True, text=True)
            if os.path.exists(cell):
                n += 1
        if n == 0:
            raise SystemExit('no frames extracted')
        subprocess.run([FFMPEG, '-v', 'error', '-framerate', '1', '-start_number', '0',
                        '-i', os.path.join(td, 'f%03d.png'), '-frames:v', '1',
                        '-vf', f'tile={cols}x{rows}', '-y', out], capture_output=True, text=True)
    return out, len(clips), total, n


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mpls')
    ap.add_argument('-o', '--out', required=True)
    ap.add_argument('--points', type=int, default=40)
    ap.add_argument('--label')
    a = ap.parse_args()
    out, nclips, total, n = build(a.mpls, a.out, a.points, a.label)
    print(f"{os.path.basename(a.mpls)}: {nclips} clip(s), {int(total//60)}:{int(total%60):02d} "
          f"total - {n} frames spanning the whole title -> {out}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
