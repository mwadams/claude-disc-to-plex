<!--
  This is the AUTHOR'S WORKING CLAUDE.md, persisted here so it can be restored.
  It lives at the root of the media working directory (e.g. D:\video\CLAUDE.md), NOT in the skill.

  Claude Code loads it automatically for that project, which is the point: these are the rules
  that must survive a context compaction. Before this file existed they had to be restated in
  every session prompt, and degraded every time the conversation was summarised.

  Adapt the paths, drive letters, NAS host and Plex section keys to your own setup.
-->
# D:\video — disc-to-Plex library work

Converting disc rips into a Plex library on a NAS. The workflow lives in the
`disc-to-plex` skill (`.claude/skills/disc-to-plex`, mirrored to the public repo
`D:\source\mwadams\claude-disc-to-plex`). Invoke that skill for any disc → library job; this file
covers the rules that apply to **this machine and this library**, which the skill deliberately
does not hard-code.

## Data safety — these are absolute

**NEVER delete, move, or rename anything on `E:` or on the NAS (`\\NASTEAMV\...`).** They are the
source rips and the published library. Local `D:` only. If something on the NAS is wrong, **flag
the exact path and wait** — do not work around it.

A hook enforces this, and **the check is TEXTUAL**: it blocks any command containing *both* a
protected path *and* a delete/move verb, even when the delete targets `D:`. Consequences:

- Split such work into two commands. Never put `Remove-Item` and a NAS path in the same command.
- **Never try to bypass the hook** — not with `Move-Item`, not with `Rename-Item`, not by
  constructing the path in a variable. If it blocks you, that is the correct outcome; report it.
- A literal wildcard (`-like 'D:\video\*'`) trips a separate guard. Use `.StartsWith('D:\video\')`.
- Avoid the variable names `$mv`, `$ri`, `$mi`, `$del`.

### Gated delete — always two commands

1. **Verify** — compare local against NAS (file count AND bytes) and write the safe `D:` paths to
   a scratch file. This command contains **no delete verb**.
2. **Delete** — read that file and remove only paths under `D:\video\`.

### Publish immediately, gate only the reclaim

- **Publish (ungated)** — copy to the NAS the moment an encode verifies, then trigger the Plex
  refresh and tell the user it is ready. Do not wait for permission; the user cannot confirm a unit
  is in Plex until it is on the NAS.
- **Reclaim (gated)** — delete the local copy ONLY after the user confirms that unit is in Plex.

## Environment

- **All `robocopy` via the PowerShell tool, NEVER the Bash tool.** Git Bash rewrites POSIX-looking
  arguments: switches become drive paths (`/E` → `E:/`) and `\\NAS\share` collapses to a local
  relative path, so the copy silently goes to `D:\NAS\share` and still verifies. Exit code 1 from
  robocopy means "files copied" — that is success.
- **Plex credentials**: `[Environment]::GetEnvironmentVariable('PLEX_TOKEN','User')` and
  `PLEX_BASEURL`. Never echo them. Films = section 6, TV = section 5.
- Long-running work goes in the background (`run_in_background`), never the foreground — a tool
  timeout mid-encode leaves an unfinalised file that later looks complete.
- Scratch files go in the session scratchpad directory, not in `D:\video`.

## Scope

Keep searches narrow. **No broad recursive scans outside `D:\video`** — check top level first and
drill down only as needed. `E:` is a slow USB spinning disk and the NAS is remote.

## Working style for this library

**Verify identity from content, not from names or structure.** Every expensive mistake in this
project passed its structural checks: the right file count, plausible durations, matching slots —
and the wrong film, cut, or episode order. Look at a frame; read the title off the screen;
transcribe the audio.

**A length or count mismatch is a prompt to investigate, not a diagnosis.** Acting on the obvious
explanation without proving it has twice made things worse than the original defect.

**When a rule can be a check, put it in a script.** `references/gotchas.md` is ~1,100 lines; rules
that live only there get violated within hours, including ones written in capitals. Guards that
abort or report survive context loss in a way that prose does not.

**Partial sets are normal.** Discs live across several external drives, so a missing episode
usually means "on another drive", not "missing". Number files to their TRUE episode position, never
sequentially, and never conclude a set is incomplete from a low title count.

**Plex/TMDB mapping is authoritative** for what a disc becomes in the library — don't re-litigate a
mapping the agent already dictates.

**Keep every genuine extra** — galleries, shorts, trailers, intros. Never drop one for being an
odd length; exclude only *identified* boilerplate (copyright reels, test patterns, promos for other
titles).

## Progress tracking

Batch state lives in `transfer-status<N>.md` and the source inventory in `list<N>.txt`. Update the
status file as units complete — it is the resume point after a context compaction.

