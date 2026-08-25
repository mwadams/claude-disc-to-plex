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

COMMENTARY_HINTS = re.compile(
    r'\b(we (shot|filmed|had|were|wanted)|the scene|this shot|the film|the movie|the director|'
    r'the script|the sequence|originally|actually|you can see|i remember|the studio|the set|'
    r'camera|takes?|edit|footage|screenplay|producer)\b', re.I)

# Audio description narrates ACTION between lines of dialogue, in the third person present tense.
AD_HINTS = re.compile(
    r'\b(he |she |they )?(walks|turns|looks|opens|closes|enters|leaves|smiles|nods|stares|reaches|'
    r'steps|drives|watches)\b|\b(cut to|fade|on screen|in the distance|a man|a woman)\b', re.I)


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


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def probe_streams(src):
    r = run([FFPROBE, '-v', 'error', '-select_streams', 'a', '-show_entries',
             'stream=index,codec_name,profile,channels,bit_rate:stream_tags=language,title',
             '-of', 'json', src])
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
    r = run([FFPROBE, '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', src])
    try:
        return float(r.stdout.strip())
    except ValueError:
        return 0.0


def rms_db(src, filtergraph):
    r = run([FFMPEG, '-hide_banner', '-ss', str(rms_db.start), '-t', str(rms_db.dur), '-i', src,
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
            r = run([FFMPEG, '-y', '-hide_banner', '-v', 'error', '-ss', str(off), '-i', src,
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
    ap.add_argument('--out')
    a = ap.parse_args()

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
        out = a.out or (src + '.tracks.json')
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
    print('  [subtraction phase: %.1fs]' % (time.monotonic() - t_phase))

    # --- transcription: only streams that could ship ----------------------------------------
    t_phase = time.monotonic()
    from faster_whisper import WhisperModel
    print(f'\nloading whisper "{a.model}"...', flush=True)
    model = WhisperModel(a.model, device='cpu', compute_type='int8')

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
    hinted = [s for s in cand
              if len(COMMENTARY_HINTS.findall(' '.join(s['samples']))) >= 2]
    if hinted and len(hinted) < len(cand):
        for s in hinted:
            print(f"  a:{s['a']} ({s['spokenLang']}) talks ABOUT the film - "
                  f"excluded from the primary election")
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
            s['role'] = 'commentary' if len(COMMENTARY_HINTS.findall(text)) >= 2 else 'commentary?'
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
        elif len(COMMENTARY_HINTS.findall(text)) >= 2 and sim < 0.5:
            s['role'] = 'commentary'
        elif len(AD_HINTS.findall(text)) >= 3 and sim >= 0.35:
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
    out = a.out or (src + '.tracks.json')
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
