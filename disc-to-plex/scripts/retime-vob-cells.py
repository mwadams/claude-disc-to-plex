#!/usr/bin/env python3
"""Rewrite per-cell timestamp resets in a carved DVD VOB into one continuous timeline.

WHY THIS EXISTS (The Champions Disk 9, 2026-09-03). A raw-VOB carve of VTS_03 (18 cells,
1048.60 s, 26,215 frames) encoded to 1,024.92 s: ffmpeg exit 0, dup=0 drop=592. The carve was
byte-perfect and decodes to all 26,215 frames - the loss was entirely in TIMESTAMP HANDLING.
Each cell of that VOB restarts SCR/PTS/DTS near zero (17 backward jumps of ~56-59 s), and
ffmpeg's TS_DISCONT rebase shares ONE offset across all streams of the input. That heuristic
loses a frame or two at every seam (the sibling title lost 11 that way), and it fails
catastrophically when a stream is ABSENT from one cell: audio 0x80 has no packets in cell 17,
so the offset flapped between the audio and video resets and 557 frames of cells 17-18 were
dropped as "duplicates". No encode-side flag fixes that reliably, because the input timestamps
are genuinely ambiguous to a single-pass reader.

THE FIX IS DETERMINISTIC, NOT HEURISTIC: two passes over the carve.
  Pass 1 finds cell boundaries (SCR backward jump > 5 s - every DVD pack carries SCR, and a
  cell's packs are contiguous), and records each cell's first/last video DTS.
  Pass 2 adds a per-cell constant to every SCR, PTS and DTS, chosen so cell k's video begins
  exactly one frame after cell k-1's video ends. Within-cell timing is UNTOUCHED, so each
  cell's A/V alignment stays exactly as the disc authored it, and a stream missing from a
  cell becomes a true gap in its own timeline (players render silence), not a desync.

Only timestamp bytes change: the output is the same length, same packs, same payloads.
A VOB with no resets (a mid-PGC cut with continuous timestamps) passes through byte-identical.

Usage:
  python retime-vob-cells.py IN.VOB OUT.VOB          # rewrite + print the cell table
  python retime-vob-cells.py IN.VOB --report-only    # pass 1 only, print the cell table

Exit codes: 0 = OK (including no-op), 2 = structural problem (refuse rather than guess).
"""
import sys, os

SECTOR = 2048
PACK_START = b"\x00\x00\x01\xba"
RESET_TICKS = 5 * 90000            # a backward SCR/DTS jump beyond 5 s = new cell
MARKER_OK = True


def read_scr(pack):
    """33-bit SCR base from an MPEG-2 pack header (bytes 4..9). Returns None if malformed."""
    b = pack
    if (b[4] >> 6) != 0b01:
        return None
    base = ((b[4] >> 3) & 0x07) << 30
    base |= (b[4] & 0x03) << 28
    base |= b[5] << 20
    base |= (b[6] >> 3) << 15
    base |= (b[6] & 0x03) << 13
    base |= b[7] << 5
    base |= b[8] >> 3
    return base


def write_scr(pack, base):
    """Write a 33-bit SCR base back, preserving the 9-bit extension and all marker bits."""
    b = pack
    b[4] = 0b01000100 | (((base >> 30) & 0x07) << 3) | ((base >> 28) & 0x03)
    b[5] = (base >> 20) & 0xFF
    b[6] = 0b00000100 | (((base >> 15) & 0x1F) << 3) | ((base >> 13) & 0x03)
    b[7] = (base >> 5) & 0xFF
    b[8] = (b[8] & 0x07) | ((base & 0x1F) << 3)  # keep marker + ext high bits


def read_ts(buf, off):
    """5-byte PTS/DTS field -> 33-bit value."""
    return (((buf[off] >> 1) & 0x07) << 30) | (buf[off + 1] << 22) | \
           (((buf[off + 2] >> 1) & 0x7F) << 15) | (buf[off + 3] << 7) | (buf[off + 4] >> 1)


def write_ts(buf, off, val):
    """Write a 33-bit value into a 5-byte PTS/DTS field, preserving the 4-bit prefix."""
    buf[off] = (buf[off] & 0xF0) | (((val >> 30) & 0x07) << 1) | 0x01
    buf[off + 1] = (val >> 22) & 0xFF
    buf[off + 2] = (((val >> 15) & 0x7F) << 1) | 0x01
    buf[off + 3] = (val >> 7) & 0xFF
    buf[off + 4] = ((val & 0x7F) << 1) | 0x01


def pes_iter(pack):
    """Yield (payload_start_offset, stream_id) for each PES packet in one 2048-byte pack."""
    # pack header: 4 start + 6 SCR + 3 mux rate + 1 stuffing-length byte, then stuffing
    off = 14 + (pack[13] & 0x07)
    while off + 6 <= SECTOR:
        if pack[off:off + 3] != b"\x00\x00\x01":
            return
        sid = pack[off + 3]
        plen = (pack[off + 4] << 8) | pack[off + 5]
        yield off, sid
        off += 6 + plen


def ts_fields(pack, off, sid):
    """Offsets of the PTS and DTS fields (either may be None) for one PES packet."""
    if sid == 0xBE or sid == 0xBF or sid == 0xBB or sid == 0xBC:   # padding/priv2/system/PSM: no PES ext
        return None, None
    if not (0xC0 <= sid <= 0xEF or sid == 0xBD):
        return None, None
    if (pack[off + 6] >> 6) != 0b10:                                # not an MPEG-2 PES header
        return None, None
    flags = pack[off + 7] >> 6
    if flags == 0b10:
        return off + 9, None
    if flags == 0b11:
        return off + 9, off + 14
    return None, None


def scan(path):
    """Pass 1: cell boundaries (pack index of each cell start) + per-cell video DTS range."""
    cells = []          # dicts: start (pack idx), firstVdts, lastVdts, scr0, scrN
    vdiffs = {}
    last_scr = None
    prev_vdts = None
    with open(path, "rb") as f:
        pi = -1
        while True:
            pack = f.read(SECTOR)
            if not pack:
                break
            pi += 1
            if len(pack) != SECTOR or pack[:4] != PACK_START:
                raise SystemExit(f"ERROR: pack {pi} is not a 2048-byte MPEG pack - refusing (exit 2)")
            scr = read_scr(pack)
            if scr is None:
                raise SystemExit(f"ERROR: pack {pi} has no parseable SCR - refusing (exit 2)")
            if last_scr is None or scr < last_scr - RESET_TICKS:
                cells.append({"start": pi, "firstV": None, "lastV": None,
                              "scr0": scr, "scrN": scr})
            cells[-1]["scrN"] = scr
            last_scr = scr
            for off, sid in pes_iter(pack):
                pts_off, dts_off = ts_fields(pack, off, sid)
                if pts_off is None:
                    continue
                eff = read_ts(pack, dts_off) if dts_off is not None else read_ts(pack, pts_off)
                if 0xE0 <= sid <= 0xEF:
                    c = cells[-1]
                    if c["firstV"] is None:
                        c["firstV"] = eff
                        prev_vdts = None
                    if prev_vdts is not None and eff > prev_vdts:
                        d = eff - prev_vdts
                        if d < 90000:
                            vdiffs[d] = vdiffs.get(d, 0) + 1
                    c["lastV"] = eff if c["lastV"] is None else max(c["lastV"], eff)
                    prev_vdts = eff
    if not cells:
        raise SystemExit("ERROR: no packs found (exit 2)")
    for k, c in enumerate(cells):
        if c["firstV"] is None:
            raise SystemExit(f"ERROR: cell {k+1} contains no timestamped video PES - refusing (exit 2)")
    frame_dur = max(vdiffs, key=vdiffs.get) if vdiffs else 3600
    return cells, frame_dur, pi + 1


def offsets_for(cells, frame_dur):
    """Per-cell tick offsets: cell k's video starts one frame after cell k-1's video ends."""
    offs = [0]
    for k in range(1, len(cells)):
        prev_end = cells[k - 1]["lastV"] + offs[k - 1]
        offs.append(prev_end + frame_dur - cells[k]["firstV"])
    return offs


def main():
    args = [a for a in sys.argv[1:]]
    if len(args) < 2:
        print(__doc__)
        return 2
    src = args[0]
    report_only = args[1] == "--report-only"
    dst = None if report_only else args[1]

    cells, frame_dur, npacks = scan(src)
    offs = offsets_for(cells, frame_dur)

    print(f"retime-vob-cells: {os.path.basename(src)} - {npacks} packs, {len(cells)} cell(s), "
          f"frame duration {frame_dur} ticks ({frame_dur/90000:.4f}s)")
    for k, (c, o) in enumerate(zip(cells, offs)):
        print(f"  cell {k+1:2d}: packs from {c['start']:8d}  videoDTS {c['firstV']/90000:9.3f}.."
              f"{c['lastV']/90000:9.3f}  offset {o/90000:+10.3f}s")
    total = (cells[-1]["lastV"] + offs[-1] + frame_dur - cells[0]["firstV"]) / 90000
    print(f"  continuous video timeline: {total:.2f}s")

    if len(cells) == 1:
        print("  single cell / no resets - nothing to rewrite" +
              ("" if report_only else "; copying input to output unchanged"))
        if not report_only:
            with open(src, "rb") as fi, open(dst, "wb") as fo:
                while True:
                    chunk = fi.read(1 << 22)
                    if not chunk:
                        break
                    fo.write(chunk)
        return 0
    if report_only:
        return 0

    # Pass 2: rewrite. Every pack belongs to the cell whose start index it is at or beyond.
    boundaries = [c["start"] for c in cells]
    ci = 0
    rewritten_ts = 0
    with open(src, "rb") as fi, open(dst, "wb") as fo:
        for pi in range(npacks):
            pack = bytearray(fi.read(SECTOR))
            while ci + 1 < len(boundaries) and pi >= boundaries[ci + 1]:
                ci += 1
            off = offs[ci]
            if off != 0:
                write_scr(pack, (read_scr(pack) + off) & 0x1FFFFFFFF)
                for poff, sid in pes_iter(pack):
                    pts_off, dts_off = ts_fields(pack, poff, sid)
                    if pts_off is not None:
                        write_ts(pack, pts_off, (read_ts(pack, pts_off) + off) & 0x1FFFFFFFF)
                        rewritten_ts += 1
                    if dts_off is not None:
                        write_ts(pack, dts_off, (read_ts(pack, dts_off) + off) & 0x1FFFFFFFF)
                        rewritten_ts += 1
            fo.write(pack)
    print(f"  rewrote {rewritten_ts} PTS/DTS fields across {npacks} packs -> {dst}")

    # Self-check: the output must be the same size and its SCR clock must never step back.
    if os.path.getsize(dst) != os.path.getsize(src):
        raise SystemExit("ERROR: output size differs from input - refusing (exit 2)")
    last = None
    with open(dst, "rb") as f:
        while True:
            pack = f.read(SECTOR)
            if not pack:
                break
            scr = read_scr(pack)
            if last is not None and scr < last - 90000:   # allow ~1s mux jitter, never a reset
                raise SystemExit("ERROR: rewritten SCR clock steps backwards - refusing (exit 2)")
            last = scr
    print("  self-check OK: size unchanged, SCR clock monotonic")
    return 0


if __name__ == "__main__":
    sys.exit(main())
