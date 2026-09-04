#!/usr/bin/env python3
"""Phase-insensitive log-energy envelope cross-correlation between two audio windows.

REACH FOR THIS WHEN: you have to say whether a published NAS file was encoded from THIS disc
title (same cut, no shift) rather than merely being the same length. `disposition-evidence.ps1
-Correlate` extracts the windows (disc side through `-f dvdvideo -title N`, NAS side through the
governor) and calls this for the arithmetic.

WHY THIS EXISTS
---------------
On 2026-09-04 the A Prize of Arms and The Sandbaggers disposition agents each wrote their own
envelope correlator from scratch ("20 s mono 8 kHz windows ... 100 Hz log-energy envelope,
mean-removed, cross-correlated over +/-3 s of lag"). Two implementations of one measurement will
eventually disagree, and the number they produce - r at the best lag - is cited in dispositions
as the evidence that a NAS file is this disc's own encode. analyze-tracks.py has a
cross-correlator too, but on 48 kHz PCM between two streams of ONE source for decoder delay,
which is a different question with a different lag window.

WHAT IT MEASURES. Both WAVs are decoded to a log-energy envelope (RMS over a 50 ms window every
10 ms, in dB, mean removed), then normalised cross-correlation is searched over +/- max-lag
seconds. It reports r at the best lag, that lag in ms, and r at zero lag. It is phase-insensitive
(so a re-encode, a different codec, or a dialnorm change do not matter) and it does not care
which side is longer: the shorter envelope slides over the longer one.

FACTS ONLY: no threshold is applied here. The agents' own experience on this library: r >= 0.9
at near-zero lag on several interior windows = same master; off-diagonal pairings sat <= 0.35.

USAGE
    python audio-envelope-correlate.py <a.wav> <b.wav> [--max-lag 10] [--json]
    (mono PCM WAVs; any rate; 8 kHz mono is plenty and is what the orchestrator extracts)
"""
import argparse
import json
import sys
import wave

import numpy as np


def read_wav(path):
    with wave.open(path, 'rb') as w:
        rate = w.getframerate()
        ch = w.getnchannels()
        width = w.getsampwidth()
        frames = w.readframes(w.getnframes())
    if width == 2:
        x = np.frombuffer(frames, dtype='<i2').astype(np.float64) / 32768.0
    elif width == 4:
        x = np.frombuffer(frames, dtype='<i4').astype(np.float64) / 2147483648.0
    elif width == 1:
        x = (np.frombuffer(frames, dtype=np.uint8).astype(np.float64) - 128.0) / 128.0
    else:
        raise SystemExit('unsupported sample width %d in %s' % (width, path))
    if ch > 1:
        x = x.reshape(-1, ch).mean(axis=1)
    return rate, x


def envelope(rate, x, hop_ms=10, win_ms=50):
    hop = max(1, int(rate * hop_ms / 1000))
    win = max(hop, int(rate * win_ms / 1000))
    n = (len(x) - win) // hop + 1
    if n < 10:
        return None
    idx = np.arange(win)[None, :] + hop * np.arange(n)[:, None]
    frames = x[idx]
    rms = np.sqrt(np.mean(frames * frames, axis=1)) + 1e-9
    env = 20.0 * np.log10(rms)
    env = env - env.mean()
    return env


def ncc(a, b, max_lag_frames):
    """Normalised cross-correlation of the shorter over the longer, lag in frames of `a`."""
    if len(a) > len(b):
        r, lag, r0 = ncc(b, a, max_lag_frames)
        return r, -lag, r0
    best_r, best_lag = -2.0, 0
    n = len(a)
    a_n = a - a.mean()
    a_den = np.sqrt(np.dot(a_n, a_n)) + 1e-12
    r0 = None
    for lag in range(-max_lag_frames, max_lag_frames + 1):
        start = lag
        if start < 0 or start + n > len(b):
            continue
        seg = b[start:start + n]
        s_n = seg - seg.mean()
        den = np.sqrt(np.dot(s_n, s_n)) * a_den + 1e-12
        r = float(np.dot(a_n, s_n) / den)
        if lag == 0:
            r0 = r
        if r > best_r:
            best_r, best_lag = r, lag
    return best_r, best_lag, r0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('a')
    ap.add_argument('b')
    ap.add_argument('--max-lag', type=float, default=10.0, help='seconds of lag searched either way')
    ap.add_argument('--json', action='store_true')
    args = ap.parse_args()
    ra, xa = read_wav(args.a)
    rb, xb = read_wav(args.b)
    ea, eb = envelope(ra, xa), envelope(rb, xb)
    out = {'a': args.a, 'b': args.b, 'aSeconds': round(len(xa) / ra, 2), 'bSeconds': round(len(xb) / rb, 2)}
    if ea is None or eb is None:
        out['measured'] = False
        out['reason'] = 'a window is too short to envelope (< 10 frames)'
    else:
        hop_s = 0.010
        r, lag, r0 = ncc(ea, eb, int(args.max_lag / hop_s))
        out.update({'measured': True, 'r': round(r, 3), 'lagMs': int(round(lag * hop_s * 1000)),
                    'rAtZeroLag': (round(r0, 3) if r0 is not None else None),
                    'method': 'log-energy envelope, 50 ms window / 10 ms hop, mean-removed, normalised '
                              'cross-correlation, lag +/- %.1f s (shorter window slid over the longer)' % args.max_lag})
    if args.json:
        print(json.dumps(out))
    else:
        if out['measured']:
            print('r=%.3f at lag %d ms (r at zero lag %s)' % (out['r'], out['lagMs'], out['rAtZeroLag']))
        else:
            print('not measured: ' + out['reason'])
    return 0


if __name__ == '__main__':
    sys.exit(main())
