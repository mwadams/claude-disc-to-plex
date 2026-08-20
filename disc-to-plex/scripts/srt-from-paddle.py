#!/usr/bin/env python3
"""Merge PaddleOCR batch results back into an SRT, using a timing skeleton.

    python srt-from-paddle.py <timings.srt> <paddle-json-dir> <out.srt>

`timings.srt` comes from `seconv <idx> subrip --time-codes-only` - every start/end pair, empty
text. `paddle-json-dir` holds cue_NNNN_res.json written by `paddleocr ocr --save_path`.

Cue N in the timing SRT is the Nth `filepos` in the .idx, and vobsub-render.py emits cue_NNNN.png
in that same order, so the two align by index with no second timing implementation to drift.

A cue with no OCR result (blank frame, or one the renderer skipped) is dropped rather than written
empty: an empty cue is a visible flicker in a player and it also fools any later "does this file
have subtitles" check into counting it.
"""
import glob
import json
import os
import re
import sys


def read_timings(path):
    """Return [(index, 'start --> end')] in file order."""
    out = []
    with open(path, "r", encoding="utf-8-sig", errors="replace") as fh:
        block = []
        for line in fh:
            if line.strip() == "":
                if len(block) >= 2 and block[0].strip().isdigit():
                    out.append((int(block[0].strip()), block[1].strip()))
                block = []
            else:
                block.append(line)
        if len(block) >= 2 and block[0].strip().isdigit():
            out.append((int(block[0].strip()), block[1].strip()))
    return out


def read_texts(json_dir):
    """Return {cue_index: 'line1\\nline2'} from paddleocr's per-image JSON."""
    texts = {}
    for path in glob.glob(os.path.join(json_dir, "**", "cue_*_res.json"), recursive=True):
        m = re.search(r"cue_(\d+)_res\.json$", os.path.basename(path))
        if not m:
            continue
        try:
            with open(path, "r", encoding="utf-8") as fh:
                data = json.load(fh)
        except Exception:
            continue
        lines = [t.strip() for t in data.get("rec_texts", []) if t and t.strip()]
        if not lines:
            continue

        # Order by vertical position when paddle gives boxes - it returns detections in reading
        # order most of the time, but a two-line cue occasionally comes back bottom-first, which
        # would silently swap the halves of a line of dialogue.
        polys = data.get("rec_polys") or data.get("rec_boxes")
        if polys and len(polys) == len(lines):
            try:
                def top_of(p):
                    pts = p if isinstance(p[0], (list, tuple)) else [p[:2], p[2:]]
                    return min(float(q[1]) for q in pts)
                lines = [t for _, t in sorted(zip([top_of(p) for p in polys], lines),
                                              key=lambda z: z[0])]
            except Exception:
                pass
        texts[int(m.group(1))] = "\n".join(lines)
    return texts


def main():
    if len(sys.argv) < 4:
        print(__doc__)
        return 2
    timings_path, json_dir, out_path = sys.argv[1], sys.argv[2], sys.argv[3]

    timings = read_timings(timings_path)
    texts = read_texts(json_dir)
    if not timings:
        print("ERROR: no cues in the timing SRT")
        return 1

    written = dropped = 0
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        n = 0
        for idx, span in timings:
            body = texts.get(idx)
            if not body:
                dropped += 1
                continue
            n += 1
            fh.write("%d\n%s\n%s\n\n" % (n, span, body))
            written += 1

    print("wrote %d cue(s) to %s (%d had no text and were dropped, of %d timed)"
          % (written, out_path, dropped, len(timings)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
