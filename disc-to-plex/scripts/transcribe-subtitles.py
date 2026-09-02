"""Generate an English subtitle sidecar for ONE media file from its audio.

FOR FILES WITH NO SUBTITLES AT ALL. This is not an alternative to OCR-ing a disc's own
subtitle stream - where a bitmap stream exists, ocr-subtitles.ps1 is strictly better, because
it reproduces what the programme's own subtitlers wrote. This exists for the case where the
disc carried nothing: on the media2 audit that was 546 files, for which the alternative is not
a worse subtitle but no subtitle.

WHAT IT PRODUCES IS A TRANSCRIPT, NOT A SUBTITLE TRACK
  - no speaker labels, no [DOOR CREAKS] sound cues, so it is not an SDH substitute
  - dialogue under music or heavy effects is where it degrades first
  - it is machine output, and it is recorded as such (see the provenance record below)
Ship it where the alternative is nothing; do not let it displace a real subtitle stream.

SETTINGS ARE MEASURED, NOT CHOSEN (2026-08-31, Day of the Triffids S01E03)

  * vad_filter MUST be off. With VAD on (min_silence 400 ms) every cue came out a correct
    PREFIX of its line with the tail cut - "Come on, let's eat." for audio that says "Come on.
    Let's eat. There's your pen knife." - and 8 gaps over 20s opened up, one of 125s. The
    output looked flawless: 308 well-formed cues, sensible durations, correct spellings.
    Reading the SRT could not reveal it; only comparing against the audio did. Hence the
    coverage guard below, which is the automated form of that comparison.
  * CUDA for whole episodes. cuda/float16 transcribes ~36x faster than cpu/int8 but pays ~25s
    fixed start-up, so break-even is ~72s of audio. An episode is far past that.
  * A lexicon may only fix spellings, and only where they are actually wrong. The first
    version rewrote "The Day of the Triffids" to "the triffids" while MISSING the real error
    ("trippy guns" for "triffid guns") - a correction pass that damages good text and leaves
    bad text is worse than none, because it makes the output look reviewed.
"""
import argparse, datetime, json, os, re, shutil, subprocess, sys, tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from whisper_device import load_model                                    # noqa: E402

TOOLS = r'D:/video/.transcode-tools/tool-paths.json'
LEXICON_DIR = r'D:/video/_lexicons'

# A cue longer than this is unreadable; shorter than this flashes past.
MIN_DUR, MAX_DUR, GAP, WRAP = 1.0, 8.0, 0.04, 42
# Refuse to write a transcript that stops early - the VAD failure's signature.
MIN_COVERAGE = 0.80
# Refuse output that is not recognisable English, mirroring the OCR pipeline's guard.
MIN_ENGLISH = 0.35
COMMON = set('the a an and or but if of to in on at for with from that this it is was are were '
             'be been being have has had do does did not no yes you i he she we they me him her '
             'them my your his our their what when where who how why can could will would should '
             'there here all any some more most just now then than so very'.split())


def hhmmss(sec):
    if sec < 0:
        sec = 0
    td = datetime.timedelta(seconds=sec)
    h, rem = divmod(td.seconds + td.days * 86400, 3600)
    m, s = divmod(rem, 60)
    return f'{h:02d}:{m:02d}:{s:02d},{int(td.microseconds / 1000):03d}'


def wrap(text, width=WRAP):
    text = re.sub(r'\s+', ' ', text).strip()
    if len(text) <= width:
        return [text]
    words, lines, cur = text.split(' '), [], ''
    for w in words:
        if len(cur) + len(w) + 1 <= width:
            cur = (cur + ' ' + w).strip()
        else:
            lines.append(cur)
            cur = w
    if cur:
        lines.append(cur)
    if len(lines) > 2:
        mid = len(text) // 2
        cut = min((i for i, c in enumerate(text) if c == ' '), key=lambda i: abs(i - mid),
                  default=mid)
        lines = [text[:cut].strip(), text[cut:].strip()]
    return lines[:2]


def load_lexicon(work, episode=''):
    """Return (fixes, prompt, path) for this work, preferring the EPISODE lexicon.

    RETURNS THE 'fixes' SUB-KEY, NOT THE WHOLE DOCUMENT. Returning the document made every
    top-level key a regex and every value its replacement, so `work` matched inside ordinary
    words and injected the programme title: "workshop" became "The Flumpsshop" and "working"
    became "The Flumpsing", four times in one episode, reported cheerfully as "4 lexicon
    fixes". Raw JSON keys also carry no \\b boundaries, which is why it matched mid-word.

    Patterns are validated here too - a non-string pattern or replacement is dropped rather
    than left to fail deep inside re.sub on some later episode.
    """
    def read(path):
        if not os.path.exists(path):
            return None
        return json.load(open(path, encoding='utf-8'))

    def clean(doc):
        """Validate fixes here rather than letting a bad entry fail inside re.sub later."""
        out = {}
        for pat, canon in (doc.get('fixes') or {}).items():
            if not isinstance(pat, str) or not isinstance(canon, str):
                print(f'[warn] lexicon entry ignored (not string->string): {pat!r}')
                continue
            try:
                re.compile(pat)
            except re.error as e:
                print(f'[warn] lexicon pattern ignored (bad regex {e}): {pat!r}')
                continue
            out[pat] = canon
        return out

    d = os.path.join(LEXICON_DIR, re.sub(r'[\\/:*?"<>|]', '_', work))
    show = read(os.path.join(d, '_show.json'))
    ep = read(os.path.join(d, f'{episode}.json')) if episode else None

    # EPISODE WINS. Guest cast is where ASR fails - the show base only carries recurring names,
    # which for a series like Danger Man is one name. Fall back to the show base when the
    # episode has no lexicon (a film, or an extra with no SxxEyy).
    fixes = {}
    if show:
        fixes.update(clean(show))
    if ep:
        fixes.update(clean(ep))
    prompt = (ep or show or {}).get('prompt') or ''
    used = (os.path.join(d, f'{episode}.json') if ep
            else os.path.join(d, '_show.json') if show else '')
    return fixes, prompt, used


def apply_lexicon(segments, fixes):
    """Fix SPELLINGS only, and only where they are wrong. Never rewrites dialogue."""
    def repl(canon):
        def f(m):
            found = m.group(0)
            if found.lower() == canon.lower():
                return found                       # already correct - do not touch its case
            return canon.capitalize() if found[:1].isupper() else canon
        return f

    changed = []
    for seg in segments:
        before = seg['text']
        t = before
        for pat, canon in fixes.items():
            t = re.sub(pat, repl(canon), t, flags=re.I)
        if t != before:
            changed.append((before, t))
            seg['text'] = t
    return changed


def english_fraction(segments):
    lines = [s['text'] for s in segments if len(s['text'].split()) >= 3]
    if not lines:
        return 0.0
    ok = sum(1 for l in lines if COMMON & set(re.findall(r"[a-z']+", l.lower())))
    return ok / len(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('--out')
    ap.add_argument('--work', default='', help='programme name, selects the lexicon')
    # MEDIUM, NOT SMALL - decided 2026-09-01 after a user caught the failure in Plex.
    #
    # `small` does not fail loudly. It degrades over a STRETCH of difficult audio: cues get long
    # (5.6s mean against 1.6s normal), punctuation and casing vanish, and the words become
    # invention. On Danger Man S01E02 a hotel password exchange came out as
    #     "eggs for two fuck too sad for a"
    # where the actual line is "Coffee and eggs for two. / For two, sir? / For two."
    # `medium` transcribes that same audio correctly, punctuation intact, on the first attempt.
    #
    # THE WHOLE-FILE GATES CANNOT SEE THIS. That file scored coverage 0.999 and englishFraction
    # 0.975 and passed everything, because eight bad cues in 331 do not move an average. A sweep
    # of the 67 Danger Man transcripts found degraded stretches in 65 of them - 867 cues - plus
    # nine profanities in a 1960s ITC series that contains none. See check-transcript-quality.py,
    # which exists so this is detected by a script instead of by a viewer.
    #
    # It costs 10x realtime against small's 17x - about 2.5 min for a 25-min episode instead of
    # 1.5. That is not the expensive part of this pipeline and never was.
    ap.add_argument('--model', default='medium')
    ap.add_argument('--keep-wav', action='store_true')
    ap.add_argument('--force', action='store_true', help='overwrite an existing sidecar')
    a = ap.parse_args()

    src = a.src
    if not os.path.exists(src):
        print(f'[failed] source not found: {src}')
        return 2
    out = a.out or (os.path.splitext(src)[0] + '.eng.srt')

    # CREATE-ONLY. Never clobber a subtitle we did not make; this pipeline must not be able
    # to overwrite an OCR'd or disc-derived sidecar.
    if os.path.exists(out) and not a.force:
        print(f'[skip] sidecar already exists: {os.path.basename(out)}')
        return 0

    paths = json.load(open(TOOLS, encoding='utf-8'))
    ff = paths['ffmpeg']
    ffprobe = os.path.join(os.path.dirname(ff), 'ffprobe.exe')

    dur = subprocess.run([ffprobe, '-v', 'error', '-show_entries', 'format=duration',
                          '-of', 'csv=p=0', src], capture_output=True, text=True).stdout.strip()
    try:
        duration = float(dur)
    except ValueError:
        print(f'[failed] no duration from ffprobe: {src}')
        return 2

    # Load the lexicon BEFORE transcribing: its prompt biases the decoder, which is where
    # proper nouns are actually won. Doing it after decoding would waste it - a post-pass can
    # only repair spellings it was told to expect, whereas the prompt shapes the decode itself.
    # The episode key comes from the FILENAME, which is Plex-named by this point, so it is the
    # same SxxEyy the lexicon builder keyed on. No match (a film, or an extra) falls back to
    # the show base.
    m = re.search(r'[Ss](\d{1,2})[Ee](\d{1,3})', os.path.basename(src))
    epkey = f'S{int(m.group(1)):02d}E{int(m.group(2)):02d}' if m else ''
    fixes, prompt, lexpath = load_lexicon(a.work, epkey) if a.work else ({}, '', '')

    # TEMP AUDIO GOES TO A SCRATCH DIR, NEVER BESIDE THE OUTPUT.
    # This used to be `<out>.tmp16k.wav`, and `out` is a NAS path whenever this runs as a
    # correction pass over the published library. Cleanup sat in a `finally` covering only the
    # transcribe call, so a KILLED process left the wav behind: 48 MB and 94 MB were found
    # stranded in Danger Man's Season 01 and Season 02 folders on 2026-09-02 - inside the Plex
    # library, and unremovable by this pipeline because the NAS is delete-protected, so they had
    # to be handed to the user. A scratch dir makes the worst case litter in %TEMP% instead.
    tmpdir = tempfile.mkdtemp(prefix='transcribe-')
    wav = os.path.join(tmpdir, 'audio.tmp16k.wav')

    try:
        subprocess.run([ff, '-v', 'error', '-i', src, '-vn', '-ac', '1', '-ar', '16000',
                        '-c:a', 'pcm_s16le', '-y', wav], check=True)
        model, dev = load_model(a.model, prefer_cuda=True, verbose=False)
        segs, info = model.transcribe(
            wav, language='en', beam_size=5,
            initial_prompt=prompt or None,     # TVDB cast + recurring terms, via build-lexicon.ps1
            vad_filter=False,                  # see module docstring - VAD ate the line tails
            condition_on_previous_text=False,  # one bad guess must not cascade
            word_timestamps=True,
        )
        segments = [{'start': s.start, 'end': s.end, 'text': s.text.strip()}
                    for s in segs if s.text.strip()]     # consume inside the guard
    except subprocess.CalledProcessError as e:
        print(f'[failed] audio extraction failed: {e}')
        return 2
    except Exception as e:
        print(f'[failed] transcription error: {type(e).__name__}: {e}')
        return 2
    finally:
        if a.keep_wav:
            print(f'[info] --keep-wav left {wav}')
        else:
            shutil.rmtree(tmpdir, ignore_errors=True)

    if not segments:
        print('[failed] transcriber produced no segments')
        return 2

    changed = apply_lexicon(segments, fixes)

    # --- GUARDS -------------------------------------------------------------------------
    coverage = segments[-1]['end'] / duration if duration else 0
    if coverage < MIN_COVERAGE:
        print(f'[failed] transcript covers only {coverage:.0%} of {duration/60:.1f} min '
              f'(floor {MIN_COVERAGE:.0%}) - refusing. This is the signature of speech being '
              f'dropped; do not ship a subtitle that stops early.')
        return 3
    frac = english_fraction(segments)
    if frac < MIN_ENGLISH:
        print(f'[failed] only {frac:.0%} of lines contain a common English word '
              f'(floor {MIN_ENGLISH:.0%}) - refusing.')
        return 3

    # --- does the transcript mention anyone the episode's cast list names? ------------------
    # Not a pass/fail - a name can simply go unspoken - but NO overlap at all is a strong hint
    # that the file is not the episode its filename claims. Danger Man S01E01 transcribed as
    # Logan/Maria/Vienna/Budapest while its lexicon named Delroy/Scarlotti/Mego: the per-episode
    # prompt turned out to be a misnaming detector as much as a spelling aid.
    names = [w for w in re.findall(r"[A-Z][a-z]{2,}", prompt)] if prompt else []
    body = ' '.join(s['text'] for s in segments)
    seen = sorted({w for w in names if re.search(r'\b' + re.escape(w) + r'\b', body)})
    overlap = len(seen)
    if names and overlap == 0:
        print(f'[warn] none of the {len(names)} name(s) from the episode lexicon appear in the '
              f'transcript - this file may not be the episode its name claims')
    elif names:
        print(f'[info] lexicon names heard: {", ".join(seen[:8])}')

    # --- write -------------------------------------------------------------------------
    rows = []
    for i, s in enumerate(segments):
        start, end = s['start'], min(s['end'], s['start'] + MAX_DUR)
        if end - start < MIN_DUR:
            end = start + MIN_DUR
        if i + 1 < len(segments):
            end = min(end, segments[i + 1]['start'] - GAP)
        if end <= start:
            end = start + 0.6
        rows.append((start, end, wrap(s['text'])))

    tmp = out + '.partial'
    with open(tmp, 'w', encoding='utf-8') as fh:
        for i, (st, en, lines) in enumerate(rows, 1):
            fh.write(f'{i}\n{hhmmss(st)} --> {hhmmss(en)}\n' + '\n'.join(lines) + '\n\n')
    os.replace(tmp, out)      # atomic: a reader never sees a half-written sidecar

    # --- provenance ---------------------------------------------------------------------
    # Recorded because "which SRTs did we generate?" had NO answer for the existing library:
    # naming could not separate our OCR output from anything else, and only a structural
    # argument settled it. Machine-transcribed subtitles must never be that ambiguous.
    rec = {
        'srt': out, 'source': src, 'work': a.work,
        'method': 'audio-transcription', 'model': a.model, 'device': dev,
        'vad': False, 'cues': len(rows),
        'coverage': round(coverage, 3), 'englishFraction': round(frac, 3),
        'lexicon': lexpath or None, 'lexiconPrompted': bool(prompt),
        'lexiconEpisodeKey': epkey or None, 'lexiconFixes': len(changed),
        'promptNameOverlap': overlap,
        'generated': datetime.datetime.now().strftime('%Y-%m-%d %H:%M:%S'),
        'note': 'MACHINE TRANSCRIPT - not disc-derived, no speaker labels, no sound cues',
    }
    with open(os.path.splitext(out)[0] + '.provenance.json', 'w', encoding='utf-8') as fh:
        json.dump(rec, fh, indent=1)

    print(f'[ok] {len(rows)} cues, coverage {coverage:.0%}, english {frac:.0%}, '
          f'{len(changed)} lexicon fix(es), {dev} -> {os.path.basename(out)}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
