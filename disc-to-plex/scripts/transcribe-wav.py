"""Transcribe one 16 kHz mono WAV to plain text. Used by catalogue-disc.ps1.

Kept as its own entry point so the catalogue loads the whisper model per call rather than holding
it in PowerShell, and so a failure to transcribe ONE title cannot abort a whole-disc sweep.
Prints nothing (exit 0) when it cannot transcribe - a missing speech sample is an absence of
evidence, and must never look like a finding.
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
    except Exception:
        return 0
    return 0

if __name__ == '__main__':
    sys.exit(main())
