"""Transcribe one 16 kHz mono WAV to plain text. Used by catalogue-disc.ps1 / catalogue-dvd.ps1.

Kept as its own entry point so the catalogue loads the whisper model per call rather than holding
it in PowerShell, and so a failure to transcribe ONE title cannot abort a whole-disc sweep.

EVERY outcome prints a POSITIVE marker - that is the contract the callers depend on
(Resolve-TranscribeOutput in lib-subtitles.ps1 parses these):

    [<lang> <prob>] <text>       speech was heard and transcribed
    [no-speech]                  the transcriber RAN and heard nothing - an earned emptiness
    [transcription-failed] ...   the transcriber crashed - a FAILURE, never an emptiness

Empty output therefore means exactly one thing: this script never ran at all (python missing,
faster-whisper not installed, process killed). Before the [no-speech] marker existed, that case
was indistinguishable from "this title is silent", and a missing dependency silently recorded
every title on a disc as speechless.

IDENTIFYING A CATALOGUED DVD TITLE? DON'T CALL THIS DIRECTLY - USE capture-evidence.py --speech.
A transcript produced here from an ad-hoc ffmpeg window is never written into the catalogue, so
assert-accounted.ps1 refuses any `speech:` quote from it even when the identification is right -
that mis-scoping cost 32 re-citations across 7 discs by 2026-09-02. capture-evidence.py extracts
the same window through the row's PROVEN dvdvideo title, transcribes it with this very script, and
records it on the row (speechSample + speechSamplesExtra) so the quote is citable. Direct use
remains right for NAS-side comparison windows and anything else that is not a catalogued disc row.
"""
import sys, io

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

def main():
    if len(sys.argv) < 2:
        return 0
    try:
        from faster_whisper import WhisperModel
        # cpu_threads=1 IS THE FAST SETTING. This is not a typo and not a throttle.
        #
        # Without it, ctranslate2 spreads this tiny int8 model across every logical core and
        # thrashes on synchronisation: the worker sits at ~4% of ONE core with 29 threads, blocked
        # rather than computing. That is what made a catalogue sweep take 2h15m for eight titles,
        # and 43 minutes for a single 90-second sample.
        #
        # Measured A/B on a 90 s sample, all five arms back to back under representative pipeline
        # load (two encode lanes, the OCR loop, a live sweep) - 2026-08-25:
        #
        #     default (all 20 cores)   load 15.0s   transcribe 246.9s
        #     cpu_threads=1            load  3.9s   transcribe  54.1s   <- 4.6x faster
        #     cpu_threads=2            load  4.0s   transcribe 131.5s
        #     cpu_threads=4            load  4.0s   transcribe 131.3s
        #     cpu_threads=8            load  3.9s   transcribe 202.0s
        #
        # Monotonically worse with more threads, and EVERY arm returned identical text (1116 chars,
        # language en) - so there is no accuracy cost to weigh. The default is simply the worst
        # available setting on a many-core box.
        #
        # If you ever raise this, re-measure. Do not raise it because a bigger number looks faster.
        # CPU ON PURPOSE - CUDA IS SLOWER FOR THIS SCRIPT. Measured 2026-08-31, base model:
        #
        #     cuda/float16   load 27.5s   transcribe 30s of audio  0.3s   total 27.7s
        #     cpu/int8       load  2.4s   transcribe 30s of audio 10.8s   total 13.2s
        #
        # CUDA transcribes ~36x faster but pays ~25s of fixed start-up per PROCESS, and this
        # script is invoked once per title on a short speech sample. Break-even is ~72s of
        # audio; the samples here are well under that, so CUDA would make cataloguing slower.
        # analyze-tracks.py transcribes far more per process and does use CUDA.
        #
        # Quiet, because this script's stdout is a PARSED CONTRACT (Resolve-TranscribeOutput)
        # and an extra line would be read as transcript text.
        import os as _os      # this module does not import os at top level
        sys.path.insert(0, _os.path.dirname(_os.path.abspath(__file__)))
        from whisper_device import load_model
        model, _dev = load_model('base', prefer_cuda=False, verbose=False)
        segs, info = model.transcribe(sys.argv[1], beam_size=1)
        text = ' '.join(s.text for s in segs).strip()
        if text:
            print(f'[{info.language} {info.language_probability:.2f}] {text}')
        else:
            # A POSITIVE statement of emptiness, so an empty stdout can only ever mean "the
            # transcriber never ran". See the module docstring for why this marker is load-bearing.
            print('[no-speech]')
    except Exception as exc:
        # DO NOT return silently. Printing nothing makes a FAILURE look identical to "this title
        # has no speech", and the caller records the absence as a finding. On Witness the feature
        # came back speech=False while every short title succeeded, and the cause was not the disc
        # at all - it was this, swallowing an error under contention from four concurrent whisper
        # runs. Same defect as an OCR failure being written down as "no usable text".
        print('[transcription-failed] %s: %s' % (type(exc).__name__, exc))
        return 0
    return 0

if __name__ == '__main__':
    sys.exit(main())
