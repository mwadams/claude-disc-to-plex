"""Identify what each audio track on a disc actually IS, without listening to it.

Blu-ray m2ts streams routinely carry no language tags, and the disc's own metadata (MPLS stream
table, CLPI clip info) lists languages in an order that does NOT map one-to-one onto ffprobe's
audio ordinals - there are often more metadata entries than exposed streams. Inferring the mapping
from that order is guesswork, and on The Italian Job it twice produced a confident wrong answer:
first dropping a commentary as a dub, then labelling French and Italian dubs AS the commentaries.

This settles it from the audio itself:
  * Whisper's language ID says whether a track is English, French, Italian, German, Spanish...
  * The transcript says whether an English track is DIALOGUE (the film) or a COMMENTARY
    (someone discussing the film - "we shot this in", "Michael Caine", "the scene where").

Usage:
  python _identify-audio.py <source.m2ts> [--tracks 0 2 3 4 5 6] [--start 2700] [--dur 40]
"""
import argparse, json, re, subprocess, sys, tempfile
from pathlib import Path

TOOLS = json.loads(Path(r'D:\video\.transcode-tools\tool-paths.json').read_text())
FFMPEG = TOOLS['ffmpeg']

# words that appear when someone is TALKING ABOUT a film rather than acting in it
COMMENTARY_HINTS = re.compile(
    r'\b(we (shot|filmed|had|were|wanted)|the scene|this shot|the film|the movie|the director|'
    r'the script|the sequence|originally|actually|you can see|i remember|the studio|the set|'
    r'camera|takes?|edit|footage|screenplay|producer)\b', re.I)


def sample(src: str, track: int, start: int, dur: int, out: Path) -> bool:
    r = subprocess.run(
        [FFMPEG, '-y', '-hide_banner', '-v', 'error', '-ss', str(start), '-i', src,
         '-t', str(dur), '-map', f'0:a:{track}', '-ac', '1', '-ar', '16000', str(out)],
        capture_output=True, text=True)
    return out.exists() and out.stat().st_size > 1000


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('src')
    ap.add_argument('--tracks', type=int, nargs='+', default=[0, 2, 3, 4, 5, 6])
    ap.add_argument('--start', type=int, default=2700)
    ap.add_argument('--dur', type=int, default=40)
    ap.add_argument('--model', default='base')
    a = ap.parse_args()

    from faster_whisper import WhisperModel
    print(f'loading whisper "{a.model}" (first run downloads the model)...', flush=True)
    model = WhisperModel(a.model, device='cpu', compute_type='int8')

    tmp = Path(tempfile.mkdtemp())
    for t in a.tracks:
        wav = tmp / f'a{t}.wav'
        if not sample(a.src, t, a.start, a.dur, wav):
            print(f'  a:{t}  <no audio extracted>')
            continue
        segments, info = model.transcribe(str(wav), beam_size=1)
        text = ' '.join(s.text for s in segments).strip()
        hits = len(COMMENTARY_HINTS.findall(text))
        kind = ''
        if info.language == 'en':
            kind = 'COMMENTARY?' if hits >= 2 else 'dialogue'
        print(f'  a:{t}  lang={info.language} ({info.language_probability:.2f})  {kind}')
        print(f'        "{text[:160]}"')
    return 0


if __name__ == '__main__':
    sys.exit(main())
