#!/usr/bin/env python3
"""Cross-process exclusive lock for read-modify-write of a shared JSON register.

WHY THIS EXISTS. `capture-evidence.py --speech` registers a captured window by reading the whole
`<disc>.catalogue.json`, mutating one row, and writing the whole file back. Run concurrently
against the SAME disc, every process reads version N and writes its own version N+1 - last writer
wins, the others' work is silently gone. On Danger Man Series 1964-1968 Disk 6 (2026-09-02) an
agent ran four captures in parallel: three of the four vanished from the catalogue and every one
of them printed "registered". The atomic `os.replace` write added earlier is NOT this fix: it
protects a concurrent READER from a half-written file, and does nothing about two writers both
basing their write on the same stale read.

THE MECHANISM, and why this one:
  * An OS byte-range lock (msvcrt.locking / fcntl.flock) on a `<file>.lock` sidecar, held only
    around the read-modify-write - not around the minutes of ffmpeg/whisper work. Contention is
    therefore milliseconds, so a plain retry loop with a generous timeout is enough.
  * The OS releases the lock when the holder dies, HOWEVER it dies. A create-a-file lock
    (O_CREAT|O_EXCL) was rejected because a killed process strands the lock file and every later
    writer hangs until a human deletes it - and killed runs are a known event in this pipeline.
  * The `.lock` sidecar itself is never deleted (deleting it while another process holds the fd
    is exactly the race the lock exists to avoid). A 0-byte `<disc>.catalogue.json.lock` beside
    the catalogue is expected litter; nothing globs it (readers open `*.catalogue.json` by name,
    and `.pre-proof.bak` already set the precedent for sidecars in that directory).
  * Per-row sidecar files merged on read were rejected: they change the on-disk format that
    assert-accounted.ps1 and in-flight disposition agents read TODAY.
  * A lock ALONE is not the whole fix: writers that predate it (or bypass it) can still clobber.
    So the caller must ALSO verify its own entry is present in the file after writing - see
    capture-evidence.py, which refuses to print "registered" until it has re-read the file.

Usual shape:

    with cat_lock.locked(cat_path):
        ...read cat_path FRESH (a read taken before the lock is stale by definition)...
        ...mutate...
        ...write tmp beside it, os.replace(tmp, cat_path)...
    ...re-read and verify your own entry, OUTSIDE the lock...
"""
import os
import time
from contextlib import contextmanager

try:
    import msvcrt

    def _try_lock(fd):
        os.lseek(fd, 0, os.SEEK_SET)
        msvcrt.locking(fd, msvcrt.LK_NBLCK, 1)

    def _unlock(fd):
        try:
            os.lseek(fd, 0, os.SEEK_SET)
            msvcrt.locking(fd, msvcrt.LK_UNLCK, 1)
        except OSError:
            pass          # the close() releases it anyway
except ImportError:        # POSIX (the public repo mirror is used off-Windows too)
    import fcntl

    def _try_lock(fd):
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

    def _unlock(fd):
        try:
            fcntl.flock(fd, fcntl.LOCK_UN)
        except OSError:
            pass


class LockTimeout(Exception):
    pass


@contextmanager
def locked(path, timeout=120.0, poll=0.2):
    """Hold an exclusive cross-process lock on `path` (via its `.lock` sidecar).

    Raises LockTimeout after `timeout` seconds - loud, so a stuck writer is a reported failure,
    never a silent skip. The default is generous precisely because holders keep the lock for
    milliseconds: hitting it means something is genuinely wrong, not busy.
    """
    lock_path = path + '.lock'
    fd = os.open(lock_path, os.O_CREAT | os.O_RDWR)
    try:
        deadline = time.monotonic() + timeout
        while True:
            try:
                _try_lock(fd)
                break
            except OSError:
                if time.monotonic() >= deadline:
                    raise LockTimeout(
                        'could not lock %s within %.0fs - another writer holds it. If nothing '
                        'else is writing this catalogue, a holder may be wedged; find it before '
                        'deleting anything.' % (lock_path, timeout))
                time.sleep(poll)
        try:
            yield
        finally:
            _unlock(fd)
    finally:
        os.close(fd)
