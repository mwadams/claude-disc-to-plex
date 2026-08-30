"""Decide a rip's AUDIO manifest fields from CONTENT, and write the evidence down.

WHY THIS EXISTS
---------------
Audio selection was being authored from EXPECTATION and corrected later, which is the same defect
class as confirming a rip from a grep of anticipated strings: the check can only find what it
already believes. Every one of these was written into a manifest (or a disposition) as fact and
was wrong:

  Thunderball    a:5 recorded as "commentary 2 - Peter Hunt & John Hopkins" because the edition
                 advertises two commentaries. It is an ITALIAN DUB tagged `eng`.
  Thunderball    a:1 assumed a second English mix. It is the LOSSY DTS CORE of a:0 - subtracting
                 the two leaves a residual 54 dB below the signal.
  Sleep Dealer   whole film tagged `eng`. The original is SPANISH.
  Fantasia       extras carry SPANISH subtitles tagged `eng`.
  The Italian Job  disc metadata order mapped onto ffprobe ordinals - confident, twice wrong.

So this script never infers from the tag, the title, or the edition's reputation. It measures:

  1. ffprobe   - codec, channels, bitrate, language TAG (recorded, never trusted)
  2. whisper   - what language is ACTUALLY SPOKEN, and what is said, at two separate offsets
  3. subtraction - every pair downmixed to mono and subtracted. A lossy core or a duplicate
                 cancels to far below the signal; two genuinely different mixes do not.

It writes `<src>.tracks.json` and proposes the manifest audio fields. `assert-tracks-analysed.ps1`
refuses to queue a manifest whose audio decisions disagree with this evidence.

USAGE
    python analyze-tracks.py "D:/video/_stage/x/Film_t00.mkv" [--offsets 1800 3600] [--model base]
"""

import argparse, difflib, json, re, subprocess, sys, tempfile, time
try:
    import numpy as np
except ImportError:                    # the lossy-core check needs it; absence must be LOUD, not silent
    np = None

# The transcripts are foreign-language by design. On Windows a redirected stdout defaults to
# cp1252, so printing a Spanish or French sample raised UnicodeEncodeError and killed the run
# AFTER the expensive whisper work - and only when redirected to a file, which is exactly how it
# is invoked from a loop or a log. Never let the report crash on the thing it exists to report.
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass
from pathlib import Path

TOOLS = json.loads(Path(r'D:\video\.transcode-tools\tool-paths.json').read_text())
FFMPEG = TOOLS['ffmpeg']
FFPROBE = str(Path(FFMPEG).parent / 'ffprobe.exe')

# INPUT OPTIONS FOR THE SOURCE. Empty for a plain file; for a DVD the source is a FOLDER and ffprobe
# cannot open a directory - it needs `-f dvdvideo -title N`, the same path transcode.ps1 encodes
# from, so the ordinals here are the ordinals `audioTracks` will mean.
#
# Without this, `assert-tracks-analysed.ps1` asked for `<src>.title<N>.tracks.json` on any DVD item
# claiming a commentary and NOTHING COULD PRODUCE IT: a guard demanding evidence its own
# evidence-producer cannot generate. Found on Farscape S1 (2026-08-29). The guard's header already
# documents this exact ffprobe-cannot-open-a-directory defect for its EXEMPTION probe; it was still
# open on the evidence side.
SRC_OPTS = []


# WHAT SEPARATES A COMMENTARY FROM DIALOGUE IS VARIETY, NOT VOLUME - and some of these words are
# simply ordinary English.
#
# This was one flat pattern counted with `len(findall(text)) >= 2`, and both halves of that were
# wrong. On Farscape S1 D6 the EPISODE's dialogue hit `we take` and `we were`, reached 2, and was
# excluded from the primary election - so the real commentary was elected primary and the 5.1
# programme mix came out labelled `commentary`. assert-tracks-analysed.ps1 would have passed that
# manifest; it was caught only by reading the transcripts.
#
# Measured over the labelled evidence files, `take` alone accounts for almost every false hit: the
# S2 D6 EPISODE scores 5 on `Take`/`take`/`takes` and nothing else, already over the old threshold.
# It escaped only because that disc's commentary scored 20, so both were hinted and the exclusion
# was skipped - the right answer by luck.
#
# So: split the vocabulary by how much a hit is worth, and count DISTINCT phrases. A commentary
# ranges over production vocabulary; dialogue repeats one common word. On the 9 labelled streams
# available, distinct-counting separates all 9 with room to spare, where occurrence-counting
# separates 7.
COMMENTARY_STRONG = re.compile(
    r'\b(we (shot|filmed|re-?shot)|the (director|script|screenplay|studio|sequence|set|scene)|'
    r'this shot|the (film|movie)|footage|producers?|first take|another take|the edit)\b', re.I)
# `the crew` was in this list for one run. The World's Fastest Indian extra says it in ordinary
# narration and was classed as commentary talk - a film about a racing team naturally has a crew,
# as do war and sea pictures. Anything a subject can plausibly have is not production vocabulary.

# Words a commentary uses freely and a drama can use in passing. Never conclusive alone.
COMMENTARY_WEAK = re.compile(
    r'\b(we (had|were|wanted)|originally|actually|you can see|i remember|camera|takes?|edit)\b',
    re.I)


def commentary_talk(text):
    """(distinct strong phrases, distinct weak phrases, is_commentary_talk) for a transcript."""
    strong = {m.group(0).lower() for m in COMMENTARY_STRONG.finditer(text)}
    weak = {m.group(0).lower() for m in COMMENTARY_WEAK.finditer(text)}
    weak -= strong
    return strong, weak, bool(strong) or len(weak) >= 3

# Audio description narrates ACTION between lines of dialogue, in the third person present tense.
#
# THE VERB LIST ALONE IS NOT ENOUGH, AND IT MISSED A WHOLE TRACK. The Iron Lady's a:2 (2026-08-30)
# is an audio description - "She smiles at Carol in the mirror", "Footage of masked IRA men firing
# volleys over a coffin", "In the present, a troubled Margaret sleeps fitfully" - and scored ZERO
# hits at the two offsets this script samples, because its narration uses plural subjects and verbs
# outside the list ("Margaret and her ministers walk along the corridor", "protesters march
# carrying a banner"). It fell through to `alternateMix` on similarity alone, and
# assert-tracks-analysed.ps1 then correctly refused the truthful manifest that tagged it as AD.
#
# So the list gains the verbs that actually appeared, plus NARRATIVE FRAMING phrases - "footage
# of", "flashbacks of", "in the present", "gets to their feet". Those describe the PICTURE and are
# vanishingly rare in dialogue, which is what makes them worth more than another verb.
AD_HINTS = re.compile(
    r'\b(he |she |they )?(walks|turns|looks|opens|closes|enters|leaves|smiles|nods|stares|reaches|'
    r'steps|drives|watches|sleeps|stands|sits|holds|pulls|pushes|climbs|hands|carries|marches)\b|'
    r'\b(cut to|fade|on screen|in the distance|a man|a woman)\b|'
    r'\b(gets? to (his|her|their) feet|footage of|flashbacks? (of|to)|archive footage|a shot of|'
    r'close-?up|in the present|the camera (pans|cuts|moves)|titles? appear|credits roll)\b', re.I)


def ad_excess(text, ptext):
    """AD hints in this track that the PRIMARY's transcript does not also carry.

    COUNT THE EXCESS, NOT THE HITS. An `alternateMix` - a restored mono beside a 5.1 remix - speaks
    the SAME WORDS as the primary, so any hint the primary's dialogue happens to contain appears in
    the alternate mix too. Scoring raw hits therefore promotes an ordinary alternate mix to
    "audio description" as soon as the film's own dialogue says "he turns" three times, and the
    wider vocabulary above makes that materially more likely than it was.

    An audio description is defined by what it says that the programme audio does NOT. Subtracting
    the primary's own score keeps the widening safe: measured over every tracks.json on disk
    (2026-08-30), this flips exactly one verdict - The Iron Lady's a:2, the true positive - and
    leaves Land and Freedom's genuine alternateMix (sim 0.73, 0 hits either way) alone.
    """
    return max(0, len(AD_HINTS.findall(text)) - len(AD_HINTS.findall(ptext)))


# whisper returns ISO 639-1 ("es"); disc tags are ISO 639-2 ("spa"). Comparing the first two
# characters calls a CORRECTLY tagged Spanish track a mismatch - and a guard that cries wolf is a
# guard that gets ignored. Map explicitly.
ISO2TO3 = {
    'en': 'eng', 'es': 'spa', 'fr': 'fra', 'de': 'deu', 'pt': 'por', 'it': 'ita', 'nl': 'nld',
    'ja': 'jpn', 'zh': 'zho', 'ru': 'rus', 'sv': 'swe', 'da': 'dan', 'no': 'nor', 'fi': 'fin',
    'pl': 'pol', 'cs': 'ces', 'hu': 'hun', 'tr': 'tur', 'ko': 'kor', 'ar': 'ara', 'he': 'heb',
    'el': 'ell', 'th': 'tha', 'hi': 'hin', 'uk': 'ukr', 'ro': 'ron', 'ca': 'cat',
}

def same_language(spoken, tag):
    """True when the spoken language is consistent with the disc's tag (or cannot be judged)."""
    if not spoken or not tag:
        return True
    tag = tag.lower()[:3]
    if tag in ('und', 'mul', 'zxx'):
        return True
    three = ISO2TO3.get(spoken.lower()[:2])
    # some discs use the bibliographic code (fre/ger/dut) rather than the terminological one
    alt = {'fra': 'fre', 'deu': 'ger', 'nld': 'dut', 'ces': 'cze', 'ell': 'gre', 'zho': 'chi',
           'ron': 'rum', 'fas': 'per', 'isl': 'ice', 'mkd': 'mac', 'msa': 'may', 'mya': 'bur'}
    ok = {three, alt.get(three, three)}
    return tag in ok


# A language call below this confidence is NOISE, not a finding. whisper returned en(0.17) for a
# plainly French track sampled over an action scene - shouting and effects carry no language.
LANG_CONFIDENCE_FLOOR = 0.55

LOSSLESS = {'dts-hd', 'truehd', 'flac', 'pcm_s16le', 'pcm_s24le', 'mlp', 'alac'}
# how far below the signal the difference must sit before two tracks are "the same content"
REDUNDANT_DB = 25.0

# Report-only floor for the delay/gain-corrected lossy-core check. See compare_aligned().
#
# THIS MUST NOT BECOME A DROP THRESHOLD. Measured on Sunrise (1927) t00, 30 s @ 1800 s:
#
#   a:0 vs a:1   naive -3.5 dB -> 16.5 dB aligned (lag -13.2 ms)   GENUINE LOSSY CORE
#   a:2 vs a:3   naive -3.4 dB -> 21.3 dB aligned (lag -13.2 ms)   GENUINE LOSSY CORE
#   a:0 vs a:2   naive -6.5 dB ->  0.0 dB aligned                  different scores, rejected
#   a:0 vs a:4   naive -9.0 dB -> 15.9 dB aligned                  *** THE COMMENTARY ***
#
# The commentary sits level with a real core because it carries the film's score underneath the
# speech, so the shared music bed correlates. Any cutoff that catches a:0/a:1 also catches a:0/a:4,
# and silently dropping a commentary is a far worse outcome than shipping a redundant core - it is
# the failure this project has paid for repeatedly. So this check RAISES A REPORT for a human or an
# agent to resolve with identify-audio.py, and changes nothing about what ships.
CORE_SUSPECT_DB = 12.0


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def probe_streams(src):
    r = run([FFPROBE, '-v', 'error', '-select_streams', 'a', '-show_entries',
             'stream=index,codec_name,profile,channels,bit_rate:stream_tags=language,title',
             '-of', 'json'] + SRC_OPTS + [src])
    out = []
    for i, s in enumerate(json.loads(r.stdout).get('streams', [])):
        t = s.get('tags', {}) or {}
        br = s.get('bit_rate')
        out.append({
            'a': i,
            'codec': s.get('codec_name', ''),
            'profile': (s.get('profile') or ''),
            'channels': s.get('channels'),
            'bitrate': int(br) if br and str(br).isdigit() else None,
            'langTag': t.get('language'),
            'titleTag': t.get('title'),
        })
    return out


def duration(src):
    r = run([FFPROBE, '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0']
            + SRC_OPTS + [src])
    try:
        return float(r.stdout.strip())
    except ValueError:
        return 0.0


def rms_db(src, filtergraph):
    r = run([FFMPEG, '-hide_banner', '-ss', str(rms_db.start), '-t', str(rms_db.dur)]
            + SRC_OPTS + ['-i', src,
             '-filter_complex', filtergraph, '-map', '[x]', '-f', 'null', '-'])
    m = re.findall(r'RMS level dB:\s*(-?[\d.]+|-?inf)', r.stderr)
    if not m:
        return None
    if m[-1].endswith('inf'):
        # DIGITAL SILENCE IS A MEASUREMENT, NOT A FAILURE. Returning None here made a
        # BIT-IDENTICAL duplicate track invisible: its difference signal is digitally silent,
        # astats reports -inf, and the comparison was silently skipped - so the one pair that is
        # most certainly the same content was the one pair never flagged. compare() distinguishes
        # "the SOURCE is silent" (unjudgeable) from "the DIFFERENCE is silent" (identical).
        return float('-inf')
    return float(m[-1])


DM = 'aformat=channel_layouts=mono:sample_fmts=fltp:sample_rates=48000'
AST = 'astats=metadata=1:reset=0'


def compare(src, i, j):
    """Return dB by which (a:i - a:j) sits below a:i. Large => same content."""
    a = rms_db(src, f'[0:a:{i}]{DM},{AST}[x]')
    d = rms_db(src, f'[0:a:{i}]{DM}[p];[0:a:{j}]{DM},volume=-1[q];'
                    f'[p][q]amix=inputs=2:normalize=0,{AST}[x]')
    if a is None or d is None:
        return None
    if a == float('-inf'):
        return None          # the SOURCE segment is silent - nothing to judge either way
    if d == float('-inf'):
        return 999.0         # the DIFFERENCE is digital silence - the tracks are identical
    return a - d


def _is_lossless(s):
    return any(x in (s['codec'] + s['profile']).lower() for x in LOSSLESS)


def core_candidate(a, b):
    """A lossless track beside a lossy one - the shape a lossy CORE always has."""
    return _is_lossless(a) != _is_lossless(b)


def _pcm(src, i):
    """Decode the comparison window of a:i to mono float32 @48k."""
    r = subprocess.run([FFMPEG, '-hide_banner', '-v', 'error',
                        '-ss', str(rms_db.start), '-t', str(rms_db.dur)]
                       + SRC_OPTS + ['-i', src,
                        '-map', f'0:a:{i}', '-ac', '1', '-ar', '48000', '-f', 'f32le', '-'],
                       capture_output=True)
    if r.returncode != 0 or not r.stdout:
        return None
    return np.frombuffer(r.stdout, dtype='<f4').astype(np.float64)


def compare_aligned(src, i, j, max_lag_ms=200.0):
    """Residual dB below signal AFTER correcting decoder delay and level.

    WHY THIS EXISTS - compare() above is sample-aligned and gain-naive, and that is a fail-OPEN
    on the exact class the check was built for. A TrueHD track and its own AC-3 core differ by a
    ~12.8 ms decoder delay plus a dialnorm gain offset, so inverting and mixing them leaves a
    residual barely below the signal: the pair reads as INDEPENDENT CONTENT and both tracks ship.
    Thunderball's a:1 was a lossy core; on Sunrise (1927) the analyzer proposed keeping all five
    streams with redundantWith=None throughout, and two of those five were cores.

    Correcting for lag and gain separates the cases unambiguously - measured on Sunrise:
        a:0 vs a:1  r = 0.9922      a:2 vs a:3  r = 0.9901     (cores)
        a:0 vs a:2  r = 0.018                                   (two genuinely different scores)

    Returns (dB, lag_ms, gain_dB), or None when it cannot measure.
    """
    x = _pcm(src, i)
    y = _pcm(src, j)
    if x is None or y is None:
        return None
    n = min(len(x), len(y))
    if n < 48000:                      # under a second of overlap - not worth a verdict
        return None
    x, y = x[:n], y[:n]
    if not np.any(x) or not np.any(y):
        return None

    # FFT cross-correlation, searched only within a plausible decoder-delay window. A wider
    # search invites a spurious peak on periodic material (music beds especially).
    nfft = 1 << int(np.ceil(np.log2(2 * n)))
    cc = np.fft.irfft(np.fft.rfft(x, nfft) * np.conj(np.fft.rfft(y, nfft)), nfft)
    max_lag = int(48000 * max_lag_ms / 1000.0)
    if max_lag < 1 or 2 * max_lag + 1 > len(cc):
        return None
    cand = np.concatenate([cc[:max_lag + 1], cc[-max_lag:]])
    idx = int(np.argmax(np.abs(cand)))
    lag = idx if idx <= max_lag else idx - (2 * max_lag + 1)

    if lag > 0:
        xs, ys = x[lag:], y[:n - lag]
    elif lag < 0:
        xs, ys = x[:n + lag], y[-lag:]
    else:
        xs, ys = x, y
    if len(xs) < 48000:
        return None

    # Least-squares gain: the scale of ys that best explains xs. This is the dialnorm difference.
    denom = float(np.dot(ys, ys))
    if denom <= 0:
        return None
    g = float(np.dot(xs, ys) / denom)
    resid = xs - g * ys
    ps, pr = float(np.dot(xs, xs)), float(np.dot(resid, resid))
    if ps <= 0:
        return None
    if pr <= 0:
        return (999.0, lag / 48.0, 0.0)
    gain_db = 20 * np.log10(abs(g)) if g else -99.0
    return (10 * np.log10(ps / pr), lag / 48.0, gain_db)


def transcribe(model, src, track, offsets, dur):
    """Returns (lang, prob, texts, agreed, status).

    status is 'ok' when at least one offset was extracted and transcribed, 'failed' otherwise.
    A FAILED transcription must never present like "no speech on this stream": extraction
    failures used to `continue` silently, so a stream ffmpeg could not read (or a whisper crash
    under contention) came back looking exactly like a silent track - the same defect class as
    an OCR failure recorded as "no usable text". The caller marks failed streams
    role='analysis-failed', which the manifest gate refuses to accept claims about.
    """
    texts, langs, failures = [], [], []
    with tempfile.TemporaryDirectory() as td:
        for off in offsets:
            wav = Path(td) / f'a{track}_{off}.wav'
            r = run([FFMPEG, '-y', '-hide_banner', '-v', 'error', '-ss', str(off)]
                    + SRC_OPTS + ['-i', src,
                     '-t', str(dur), '-map', f'0:a:{track}', '-ac', '1', '-ar', '16000', str(wav)])
            if not wav.exists() or wav.stat().st_size < 1000:
                failures.append('offset %ds: extraction produced no usable wav (%s)'
                                % (off, (r.stderr or '').strip()[-120:] or 'no ffmpeg error text'))
                continue
            try:
                segs, info = model.transcribe(str(wav), beam_size=1)
                text = ' '.join(s.text for s in segs).strip()
                texts.append(text)
                # AN EMPTY TRANSCRIPT CANNOT SUPPORT A LANGUAGE CLAIM. whisper reports a language
                # for pure MUSIC - Metropolis (1927)'s orchestral score came back "la" (Latin) at
                # 0.64 with a BLANK transcript, self-consistently across both offsets, so neither
                # the confidence floor nor cross-offset agreement caught it. That bogus "la"
                # became the primary language, which reclassified the disc's genuine English
                # commentary (1.00) as a DUB and dropped it from the proposal. Only count a
                # language vote from an offset that produced actual words.
                if text:
                    langs.append((info.language, round(info.language_probability, 2)))
            except Exception as exc:
                failures.append('offset %ds: whisper failed: %s: %s'
                                % (off, type(exc).__name__, exc))
    def _has_words(t):
        # WHISPER ON MUSIC DOES NOT RETURN AN EMPTY STRING - IT RETURNS JUNK.
        #
        # The blank test below is right in principle and too literal in practice. On City Girl
        # (1930, silent) whisper transcribed the orchestral score as "1.0% 2.0% 2.0% ..." - not
        # empty, so status became 'ok', the score never became `music`, `silentFilm` stayed False,
        # and primary election then picked the only reliably-spoken stream: THE COMMENTARY. The
        # film's own score came out `commentary?` and the commentary came out `primary` - exactly
        # inverted, and the manifest that described the disc correctly was refused by the gate.
        #
        # A transcript with no alphabetic run of two or more characters carries no words in any
        # language whisper reports. Percentages, digits, stray punctuation and lone letters are
        # not speech. (Two chars, not one: "I" and "a" are words but never appear alone across a
        # whole sample, whereas OCR-ish noise is full of single characters.)
        import re as _re
        return bool(_re.search(r'[^\W\d_]{2,}', t or '', _re.UNICODE))

    if texts and not any(_has_words(t) for t in texts):
        # Every offset transcribed cleanly and none produced WORDS: an EARNED emptiness
        # (the caller separates score from phantom silence by measuring the audio level).
        status = 'no-speech'
    elif texts or langs:
        status = 'ok'
    else:
        status = 'failed'
    if failures:
        # loud, per-offset, even when the other offset succeeded - a half-measured stream is
        # weaker evidence and the agreement flag below will already be False.
        for f in failures:
            print(f'  a:{track} TRANSCRIBE FAILURE - {f}')
    # TWO INDEPENDENT MEASUREMENTS MUST AGREE - the same rule the subtitle work uses for anchors.
    # A single confident-looking call is not evidence: sampled over an action scene, whisper called
    # a Portuguese track English at 0.86 ("I'll find you. Oh, no! Yeah!") because shouting and
    # effects carry no language at all. A confidence floor cannot catch that; disagreement can.
    if not langs:
        return None, 0.0, texts, False, status
    names = [l for l, _ in langs]
    lang = max(set(names), key=names.count)
    prob = max([p for l, p in langs if l == lang], default=0.0)
    agreed = len(set(names)) == 1 and len(names) > 1
    return lang, prob, texts, agreed, status



def content_tokens(text):
    """Lowercase alphabetic tokens, minus the filler that dominates shouted action audio."""
    stop = {'the','a','an','and','or','but','is','it','to','of','in','on','at','i','you','he',
            'she','we','they','oh','ah','no','yes','yeah','hey','get','down','do','dont','not'}
    toks = re.findall(r"[a-z']{3,}", text.lower())
    return {t for t in toks if t not in stop}


def similarity(a_text, b_text):
    """Jaccard overlap of content words.

    NOT difflib on raw strings. whisper segments the same audio differently between runs, so a
    character-level ratio swung 0.81 -> 0.45 for ONE track across two runs of this very script -
    straddling the 0.5 threshold and flipping its role from 'alternateMix' to 'commentary?'. A
    classifier whose verdict depends on which run you look at cannot gate a manifest.
    """
    A, B = content_tokens(a_text), content_tokens(b_text)
    if not A or not B:
        return 0.0
    return len(A & B) / float(len(A | B))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('--offsets', type=int, nargs='+')
    ap.add_argument('--dur', type=int, default=75)
    ap.add_argument('--model', default='base')
    ap.add_argument('--dvd-title', type=int, metavar='N',
                    help="source is a DVD FOLDER: read it through `-f dvdvideo -title N`, the same "
                         "path transcode.ps1 encodes from. Output defaults to "
                         "<src>.title<N>.tracks.json, which is what assert-tracks-analysed.ps1 "
                         "requires when several titles share one disc folder.")
    ap.add_argument('--out')
    a = ap.parse_args()
    # Arm the DVD input options BEFORE anything probes the source.
    if getattr(a, 'dvd_title', None):
        globals()['SRC_OPTS'] = ['-f', 'dvdvideo', '-title', str(a.dvd_title)]

    src = a.src
    dur_total = duration(src)

    # REFUSE AN IMPLAUSIBLE DURATION - it means a broken container, not a long film.
    #
    # A truncated MakeMKV rip reports a nonsense header: Back to the Future t18 died mid-rip and
    # claimed 77 HOURS. Sampling offsets are derived from that duration, so this script then asked
    # ffmpeg to seek to -ss 97010 and -ss 166304 in a 25 GB file. Each seek scans the whole file
    # looking for a position that does not exist, taking ~13 minutes, and there is one per sample
    # per stream. The analyse track was wedged for half an hour on a file already known to be
    # garbage, and the manifest waiting on it could not be authored.
    #
    # No disc title runs 12 hours. Refusing here is not merely faster - it turns "silently wedged"
    # into a NAMED failure the operator can act on, and the caller records nothing and retries,
    # which is the correct outcome for a source that needs re-ripping rather than re-analysing.
    if dur_total is None or dur_total <= 0:
        print(f'REFUSING: {src} reports no usable duration - the container is broken or the file '
              f'is still being written. Re-rip it, or wait for the writer to finish.')
        return 2
    if dur_total > 12 * 3600:
        print(f'REFUSING: {src} reports a duration of {dur_total/3600:.1f} HOURS. No disc title '
              f'runs that long - this is a broken/truncated container (a killed rip reports a '
              f'bogus header). Re-rip the title; analysing it would seek for hours and learn '
              f'nothing.')
        return 2
    # Sample WELL INSIDE the film: titles and end credits are music over every track alike, which
    # makes distinct mixes look identical and silent tracks look like failures.
    offsets = a.offsets or [int(dur_total * f) for f in (0.35, 0.6)]
    rms_db.start, rms_db.dur = offsets[0], min(30, a.dur)

    streams = probe_streams(src)
    if not streams:
        # NO AUDIO IS A FINDING, NOT A FAILURE.
        #
        # This returned 1, and the analyse loop treats a non-zero exit as "unexplained failure -
        # record nothing, retry next pass". For a STILLS GALLERY, which by definition carries no
        # audio, that is an infinite retry: five Back to the Future galleries were re-analysed
        # every pass forever, starving the real work behind them. Exactly the shape the rip loop
        # hit on the same titles, and the same shape as the OCR loop's exhausted-vs-retry lesson:
        # a permanent condition must be recorded as settled, or it is retried until someone looks.
        #
        # Write the evidence file so the loop counts this as analysed, with an empty stream list
        # and a proposal that ships no audio - which is the correct manifest for a gallery.
        out = a.out or (src + ('.title%d.tracks.json' % a.dvd_title
                               if getattr(a, 'dvd_title', None) else '.tracks.json'))
        payload = {'src': src, 'duration': dur_total, 'offsets': offsets, 'streams': [],
                   'proposal': {'audioTracks': [], 'audioLangs': []},
                   'warnings': ['no audio streams on this title - nothing to analyse. Normal for a '
                                'stills gallery or a silent extra; ship it with audioTracks: [].']}
        with open(out, 'w', encoding='utf-8') as fh:
            json.dump(payload, fh, indent=2, ensure_ascii=False)
        print('no audio streams - recorded as a positive finding (audioTracks: [])')
        return 0
    print(f'{len(streams)} audio stream(s), duration {dur_total:.0f}s, sampling at {offsets}\n')

    # --- redundancy FIRST: which tracks are the same content? --------------------------------
    #
    # ORDER IS THE OPTIMISATION. Subtraction costs ~2s per candidate pair; whisper costs
    # ~2 x 75s of decode+inference PER STREAM, and it is pure waste on a stream the subtraction
    # is about to mark redundant - a lossy core's language is its parent's language, and the
    # stream is being dropped regardless. So: group duplicates first, then transcribe only one
    # representative of each group plus every unique stream. Measured on a synthetic 4-stream
    # file (2 distinct contents, each with an identical sibling), same machine, back to back:
    # 179.1s before (whisper 175.5s, all 4 streams) vs 67.0s after (whisper 64.8s, 2 streams),
    # with identical redundancy verdicts and identical language calls on the surviving streams.
    # The saving scales with the number of redundant streams - on the 12-stream features where
    # this script is the bottleneck, cores and duplicates are most of the count.
    # None of the checks that matter is weakened: lossy-core detection IS the subtraction
    # (unchanged), dub/commentary/AD detection runs on every stream that could ship.
    print('pairwise subtraction (dB below signal; >%.0f = same content):' % REDUNDANT_DB)
    t_phase = time.monotonic()
    groups = []
    core_suspects = []
    # ONLY COMPARE PAIRS THAT COULD ACTUALLY BE THE SAME CONTENT.
    #
    # This was every pair: 12 streams on When Harry Met Sally = 66 subtractions, each decoding two
    # 30 s segments, putting ~20 minutes of CPU between the rip finishing and the GPU starting.
    # The check exists to catch a lossy core beside its lossless parent, or a straight duplicate -
    # and BOTH always share a channel count and a language tag. A 6-channel DTS track cannot be a
    # duplicate of a 2-channel AC3 one, so subtracting them only burns time.
    #
    # An untagged stream is still compared against everything with its channel count: a missing tag
    # tells us nothing, and that is exactly where a duplicate hides.
    def could_match(a, b):
        if a['channels'] != b['channels']:
            return False
        ta, tb = (a['langTag'] or '').lower(), (b['langTag'] or '').lower()
        return (not ta) or (not tb) or ta == tb

    pairs = [(i, j) for i in range(len(streams)) for j in range(i + 1, len(streams))
             if could_match(streams[i], streams[j])]
    skipped = len(streams) * (len(streams) - 1) // 2 - len(pairs)
    print('  %d candidate pair(s); %d skipped as impossible (channel count / language tag differ)'
          % (len(pairs), skipped))
    for i, j in pairs:
        d = compare(src, i, j)
        if d is None:
            continue
        same = d > REDUNDANT_DB
        # ESCALATE A "NOT THE SAME" VERDICT ON A LOSSLESS/LOSSY PAIR.
        # The naive subtraction cannot see through a decoder delay, so its NEGATIVE answer on
        # exactly this shape is untrustworthy. Only this shape is escalated: it keeps the phase
        # cost off the many-stream discs the pair-filter above was written to speed up.
        if not same and core_candidate(streams[i], streams[j]):
            r = compare_aligned(src, i, j) if np is not None else None
            if np is None:
                print(f'  a:{i} vs a:{j}  {d:6.1f}  *** lossless/lossy pair but numpy is MISSING - '
                      f'the lossy-core check did not run; treat this verdict as unproven ***')
            if r is not None:
                d2, lag_ms, gain_db = r
                if d2 > CORE_SUSPECT_DB:
                    core_suspects.append((i, j, d, d2, lag_ms, gain_db))
        if same:
            print(f'  a:{i} vs a:{j}  {d:6.1f}  SAME CONTENT')
            for g in groups:
                if i in g or j in g:
                    g.update({i, j}); break
            else:
                groups.append({i, j})
        elif d > 12:
            print(f'  a:{i} vs a:{j}  {d:6.1f}  (close - inspect)')

    def rank(k):
        s = streams[k]
        loss = any(x in (s['codec'] + s['profile']).lower() for x in LOSSLESS)
        return (loss, s['bitrate'] or 0, s['channels'] or 0)

    for s in streams:
        s['redundantWith'] = None
    for g in groups:
        keep = max(g, key=rank)
        for k in g:
            if k != keep:
                streams[k]['redundantWith'] = keep
                print(f'  -> a:{k} is redundant with a:{keep} (drop)')
    if core_suspects:
        print('  POSSIBLE LOSSY CORE(S) - the naive subtraction cannot see these, and this check')
        print('  does NOT drop them. Confirm with identify-audio.py before changing any manifest:')
        for (i, j, d, d2, lag_ms, gain_db) in core_suspects:
            print(f'    a:{i} vs a:{j}  {d:.1f} dB naive -> {d2:.1f} dB after alignment '
                  f'(lag {lag_ms:+.1f} ms, gain {gain_db:+.1f} dB)')
        print('    NB a COMMENTARY over the same score scores here too (Sunrise a:0 vs a:4 = 15.9 dB).')
        print('    A commentary must never be dropped as a duplicate - transcribe before deciding.')
    print('  [subtraction phase: %.1fs]' % (time.monotonic() - t_phase))

    # --- transcription: only streams that could ship ----------------------------------------
    t_phase = time.monotonic()
    from faster_whisper import WhisperModel
    print(f'\nloading whisper "{a.model}"...', flush=True)
    # cpu_threads=1 IS THE FAST SETTING - measured 4.6x faster than the default, with the full
    # numbers in transcribe-wav.py. It is counter-intuitive, which is exactly why it was documented
    # there and then missing here: this script does far more transcription than that one does.
    model = WhisperModel(a.model, device='cpu', compute_type='int8', cpu_threads=1)

    for s in streams:
        # defaults, so every stream carries every key whatever path it takes below
        s['langAgreedAcrossOffsets'] = False
        s['spokenLang'] = None
        s['langProb'] = 0.0
        s['samples'] = []
        s['langReliable'] = False
        s['tagMismatch'] = False
        s['audioLevelDb'] = None
        if s['redundantWith'] is not None:
            # Same content as its parent, and being dropped - transcribing it would repeat the
            # parent's answer at full whisper cost. NOTE the honest limit: its language and tag
            # are NOT independently verified; if it is claimed in a manifest anyway, the gate
            # refuses it as redundant long before language matters.
            s['transcribeStatus'] = 'skipped-redundant'
            print(f"  a:{s['a']} {s['codec']:9} {str(s['channels']):>2}ch tag={s['langTag']}"
                  f" [not transcribed: same content as a:{s['redundantWith']}]")
            continue
        lang, prob, texts, agreed, status = transcribe(model, src, s['a'], offsets, a.dur)
        s['transcribeStatus'] = status
        s['langAgreedAcrossOffsets'] = agreed
        s['spokenLang'] = lang
        s['langProb'] = prob
        s['samples'] = texts
        # Abstain when the detector is not confident: assert nothing rather than assert noise.
        s['langReliable'] = bool(lang and prob >= LANG_CONFIDENCE_FLOOR and agreed)
        s['tagMismatch'] = bool(s['langReliable'] and s['langTag']
                                and not same_language(lang, s['langTag']))
        if status == 'no-speech':
            # Blank transcript at every offset. Separate a SCORE from a phantom/empty track by
            # MEASURING the audio, not assuming: a silent-film disc (Metropolis) carries real
            # orchestral tracks here, while a broken menu artifact carries near-silence.
            s['audioLevelDb'] = rms_db(src, f"[0:a:{s['a']}]{DM},{AST}[x]")
        print(f"  a:{s['a']} {s['codec']:9} {str(s['channels']):>2}ch tag={s['langTag']}"
              f" spoken={lang}({prob})"
              + ('  <<< TAG MISMATCH' if s['tagMismatch'] else '')
              + ('  <<< TRANSCRIBE FAILED - no evidence for this stream' if status == 'failed' else '')
              + ('  [no speech at any offset; level %s dB - music or silence, see roles]'
                 % (('%.1f' % s['audioLevelDb']) if isinstance(s['audioLevelDb'], float)
                    and s['audioLevelDb'] != float('-inf') else 'n/a')
                 if status == 'no-speech' else '')
              + ('  [not judged: %s]' % ('offsets disagree' if lang and not agreed
                                                          else 'low confidence')
                 if lang and not s['langReliable'] else ''))
    print('  [whisper phase: %.1fs]' % (time.monotonic() - t_phase))

    # --- classify ----------------------------------------------------------------------------
    # PASS 1: roles that need no speech reference. Doing these first is load-bearing: a stream
    # with NO SPEECH must never become the reference the other streams are judged against.
    # On Metropolis (1927) the orchestral score's blank transcript still carried whisper's bogus
    # "la" language, became the primary, reclassified the genuine English commentary (1.00) as a
    # DUB, and the proposal dropped everything but the stereo score.
    MUSIC_FLOOR_DB = -50.0
    for s in streams:
        s['role'] = None
        if s['redundantWith'] is not None:
            s['role'] = 'redundant'
        elif s.get('transcribeStatus') == 'failed':
            # No transcript could be taken, so NOTHING about this stream is evidenced. This must
            # be its own role, not 'commentary?': a failure classified as a plausible role is a
            # verdict that was never earned, and the manifest gate refuses claims about it.
            s['role'] = 'analysis-failed'
        elif s.get('transcribeStatus') == 'no-speech':
            lvl = s['audioLevelDb']
            if lvl is None:
                # the level measurement itself failed - that is a failure, not silence
                s['role'] = 'analysis-failed'
            elif lvl == float('-inf') or lvl < MUSIC_FLOOR_DB:
                s['role'] = 'silent?'      # near-silent: phantom/menu artifact - inspect, do not ship
            else:
                s['role'] = 'music'        # real audio, no words: a score. A POSITIVE finding.

    # The REFERENCE stream for dub/commentary/mix comparison: the first non-redundant stream
    # that actually carries RELIABLE speech; failing that, the first with any speech at all.
    # (Reliability preferred so one hallucinated word on a music track cannot outrank a clean
    # commentary transcript.)
    # ELECT BY THE MOST-REPRESENTED LANGUAGE, NOT BY STREAM ORDER.
    #
    # This used to take the FIRST stream carrying reliable speech. On a foreign-market pressing
    # that is the local dub: the Japanese Universal Blu-ray of Back to the Future puts jpn at a:0,
    # so the reference for "is this a dub?" became Japanese, every English track differed from it,
    # and BOTH genuine English commentaries were classified away. Worse, the Japanese dub matched
    # the reference language, reached the commentary test, and came back `commentary?` - which the
    # gate accepts. The disc could have shipped a dub labelled "Audio Commentary" while refusing
    # the real ones.
    #
    # A disc's ORIGINAL language is the one it has most tracks in: the film, plus every commentary,
    # plus any alternate mix, are all in it, while each dub appears once. Back to the Future's
    # Japanese pressing carries eng x3 (film + two commentaries) against jpn x2 (5.1 and 2.0 dubs)
    # - so English wins, which is correct. Ties break toward the most channels, since the feature
    # mix is the fullest one on the disc.
    #
    # This is a heuristic about AUDIO LAYOUT only. It says nothing about the film's identity, which
    # is settled from content elsewhere and by the Plex/TMDB match.
    cand = [s for s in streams if s['role'] is None and s['langReliable'] and s['spokenLang']]

    # A STREAM THAT TALKS ABOUT THE FILM CANNOT BE THE FILM. Score the commentary hints BEFORE the
    # election, not after it.
    #
    # The count-by-language heuristic below assumes the original language owns the most tracks
    # because "the film, plus every commentary, are all in it". A FOREIGN-LANGUAGE FILM WITH
    # ENGLISH COMMENTARIES FALSIFIES THAT. On Eureka's M (1931) the disc carries deu x1 (the film)
    # against eng x2 (two English commentaries): English won the count, a COMMENTARY was elected
    # primary, and Fritz Lang's German soundtrack was then labelled a `dub`. The proposal was
    # `audioTracks [2,4]` - two commentaries and NO FILM.
    #
    # It could not self-correct downstream either: in PASS 2 the `elif s is primary` arm runs
    # BEFORE the COMMENTARY_HINTS test, so whichever stream wins the election can never be
    # reclassified. That is why the second commentary was caught by content and the first was not.
    #
    # Same lesson this file already records for the dub test: TEST THE CONTENT FIRST, then let
    # structure break ties. Excluding hinted streams is safe in one direction only - a real feature
    # soundtrack does not discuss its own screenplay, camera or edit - and it never removes every
    # candidate, because that would leave nothing to elect.
    hintEv = {s['a']: commentary_talk(' '.join(s['samples'])) for s in cand}
    hinted = [s for s in cand if hintEv[s['a']][2]]
    if hinted and len(hinted) < len(cand):
        for s in hinted:
            strong, weak, _ = hintEv[s['a']]
            # PRINT THE PHRASES, not just the verdict. This exclusion is what elected a commentary
            # as primary on Farscape S1 D6, and the log said only "talks ABOUT the film" - true of
            # nothing in that transcript. The evidence has to be visible to be disbelieved.
            print(f"  a:{s['a']} ({s['spokenLang']}) talks ABOUT the film - "
                  f"excluded from the primary election "
                  f"[strong: {', '.join(sorted(strong)) or 'none'}; "
                  f"weak: {', '.join(sorted(weak)) or 'none'}]")
        cand = [s for s in cand if s not in hinted]

    primary = None
    if cand:
        counts = {}
        for s in cand:
            counts[s['spokenLang']] = counts.get(s['spokenLang'], 0) + 1
        best = max(counts.values())
        top = [l for l, n in counts.items() if n == best]
        if len(top) > 1:
            # tie: prefer the language owning the highest channel count on the disc
            top.sort(key=lambda l: -max((s['channels'] or 0) for s in cand if s['spokenLang'] == l))
        winner = top[0]
        inLang = [s for s in cand if s['spokenLang'] == winner]
        primary = max(inLang, key=lambda s: (s['channels'] or 0, -s['a']))
        print(f"primary reference: a:{primary['a']} ({winner}) - "
              f"{best} of {len(cand)} speech track(s) are {winner}")
    if primary is None:
        for s in streams:
            if s['role'] is None and s['spokenLang']:
                primary = s; break
    ptext = ' '.join(primary['samples']) if primary else ''

    # SILENT FILM: the film's own audio (the first non-redundant stream) is a score. Any speech
    # stream on such a disc is ABOUT the film - a commentary - not its primary audio, and must
    # not be proposed as the default track a viewer lands on.
    firstMain = next((s for s in streams if s['redundantWith'] is None), None)
    silentFilm = bool(firstMain is not None and firstMain['role'] == 'music')

    # PASS 2: speech streams, judged against the reference.
    for s in streams:
        text = ' '.join(s['samples'])
        sim = similarity(ptext, text)
        s['similarityToPrimary'] = round(sim, 2)
        if s['role'] is not None:
            continue
        primaryLang = primary['spokenLang'] if primary else 'en'
        if silentFilm:
            s['role'] = 'commentary' if commentary_talk(text)[2] else 'commentary?'
        elif s is primary:
            s['role'] = 'primary'
        # COMMENTARY AND AD ARE TESTED BEFORE THE LANGUAGE-BASED DUB TEST.
        #
        # They used to come after, and on a foreign pressing that made a genuine commentary
        # UNDETECTABLE. `primary` is elected as the first stream carrying reliable speech, which on
        # a JAPANESE Back to the Future Blu-ray is the Japanese dub - so every English track
        # differed from the "primary" language and was labelled `dub` by language alone, before
        # COMMENTARY_HINTS was ever consulted. Both of that disc's real commentaries were refused
        # by assert-tracks-analysed.ps1, and no re-run at any offset or model size could change it.
        #
        # The inverse was the dangerous half: a:6, the Japanese DUB, shared the elected primary's
        # language, skipped the dub branch, reached this test with a garbled transcript scoring
        # sim < 0.5, and came out `commentary?` - which the gate ACCEPTS. The evidence file would
        # have waved through a manifest labelling a dub "Audio Commentary" while refusing the two
        # real ones. That is the Thunderball failure with the sign flipped.
        #
        # Testing content first is safe: COMMENTARY_HINTS and AD_HINTS are English phrases, so a
        # foreign-language dub scores no hits and still falls through to the dub branch below.
        elif commentary_talk(text)[2] and sim < 0.5:
            s['role'] = 'commentary'
        elif ad_excess(text, ptext) >= 3 and sim >= 0.35:
            s['role'] = 'audioDescription'
        elif s['langReliable'] and s['spokenLang'] != primaryLang:
            s['role'] = 'dub'
        elif not s['langReliable'] and s['langTag'] and not same_language(primaryLang, s['langTag']):
            # The detector could not judge (action scenes carry no language), but the disc tag says
            # a foreign track and nothing contradicts it. Trust the tag ONLY in this direction -
            # it demotes a track out of the English set, it never promotes one into it.
            s['role'] = 'dub (per tag, speech not confirmed)'
        elif sim >= 0.5:
            # Same dialogue, not a bit-for-bit match: a genuinely different mix of the same audio -
            # typically the restored original mono alongside a 5.1 remix. Keep it, do not tag it
            # as a commentary.
            s['role'] = 'alternateMix'
        else:
            s['role'] = 'commentary?'

    # CONFIRM EVERY `dub` WITH MORE EVIDENCE, BECAUSE `dub` MEANS DISCARD.
    #
    # Two 30-second windows (35% and 60% of runtime) decide every role here. That is ample for a
    # KEEP decision - a wrong keep is visible in the library. It is not ample for a DROP: a
    # commentary that happens not to say "the film", "the director" or "the scene" in either window
    # scores under the two-hint threshold, differs in language from the primary, and is silently
    # written off as a foreign dub.
    #
    # That is exactly what happened to Eureka's M (1931). Its first commentary sampled as
    # "...rendered cinematically in Uli Lomo's film of the early 70s..." - which reads as
    # commentary to a human but trips no hint, because the regex wants "the film", not "Lomo's
    # film". It was labelled `dub` and dropped, while the second commentary - which did say the
    # magic words - was kept.
    #
    # So re-sample the dubs, and only the dubs, at three fresh offsets. The cost is bounded (dubs
    # are few) and it is spent exactly where a mistake destroys content rather than merely
    # embarrassing us. A real foreign dub gains nothing from more English samples and stays a dub.
    suspects = [s for s in streams if s['role'] == 'dub']
    if suspects:
        extra = [int(dur_total * f) for f in (0.15, 0.5, 0.8)]
        print(f'\nconfirming {len(suspects)} `dub` classification(s) at offsets {extra} - '
              f'a drop needs more evidence than a keep:')
        for s in suspects:
            lang2, prob2, texts2, agreed2, status2 = transcribe(model, src, s['a'], extra, a.dur)
            merged = ' '.join(s['samples'] + list(texts2))
            hits = len(commentary_talk(merged)[0]) + len(commentary_talk(merged)[1])
            if hits >= 2:
                s['role'] = 'commentary'
                s['samples'] = s['samples'] + list(texts2)
                s['reclassifiedOnResample'] = True
                print(f"  a:{s['a']} -> COMMENTARY after all ({hits} hint(s) across "
                      f"{len(s['samples'])} samples) - it was about to be dropped")
            else:
                print(f"  a:{s['a']} stays `dub` ({hits} hint(s) across "
                      f"{len(s['samples']) + len(texts2)} samples)")

    print('\nroles:')
    for s in streams:
        print(f"  a:{s['a']} {s['role']:17} sim={s['similarityToPrimary']:.2f}"
              f"  \"{(' '.join(s['samples']))[:90]}\"")

    # --- proposed manifest fields -------------------------------------------------------------
    keep = [s['a'] for s in streams
            if s['role'] in ('primary', 'commentary', 'audioDescription', 'alternateMix', 'music')]
    # Map whisper's ISO 639-1 to the 639-2 code the manifest/mkv wants via the SAME table the
    # tag comparison uses. The old `.replace('en', 'eng')[:3]` was a single-sample shortcut:
    # right for English, and it silently left every other language as a 2-letter code
    # ('fr', 'es') in the proposal.
    # A music track's language is 'zxx' - ISO 639-2 for "no linguistic content" - which is both
    # true and what stops anyone re-tagging a score with whatever whisper hallucinated for it.
    def proposed_lang(k):
        if streams[k]['role'] == 'music':
            return 'zxx'
        return ISO2TO3.get((streams[k]['spokenLang'] or '')[:2], 'und')
    proposal = {
        'audioTracks': keep,
        'audioLangs': [proposed_lang(k) for k in keep],
    }
    for s in streams:
        if s['role'] == 'commentary':
            proposal['commentary'] = s['a']
        if s['role'] == 'audioDescription':
            proposal['audioDescription'] = s['a']

    warnings = []
    for s in streams:
        if s['role'] == 'analysis-failed':
            warnings.append(f"a:{s['a']} could NOT be transcribed - there is NO evidence for this "
                            f"stream. Re-run after the contention clears; do not claim it in a "
                            f"manifest until it measures")
        if s['tagMismatch']:
            warnings.append(f"a:{s['a']} tag={s['langTag']} but SPOKEN {s['spokenLang']} - "
                            f"do not ship it under the disc's tag")
        if s['role'] == 'commentary?':
            warnings.append(f"a:{s['a']} differs from the primary but shows few commentary cues - "
                            f"listen before shipping; it may be a second commentary or a dub")
        if s['role'] == 'alternateMix':
            warnings.append(f"a:{s['a']} is a DIFFERENT MIX of the same dialogue "
                            f"({s['channels']}ch) - usually the restored original. Confirm it is "
                            f"wanted, and give it a title; do NOT tag it as commentary")
        if s['role'] == 'silent?':
            warnings.append(f"a:{s['a']} carries NEAR-SILENT audio ({s['audioLevelDb']} dB) with no "
                            f"speech - probably a phantom/menu artifact. Excluded from the "
                            f"proposal; verify before shipping or dropping it")
    if silentFilm:
        warnings.append("FIRST AUDIO STREAM HAS NO SPEECH but real level - this looks like a "
                        "SILENT FILM with a score. Music tracks proposed as 'zxx'; any speech "
                        "stream was classified as commentary ABOUT the film, and no language "
                        "warning is derived from the score tracks")
    # "PRIMARY IS X" is only meaningful when the reference stream really is the film's primary
    # audio. On a silent film the reference is a commentary, and on Metropolis this warning
    # previously read "PRIMARY IS LA" off a blank transcript of the orchestral score.
    if primary and primary['role'] == 'primary' and primary['spokenLang'] != 'en':
        warnings.append(f"PRIMARY IS {primary['spokenLang'].upper()}, not English - this is likely "
                        f"a foreign-language original; ship it as the original, not as 'eng'")

    result = {'src': src, 'duration': dur_total, 'offsets': offsets,
              'streams': streams, 'proposal': proposal, 'warnings': warnings}
    out = a.out or (src + ('.title%d.tracks.json' % a.dvd_title
                          if getattr(a, 'dvd_title', None) else '.tracks.json'))
    Path(out).write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')

    print('\nproposed manifest audio fields:')
    print(json.dumps(proposal, indent=2))
    if warnings:
        print('\nWARNINGS - resolve each before queueing:')
        for w in warnings:
            print(f'  !! {w}')
    print(f'\nevidence written to {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
