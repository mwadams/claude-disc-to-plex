"""ONE parser for .srt cues, shared by prepare-srt-review.py and apply-srt-corrections.py.

WHY ONE PARSER, AND WHY THIS SHAPE (2026-09-04)
------------------------------------------------
The correction pass is a two-step conversation: prepare-srt-review.py prints each cue as
"<number>|<text>", the model quotes those numbers back, and apply-srt-corrections.py resolves
each number to a cue and checks the quoted text is really there. That only works if both halves
agree on what "cue 226" means. They did not:

  * prepare printed the NUMBER WRITTEN IN THE FILE (the label line above the timing);
  * apply used the POSITION of the block in its own parse (blocks[cue - 1]).

Both split the file on blank lines. Danger Man S01E32 cue 225 was written with a blank line
between its timing and its text (a wrap() bug on one 58-character word), so the blank-line split
saw 471 cues in a file numbered to 472. From cue 226 on, label and position differed by one, every
proposal on the second half of the episode "did not occur in the cue text", the unmatched rate
(40-58%) tripped the 20% refusal cap, and the pass was refused - on every one of 1,122 attempts.

So: parse by TIMING LINES, not blank lines. A cue is a timing line plus every non-blank line up
to the next timing line (or the label that precedes it). A stray blank line inside a cue, or a
missing one between cues, cannot change the count. And the label is kept, so apply can resolve
a number the way the reviewer saw it.

    parse_srt(path) -> [[label_or_None, timing_line, [text lines]], ...]
"""
import io
import re

TIMING = re.compile(r'^\s*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}\s*-->\s*\d{1,2}:\d{2}:\d{2}[,.]\d{1,3}')


def _is_label_for(lines, i):
    """lines[i] is an integer label immediately followed by a timing line."""
    return (lines[i].strip().isdigit() and i + 1 < len(lines) and TIMING.match(lines[i + 1]) is not None)


def parse_srt(path):
    raw = io.open(path, encoding='utf-8', errors='replace').read().replace('\r', '')
    lines = raw.split('\n')
    n = len(lines)
    cues = []
    i = 0
    while i < n:
        if not TIMING.match(lines[i]):
            i += 1
            continue
        label = lines[i - 1].strip() if i > 0 and _is_label_for(lines, i - 1) else None
        timing = lines[i]
        i += 1
        text = []
        while i < n and not TIMING.match(lines[i]) and not _is_label_for(lines, i):
            if lines[i].strip() != '':
                text.append(lines[i])
            i += 1
        cues.append([label, timing, text])
    return cues


def label_positions(cues):
    """{label: 1-based position} for every labelled cue (first occurrence wins), plus the count
    of labels that do NOT equal their position - non-zero means the file's own numbering and the
    parse order disagree, which is worth saying out loud."""
    by_label, off = {}, 0
    for pos, (label, _t, _x) in enumerate(cues, 1):
        if label is None:
            continue
        if label not in by_label:
            by_label[label] = pos
        if label != str(pos):
            off += 1
    return by_label, off
