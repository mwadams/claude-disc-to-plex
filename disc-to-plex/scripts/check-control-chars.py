r"""Fail if a file contains control characters that a mangled Windows path leaves behind.

WHY. Writing a Windows path inside a Python (or JS, or JSON) string literal silently rewrites it:
`"D:\video\.transcode-tools\tool-paths.json"` becomes `D:<VT>ideo\.transcode-tools<TAB>ool-paths.json`,
because \v is a vertical tab and \t is a tab. The path still LOOKS right in most editors.

This happened three times in one session (2026-08-23), to a memory file, to _publish.ps1, and to
assert-tracks-analysed.ps1. The last was the dangerous one: the script failed to load its config,
so the guard it implements did not run - and the failure was invisible because the exit code was
being read through a pipe.

RULE: in generated code, write Windows paths with FORWARD SLASHES ('D:/video/...'). PowerShell,
ffmpeg and Python all accept them. Use backslashes only in a raw string or with them doubled.

Exit 0 clean, 2 if a suspect control character is present.
"""
import sys, io

# This tool reports on arbitrary file content, so it MUST NOT die on it. A redirected stdout
# defaults to cp1252 on Windows and an arrow or dash in the snippet raised UnicodeEncodeError -
# a checker that crashes on the file it is checking reports nothing, which reads as "clean".
for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

SUSPECT = {0x0b: r'\v (vertical tab)', 0x0c: r'\f (form feed)', 0x07: r'\a (bell)',
           0x08: r'\b (backspace)'}

def main():
    bad = 0
    for path in sys.argv[1:]:
        try:
            data = io.open(path, 'rb').read()
        except Exception:
            continue
        text = data.decode('utf-8', 'replace')
        for i, ch in enumerate(text):
            if ord(ch) in SUSPECT:
                line = text.count('\n', 0, i) + 1
                snippet = text[max(0, i - 30):i + 30].replace('\n', ' ')
                print(f"{path}:{line}: contains {SUSPECT[ord(ch)]} - almost certainly a Windows "
                      f"path written in a non-raw string literal")
                print(f"    ...{snippet}...")
                print(f"    FIX: use forward slashes - 'D:/video/...' - or a raw string.")
                bad += 1
                break
    return 2 if bad else 0

if __name__ == '__main__':
    sys.exit(main())
