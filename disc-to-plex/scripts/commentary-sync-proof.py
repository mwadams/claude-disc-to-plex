"""Prove that a commentary stream taken from a Blu-ray COMMENTARY DOOR is in sync with the
PUBLISHED episode it is about to be muxed into - by measurement, before anything is built.

REACH FOR THIS WHEN: an audio stream from one source (a door-playlist rip, a re-rip) is going to be
added to a file encoded from a DIFFERENT source, and you must show the two timelines agree.

WHY THIS EXISTS
---------------
16 Friends episodes shipped without the cast commentary that sits on each disc's "commentary door"
playlist (002xx), a second playlist over the same clip as the episode's main playlist. The recovery
rips only that door and muxes its commentary into the published file. The door carries NO programme
audio - its four English streams are the commentary and three copies of it (measured on S8 D2:
clip a:5 = commentary, a:6-a:8 redundantWith 5) - so "correlate the programme audio of both" is not
available. Two independent measurements stand in for it:

  1. VIDEO (decisive). The door rip and the published file show the same picture, because both come
     from one clip. Each file is decoded ONCE, start to end, at 32x18 grey, and the per-frame change
     in mean luma (a cut detector) is cross-correlated in several windows spread over the running
     time. Same timeline = high r at ONE lag, the same lag in every window. A drift or a different
     cut shows as a lag that moves between windows. No seek is used at all, so the dvdvideo
     input-seek alignment trap cannot arise; a whole-file decode is also cheaper than N seeks,
     because an output-side seek decodes everything before it anyway.
  2. AUDIO (corroboration). Friends commentaries are mixed OVER the programme sound, so the
     commentary's log-energy envelope still follows the programme's. Measured 2026-09-19 on S08E23:
     r 0.13-0.45 in 5/5 windows, against -0.07..-0.01 for the same commentary laid over the NEXT
     episode. Weak in r, consistent in lag (within ~0.1 s of zero - see --audio-lag-tolerance-ms). The envelope arithmetic is imported from
     audio-envelope-correlate.py - one implementation of that measurement, not two.

Output: a JSON verdict. `ok` is true only when every test passes; `offsetMs` is the one lag the
video windows agree on (0 when the timelines are identical). The caller applies nothing it has not
been told here, and never builds on ok=false.

USAGE
    python commentary-sync-proof.py --door DOOR.mkv --door-audio 0 --published PUB.mkv
                                    [--published-audio 0] [--windows 6] [--json OUT.json]
"""
import argparse, importlib.util, json, os, subprocess, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = json.load(open('D:/video/.transcode-tools/tool-paths.json'))
FFMPEG = TOOLS['ffmpeg']
FFPROBE = os.path.join(os.path.dirname(FFMPEG), 'ffprobe.exe')

_spec = importlib.util.spec_from_file_location('aec', os.path.join(HERE, 'audio-envelope-correlate.py'))
aec = importlib.util.module_from_spec(_spec); _spec.loader.exec_module(aec)

FPS = 24000 / 1001          # every Friends source; the decode is resampled to it so both series share a clock
W, H = 32, 18


def probe(path):
    out = subprocess.run([FFPROBE, '-v', 'error', '-show_entries', 'format=duration:stream=index,codec_type,channels',
                          '-of', 'json', path], capture_output=True, text=True)
    j = json.loads(out.stdout or '{}')
    return float(j.get('format', {}).get('duration') or 0), j.get('streams', [])


def luma_series(path):
    """Mean luma of every frame, whole file, one decode."""
    cmd = [FFMPEG, '-v', 'error', '-i', path, '-map', '0:v:0', '-an', '-sn',
           '-vf', 'fps=%s,scale=%d:%d:flags=area,format=gray' % ('24000/1001', W, H), '-f', 'rawvideo', '-']
    raw = subprocess.run(cmd, capture_output=True).stdout
    n = len(raw) // (W * H)
    if n == 0:
        return np.zeros(0)
    return np.frombuffer(raw[:n * W * H], dtype=np.uint8).reshape(n, W * H).astype(np.float64).mean(axis=1)


def audio_mono(path, ordinal, rate=8000):
    cmd = [FFMPEG, '-v', 'error', '-i', path, '-map', '0:a:%d' % ordinal, '-vn', '-ac', '1', '-ar', str(rate),
           '-f', 's16le', '-']
    raw = subprocess.run(cmd, capture_output=True).stdout
    return rate, np.frombuffer(raw, dtype='<i2').astype(np.float64) / 32768.0


def xcorr(a, b, max_lag):
    """Normalised cross-correlation of two equal-length, mean-removed series over +/- max_lag samples.
    Returns (r_best, lag_best) where a positive lag means b is LATE relative to a."""
    a = a - a.mean(); b = b - b.mean()
    best = (-2.0, 0)
    for lag in range(-max_lag, max_lag + 1):
        if lag >= 0:
            x, y = a[:len(a) - lag] if lag else a, b[lag:]
        else:
            x, y = a[-lag:], b[:len(b) + lag]
        n = min(len(x), len(y))
        if n < 10:
            continue
        x = x[:n]; y = y[:n]
        d = np.sqrt((x * x).sum() * (y * y).sum())
        if d == 0:
            continue
        r = float((x * y).sum() / d)
        if r > best[0]:
            best = (r, lag)
    return best


def audio_windows(a, rd, xd, rp, xp):
    out = []
    tot = min(len(xd) / rd, len(xp) / rp)
    aw = a.audio_window_s
    shift = max(90.0, tot / 5)          # control: the same commentary against a DIFFERENT stretch
    for s in np.linspace(60, max(61, tot - aw - shift - 5), a.windows):
        seg_d = xd[int(s * rd):int((s + aw) * rd)]
        seg_p = xp[int(s * rp):int((s + aw) * rp)]
        seg_c = xp[int((s + shift) * rp):int((s + shift + aw) * rp)]
        if min(len(seg_d), len(seg_p), len(seg_c)) < rd:
            continue
        ed = aec.envelope(rd, seg_d); ep = aec.envelope(rp, seg_p); ec = aec.envelope(rp, seg_c)
        m = min(len(ed), len(ep), len(ec))
        r, lag = xcorr(ed[:m], ep[:m], 300)          # 10 ms hop -> +/- 3 s
        rc, _ = xcorr(ed[:m], ec[:m], 300)
        out.append({'atSeconds': round(float(s), 1), 'r': round(r, 3), 'lagMs': int(lag * 10), 'controlR': round(rc, 3)})
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--door', required=True)
    ap.add_argument('--door-audio', type=int, required=True, help='audio ORDINAL (0-based, a:N) of the commentary in the door rip')
    ap.add_argument('--published', required=True)
    ap.add_argument('--published-audio', type=int, default=-1,
                    help='published audio ordinal to compare against; -1 (default) = try every one and keep the best')
    ap.add_argument('--windows', type=int, default=6)
    ap.add_argument('--video-window-s', type=float, default=60.0)
    ap.add_argument('--audio-window-s', type=float, default=30.0)
    ap.add_argument('--max-duration-delta', type=float, default=1.5)
    ap.add_argument('--min-video-r', type=float, default=0.60,
                    help='a window counts as matched at this r; low-activity windows (few cuts) sit lower')
    ap.add_argument('--min-video-windows', type=int, default=4)
    # 200 ms, MEASURED: on S08E23 the commentary-vs-programme envelope peaks at +100..+110 ms in 5 of
    # 6 windows although the true offset is ZERO (the door commentary against the commentary shipped
    # from the raw clip: r 0.91-0.95 at 0 ms). The commentary's programme bed is not the programme
    # mix, so this estimate is biased by ~0.1 s; wrong-programme pairings scatter by seconds.
    ap.add_argument('--audio-lag-tolerance-ms', type=int, default=200)
    ap.add_argument('--min-audio-margin', type=float, default=0.08,
                    help='median in-sync audio r must beat the median control r by this much')
    ap.add_argument('--json')
    a = ap.parse_args()

    res = {'door': a.door, 'published': a.published, 'doorAudio': a.door_audio, 'publishedAudio': a.published_audio,
           'ok': False, 'reasons': [], 'offsetMs': None}
    dd, _ = probe(a.door); pd, _ = probe(a.published)
    res['doorSeconds'] = round(dd, 3); res['publishedSeconds'] = round(pd, 3)
    if dd <= 0 or pd <= 0:
        res['reasons'].append('a duration could not be read')
    elif abs(dd - pd) > a.max_duration_delta:
        res['reasons'].append('durations differ by %.3f s (> %.1f s): not the same programme length' % (dd - pd, a.max_duration_delta))

    # ---- video ------------------------------------------------------------------------------
    lv_d = luma_series(a.door); lv_p = luma_series(a.published)
    res['doorFrames'] = int(len(lv_d)); res['publishedFrames'] = int(len(lv_p))
    n = min(len(lv_d), len(lv_p))
    vwin = int(a.video_window_s * FPS); maxlag_f = int(2 * FPS)
    vres = []
    if n > vwin + 2 * maxlag_f:
        cut_d = np.abs(np.diff(lv_d)); cut_p = np.abs(np.diff(lv_p))
        starts = np.linspace(maxlag_f, n - vwin - maxlag_f - 2, a.windows).astype(int)
        for s in starts:
            r, lag = xcorr(cut_d[s:s + vwin], cut_p[s:s + vwin], maxlag_f)
            vres.append({'atSeconds': round(s / FPS, 1), 'r': round(r, 3), 'lagFrames': int(lag)})
    res['video'] = vres
    if not vres:
        res['reasons'].append('video: too few decoded frames to test (%d)' % n)
    else:
        good = [v for v in vres if v['r'] >= a.min_video_r]
        if len(good) < min(a.min_video_windows, len(vres)):
            res['reasons'].append('video: only %d of %d window(s) reach r %.2f (%s)' % (len(good), len(vres), a.min_video_r,
                                  ', '.join('%.0fs r=%.2f lag %d' % (v['atSeconds'], v['r'], v['lagFrames']) for v in vres)))
        lags = [v['lagFrames'] for v in (good or vres)]
        if max(lags) - min(lags) > 1:
            res['reasons'].append('video: the lag MOVES between matched windows (%s frames) - drift or a different cut' % lags)
        med = int(np.median(lags))
        res['offsetMs'] = int(round(med * 1000 / FPS))
        res['videoMatchedWindows'] = len(good)
        if abs(med) > 1:
            res['reasons'].append('video: a consistent offset of %d frame(s) (%d ms) - measured, but this tool does not approve shifted builds; investigate' % (med, res['offsetMs']))

    # ---- audio (corroboration) ----------------------------------------------------------------
    rd, xd = audio_mono(a.door, a.door_audio)
    _, pstreams = probe(a.published)
    n_pa = len([st for st in pstreams if st.get('codec_type') == 'audio'])
    cands = [a.published_audio] if a.published_audio >= 0 else list(range(n_pa))
    best = None
    for pa in cands:
        rp, xp = audio_mono(a.published, pa)
        ares = audio_windows(a, rd, xd, rp, xp) if len(xd) and len(xp) else []
        score = float(np.median([x['r'] - x['controlR'] for x in ares])) if ares else -9
        if best is None or score > best[0]:
            best = (score, pa, ares)
    ares = best[2] if best else []
    res['publishedAudio'] = best[1] if best else None
    res['audio'] = ares
    if not ares:
        res['reasons'].append('audio: no audio could be decoded from one side')
    else:
        inlag = [x for x in ares if abs(x['lagMs']) <= a.audio_lag_tolerance_ms]
        med_r = float(np.median([x['r'] for x in ares])); med_c = float(np.median([x['controlR'] for x in ares]))
        res['audioMedianR'] = round(med_r, 3); res['audioMedianControlR'] = round(med_c, 3)
        if len(inlag) < max(3, int(np.ceil(0.6 * len(ares)))):
            res['reasons'].append('audio: only %d of %d window(s) peak within %d ms of zero lag' % (len(inlag), len(ares), a.audio_lag_tolerance_ms))
        if med_r - med_c < a.min_audio_margin:
            res['reasons'].append('audio: median r %.3f does not beat the control %.3f by %.2f - the commentary does not follow THIS programme' % (med_r, med_c, a.min_audio_margin))

    res['ok'] = not res['reasons']
    txt = json.dumps(res, indent=1)
    if a.json:
        open(a.json, 'w', encoding='utf-8').write(txt)
    print(txt)
    sys.exit(0 if res['ok'] else 2)


if __name__ == '__main__':
    main()
