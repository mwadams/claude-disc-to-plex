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

import argparse, difflib, json, re, subprocess, sys, tempfile

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
    if not m or m[-1].endswith('inf'):
        return None
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
    return a - d


def transcribe(model, src, track, offsets, dur):
    texts, langs = [], []
    with tempfile.TemporaryDirectory() as td:
        for off in offsets:
            wav = Path(td) / f'a{track}_{off}.wav'
            run([FFMPEG, '-y', '-hide_banner', '-v', 'error', '-ss', str(off), '-i', src,
                 '-t', str(dur), '-map', f'0:a:{track}', '-ac', '1', '-ar', '16000', str(wav)])
            if not wav.exists() or wav.stat().st_size < 1000:
                continue
            segs, info = model.transcribe(str(wav), beam_size=1)
            texts.append(' '.join(s.text for s in segs).strip())
            langs.append((info.language, round(info.language_probability, 2)))
    # TWO INDEPENDENT MEASUREMENTS MUST AGREE - the same rule the subtitle work uses for anchors.
    # A single confident-looking call is not evidence: sampled over an action scene, whisper called
    # a Portuguese track English at 0.86 ("I'll find you. Oh, no! Yeah!") because shouting and
    # effects carry no language at all. A confidence floor cannot catch that; disagreement can.
    if not langs:
        return None, 0.0, texts, False
    names = [l for l, _ in langs]
    lang = max(set(names), key=names.count)
    prob = max([p for l, p in langs if l == lang], default=0.0)
    agreed = len(set(names)) == 1 and len(names) > 1
    return lang, prob, texts, agreed



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
    # Sample WELL INSIDE the film: titles and end credits are music over every track alike, which
    # makes distinct mixes look identical and silent tracks look like failures.
    offsets = a.offsets or [int(dur_total * f) for f in (0.35, 0.6)]
    rms_db.start, rms_db.dur = offsets[0], min(30, a.dur)

    streams = probe_streams(src)
    if not streams:
        print('no audio streams'); return 1
    print(f'{len(streams)} audio stream(s), duration {dur_total:.0f}s, sampling at {offsets}\n')

    from faster_whisper import WhisperModel
    print(f'loading whisper "{a.model}"...', flush=True)
    model = WhisperModel(a.model, device='cpu', compute_type='int8')

    for s in streams:
        lang, prob, texts, agreed = transcribe(model, src, s['a'], offsets, a.dur)
        s['langAgreedAcrossOffsets'] = agreed
        s['spokenLang'] = lang
        s['langProb'] = prob
        s['samples'] = texts
        # Abstain when the detector is not confident: assert nothing rather than assert noise.
        s['langReliable'] = bool(lang and prob >= LANG_CONFIDENCE_FLOOR and agreed)
        s['tagMismatch'] = bool(s['langReliable'] and s['langTag']
                                and not same_language(lang, s['langTag']))
        print(f"  a:{s['a']} {s['codec']:9} {str(s['channels']):>2}ch tag={s['langTag']}"
              f" spoken={lang}({prob})"
              + ('  <<< TAG MISMATCH' if s['tagMismatch'] else '')
              + ('  [not judged: %s]' % ('offsets disagree' if lang and not agreed
                                                          else 'low confidence')
                 if lang and not s['langReliable'] else ''))

    # --- redundancy: which tracks are the same content? -------------------------------------
    print('\npairwise subtraction (dB below signal; >%.0f = same content):' % REDUNDANT_DB)
    groups = []
    for i in range(len(streams)):
        for j in range(i + 1, len(streams)):
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

    # --- classify ----------------------------------------------------------------------------
    primary = None
    for s in streams:
        if s['redundantWith'] is None and s['spokenLang']:
            primary = s; break
    ptext = ' '.join(primary['samples']) if primary else ''

    for s in streams:
        text = ' '.join(s['samples'])
        sim = similarity(ptext, text)
        s['similarityToPrimary'] = round(sim, 2)
        primaryLang = primary['spokenLang'] if primary else 'en'
        if s['redundantWith'] is not None:
            s['role'] = 'redundant'
        elif s is primary:
            s['role'] = 'primary'
        elif s['langReliable'] and s['spokenLang'] != primaryLang:
            s['role'] = 'dub'
        elif not s['langReliable'] and s['langTag'] and not same_language(primaryLang, s['langTag']):
            # The detector could not judge (action scenes carry no language), but the disc tag says
            # a foreign track and nothing contradicts it. Trust the tag ONLY in this direction -
            # it demotes a track out of the English set, it never promotes one into it.
            s['role'] = 'dub (per tag, speech not confirmed)'
        elif len(COMMENTARY_HINTS.findall(text)) >= 2 and sim < 0.5:
            s['role'] = 'commentary'
        elif len(AD_HINTS.findall(text)) >= 3 and sim >= 0.35:
            s['role'] = 'audioDescription'
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
            if s['role'] in ('primary', 'commentary', 'audioDescription', 'alternateMix')]
    proposal = {
        'audioTracks': keep,
        'audioLangs': [(streams[k]['spokenLang'] or 'und').replace('en', 'eng')[:3] for k in keep],
    }
    for s in streams:
        if s['role'] == 'commentary':
            proposal['commentary'] = s['a']
        if s['role'] == 'audioDescription':
            proposal['audioDescription'] = s['a']

    warnings = []
    for s in streams:
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
    if primary and primary['spokenLang'] != 'en':
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
