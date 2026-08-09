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
DVD deinterlacing, PGS/VOBSUB subtitles, an audio matrix that keeps every original track plus a
universal compatibility downmix, and library naming that merges cleanly into an existing
collection. Reads via ffmpeg's libavformat, so it survives discs that **crash HandBrake's
libbluray reader** (PGS subtitle timestamp discontinuities). Fully manifest-driven and resumable.

You can use either skill on its own — `disc-to-plex` works on any already-decrypted rip; run
`disc-backup` first only when you're starting from a physical, possibly-encrypted disc.

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
