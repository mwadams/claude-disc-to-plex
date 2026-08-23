"""List the CLIPS a Blu-ray playlist (.mpls) is made of, with each clip's in/out time.

WHY THIS EXISTS
---------------
A playlist title is probed through its FIRST CLIP only, because that is the one file ffmpeg can
open without libbluray. Everything derived from that probe therefore describes the first clip, not
the title: geometry, audio fingerprint, and - the expensive one - the head strip used to NAME it.

On You Only Live Twice, t02 is a 52-minute playlist whose first clip is 1960s trailer material.
Naming the title from its head would have called a 52-minute compilation after its opening
segment. The two frames the catalogue took at 30 s and 95 s were both inside that same first clip,
so they could not contradict it either.

Reading the playlist fixes it properly: every segment gets sampled, so a compilation reveals each
part's own title card, and a single-clip title is confirmed to be exactly that.

MPLS layout (Blu-ray BDAV spec), all big-endian:
    0x00  4  "MPLS"
    0x04  4  version ("0100"/"0200"/"0300")
    0x08  4  PlayList start address
    0x0C  4  PlayListMark start address
  at PlayList start:
    +0x00 4  length
    +0x04 2  reserved
    +0x06 2  number_of_PlayItems
    +0x08 2  number_of_SubPaths
    then each PlayItem:
    +0x00 2  length (of the rest of this PlayItem)
    +0x02 5  clip_information_file_name  e.g. "00501"
    +0x07 4  clip_codec_identifier       "M2TS"
    +0x0B 2  flags (bit 4 of the high byte = is_multi_angle)
    +0x0D 1  ref_to_STC_id
    +0x0E 4  IN_time   (45 kHz ticks)
    +0x12 4  OUT_time  (45 kHz ticks)

USAGE
    python mpls-clips.py "D:/video/_stage/DISC/BDMV/PLAYLIST/00301.mpls" [--json]
"""

import argparse, json, os, struct, sys

TICKS = 45000.0


def parse(path):
    with open(path, 'rb') as fh:
        b = fh.read()
    if b[:4] != b'MPLS':
        raise ValueError(f'not an MPLS file: {path}')
    pl = struct.unpack_from('>I', b, 8)[0]
    n_items = struct.unpack_from('>H', b, pl + 6)[0]

    clips, off = [], pl + 10
    for _ in range(n_items):
        length = struct.unpack_from('>H', b, off)[0]
        body = off + 2
        name = b[body:body + 5].decode('ascii', 'replace')
        codec = b[body + 5:body + 9].decode('ascii', 'replace')
        flags = struct.unpack_from('>H', b, body + 9)[0]
        in_t = struct.unpack_from('>I', b, body + 12)[0]
        out_t = struct.unpack_from('>I', b, body + 16)[0]
        clips.append({
            'clip': name,
            'codec': codec,
            'multiAngle': bool(flags & 0x0010),
            'inSec': round(in_t / TICKS, 2),
            'outSec': round(out_t / TICKS, 2),
            'durSec': round((out_t - in_t) / TICKS, 2),
        })
        off = body + length
    return clips


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('mpls')
    ap.add_argument('--json', action='store_true')
    ap.add_argument('--stream-dir', help='resolve each clip to its .m2ts path')
    a = ap.parse_args()

    clips = parse(a.mpls)
    sd = a.stream_dir or os.path.join(os.path.dirname(os.path.dirname(a.mpls)), 'STREAM')
    for c in clips:
        p = os.path.join(sd, c['clip'] + '.m2ts')
        c['path'] = p if os.path.exists(p) else None

    total = sum(c['durSec'] for c in clips)
    if a.json:
        print(json.dumps({'playlist': os.path.basename(a.mpls), 'clipCount': len(clips),
                          'totalSec': round(total, 2), 'clips': clips}, indent=2))
    else:
        print(f"{os.path.basename(a.mpls)}: {len(clips)} clip(s), total "
              f"{int(total // 3600)}:{int(total % 3600 // 60):02d}:{int(total % 60):02d}")
        for c in clips:
            miss = '' if c['path'] else '   <-- .m2ts NOT FOUND'
            ma = ' multi-angle' if c['multiAngle'] else ''
            print(f"  {c['clip']}  {c['durSec']:8.2f}s  in={c['inSec']:.2f}{ma}{miss}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
