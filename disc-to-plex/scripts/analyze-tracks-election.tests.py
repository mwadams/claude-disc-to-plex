"""Tests for quiet_programme (analyze-tracks.py) - the near-wordless-film case of the primary election.
Run: python analyze-tracks-election.tests.py

Case 1 is the measured stream table of Chantal Akerman's Saute ma ville (BFI Blu-ray, 00004.m2ts,
2026-09-26): a:0 the film's mono PCM with too little speech for a reliable language, a:1 a 2.0
commentary. The negatives matter most: one ordinary speech track anywhere must leave the normal
election in charge.
"""
import importlib.util, os, sys

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location('analyze_tracks', os.path.join(here, 'analyze-tracks.py'))
at = importlib.util.module_from_spec(spec)
spec.loader.exec_module(at)

fails = 0
def check(name, got, want):
    global fails
    if got == want:
        print('  ok   ' + name)
    else:
        print('  FAIL %s - got %r, want %r' % (name, got, want)); fails += 1

def S(a, reliable, role=None, redundant=None):
    return {'a': a, 'langReliable': reliable, 'spokenLang': 'en', 'role': role, 'redundantWith': redundant}

def pick(streams, hinted_idx):
    cand = [s for s in streams if s['role'] is None and s['langReliable'] and s['spokenLang']]
    hinted = [s for s in cand if s['a'] in hinted_idx]
    p = at.quiet_programme(streams, cand, hinted)
    return None if p is None else p['a']

print('1. POSITIVE: Saute ma ville - a:0 quiet film, a:1 the only speech track, a commentary')
check('a:0 is the programme', pick([S(0, False), S(1, True)], {1}), 0)

print('2. NEGATIVE: an ordinary speech track is present - normal election, nothing forced')
check('no override', pick([S(0, True), S(1, True)], {1}), None)

print('3. NEGATIVE: the quiet track is authored AFTER the commentary - not the programme by order')
check('no override', pick([S(0, True), S(1, False)], {0}), None)

print('4. NEGATIVE: the only earlier track is a redundant copy - it cannot be the programme')
check('no override', pick([S(0, False, redundant=2), S(1, True)], {1}), None)

print('5. NEGATIVE: the earlier track is already classified (music -> the silent-film branch owns it)')
check('no override', pick([S(0, False, role='music'), S(1, True)], {1}), None)

print('6. NEGATIVE: nothing hinted - the ordinary case')
check('no override', pick([S(0, False), S(1, True)], set()), None)

print('7. POSITIVE: two commentaries over a quiet film - the first authored track wins')
check('a:0 is the programme', pick([S(0, False), S(1, True), S(2, True)], {1, 2}), 0)

print('%d failure(s)' % fails)
sys.exit(1 if fails else 0)
