---
name: disc-backup
description: >-
  Rip and decrypt a physical Blu-ray or DVD into a folder backup (BDMV/ or VIDEO_TS/) using
  MakeMKV, ready to feed the disc-to-plex transcode skill. Use this whenever the user wants to
  rip, back up, or decrypt a disc; mentions MakeMKV, libdvdcss, AACS, CSS, an optical/BD/DVD
  drive, or "get this disc onto the NAS/Plex"; or has a disc in the drive and wants it in their
  library. This is the upstream half of the pipeline — it produces the decrypted disc folders
  that the disc-to-plex skill then transcodes. Reach for it before disc-to-plex whenever the
  starting point is a physical disc rather than an existing rip.
---

# Disc → decrypted folder backup

Turn a physical disc into a decrypted **folder backup** — `BDMV/STREAM/*.m2ts` for Blu-ray,
`VIDEO_TS/*.VOB` for DVD — using MakeMKV's backup mode. That folder is exactly what the
**disc-to-plex** skill consumes, so this is stage 1 of a two-stage pipeline:

```
physical disc  --(disc-backup)-->  decrypted BDMV/VIDEO_TS folder  --(disc-to-plex)-->  Plex-ready MKVs
```

Backup mode (not "Make MKV" mode) is deliberate: it yields the same disc structure as an
unprotected rip, so nothing downstream changes.

## Prerequisites

- **MakeMKV** installed (provides `makemkvcon64.exe`). It must be **registered** — the free beta
  key rotates roughly every two months. The CLI uses the same key as the GUI (stored in
  `%APPDATA%\MakeMKV\settings.conf`).
- **libdvdcss** helps tools read CSS-protected DVDs; MakeMKV also carries its own AACS/CSS
  handling, so a MakeMKV backup normally needs nothing extra.
- Decryption is legitimate only for discs the user owns and where local law permits format-
  shifting. This skill drives MakeMKV; it does not itself crack or distribute keys.

## Steps

1. **Check registration / drives** — `pwsh -File scripts/list-discs.ps1`. Lists optical drives
   and any loaded disc with its MakeMKV index. If it reports a registration problem, apply a
   key first (below). Laptops usually need an external USB Blu-ray drive attached.

2. **Register if needed** — `pwsh -File scripts/register-makemkv.ps1 -Fetch` pulls the current
   beta key from the maintained thread
   (<https://forum.makemkv.com/forum/viewtopic.php?t=20579>) and writes it to `settings.conf`;
   or `-Key "T-…"` to paste one. Skip if a purchased license is installed. See
   `references/makemkv.md`.

3. **Back up the disc** — `pwsh -File scripts/backup-disc.ps1 -Dest "E:\Movies\<Title> Disk N"`.
   Auto-detects the single loaded disc (or pass `-Drive N`). Runs `makemkvcon backup --decrypt`
   and verifies a `BDMV/STREAM` or `VIDEO_TS` tree resulted. Reading a whole disc takes 20–60+
   minutes; run it in the background. Name `-Dest` the way disc-to-plex expects
   (`<Show> Disk N` for a series disc, `<Movie>` for a film) — see the disc-to-plex naming ref.

4. **Hand off** — pass the resulting folder to the **disc-to-plex** skill to identify titles,
   build a manifest, transcode, and stage into the library.

## Notes

- One disc at a time per drive; for a box set, back up each disc to its own `Disk N` folder.
- If MakeMKV emits `.mkv` files instead of a folder tree, it ran in title mode, not backup mode
  — re-run with `backup --decrypt` (as `backup-disc.ps1` does). disc-to-plex expects the folder
  structure, not loose MKVs.
- Verify the backup opens (`ffprobe` a main-title `.m2ts`/`.VOB`) before recycling the disc.
- Back up onto the staging drive with plenty of free space (a BD is 25–50 GB); the transcode
  output is much smaller and lands in the library separately.

## Reference

- `references/makemkv.md` — registration/keys, drive+disc parsing, Blu-ray vs DVD backup
  behaviour, verifying a backup, and the libdvdcss role.
