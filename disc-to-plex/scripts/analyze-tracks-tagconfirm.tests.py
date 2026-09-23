"""Tests for tag_confirm_verdict (analyze-tracks.py) - the forced-decode check that may overrule a
wrong language detection ONLY in favour of the disc's own tag. Run: python analyze-tracks-tagconfirm.tests.py

Every number below was MEASURED on 2026-09-23 with the medium model (see the header in
analyze-tracks.py). The negatives matter most: this check must never relabel real foreign speech.
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

def W(lp_tag, lp_det, words_tag=30, words_det=30):
    return {'lpTag': lp_tag, 'lpDetected': lp_det, 'wordsTag': words_tag, 'wordsDetected': words_det}

print('1. POSITIVE: Blake\'s 7 S1 D4 t09 (English Blue Peter, detected cy 0.93) - tag eng confirmed')
check('confirmed', at.tag_confirm_verdict([W(-0.466, -1.563), W(-0.248, -0.810), W(-0.151, -0.843)])[0], True)

print('2. POSITIVE: The Aztecs t08 (English designer interview, detected cy) - tag eng confirmed')
check('confirmed', at.tag_confirm_verdict([W(-0.270, -0.889), W(-0.202, -1.003), W(-0.292, -0.853)])[0], True)

print('3. NEGATIVE: Winter in Wartime - genuine Dutch speech, as if the disc had tagged it eng')
#    tag=en vs detected=nl at 1200 / 2400 / 4800 s: English LOSES one window, wins one by 0.27, ties one
check('not confirmed', at.tag_confirm_verdict([W(-0.540, -0.328), W(-0.330, -0.597), W(-0.592, -0.593)])[0], False)

print('4. NEGATIVE: any window where the tag fits worse blocks confirmation, however big the wins')
check('one loss blocks', at.tag_confirm_verdict([W(-0.2, -1.5), W(-0.2, -1.4), W(-0.6, -0.5)])[0], False)

print('5. NEGATIVE: silence is not evidence - empty decodes score 0.0, the BEST logprob')
check('no speech', at.tag_confirm_verdict([W(0.0, -1.0, 0, 0), W(0.0, -1.2, 3, 0), W(-0.2, -1.0)])[0], False)

print('6. NEGATIVE: one strong window is not enough (need 2)')
check('one window', at.tag_confirm_verdict([W(-0.2, -1.5)])[0], False)

print('7. NEGATIVE: wins under the margin do not count')
check('thin wins', at.tag_confirm_verdict([W(-0.30, -0.60), W(-0.30, -0.65)])[0], False)

print('8. the ISO 639-2 -> 639-1 map covers both code styles a disc may carry')
check('eng', at.ISO3TO2.get('eng'), 'en')
check('ger', at.ISO3TO2.get('ger'), 'de')
check('dut', at.ISO3TO2.get('dut'), 'nl')

print('')
if fails:
    print('%d test(s) FAILED' % fails); sys.exit(1)
print('all tests passed'); sys.exit(0)
