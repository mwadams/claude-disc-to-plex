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

print('8. POSITIVE: Jeanne Dielman (Akerman Vol.1 D3, 00000.m2ts, 2026-09-27) - a:0 the near-'
      'silent French film (langReliable False, langProb 0.85), a:1 the English commentary. a:1 '
      'must be HINTED from its own samples (no COMMENTARY_STRONG/WEAK vocabulary hit before this '
      'fix - see COMMENTARY_STRONG history), so quiet_programme elects a:0 as the programme.')
AKERMAN_A1_SAMPLES = [
    "haven't even mentioned sex work, which is also part of her routine. And I mean, I wasn't  "
    "around in 1975, but I'm willing to bet was perhaps not a standard part of the Belgian  "
    "housewife routine at the time. I maybe I don't know that for sure, but you know, that's  "
    "and that's also the source of some of the more interesting kind of, I don't know, ambiguous  "
    "textual questions that are floating around about what it is that John gets up to and how  "
    "it relates to this sort of increasing chaos level. Yeah, the idea of the housewife who  "
    "prostitutes herself, right? I mean, this also like wasn't new. I mean, this wasn't an invention  "
    "of accraments, right? This is something that had already been explored in cinema prayers  "
    "of this. And there, yeah, I can maybe say a little bit more later about how this relates  "
    "to the idea of kind of accraments like hyper realism. But there is a sense again, and this  "
    "comes back to this question of like representation. Evonie Margulies, who I haven't named, I think,  "
    "yet here, but she was the critic who wrote a very famous book about accraman. I think that  "
    "book comes out in like the mid 90s. It's called",
    "resistance to the impulse that people often bring to films to want to interpret everything,  "
    "right?  So like, find a kind of hidden meaning or a deeper meaning or a symbolic meaning or whatever  "
    "it is that really all you're left with as an acumen take unfold is you're left with the  "
    "impulse to like describe things that are happening because you're, that's all you can do is like  "
    "you can say, oh, you know, Jean is getting out from the table now and now she's putting  "
    "this away and she's doing that.  But there, the way that this film is structured, it's not that there's some deeper meaning  "
    "behind things.  But all to say, I think she uses the long take as a tool in that, right?  "
    "When a, when a new scene starts, it's very, it's very easy to kind of get the sense  "
    "of what the information is that you're being given in that scene, right?  Like, oh, now they're having dinner.  "
    "You take you five seconds to get that.  And yet the take goes on for another seven, eight minutes, right?  "
    "Why?  It's not to, as you say, it's not to kind of create a sort of, yeah, tech people for duality  "
    "play.  It is a way to force you to think about the image.  It's a way to force you to think about these questions of like, why am I sitting here  "
    "watching this?",
]
strong, weak, hinted = at.commentary_talk(' '.join(AKERMAN_A1_SAMPLES))
check('a:1 samples are hinted as commentary talk', hinted, True)
akerman_streams = [
    {'a': 0, 'langReliable': False, 'spokenLang': 'fr', 'role': None, 'redundantWith': None},
    {'a': 1, 'langReliable': True, 'spokenLang': 'en', 'role': None, 'redundantWith': None},
]
check('a:0 elected programme from real Akerman D3 samples',
      pick(akerman_streams, {1}), 0)

print('%d failure(s)' % fails)
sys.exit(1 if fails else 0)
