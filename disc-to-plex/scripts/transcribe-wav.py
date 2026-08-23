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
        model = WhisperModel('base', device='cpu', compute_type='int8')
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
