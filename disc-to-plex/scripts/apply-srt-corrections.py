#!/usr/bin/env python3
"""Apply a reviewed list of WORD-LEVEL corrections to a machine-transcribed .srt.

WHY THIS EXISTS
---------------
Whisper produces fluent text with homophone errors that a dictionary cannot catch, because both
spellings are real words. Measured in this library's own output:

    "Patrick McGoon"                        -> Patrick McGoohan
    "he missed the send bag"                -> sand bag
    "watered by the chef, watered by the police" -> wanted by the chief, wanted by the police
    "No memory apartment to run to"         -> (garbled; a reader sees it instantly)

Every one is obvious in context and invisible to a spell-checker. That is exactly the gap a
language model closes - and exactly the gap where a language model is most dangerous, because its
output is FLUENT. A rewritten subtitle that invents a plausible line is indistinguishable from a
correct one, across 700 cues an episode nobody can check.

So this script does not accept a rewritten transcript. It accepts a LIST OF SUBSTITUTIONS and
enforces that they are what they claim to be:

  * every correction names a cue, an exact `from` string and a `to` string
  * `from` MUST occur in that cue verbatim, or the correction is refused - a proposal that does
    not match the text it claims to fix is a hallucination, and this is where it stops
  * cue COUNT and every TIMESTAMP are copied through untouched; only text inside a cue changes
  * a cap on how much may change (default 8% of cues); a pass that wants more is not a
    correction pass, it is a rewrite, and it is refused wholesale
  * the original is kept beside the file, and a machine-readable diff is written
  * provenance records that a correction pass ran, with counts

Reversible by construction: copy the original back from D:/video/_correction-originals.
(Backups are kept OUT of the media folder - Plex indexes subtitle-shaped sidecars it finds there.)

  python apply-srt-corrections.py <file.eng.srt> --corrections fixes.json [--max-change-pct 8]
  python apply-srt-corrections.py <file.eng.srt> --corrections fixes.json --dry-run

`fixes.json` is a list of objects:
  [{"cue": 12, "from": "send bag", "to": "sand bag", "why": "sandbag - homophone"}, ...]
"""
import argparse
import io
import json
import os
import re
import shutil
import sys


def norm(t):
    """Whitespace-insensitive form for matching. Cue text is WRAPPED for display, so a phrase can
    straddle a newline while the reviewer reads it joined - which is how it is presented and how
    anyone reads a sentence. Matching raw lines rejected CORRECT proposals purely because of where
    the wrap fell: "Colonel Coots" against text broken as "Colonel" / "Coots"."""
    return re.sub(r"\s+", " ", t).strip()


def edit_ratio(a, b):
    """Levenshtein distance normalised by the longer string. 0 = identical, 1 = nothing in common."""
    a, b = norm(a), norm(b)
    if not a and not b:
        return 0.0
    prev = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        cur = [i]
        for j, cb in enumerate(b, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (ca != cb)))
        prev = cur
    return prev[-1] / float(max(len(a), len(b)))


def rewrap(text, width=42):
    """Re-wrap a corrected cue to at most two display lines, as the transcriber does."""
    words, out, cur = text.split(), [], ""
    for w in words:
        if cur and len(cur) + 1 + len(w) > width:
            out.append(cur); cur = w
        else:
            cur = (cur + " " + w).strip()
    if cur:
        out.append(cur)
    if len(out) <= 2:
        return out
    mid = len(words) // 2
    return [" ".join(words[:mid]), " ".join(words[mid:])]


def _backup_path(srt, backup_dir):
    """Mirror <backup_dir>/<grandparent>/<parent>/<name>.srt, so 'Season 01' alone never collides
    across shows. An empty backup_dir keeps the old beside-the-file behaviour."""
    if not backup_dir:
        return srt[:-4] + '.pre-correction.srtbak'
    parent = os.path.basename(os.path.dirname(srt))
    gp = os.path.basename(os.path.dirname(os.path.dirname(srt)))
    safe = lambda x: re.sub(r'[<>:"/\|?*]', '_', x).strip() or '_'
    return os.path.join(backup_dir, safe(gp), safe(parent), os.path.basename(srt))


sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from srt_cues import parse_srt, label_positions      # noqa: E402  (ONE parser - see srt_cues.py)


def write_srt(path, blocks):
    out = []
    for i, (_idx, timing, text) in enumerate(blocks, 1):
        out.append(str(i))
        out.append(timing)
        out.extend(text)
        out.append('')
    io.open(path, 'w', encoding='utf-8', newline='\n').write('\n'.join(out))


def main():
    # The Windows console is cp1252 and these transcripts are not. A U+251C box-drawing character
    # in one Danger Man cue crashed the --dry-run report with UnicodeEncodeError - the script had
    # done its work correctly and died reporting it. Never let the OUTPUT encoding decide whether
    # a pass succeeds.
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(encoding='utf-8', errors='replace')
        except Exception:
            pass
    ap = argparse.ArgumentParser()
    ap.add_argument('srt')
    ap.add_argument('--corrections', required=True, help='JSON list of {cue, from, to, why}')
    # WHY 15 AND NOT 8. The first cap was 8%, guessed. It fired on Danger Man S01E15 at 8.1% -
    # 33 corrections, of which FOUR were the series lead's own name mis-heard four different ways
    # ("Mr. Bray", "Mr. Frege", "Mr. Dre", "Mr. Jay" -> Mr. Drake), plus six "Martin" -> "Martine",
    # four "General Abellon/Abayon/Abeyon" -> Abeijon and four Bernard variants. A name-dense
    # episode legitimately reaches this figure BECAUSE one recurring name is one substitution
    # repeated, not a rewrite. Discarding all 33 over 0.1% was the worst outcome available.
    # The percentage of cues touched was never the right discriminator; --max-edit-ratio below is.
    ap.add_argument('--max-change-pct', type=float, default=15.0,
                    help='refuse the whole pass if it would touch more than this %% of cues')
    # A CORRECTION IS A SMALL PERTURBATION OF WHAT IS THERE; an invention is not. Measured over the
    # 33 proposals above, the largest normalised edit distance was 0.44 ("Mr. Bray" -> "Mr. Drake")
    # (0.5 proved too tight - a correct S01E34 fix measured 0.52) and most under 0.3, including the long ones ("This by I must warn you" -> "But I must
    # warn you", 0.22). A substitution that rewrites more than half its own anchor is not fixing a
    # mis-hearing, and THAT is the thing the cue-percentage cap was reaching for.
    ap.add_argument('--max-edit-ratio', type=float, default=0.6,
                    help='refuse a substitution that rewrites more than this fraction of its anchor')
    ap.add_argument('--min-ratio-len', type=int, default=12,
                    help='only apply --max-edit-ratio to anchors at least this many characters')
    # ONE BAD ANCHOR SHOULD NOT DISCARD THE VERIFIED ONES. Danger Man S01E21 proposed 7; six
    # matched verbatim and one named 'Mr. Jake' in a cue reading "Inside, please." The original
    # policy binned all seven, reasoning that the survivors were "exactly as unverified" as the
    # failure. That reasoning does not hold: each substitution is verified INDEPENDENTLY by its own
    # anchor match, which is the entire design. What a mismatch really signals is a pass that was
    # not reading this transcript closely - and that signal is in the RATE, not in any single miss.
    # So: drop a few unmatched proposals and apply the rest; refuse the whole pass once mismatches
    # are common enough to mean the model was working from something else.
    ap.add_argument('--max-unmatched-pct', type=float, default=20.0,
                    help='refuse the whole pass if more than this %% of proposals fail to match')
    ap.add_argument('--dry-run', action='store_true')
    # OFF THE LIBRARY ENTIRELY. See the note where the backup is written.
    ap.add_argument('--backup-dir', default='D:/video/_correction-originals',
                    help='where originals are kept; "" puts them beside the subtitle (not advised)')
    a = ap.parse_args()

    if not os.path.exists(a.srt):
        print('[failed] no such subtitle: %s' % a.srt)
        return 2
    fixes = json.load(io.open(a.corrections, encoding='utf-8'))
    if not isinstance(fixes, list):
        print('[failed] corrections file must be a JSON LIST of {cue, from, to}')
        return 2

    blocks = parse_srt(a.srt)
    if not blocks:
        print('[failed] parsed 0 cues from %s - refusing' % a.srt)
        return 2
    # RESOLVE A PROPOSAL'S CUE NUMBER THE WAY THE REVIEWER SAW IT. prepare-srt-review.py prints
    # the label written in the file; position is only the fallback for an unlabelled cue. When
    # the two disagree anywhere, say so - it means the file is malformed or renumbered, and it is
    # the single fact that explained 1,122 refused passes on one episode (see srt_cues.py).
    by_label, off_by = label_positions(blocks)
    if off_by:
        print('[warn] %d cue label(s) differ from their parse position in %s - resolving proposals '
              'by LABEL; the rewrite will renumber the file 1..%d' % (off_by, os.path.basename(a.srt), len(blocks)))

    def resolve(ci):
        return by_label.get(str(ci), ci)

    # ---- validate BEFORE changing anything.
    # Two kinds of complaint, kept apart on purpose:
    #   unmatched - the anchor is not in the cue. Tolerated in small numbers (the proposal is
    #               DROPPED), because every other proposal is verified by its own anchor match and
    #               is untouched by this one's failure.
    #   fatal     - malformed, out of range, or a substitution that rewrites its own anchor beyond
    #               recognition. These say the pass is not what it claims to be, so they stop it.
    unmatched, fatal, planned = [], [], []
    for n, f in enumerate(fixes, 1):
        missing = [k for k in ('cue', 'from', 'to') if k not in f]
        if missing:
            fatal.append('correction %d is missing %s' % (n, ', '.join('"%s"' % k for k in missing)))
            continue
        try:
            ci = resolve(int(f['cue']))
        except (TypeError, ValueError):
            fatal.append('correction %d has a non-numeric cue %r' % (n, f['cue']))
            continue
        if ci < 1 or ci > len(blocks):
            fatal.append('correction %d names cue %d, outside 1..%d' % (n, ci, len(blocks)))
            continue
        joined = ' '.join(blocks[ci - 1][2])
        if norm(f['from']) not in norm(joined):
            unmatched.append('cue %d: %r does not occur in the cue text %r'
                             % (ci, f['from'], joined[:70]))
            continue
        if norm(f['from']) == norm(f['to']):
            unmatched.append('cue %d: "from" and "to" are identical' % ci)
            continue
        # ONLY MEANINGFUL ON A LONG ANCHOR. Normalised edit distance is inherently large on short
        # strings, and word swaps are exactly what this pass exists to make: the first version of
        # this check rejected 'chitin' -> 'kite' at 67% - a plainly correct fix, since chitin is
        # insect shell and the line is about a kite. Below the floor the verbatim anchor match IS
        # the guarantee; above it, "you rewrote the line" is a claim worth making.
        r = edit_ratio(f['from'], f['to']) if len(norm(f['from'])) >= a.min_ratio_len else 0.0
        if r > a.max_edit_ratio:
            # DROPPED, not fatal. Made fatal, this binned twelve good corrections on S01E34 over
            # one proposal at 52% ("If there's Amida's home" -> "If Zemida is at home", which is
            # right - Zemida is the character). A single over-reaching proposal is one bad
            # proposal; a pass that rewrites THROUGHOUT is caught by the rate guard below, which
            # is where "this is a rewrite, not a correction" can actually be established.
            unmatched.append('cue %d: %r -> %r rewrites %.0f%% of the anchor (cap %.0f%%)'
                             % (ci, f['from'], f['to'], 100 * r, 100 * a.max_edit_ratio))
            continue
        planned.append((ci, f['from'], f['to'], f.get('why', '')))

    touched = len({p[0] for p in planned})
    pct = 100.0 * touched / len(blocks)
    print('%d cue(s) in %s' % (len(blocks), os.path.basename(a.srt)))
    print('%d correction(s) proposed, %d applicable, touching %d cue(s) (%.1f%%)'
          % (len(fixes), len(planned), touched, pct))

    if fatal:
        print('\nREFUSING - %d proposal(s) are not corrections of this transcript:' % len(fatal))
        for q in fatal[:12]:
            print('   !! %s' % q)
        print('\nNothing has been changed.')
        return 3

    unmatched_pct = 100.0 * len(unmatched) / len(fixes) if fixes else 0.0
    if unmatched:
        print('\n%d proposal(s) (%.0f%%) could not be applied and are DROPPED:'
              % (len(unmatched), unmatched_pct))
        for q in unmatched[:8]:
            print('   -- %s' % q)
    if unmatched_pct > a.max_unmatched_pct:
        print('\nREFUSING - %.0f%% of proposals do not match, over the %.0f%% cap. A pass that'
              % (unmatched_pct, a.max_unmatched_pct))
        print('cannot quote the transcript it was given was not reading it. Nothing changed.')
        return 3

    if pct > a.max_change_pct:
        print('\nREFUSING - this pass would alter %.1f%% of cues, over the %.1f%% cap.' % (pct, a.max_change_pct))
        print('That is a rewrite, not a correction pass. Raise --max-change-pct deliberately if')
        print('you really mean it, having read the diff.')
        return 3

    if a.dry_run:
        print('\nDRY RUN - would apply:')
        for ci, frm, to, why in planned[:40]:
            print('   cue %-5d %r -> %r   %s' % (ci, frm, to, why))
        if len(planned) > 40:
            print('   ... and %d more' % (len(planned) - 40))
        return 0

    # ---- apply
    applied = []
    for ci, frm, to, why in planned:
        # Operate on the JOINED cue then re-wrap, so a correction spanning the display wrap
        # applies and the result is still a normally-shaped two-line cue.
        joined = norm(' '.join(blocks[ci - 1][2]))
        nfrm = norm(frm)
        if nfrm not in joined:
            continue                      # already validated; belt and braces
        blocks[ci - 1][2] = rewrap(joined.replace(nfrm, norm(to)))
        applied.append({'cue': ci, 'from': frm, 'to': to, 'why': why})

    # THE BACKUP DOES NOT GO IN THE LIBRARY. Plex offers every subtitle-shaped sidecar it finds
    # beside a video as an external track, so "<name>.eng.pre-correction.srt" gave the viewer TWO
    # English tracks with no way to tell them apart - caught on Danger Man S01E02 within minutes.
    # I then "fixed" that by switching to .txt, ASSERTING Plex ignores .txt. IT DOES NOT; those
    # showed up in the subtitle menu too. One guess became two wrong extensions, and because
    # nothing here may remove anything from the NAS, both became the user's cleanup rather than
    # mine.
    #
    # So stop reasoning about which extensions are safe. The only sidecar that is certainly safe is
    # one that is not in the media folder at all. Originals go to a local mirror instead, keyed by
    # the two path components above the file (show/season, or the film's own folder), which keeps
    # same-named episodes from different shows apart.
    # Reversible: copy the .srt back from the mirror over the corrected one.
    backup = _backup_path(a.srt, a.backup_dir)
    if not os.path.exists(backup):
        d = os.path.dirname(backup)
        if d and not os.path.isdir(d):
            os.makedirs(d)
        shutil.copy(a.srt, backup)          # never overwrite an existing original
    write_srt(a.srt, blocks)

    diff_path = a.srt[:-4] + '.corrections.json'
    io.open(diff_path, 'w', encoding='utf-8').write(
        json.dumps({'srt': a.srt, 'cues': len(blocks), 'cuesTouched': touched,
                    'pctTouched': round(pct, 2), 'proposed': len(fixes),
                    'droppedUnmatched': unmatched, 'corrections': applied},
                   indent=1, ensure_ascii=False))

    # provenance: say that this happened, next to the record of how the transcript was made
    prov = a.srt[:-4] + '.provenance.json'
    if os.path.exists(prov):
        try:
            d = json.load(io.open(prov, encoding='utf-8'))
            d['correctionPass'] = {'applied': len(applied), 'cuesTouched': touched,
                                   'pctTouched': round(pct, 2),
                                   'original': backup,
                                   'diff': os.path.basename(diff_path)}
            io.open(prov, 'w', encoding='utf-8').write(json.dumps(d, indent=1, ensure_ascii=False))
        except Exception as e:
            print('  (provenance not updated: %s)' % e)

    print('\napplied %d correction(s) across %d cue(s)' % (len(applied), touched))
    print('original -> %s' % backup)
    print('diff     -> %s' % os.path.basename(diff_path))
    return 0


if __name__ == '__main__':
    sys.exit(main())
