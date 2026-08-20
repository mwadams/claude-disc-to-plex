#!/usr/bin/env python3
"""Render each VOBSUB cue to a PNG, for batch OCR.

WHY THIS EXISTS
---------------
seconv can drive PaddleOCR, but it spawns a FRESH paddleocr process per subtitle image, so the
neural model is loaded from scratch every cue. Measured on a 504-cue episode: still unfinished
after ~50 minutes, with the python PIDs visibly churning. Model loading dominates; recognition is
a rounding error beside it.

Batch OCR fixes that - one paddleocr invocation over a folder loads the model once - but nothing
in the toolchain emits the per-cue bitmaps:

  * seconv's BDN Xml (format 367) is INPUT-ONLY, so it cannot export images.
  * ffmpeg can decode the .idx/.sub pair, but overlaying onto a `color` source does not work with
    an input seek: the colour source restarts at t=0 while the subtitle stream is seeked, so the
    frames come out blank. Rendering a whole pass at a fixed fps and matching frames back to cues
    means guessing an fps that never misses a short cue.

So decode the SPU stream directly. It is a small, well-specified format and we already parse most
of it for the palette repair in ocr-subtitles.ps1.

TIMINGS ARE NOT COMPUTED HERE. `seconv <idx> subrip --time-codes-only` produces every start/end
pair in seconds, and cue N there is the Nth `filepos` in the .idx. This script emits cue_0001.png,
cue_0002.png ... in that same order, so the two line up by index and there is no second timing
implementation to disagree with the first.

USAGE
    python vobsub-render.py <sub.idx> <out-dir> [--scale 3] [--limit N]
"""
import os
import struct
import sys


def parse_idx(path):
    """Return (palette:list[int], fileposes:list[int])."""
    palette, fileposes = [], []
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        for line in fh:
            s = line.strip()
            if s.startswith("palette:"):
                palette = [int(x.strip(), 16) for x in s[len("palette:"):].split(",")]
            elif "filepos:" in s:
                fileposes.append(int(s.split("filepos:")[1].strip(), 16))
    return palette, fileposes


def read_spu(buf, start):
    """Reassemble one SPU packet starting at a .sub byte offset.

    The packet is spread over consecutive 2 KB MPEG program-stream sectors: each has a pack header
    (0x000001BA) then a private_stream_1 PES (0x000001BD) whose payload begins with a substream id
    byte. Concatenate payloads until we have the length the SPU declares in its own first 2 bytes.
    """
    out = bytearray()
    p, want = start, -1
    n = len(buf)
    while p < n - 6:
        if buf[p] != 0 or buf[p + 1] != 0 or buf[p + 2] != 1:
            p += 1
            continue
        sc = buf[p + 3]
        if sc == 0xBA:
            p += 14 + (buf[p + 13] & 7)
            continue
        plen = (buf[p + 4] << 8) | buf[p + 5]
        if sc == 0xBD:
            frm = p + 9 + buf[p + 8] + 1
            to = min(p + 6 + plen, n)
            out += buf[frm:to]
            if want < 0 and len(out) >= 2:
                want = (out[0] << 8) | out[1]
            if want >= 0 and len(out) >= want:
                break
        p += 6 + plen
    return bytes(out)


def decode_cue(spu):
    """Decode one SPU into (width, height, rows_of_indices, pal_idx, alpha) or None."""
    if len(spu) < 8:
        return None
    dcsq = (spu[2] << 8) | spu[3]
    pal_idx = alpha = None
    x1 = y1 = x2 = y2 = None
    off0 = off1 = -1
    seen = set()
    while 0 < dcsq < len(spu) - 4 and dcsq not in seen:
        seen.add(dcsq)
        nxt = (spu[dcsq + 2] << 8) | spu[dcsq + 3]
        i = dcsq + 4
        while i < len(spu):
            c = spu[i]
            if c == 0xFF:
                break
            if c <= 0x02:
                i += 1
            elif c == 0x03:                      # SET_COLOR - highest index first
                if pal_idx is None:
                    pal_idx = [spu[i + 2] & 15, spu[i + 2] >> 4, spu[i + 1] & 15, spu[i + 1] >> 4]
                i += 3
            elif c == 0x04:                      # SET_CONTRAST (alpha)
                a = [spu[i + 2] & 15, spu[i + 2] >> 4, spu[i + 1] & 15, spu[i + 1] >> 4]
                if alpha is None and any(v > 0 for v in a):
                    alpha = a
                i += 3
            elif c == 0x05:                      # SET_DISPLAY_AREA - two 12-bit pairs
                x1 = (spu[i + 1] << 4) | (spu[i + 2] >> 4)
                x2 = ((spu[i + 2] & 15) << 8) | spu[i + 3]
                y1 = (spu[i + 4] << 4) | (spu[i + 5] >> 4)
                y2 = ((spu[i + 5] & 15) << 8) | spu[i + 6]
                i += 7
            elif c == 0x06:                      # SET_PIXEL_DATA_ADDRESS
                off0 = (spu[i + 1] << 8) | spu[i + 2]
                off1 = (spu[i + 3] << 8) | spu[i + 4]
                i += 5
            elif c == 0x07:
                i += 1 + ((spu[i + 1] << 8) | spu[i + 2])
            else:
                i += 1
        if nxt == dcsq:
            break
        dcsq = nxt

    if None in (pal_idx, alpha, x1, y1, x2, y2) or off0 < 0:
        return None
    w, h = x2 - x1 + 1, y2 - y1 + 1
    if w <= 0 or h <= 0 or w > 4096 or h > 4096:
        return None

    rows = [[0] * w for _ in range(h)]
    for field in (0, 1):
        ni = 2 * (off0 if field == 0 else off1)   # nibble index
        y = field
        while y < h:
            x = 0
            while x < w:
                n = 0
                ran = False
                for k in range(4):
                    bi = ni >> 1
                    if bi >= len(spu):
                        ran = True
                        break
                    v = (spu[bi] >> 4) if (ni % 2 == 0) else (spu[bi] & 15)
                    ni += 1
                    n = (n << 4) | v
                    if n >= (4 << (2 * k)):
                        break
                if ran:
                    break
                cnt, col = n >> 2, n & 3
                if cnt == 0 or cnt > (w - x):
                    cnt = w - x
                for xx in range(x, x + cnt):
                    rows[y][xx] = col
                x += cnt
            if ni % 2:
                ni += 1                            # rows restart on a byte boundary
            y += 2
    return w, h, rows, pal_idx, alpha


def write_png(path, w, h, pixels, scale):
    """Minimal greyscale PNG writer - avoids a Pillow dependency in this tool env."""
    import zlib
    sw, sh = w * scale, h * scale
    raw = bytearray()
    for y in range(sh):
        raw.append(0)
        row = pixels[y // scale]
        for x in range(sw):
            raw.append(row[x // scale])
    def chunk(tag, data):
        c = struct.pack(">I", len(data)) + tag + data
        return c + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", sw, sh, 8, 0, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(raw), 6))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as fh:
        fh.write(png)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    idx_path, out_dir = sys.argv[1], sys.argv[2]
    scale = 3
    limit = 0
    if "--scale" in sys.argv:
        scale = int(sys.argv[sys.argv.index("--scale") + 1])
    if "--limit" in sys.argv:
        limit = int(sys.argv[sys.argv.index("--limit") + 1])

    sub_path = os.path.splitext(idx_path)[0] + ".sub"
    palette, fileposes = parse_idx(idx_path)
    if not palette or not fileposes:
        print("ERROR: could not read palette/filepos from the .idx")
        return 1
    with open(sub_path, "rb") as fh:
        buf = fh.read()
    os.makedirs(out_dir, exist_ok=True)

    written = skipped = 0
    for n, fp in enumerate(fileposes, start=1):
        if limit and n > limit:
            break
        cue = decode_cue(read_spu(buf, fp))
        if not cue:
            skipped += 1
            continue
        w, h, rows, pal_idx, alpha = cue

        # Black text on white, which is what OCR engines expect. Every VISIBLE index becomes ink;
        # only the transparent index is background. Isolating just the fill is what erodes thin
        # strokes and splits letters (d->cl, m->rn) - the exact defect that made Tesseract score
        # 94% on this material, so do NOT reproduce it here.
        # GREYSCALE BY LUMINANCE, not a binary threshold.
        #
        # A DVD subpicture is white FILL + grey ANTI-ALIAS + black OUTLINE + transparent background.
        # Both naive mappings damage the glyph and each fails in the opposite direction:
        #   fill only, everything else white  -> strokes erode to hairlines, thin joins break, and
        #                                        'd' reads as "cl", 'm' as "rn"  (letters SPLIT)
        #   every visible index solid black   -> glyphs fatten and adjacent letters fuse, so "like"
        #                                        reads as "Uke" and "listen" as "Usten" (letters MERGE)
        # The second is not hypothetical: it is what this renderer did first, and PaddleOCR then
        # reproduced Tesseract's "Uke"/"Usten" errors exactly - proving the defect was in the image
        # handed to the engine, not in the engine.
        #
        # So preserve the anti-alias as an actual mid-tone. Invert by luminance: the brightest
        # visible index (the fill) becomes black, the darkest (the outline) becomes white so it
        # merges into the background, and the anti-alias lands in between - which is exactly the
        # smooth edge OCR engines are trained on.
        lum = {}
        for i in range(4):
            c = palette[pal_idx[i]] if pal_idx[i] < len(palette) else 0
            lum[i] = 0.299 * ((c >> 16) & 255) + 0.587 * ((c >> 8) & 255) + 0.114 * (c & 255)
        vis = [i for i in range(4) if alpha[i] > 0]
        lut = [255] * 4
        if vis:
            hi = max(lum[i] for i in vis)
            lo = min(lum[i] for i in vis)
            span = (hi - lo) or 1.0
            for i in vis:
                # fill (brightest) -> 0, outline (darkest) -> 255
                lut[i] = int(round(255 * (hi - lum[i]) / span))
        pix = [[lut[c] for c in row] for row in rows]

        # CROP TO THE INK. The disc's SET_DISPLAY_AREA is close to full-frame on this material, so
        # a cue arrives as a ~2160x1716 canvas that is ~90% white. PaddleOCR's detection pass scans
        # all of it: measured 167,958 ms for ONE cue, i.e. 23 hours for a 504-cue episode. Cropping
        # to the actual glyph bounds removes almost all of that area. Do this BEFORE scaling so the
        # upscale is spent on text rather than on background.
        top, bot, left, right = h, -1, w, -1
        for y in range(h):
            row = pix[y]
            for x in range(w):
                if row[x] < 250:          # any ink, not just pure black (the image is greyscale now)
                    if y < top: top = y
                    if y > bot: bot = y
                    if x < left: left = x
                    if x > right: right = x
        if bot < 0:
            skipped += 1          # nothing visible - an empty cue, not a render failure
            continue
        pad = 4
        top = max(0, top - pad); bot = min(h - 1, bot + pad)
        left = max(0, left - pad); right = min(w - 1, right + pad)
        cw, ch = right - left + 1, bot - top + 1
        cropped = [bytes(pix[y][left:right + 1]) for y in range(top, bot + 1)]

        write_png(os.path.join(out_dir, "cue_%04d.png" % n), cw, ch, cropped, scale)
        written += 1

    print("rendered %d cue(s), %d undecodable, scale x%d -> %s" % (written, skipped, scale, out_dir))
    return 0


if __name__ == "__main__":
    sys.exit(main())
