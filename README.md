# claude-disc-to-plex

A [Claude Code](https://claude.com/claude-code) **skill** for turning ripped Blu-ray and DVD
discs into a clean, Plex-ready media library — GPU-accelerated with NVIDIA NVENC, fully
manifest-driven, and hardened against the sharp edges that make this fiddly by hand.

It handles TV episodes, movies, and bonus features in one pass: correct aspect ratio and
cropping, deinterlacing for DVD, PGS/VOBSUB subtitle handling, an audio matrix that keeps every
original track plus a universal compatibility downmix, and Plex naming that merges cleanly into
an existing library.

## Why it exists

- HandBrake's Blu-ray reader (libbluray) **crashes on some discs** — PGS subtitle timestamp
  discontinuities being the usual culprit. This pipeline reads via ffmpeg's libavformat instead,
  which tolerates them.
- Driving a large, correctly-named, resumable batch by hand is error-prone. A manifest + one
  script makes it repeatable.
- The non-obvious failure modes (m2ts double-listing audio streams, no-audio titles, anamorphic
  DVD, subtitle drift after cropping, driver/ffmpeg NVENC mismatches) are all documented and
  handled — see [`references/gotchas.md`](references/gotchas.md).

## Install

Clone into your Claude Code skills directory:

```bash
git clone https://github.com/mwadams/claude-disc-to-plex.git ~/.claude/skills/disc-to-plex
```

(or a project-level `<project>/.claude/skills/disc-to-plex`). Claude will discover it
automatically and consult `SKILL.md` when you ask to convert discs for Plex.

## Requirements

- **Windows** with **PowerShell 7+** (`pwsh`) and an **NVIDIA GPU** (NVENC).
- The toolchain (a driver-compatible ffmpeg build + SupMover) is fetched automatically by
  `scripts/install-tools.ps1` — no manual installs.
- Decrypted rips as input: plain `BDMV/` (m2ts) or `VIDEO_TS/` (VOB) folders. Decryption is a
  separate rip-stage concern and out of scope (this skill performs no DRM circumvention).

## Usage in brief

```powershell
# 1. one-time toolchain setup + NVENC self-test
pwsh -File scripts/install-tools.ps1 -ToolsDir D:\video\.transcode-tools

# 2. write a manifest (one object per output) — see SKILL.md for the schema
# 3. transcode
pwsh -File scripts/transcode.ps1 -Manifest items.json -ToolsDir D:\video\.transcode-tools
```

The full workflow — inspecting discs, identifying titles and the correct Plex/TMDB episode
order, building the manifest, verifying, and staging into the library — is described in
[`SKILL.md`](SKILL.md).

## What's inside

```
SKILL.md                     the workflow Claude follows
scripts/install-tools.ps1    fetch ffmpeg (BtbN n7.1) + SupMover, verify NVENC
scripts/transcode.ps1        manifest-driven encoder (BD + DVD, one code path)
references/pipelines.md       BD vs DVD encode details, audio matrix, subtitles
references/naming.md          Plex naming + library/Season-00 conventions
references/identification.md  identifying titles and the correct episode order
references/gotchas.md         the non-obvious failure modes and their fixes
```

## License

MIT — see [LICENSE](LICENSE).

---

*Built with [Claude Code](https://claude.com/claude-code).*
