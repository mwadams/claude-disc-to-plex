"""Pick the fastest WORKING faster-whisper device, and prove it before returning it.

WHY THIS IS NOT A ONE-LINER
---------------------------
`device='cuda'` cannot be trusted on the strength of ctranslate2 reporting a CUDA device.
On this machine `get_cuda_device_count()` returns 1 and `get_supported_compute_types('cuda')`
advertises float16, the model CONSTRUCTS without error - and then the first encode dies with
"Library cublas64_12.dll is not found or cannot be loaded". The CUDA runtime was not installed;
only the driver was.

Worse, `model.transcribe()` returns a GENERATOR. Nothing runs until the segments are consumed,
so a try/except around construction (or even around the transcribe call) catches nothing and the
failure surfaces later, somewhere else entirely. The probe below therefore CONSUMES a tiny
transcription inside the guard - the only way to know CUDA works is to make it work.

The runtime now comes from pip (nvidia-cublas-cu12, nvidia-cudnn-cu12), which unpacks into
site-packages instead of onto PATH, so the DLL directories have to be registered explicitly and
BEFORE faster_whisper is imported.

Falls back to the measured-optimal CPU settings, which are counter-intuitive and documented in
transcribe-wav.py: cpu_threads=1 is 4.6x faster than the all-cores default on a many-core box.

CUDA IS NOT ALWAYS THE RIGHT ANSWER - measured 2026-08-31, base model, RTX 4060:

    cuda/float16   load 27.5s   transcribe 30s of audio   0.3s   total 27.7s
    cpu/int8       load  2.4s   transcribe 30s of audio  10.8s   total 13.2s

CUDA transcribes ~36x faster but pays ~25s of FIXED start-up per process. Break-even is
therefore ~72 seconds of audio in one invocation:

  * transcribe-wav.py  - one short speech sample per process, called per title. CPU. Passing
                         prefer_cuda here would make a disc catalogue SLOWER, not faster.
  * analyze-tracks.py  - several streams x 75s offsets in one process. CUDA.
  * whole-episode work - always CUDA; a 27-minute episode is ~1600s of audio.

So callers choose, and the choice is a measurement rather than a preference.
"""
import os
import sysconfig

_registered = False


def register_cuda_dlls():
    """Put the pip-installed CUDA runtime where the loader can find it. Idempotent."""
    global _registered
    if _registered or os.name != 'nt':
        return
    nv = os.path.join(sysconfig.get_paths()['purelib'], 'nvidia')
    for sub in ('cublas', 'cudnn'):
        d = os.path.join(nv, sub, 'bin')
        if os.path.isdir(d):
            try:
                os.add_dll_directory(d)
            except OSError:
                pass
            os.environ['PATH'] = d + os.pathsep + os.environ.get('PATH', '')
    _registered = True


def load_model(size='base', prefer_cuda=True, verbose=True):
    """Return (model, description). Never raises for a missing/broken CUDA - falls back to CPU."""
    register_cuda_dlls()
    import numpy as np
    from faster_whisper import WhisperModel

    if prefer_cuda:
        try:
            m = WhisperModel(size, device='cuda', compute_type='float16')
            # PROVE IT: construction is not evidence. Consume a real (silent) transcription so
            # the encode actually executes inside this guard.
            segs, _ = m.transcribe(np.zeros(16000, dtype=np.float32), language='en')
            list(segs)
            if verbose:
                print(f'whisper "{size}" on cuda/float16', flush=True)
            return m, 'cuda/float16'
        except Exception as e:
            if verbose:
                print(f'cuda unusable ({type(e).__name__}: {e}); using cpu', flush=True)

    m = WhisperModel(size, device='cpu', compute_type='int8', cpu_threads=1)
    if verbose:
        print(f'whisper "{size}" on cpu/int8 (cpu_threads=1, the measured-fastest setting)',
              flush=True)
    return m, 'cpu/int8'
