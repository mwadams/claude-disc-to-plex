#!/usr/bin/env python3
"""Generate scripts/INDEX.md - one line per script: purpose, "reach for this when", how to invoke.

WHY THIS EXISTS
---------------
The scripts folder holds ~100 tools and nobody briefing an agent - or the agent itself - knows what
is in it. Measured on 2026-09-04 alone: `copy-to-planned-names.ps1` exists for exactly the NAS
renumber-by-copy job (including the ordering hazard) and the orchestrator hand-rolled a Copy-Item
loop; `make-manifest.ps1` exists to remove hand-built manifest JSON and the orchestrator hand-wrote
the JSON; several agents wrote parallel implementations of measurements existing scripts already
perform. An unknown tool costs twice: once to rebuild, then forever, because two implementations of
one measurement eventually disagree and nobody knows which to believe.

THE INDEX IS GENERATED, NEVER HAND-MAINTAINED. Every line comes from the script's own header (a
PowerShell `<# .SYNOPSIS #>` block or leading `#` comment block; a Python module docstring). A
script with no usable header is listed as `NO HEADER - purpose unknown` rather than omitted or
invented for: a silently incomplete index is worse than an obviously incomplete one.

REGENERATION. `D:/video/.claude/hooks/regenerate_script_index.py` (PostToolUse on Write|Edit and on
Bash|PowerShell) re-runs this whenever any indexed script is newer than INDEX.md, so an edit made
through the tools cannot leave it stale. Run it by hand after an edit made outside Claude Code:

    python build-script-index.py            # writes scripts/INDEX.md, prints a one-line summary
    python build-script-index.py --check    # exit 2 if INDEX.md is missing or older than a script
    python build-script-index.py --stdout   # print instead of writing

WHAT IT READS FROM A HEADER
  purpose   `.SYNOPSIS` text if present, else the header's first paragraph (a leading
            "<name> - " is dropped). Cut at a sentence boundary past ~220 characters.
  trigger   an explicit `REACH FOR THIS WHEN` / `USE WHEN` / `RUN THIS WHEN` / `WHEN TO USE` line
            if the header has one; else the first sentence of its `WHY` / `WHY THIS EXISTS` /
            `WHY THIS IS A SCRIPT` section (which names the situation the tool answers); else
            `NO TRIGGER IN HEADER`. Adding an explicit `REACH FOR THIS WHEN:` line to a header is
            the way to improve a script's row - edit the script, not this file or the index.
  invoke    the first `pwsh -File ...` / `python ...` example line in the header, or the first
            `.EXAMPLE` command; else `-`.
"""
import argparse
import ast
import io
import os
import re
import sys
import tempfile
import time
import warnings

SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
LOOPS_DIR = 'D:/video'                      # the self-draining tracks live at the video root
INDEX_PATH = os.path.join(SCRIPTS_DIR, 'INDEX.md')
EXTS = ('.ps1', '.py')
PURPOSE_MAX = 220
TRIGGER_MAX = 200
NO_HEADER = 'NO HEADER - purpose unknown'
NO_TRIGGER = 'NO TRIGGER IN HEADER'

for _s in (sys.stdout, sys.stderr):
    try:
        _s.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass


# ------------------------------------------------------------------------------ header extraction

def read_text(path):
    with io.open(path, 'rb') as fh:
        return fh.read().decode('utf-8', 'replace')


def header_ps1(src):
    """The leading comment block of a .ps1, with comment markers stripped. '' if none."""
    lines = src.splitlines()
    i = 0
    while i < len(lines) and not lines[i].strip():
        i += 1
    if i >= len(lines):
        return ''
    first = lines[i].strip()
    if first.startswith('<#'):
        body = []
        rest = first[2:]
        if '#>' in rest:
            return rest.split('#>', 1)[0].strip()
        if rest.strip():
            body.append(rest)
        for ln in lines[i + 1:]:
            if '#>' in ln:
                body.append(ln.split('#>', 1)[0])
                break
            body.append(ln)
        return '\n'.join(body)
    if first.startswith('#'):
        body = []
        for ln in lines[i:]:
            s = ln.strip()
            if s.startswith('#!'):        # shebang - not a header line
                continue
            if not s.startswith('#'):
                break
            body.append(re.sub(r'^\s*#\s?', '', ln))
        return '\n'.join(body)
    return ''


def header_py(src):
    """The module docstring of a .py. '' if none (or if the file does not parse)."""
    try:
        # An indexed script's own SyntaxWarnings (a "\:" in a non-raw string, say) are not this
        # tool's business and would print into the hook's output as if the index had a problem.
        with warnings.catch_warnings():
            warnings.simplefilter('ignore')
            doc = ast.get_docstring(ast.parse(src))
        return doc or ''
    except Exception:
        m = re.match(r'\s*(?:#![^\n]*\n)?(?:#[^\n]*\n)*\s*[rRuUbB]?("""|\'\'\')(.*?)\1', src, re.S)
        return m.group(2) if m else ''


def dedent_lines(text):
    lines = text.splitlines()
    indents = [len(l) - len(l.lstrip()) for l in lines if l.strip()]
    cut = min(indents) if indents else 0
    return [l[cut:] if len(l) >= cut else l.lstrip() for l in lines]


def paragraphs(lines):
    out, cur = [], []
    for l in lines:
        if l.strip():
            cur.append(l.rstrip())
        elif cur:
            out.append(cur)
            cur = []
    if cur:
        out.append(cur)
    return out


def squash(text):
    return re.sub(r'\s+', ' ', text).strip()


def clip(text, limit):
    text = squash(text)
    if len(text) <= limit:
        return text
    # cut at the last sentence end before the limit, if there is one past a third of it
    cut = -1
    for m in re.finditer(r'[.!?](\s|$)', text):
        if m.end() <= limit:
            cut = m.end()
    if cut >= limit // 3:
        return text[:cut].strip()
    return text[:limit - 3].rstrip() + '...'


def is_section_heading(line):
    s = line.strip()
    if re.match(r'^\.[A-Z][A-Z ]+', s):                 # .SYNOPSIS / .WHY THIS EXISTS
        return True
    if re.match(r'^-{3,}$', s) or re.match(r'^={3,}$', s):
        return True
    return bool(re.match(r'^[A-Z][A-Z0-9 ,\-\'/()]{3,}$', s)) and len(s) < 80


# A WHY heading is either a WHOLE LINE in capitals ("WHY THIS EXISTS", "WHY IT WAS REWRITTEN",
# ".WHY") - its paragraph follows - or an inline "WHY. text" / "WHY a portable ffmpeg: text".
WHY_HEADING_LINE = re.compile(r"^\.?WHY[A-Z0-9 ,'\-()/]*\s*$")
WHY_INLINE = re.compile(r'^\.?WHY\b(?P<lead>[^.:\n]{0,70}?)\s*[.:]\s+(?P<rest>\S.*)$')
TRIGGER_MARKERS = re.compile(r'\b(REACH FOR THIS WHEN|USE (THIS )?WHEN|RUN THIS WHEN|WHEN TO USE)\b[:\s-]*(.*)', re.I)
INVOKE_LINE = re.compile(r'^\s*(pwsh\s+(-NoProfile\s+)?-File\s+\S+.*|python3?\s+\S+\.py.*|\.\s+\S+\.ps1.*|\.\s*\(Join-Path.*)$')
USAGE_LINE = re.compile(r'^\s*(Usage|USAGE|Run:|Runs?:|Example)\b')


def extract(name, header):
    """(purpose, trigger, invoke) from a header's text."""
    if not header.strip():
        return NO_HEADER, NO_TRIGGER, '-'
    lines = dedent_lines(header)
    paras = paragraphs(lines)

    # ---- purpose -------------------------------------------------------------------------------
    purpose = ''
    syn = [i for i, l in enumerate(lines) if l.strip().upper().startswith('.SYNOPSIS')]
    if syn:
        buf = []
        for l in lines[syn[0] + 1:]:
            if not l.strip() or l.strip().startswith('.'):
                break
            buf.append(l)
        purpose = ' '.join(buf)
    if not purpose:
        for p in paras:
            body = []
            for l in p:
                if is_section_heading(l):
                    continue
                if USAGE_LINE.match(l) or INVOKE_LINE.match(l):
                    break               # the usage block is not the purpose
                if TRIGGER_MARKERS.search(l) or WHY_INLINE.match(l.strip()):
                    break               # the trigger sentence is not the purpose either
                body.append(l)
            if not body:
                continue
            purpose = ' '.join(body)
            break
    stem = re.escape(os.path.splitext(name)[0])
    purpose = re.sub(r'^\s*' + stem + r'(\.ps1|\.py)?\s*[-\u2014\u2013:]\s*', '', purpose)
    purpose = clip(purpose, PURPOSE_MAX) if purpose.strip() else NO_HEADER
    if purpose != NO_HEADER and purpose[:1].islower():
        purpose = purpose[0].upper() + purpose[1:]

    # ---- trigger -------------------------------------------------------------------------------
    def paragraph_after(start, started=False):
        # The paragraph that follows line `start`. With started=True the caller already holds the
        # paragraph's first sentence, so the first blank line ends it (a "WHY. text" line followed
        # by a blank line and then a usage example must not swallow the example).
        buf = []
        for l2 in lines[start:]:
            s = l2.strip()
            if not s and (buf or started):
                break
            if not s or re.match(r'^[-=]{3,}$', s):
                continue
            if is_section_heading(l2) or USAGE_LINE.match(l2) or INVOKE_LINE.match(l2):
                break
            buf.append(l2)
        return squash(' '.join(buf))

    trigger = ''
    for i, l in enumerate(lines):
        m = TRIGGER_MARKERS.search(l)
        if m:
            text = squash(m.group(3) + ' ' + paragraph_after(i + 1, started=True))
            if text:
                trigger = 'when: ' + clip(text[0].lower() + text[1:], TRIGGER_MAX)
            break
    if not trigger:
        for i, l in enumerate(lines):
            s = l.strip()
            if WHY_HEADING_LINE.match(s):
                text = paragraph_after(i + 1)
            else:
                m = WHY_INLINE.match(s)
                if not m:
                    continue
                lead = m.group('lead').strip()
                if lead and lead == lead.upper():
                    lead = ''            # "THIS IS A SCRIPT" / "IT EXISTS" - a heading suffix, not text
                text = squash((lead + ' - ' if lead else '') + m.group('rest') + ' ' + paragraph_after(i + 1, started=True))
            if text:
                trigger = 'when: ' + clip(text, TRIGGER_MAX)
                break
    if not trigger:
        # A .DESCRIPTION block usually opens with the situation the tool answers.
        desc = [i for i, l in enumerate(lines) if l.strip().upper().startswith('.DESCRIPTION')]
        if desc:
            text = paragraph_after(desc[0] + 1)
            if text:
                trigger = 'see: ' + clip(text, TRIGGER_MAX)
    if not trigger:
        trigger = NO_TRIGGER

    # ---- invoke --------------------------------------------------------------------------------
    invoke = '-'
    ex = [i for i, l in enumerate(lines) if l.strip().upper().startswith('.EXAMPLE')]
    cands = []
    for l in lines:
        if INVOKE_LINE.match(l):
            cands.append(l.strip())
    if ex:
        for l in lines[ex[0] + 1:]:
            if l.strip() and not l.strip().startswith('#'):
                cands.insert(0, l.strip())
                break
    if cands:
        invoke = re.sub(r'\s*`\s*$', '', cands[0])        # a PowerShell line continuation
        invoke = re.sub(r'\s{2,}#.*$', '', invoke)         # a trailing "# comment"
        if len(invoke) > 110:
            invoke = invoke[:107] + '...'
    return purpose, trigger, invoke


# ---------------------------------------------------------------------------------- self-test

def selftest():
    """Prove the extraction on the shapes that exist in this folder, plus the no-header case.

    Returns the number of failures. Printed, never swallowed: a self-test that only returns a code
    is exactly the kind of check that reads as green when it never ran.
    """
    cases = [
        ('synopsis.ps1', "<#\n.SYNOPSIS\n  Refuse a thing.\n\n.WHY THIS EXISTS\n  It broke once. Twice.\n#>\nparam()\n",
         ('Refuse a thing.', 'when: It broke once. Twice.')),
        ('hash.ps1', "# Count the packets. More words.\n#\n# WHY THIS IS A SCRIPT. Because it hurt.\n#\n#   pwsh -File hash.ps1 -Path x\nparam()\n",
         ('Count the packets. More words.', 'when: Because it hurt.')),
        ('py.py', '#!/usr/bin/env python3\n"""Carve cells.\n\nWHY THIS EXISTS\n---------------\nNobody could.\n\nUSAGE\n    python py.py x\n"""\n',
         ('Carve cells.', 'when: Nobody could.')),
        ('explicit.ps1', "# Do a thing.\n# REACH FOR THIS WHEN: the NAS needs renumbering.\nparam()\n",
         ('Do a thing.', 'when: the NAS needs renumbering.')),
        ('desc.ps1', "<#\n.SYNOPSIS\n  Lock titles.\n.DESCRIPTION\n  The agent mislabels specials.\n#>\n",
         ('Lock titles.', 'see: The agent mislabels specials.')),
        ('bare.ps1', "param([string]$X)\nWrite-Host $X\n", (NO_HEADER, NO_TRIGGER)),
        ('barepy.py', "import os\nprint(os.getcwd())\n", (NO_HEADER, NO_TRIGGER)),
        ('named.ps1', "<#\n  named.ps1 - turn a table into JSON.\n  Usage:\n    pwsh -File named.ps1 -T x `\n         -Y z\n#>\n",
         ('Turn a table into JSON.', NO_TRIGGER)),
    ]
    fails = 0
    with tempfile.TemporaryDirectory() as d:
        for fname, src, want in cases:
            p = os.path.join(d, fname)
            with io.open(p, 'w', encoding='utf-8') as fh:
                fh.write(src)
            header = header_py(src) if fname.endswith('.py') else header_ps1(src)
            purpose, trigger, invoke = extract(fname, header)
            ok = (purpose, trigger) == want
            print('  %s %-14s purpose=%r trigger=%r invoke=%r' % ('ok  ' if ok else 'FAIL', fname, purpose, trigger, invoke))
            if not ok:
                print('        wanted purpose=%r trigger=%r' % want)
                fails += 1
        # the invoke line loses its continuation backtick
        _, _, inv = extract('named.ps1', header_ps1(cases[7][1]))
        if inv != 'pwsh -File named.ps1 -T x':
            print('  FAIL invoke continuation: %r' % inv)
            fails += 1
    print('selftest: %d failure(s)' % fails)
    return fails


def kind_of(name):
    low = name.lower()
    if low.endswith('.tests.ps1'):
        return 'tests'
    if low.startswith('lib-'):
        return 'library'
    if low.endswith('.py'):
        return 'python'
    return 'command'


def collect(dir_path, pattern=None):
    rows = []
    for name in sorted(os.listdir(dir_path), key=str.lower):
        if not name.lower().endswith(EXTS):
            continue
        if pattern and not pattern.match(name):
            continue
        path = os.path.join(dir_path, name)
        if not os.path.isfile(path):
            continue
        src = read_text(path)
        header = header_py(src) if name.lower().endswith('.py') else header_ps1(src)
        purpose, trigger, invoke = extract(name, header)
        rows.append({'name': name, 'kind': kind_of(name), 'purpose': purpose,
                     'trigger': trigger, 'invoke': invoke, 'mtime': os.path.getmtime(path)})
    return rows


def md_cell(text):
    return text.replace('|', '\\|').replace('\n', ' ')


def render(rows_scripts, rows_loops):
    no_header = [r for r in rows_scripts + rows_loops if r['purpose'] == NO_HEADER]
    no_trigger = [r for r in rows_scripts + rows_loops if r['trigger'] == NO_TRIGGER]
    out = []
    out.append('# Script index - GENERATED, do not edit')
    out.append('')
    out.append('Generated %s by `build-script-index.py` from each script\'s own header. '
               'To change a row, edit the script\'s header (add a `REACH FOR THIS WHEN:` line to '
               'improve its trigger); the index regenerates on the next tool call through the '
               'PostToolUse hook, or by `python build-script-index.py`.' %
               time.strftime('%Y-%m-%d %H:%M'))
    out.append('')
    out.append('**%d scripts under `scripts/`, %d loop scripts under `D:/video/`. %d with NO usable header, '
               '%d with no trigger sentence.** Consult this BEFORE writing any new tooling: if a row '
               'already answers the question, use that script.' %
               (len(rows_scripts), len(rows_loops), len(no_header), len(no_trigger)))
    out.append('')
    out.append('Kinds: `command` = run with `pwsh -File`; `python` = run with `python`; `library` = dot-source, '
               'defines functions only; `tests` = a test suite, exit 0 = all passed.')
    out.append('')
    for title, rows in (('## `.claude/skills/disc-to-plex/scripts/`', rows_scripts),
                        ('## `D:/video/*.ps1` - the self-draining tracks and operator tools', rows_loops)):
        out.append(title)
        out.append('')
        out.append('| Script | Kind | Purpose | Reach for this when... | Invoke |')
        out.append('|---|---|---|---|---|')
        for r in rows:
            out.append('| `%s` | %s | %s | %s | %s |' % (
                r['name'], r['kind'], md_cell(r['purpose']), md_cell(r['trigger']),
                ('`%s`' % md_cell(r['invoke'])) if r['invoke'] != '-' else '-'))
        out.append('')
    out.append('## Scripts with NO usable header (%d)' % len(no_header))
    out.append('')
    if no_header:
        out.append('These are listed, not described. Their purpose is unknown to this index until '
                   'someone gives them a header comment / docstring.')
        out.append('')
        for r in no_header:
            out.append('- `%s`' % r['name'])
    else:
        out.append('None.')
    out.append('')
    return '\n'.join(out) + '\n'


def newest_source_mtime():
    latest = 0.0
    for d, pat in ((SCRIPTS_DIR, None), (LOOPS_DIR, re.compile(r'^[A-Za-z_].*\.ps1$'))):
        try:
            names = os.listdir(d)
        except OSError:
            continue
        for n in names:
            if not n.lower().endswith(EXTS):
                continue
            if pat and not pat.match(n):
                continue
            p = os.path.join(d, n)
            if os.path.isfile(p):
                latest = max(latest, os.path.getmtime(p))
    return latest


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--check', action='store_true', help='exit 2 if INDEX.md is missing or stale')
    ap.add_argument('--stdout', action='store_true', help='print the index instead of writing it')
    ap.add_argument('--selftest', action='store_true', help='prove the header extraction; exit 2 on any failure')
    a = ap.parse_args()

    if a.selftest:
        return 2 if selftest() else 0

    if a.check:
        if not os.path.isfile(INDEX_PATH):
            print('INDEX.md is missing')
            return 2
        if newest_source_mtime() > os.path.getmtime(INDEX_PATH):
            print('INDEX.md is older than a script')
            return 2
        print('INDEX.md is current')
        return 0

    rows_scripts = collect(SCRIPTS_DIR)
    rows_loops = collect(LOOPS_DIR, re.compile(r'^[A-Za-z_].*\.ps1$'))
    text = render(rows_scripts, rows_loops)
    if a.stdout:
        sys.stdout.write(text)
        return 0
    tmp = INDEX_PATH + '.tmp'
    with io.open(tmp, 'w', encoding='utf-8', newline='\n') as fh:
        fh.write(text)
    os.replace(tmp, INDEX_PATH)
    nh = sum(1 for r in rows_scripts + rows_loops if r['purpose'] == NO_HEADER)
    nt = sum(1 for r in rows_scripts + rows_loops if r['trigger'] == NO_TRIGGER)
    print('INDEX.md: %d scripts + %d loop scripts indexed; %d NO HEADER; %d no trigger -> %s'
          % (len(rows_scripts), len(rows_loops), nh, nt, INDEX_PATH))
    return 0


if __name__ == '__main__':
    sys.exit(main())
