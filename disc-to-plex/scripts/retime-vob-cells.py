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
  cell's packs are contiguous), COUNTS THE CODED PICTURES in each cell, and records each cell's
  first/last video DTS together with WHICH PICTURE each of those timestamps belongs to.
  Pass 2 adds a per-cell constant to every SCR, PTS and DTS, chosen so cell k's video begins
  exactly one frame after cell k-1's LAST PICTURE would have been shown. Within-cell timing is
  UNTOUCHED, so each cell's A/V alignment stays exactly as the disc authored it, and a stream
  missing from a cell becomes a true gap in its own timeline (players render silence), not a
  desync.

Only timestamp bytes change: the output is the same length, same packs, same payloads.
A VOB with no resets (a mid-PGC cut with continuous timestamps) passes through byte-identical.

THE MODAL DTS INTERVAL IS *NOT* THE FRAME DURATION (fixed 2026-09-03, shipped broken)
-------------------------------------------------------------------------------------
Until now this script inferred `frame_dur` as the MODAL DIFFERENCE BETWEEN CONSECUTIVE VIDEO
DTS VALUES. That quantity is not a frame duration. It is the VOBU/DTS-SIGNALLING PERIOD - how
often the muxer bothers to stamp a timestamp - and it is PER-DISC:

  * The Champions Disk 9 measured 18000 ticks (0.2000 s) = FIVE frames at 25 fps.
  * A League of Gentlemen Series 2 Disk 1 angle carve measured 43200 ticks (0.4800 s) = TWELVE
    frames (a PAL GOP). Of that carve's 37,704 video PES packets only 250 carried a timestamp,
    and every single difference between them was identical - so the mode is perfectly stable
    and perfectly wrong.

The seam arithmetic was `cell k starts at cell k-1's LAST TIMESTAMPED picture + one signalling
period`. That is right only when the last signalling group of every cell is FULL, i.e. when
each cell's picture count is an exact multiple of the period. The Champions D9 passed for
exactly that reason: all 18 cells of VTS_03 and all 8 of VTS_04 divide by 5, so every one of
its 25 seams landed on the correct frame (had they not, the worst case there was 68 frames /
2.72 s cumulative). Where a cell ends on a PARTIAL group the seam OVERSHOOTS by the remainder,
and BOTH existing guards pass, so it ships silently. On the League angle-1 carve above the old
arithmetic yields a 3,000-frame timeline for a 2,982-picture carve: 18 frames of overshoot,
against a PGC that declares 119.28 s = exactly 2,982 frames.

So: the frame duration is READ, not inferred - from the MPEG-2 sequence header's
`frame_rate_code` - and the per-cell allotment is an EXACT PICTURE COUNT obtained by scanning
the video payload for `picture_start_code` (00 00 01 00), not a remainder inferred from the
timestamp chain. The modal DTS interval is still measured, but only ever reported, labelled as
what it is (the signalling period), and used to say how many frames the pre-fix arithmetic
would have got wrong.

BOUNDED BLAST RADIUS (established by the diagnosis, worth keeping written down). A wrong
`frame_dur` here CANNOT produce intra-cell audio/video drift, because the per-cell offset is
applied to the SCR, PTS and DTS of EVERY stream in that cell alike - the streams move together.
Its only two effects are (a) holding or dropping frames AT A SEAM and (b) changing the total
length. That is why the three items already published from multi-cell carves are clean rather
than subtly desynced, and why the postflight discriminator for this defect is a frame-count
comparison (`check-cfr-frame-count.ps1`) rather than an A/V sync measurement.

REFUSALS (exit 2) - a multi-cell carve only, because a single-cell carve is a byte-identical
no-op that makes no timing decision at all:
  * no MPEG-2 sequence header, or a `frame_rate_code` whose period is not a whole number of
    90 kHz ticks, or two sequence headers that disagree - the frame duration is then unknown
    and every seam would be a guess;
  * the modal DTS signalling interval is not a whole multiple of the frame duration;
  * ANY cell whose timestamp chain and picture chain disagree, i.e. where
    `lastDTS - firstDTS != (lastPictureIndex - firstPictureIndex) * frame_dur`. This is the
    assertion that makes the picture count usable as a duration: it fails if the frame duration
    is wrong, if a picture is held for other than one frame period (field repeats / pulldown),
    or if the DTS chain is not monotone in picture order;
  * the per-cell picture counts do not sum to the picture count of the whole carve, measured
    independently with a rolling scan that knows nothing about cell boundaries.

Usage:
  python retime-vob-cells.py IN.VOB OUT.VOB          # rewrite + print the cell table
  python retime-vob-cells.py IN.VOB --report-only    # pass 1 only, print the cell table

Exit codes: 0 = OK (including no-op), 2 = structural problem (refuse rather than guess).
"""
import sys, os

SECTOR = 2048
PACK_START = b"\x00\x00\x01\xba"
RESET_TICKS = 5 * 90000            # a backward SCR/DTS jump beyond 5 s = new cell
PIC_START = b"\x00\x00\x01\x00"    # picture_start_code
SEQ_START = b"\x00\x00\x01\xb3"    # sequence_header_code
MARKER_OK = True

# frame_rate_code (MPEG-2 sequence header) -> 90 kHz ticks per coded picture.
# Only codes whose period is a WHOLE number of ticks are listed; DVD-Video permits just 3 (PAL
# 25) and 4 (NTSC 30000/1001), both of which are exact. Codes 1 (24000/1001) and 7 (60000/1001)
# are not representable in whole ticks and are refused rather than rounded.
FRC_TICKS = {2: 3750, 3: 3600, 4: 3003, 5: 3000, 6: 1800, 8: 1500}
FRC_NAME = {1: "24000/1001", 2: "24", 3: "25", 4: "30000/1001", 5: "30",
            6: "50", 7: "60000/1001", 8: "60"}


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


def pes_payload(pack, off):
    """(start, end) byte offsets of one PES packet's PAYLOAD inside the pack, or None."""
    plen = (pack[off + 4] << 8) | pack[off + 5]
    end = min(off + 6 + plen, SECTOR)
    if (pack[off + 6] >> 6) != 0b10:
        return None
    start = off + 9 + pack[off + 8]
    if start >= end:
        return None
    return start, end


def scan_starts(tail, payload, code4):
    """Count occurrences of a 4-byte start code in `payload`, split into two groups.

    Returns (straddling, inside): `straddling` are the occurrences whose FIRST byte lies in the
    3-byte `tail` carried over from the previous payload of the same elementary stream - those
    pictures began before this payload; `inside` are the ones wholly within `payload`.

    Two occurrences of a start code cannot overlap in a legal stream (after 00 00 01 xx the next
    prefix can only begin 3 bytes later at the earliest), so `bytes.count` is exact for the
    inside group. The overlapping degenerate case is start-code emulation, which is illegal -
    and the sum-of-cells assertion in scan() would catch it as a discrepancy anyway.
    """
    straddling = 0
    if tail:
        edge = tail + payload[:3]
        pos = 0
        while True:
            j = edge.find(code4, pos)
            if j < 0 or j >= len(tail):
                break
            straddling += 1
            pos = j + 3
    return straddling, payload.count(code4)


def frame_rate_code(tail, payload):
    """First frame_rate_code in a sequence header found in this payload, else None.

    frame_rate_code is the low nibble of the 4th byte AFTER the sequence_header_code, so it is
    only readable when those 4 bytes are present in `tail + payload`. A header split across the
    boundary is skipped: MPEG-2 repeats the sequence header at every GOP, so the next one serves.
    """
    data = tail + payload
    pos = 0
    while True:
        j = data.find(SEQ_START, pos)
        if j < 0:
            return None
        if j + 7 < len(data):
            return data[j + 7] & 0x0F
        return None


def scan(path):
    """Pass 1: cell boundaries, per-cell PICTURE COUNT, and the DTS<->picture correspondence."""
    cells = []
    dts_gaps = {}                  # histogram of consecutive-DTS differences (diagnostic only)
    frc = None
    gpics = 0                      # whole-carve picture count, no knowledge of cell boundaries
    gtails = {}                    # rolling 3-byte tails for that independent count
    tails = {}                     # rolling 3-byte tails, RESET at every cell boundary
    last_scr = None
    prev_dts = None
    pending = None                 # a DTS awaiting the picture it belongs to
    orphan_ts = 0                  # timestamps that never reached a picture (diagnostic)
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
                              "firstIdx": None, "lastIdx": None, "npics": 0,
                              "scr0": scr, "scrN": scr})
                tails = {}         # a cell restarts its elementary stream: no straddle across a seam
                prev_dts = None
                if pending is not None:
                    orphan_ts += 1
                pending = None
            c = cells[-1]
            c["scrN"] = scr
            last_scr = scr
            for off, sid in pes_iter(pack):
                if not (0xE0 <= sid <= 0xEF):
                    continue
                pts_off, dts_off = ts_fields(pack, off, sid)
                if pts_off is not None:
                    if pending is not None:
                        orphan_ts += 1
                    pending = read_ts(pack, dts_off) if dts_off is not None else read_ts(pack, pts_off)
                span = pes_payload(pack, off)
                if span is None:
                    continue
                payload = pack[span[0]:span[1]]

                v = frame_rate_code(tails.get(sid, b""), payload)
                if v is not None:
                    if frc is None:
                        frc = v
                    elif v != frc:
                        raise SystemExit(
                            f"ERROR: pack {pi}: sequence header frame_rate_code changes "
                            f"{frc} -> {v} mid-carve; the frame duration is not constant - "
                            f"refusing (exit 2)")

                stradd, inside = scan_starts(tails.get(sid, b""), payload, PIC_START)
                c["npics"] += stradd
                if pending is not None and inside:
                    # This PES's timestamp belongs to the first picture that STARTS in its own
                    # payload - the straddling ones began in the previous PES and are already
                    # counted above.
                    idx = c["npics"]
                    if c["firstV"] is None:
                        c["firstV"], c["firstIdx"] = pending, idx
                    if prev_dts is not None and pending > prev_dts:
                        d = pending - prev_dts
                        if d < 90000:
                            dts_gaps[d] = dts_gaps.get(d, 0) + 1
                    prev_dts = pending
                    c["lastV"], c["lastIdx"] = pending, idx
                    pending = None
                c["npics"] += inside
                tails[sid] = payload[-3:] if len(payload) >= 3 else \
                    (tails.get(sid, b"") + payload)[-3:]

                gs, gi = scan_starts(gtails.get(sid, b""), payload, PIC_START)
                gpics += gs + gi
                gtails[sid] = payload[-3:] if len(payload) >= 3 else \
                    (gtails.get(sid, b"") + payload)[-3:]
    if not cells:
        raise SystemExit("ERROR: no packs found (exit 2)")
    for k, c in enumerate(cells):
        if c["firstV"] is None:
            raise SystemExit(f"ERROR: cell {k+1} contains no timestamped video PES - refusing (exit 2)")
        if c["npics"] == 0:
            raise SystemExit(f"ERROR: cell {k+1} contains no coded pictures - refusing (exit 2)")
    dts_period = max(dts_gaps, key=dts_gaps.get) if dts_gaps else None
    frame_dur = FRC_TICKS.get(frc) if frc is not None else None
    return cells, frame_dur, frc, dts_period, gpics, orphan_ts, pi + 1


def cell_t0(c, frame_dur):
    """Notional DTS of a cell's FIRST coded picture (its first timestamp, walked back)."""
    return c["firstV"] - c["firstIdx"] * frame_dur


def offsets_for(cells, frame_dur):
    """Per-cell tick offsets: cell k's first picture follows cell k-1's LAST picture exactly.

    Cell k-1 shows `npics` pictures starting at its notional t0, so it ends - in the continuous
    timeline - at `t0 + offset + npics * frame_dur`. That is an EXACT COUNT, not a remainder
    inferred from where the timestamp chain happened to stop.
    """
    offs = [0]
    for k in range(1, len(cells)):
        prev = cells[k - 1]
        prev_end = cell_t0(prev, frame_dur) + offs[k - 1] + prev["npics"] * frame_dur
        offs.append(prev_end - cell_t0(cells[k], frame_dur))
    return offs


def assert_consistent(cells, frame_dur, frc, dts_period, gpics):
    """The two refusals that make the picture count usable as a duration. Multi-cell only."""
    if frame_dur is None:
        if frc is None:
            raise SystemExit("ERROR: no MPEG-2 sequence header found in the video payload, so "
                             "the frame duration is unknown - refusing to guess a seam (exit 2)")
        raise SystemExit(f"ERROR: sequence header frame_rate_code {frc} "
                         f"({FRC_NAME.get(frc, '?')} fps) is not a whole number of 90 kHz "
                         f"ticks - refusing (exit 2)")
    if dts_period is not None and dts_period % frame_dur:
        raise SystemExit(f"ERROR: modal DTS signalling interval {dts_period} ticks is not a "
                         f"whole multiple of the {frame_dur}-tick frame duration - the two "
                         f"disagree about this stream - refusing (exit 2)")
    for k, c in enumerate(cells):
        want = (c["lastIdx"] - c["firstIdx"]) * frame_dur
        got = c["lastV"] - c["firstV"]
        if got != want:
            raise SystemExit(
                f"ERROR: cell {k+1}: timestamp chain and picture chain DISAGREE - DTS spans "
                f"{got} ticks over {c['lastIdx'] - c['firstIdx']} picture(s), which at "
                f"{frame_dur} ticks/picture should be {want} ticks. Either the frame duration "
                f"is wrong or a picture is held for other than one frame period (field repeat / "
                f"pulldown). The seam cannot be placed from a picture count here - "
                f"refusing (exit 2)")
    tot = sum(c["npics"] for c in cells)
    if tot != gpics:
        raise SystemExit(f"ERROR: per-cell picture counts sum to {tot} but the whole carve "
                         f"contains {gpics} coded picture(s) - {abs(tot - gpics)} picture(s) "
                         f"unaccounted for at a cell boundary - refusing (exit 2)")


def main():
    args = [a for a in sys.argv[1:]]
    if len(args) < 2:
        print(__doc__)
        return 2
    src = args[0]
    report_only = args[1] == "--report-only"
    dst = None if report_only else args[1]

    cells, frame_dur, frc, dts_period, gpics, orphan_ts, npacks = scan(src)
    multi = len(cells) > 1
    if multi:
        assert_consistent(cells, frame_dur, frc, dts_period, gpics)

    fd_txt = (f"{frame_dur} ticks ({frame_dur/90000:.4f}s, frame_rate_code {frc} = "
              f"{FRC_NAME.get(frc, '?')} fps)" if frame_dur else
              f"UNKNOWN (frame_rate_code {frc})")
    print(f"retime-vob-cells: {os.path.basename(src)} - {npacks} packs, {len(cells)} cell(s), "
          f"{gpics} coded picture(s), frame duration {fd_txt}")
    if dts_period is not None:
        per = f"{dts_period/frame_dur:g} frame(s)" if frame_dur and dts_period % frame_dur == 0 \
              else "NOT a whole number of frames"
        print(f"  DTS signalling period (modal interval, DIAGNOSTIC ONLY - never the frame "
              f"duration): {dts_period} ticks = {per}")
    if orphan_ts:
        print(f"  note: {orphan_ts} video timestamp(s) reached no picture start in their own PES")

    if frame_dur is None:
        # Single-cell only (assert_consistent would already have refused a multi-cell carve):
        # nothing is retimed, so an unknown frame duration decides nothing.
        offs = [0] * len(cells)
        for k, c in enumerate(cells):
            print(f"  cell {k+1:2d}: packs from {c['start']:8d}  {c['npics']:6d} picture(s)  "
                  f"videoDTS {c['firstV']/90000:9.3f}..{c['lastV']/90000:9.3f}")
    else:
        offs = offsets_for(cells, frame_dur)
        period = dts_period // frame_dur if dts_period and dts_period % frame_dur == 0 else None
        partial = []
        for k, (c, o) in enumerate(zip(cells, offs)):
            trail = c["npics"] - 1 - c["lastIdx"]      # pictures after the last timestamped one
            tag = ""
            # A partial trailing group only MEANS anything where a seam follows it. On a
            # single-cell carve nothing is retimed, so flagging one is noise.
            if period is not None and multi:
                if (c["npics"] % period) != 0:
                    tag = f"  PARTIAL trailing group ({c['npics'] % period}/{period})"
                    partial.append(k + 1)
            print(f"  cell {k+1:2d}: packs from {c['start']:8d}  {c['npics']:6d} picture(s)  "
                  f"videoDTS {c['firstV']/90000:9.3f}..{c['lastV']/90000:9.3f}  "
                  f"(+{trail} untimestamped)  offset {o/90000:+10.3f}s{tag}")
        frames = sum(c["npics"] for c in cells)
        print(f"  continuous video timeline: {frames} frames = "
              f"{frames * frame_dur / 90000:.2f}s")
        if period is not None and partial:
            # What the pre-2026-09-03 modal-interval arithmetic would have produced. Kept as a
            # printed number because this defect's whole problem was being invisible.
            #
            # The number that MATTERS is the cumulative SEAM overshoot - the gap the encoder has
            # to fill - which is the difference in the LAST cell's offset. A partial group in the
            # final cell costs nothing, because no seam follows it; measured on the League angle-1
            # carve, cell 1's 5/12 group put 7 frames of gap at its single seam and the old
            # output declared 119.56 s against a true 2,982 pictures = 119.28 s.
            old = [0]
            for k in range(1, len(cells)):
                old.append(cells[k - 1]["lastV"] + old[k - 1] + dts_period - cells[k]["firstV"])
            delta = old[-1] - offs[-1]
            print(f"  cell(s) {','.join(str(p) for p in partial)} end on a PARTIAL signalling "
                  f"group; the pre-fix modal-interval arithmetic would have opened "
                  f"{delta // frame_dur} frame(s) of gap at the seam(s) ({delta/90000:+.2f}s "
                  f"cumulative)")

    if not multi:
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
    # `raise SystemExit("message")` prints the message but exits 1, NOT 2 - so every refusal in
    # this script documented itself as "exit 2" while actually returning 1. transcode.ps1 tests
    # `-ne 0` so it failed the item correctly either way, but the contract was a lie and any
    # caller distinguishing "refused on structure" (2) from "crashed" (1) would be misled.
    # Same wrapper as dvd-angle-cells.py, for the same reason.
    try:
        sys.exit(main())
    except SystemExit as e:
        if isinstance(e.code, str):
            sys.stderr.write(e.code + "\n")
            sys.exit(2)
        raise
