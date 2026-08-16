# claude-disc-to-plex

Two [Claude Code](https://claude.com/claude-code) **skills** that together take a physical
Blu-ray or DVD all the way to a clean, Plex-ready media library — decrypt & back up the disc,
then GPU-transcode it with NVIDIA NVENC and stage it into a correctly-named library.

```
physical disc ──[ disc-backup ]──▶ decrypted BDMV/VIDEO_TS folder ──[ disc-to-plex ]──▶ Plex-ready MKVs
```

## The skills

### [`disc-backup/`](disc-backup/) — rip & decrypt (stage 1)
Drives **MakeMKV** to back a disc up to a decrypted folder (`BDMV/` for Blu-ray, `VIDEO_TS/` for
DVD) — the same structure an unprotected rip produces, so the transcode stage needs no changes.
Handles drive enumeration and the rotating MakeMKV beta key. Operates only on discs you own,
where local law permits format-shifting; it does not crack or distribute keys.

### [`disc-to-plex/`](disc-to-plex/) — transcode & stage (stage 2)
Turns a decrypted rip into Plex-named MKVs: H.264 NVENC (CQ 20), correct cropping and aspect,
DVD deinterlacing, PGS/VOBSUB subtitles with OCR to SRT sidecars, a selectable audio matrix with
a universal compatibility downmix, and library naming that merges cleanly into an existing
collection. Reads via ffmpeg's libavformat, so it survives discs that **crash HandBrake's
libbluray reader** (PGS subtitle timestamp discontinuities). Fully manifest-driven and resumable.

You can use either skill on its own — `disc-to-plex` works on any already-decrypted rip; run
`disc-backup` first only when you're starting from a physical, possibly-encrypted disc.

## What this repo is really about

The encoding is the easy part. What took the hours — and what most of these files encode — is that
**disc jobs fail quietly**. They ship a plausible file: the wrong cut of the film, an extra
truncated at its first clip, a commentary a viewer lands on by picking "English", an episode one
slot out for a whole series. Every structural check passes. Counts match, durations look sane.

Two things follow, and they shape the whole repo:

1. **Verify identity from the content** — look at a frame, read the title off the screen,
   transcribe the audio. Names, file sizes and durations are hints, not evidence.
2. **When a rule can be a check, make it a check.** Prose does not enforce itself. Rules written
   in this repo — in capitals — were violated within hours of being committed, because the
   reference file had grown past what anyone (human or model) reads before acting.

So the hard-won rules now run as guards inside the scripts:

| Guard | Catches |
|---|---|
| Raw `.m2ts` vs a playlist that **contains** it → abort | truncated extras, wrong cut of a film |
| Untitled / duplicate-signature audio → report | hidden commentaries, the same mix shipped twice |
| `.mkv` with `duration = N/A` → refuse to publish | unfinalised partial encodes |
| ffmpeg live, or folder touched < 5 min ago → refuse | deleting an active encode's output |
| OCR cue-count and junk-fraction floors → refuse | failed recognition reported as success |

The remaining knowledge lives in [`disc-to-plex/references/gotchas.md`](disc-to-plex/references/gotchas.md),
an index over seven domain files (Blu-ray, DVD, audio, subtitles, Plex, pipeline, process). It is
split deliberately: read the one that matches the job, not all of it.

## Project instructions

[`examples/CLAUDE.md`](examples/CLAUDE.md) is the author's working `CLAUDE.md`, which lives at the
root of the media directory rather than in a skill. It carries the rules that must survive a
context compaction — source/NAS write protection, a two-command gated-delete protocol,
publish-immediately/reclaim-only-when-confirmed, and the environment quirks that silently corrupt
copies. Adapt the paths to your own setup.

## Install

Clone the repo, then point Claude Code at each skill (copy or symlink into your skills dir):

```bash
git clone https://github.com/mwadams/claude-disc-to-plex.git
# then, e.g.
cp -r claude-disc-to-plex/disc-backup   ~/.claude/skills/disc-backup
cp -r claude-disc-to-plex/disc-to-plex  ~/.claude/skills/disc-to-plex
```

Claude discovers them automatically and consults the relevant `SKILL.md` when you ask to rip or
convert discs for Plex.

## Requirements

- **Windows** with **PowerShell 7+** (`pwsh`) and an **NVIDIA GPU** (NVENC) for transcoding.
- **MakeMKV** (registered) for the backup stage; **libdvdcss** helps with CSS DVDs.
- The transcode toolchain (a driver-compatible ffmpeg + SupMover) is fetched automatically by
  `disc-to-plex/scripts/install-tools.ps1` — no manual installs.

Each skill's `SKILL.md` and `references/` document the full workflow and the non-obvious failure
modes. Start with [`disc-backup/SKILL.md`](disc-backup/SKILL.md) and
[`disc-to-plex/SKILL.md`](disc-to-plex/SKILL.md).

## License

MIT — see [LICENSE](LICENSE).

---

*Built with [Claude Code](https://claude.com/claude-code).*
