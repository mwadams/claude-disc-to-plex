# MakeMKV backup — details

## Registration / the beta key

MakeMKV runs as a perpetual free **beta** whose registration key rotates roughly every two
months. Without a valid key, backup/decrypt fails. The current beta key is community-maintained
at <https://forum.makemkv.com/forum/viewtopic.php?t=20579>.

- The CLI (`makemkvcon`) and GUI share one key in `%APPDATA%\MakeMKV\settings.conf` as
  `app_Key = "T-…"`.
- `register-makemkv.ps1 -Fetch` scrapes that thread for the `T-…` key and writes it;
  `-Key "T-…"` sets one you paste. The `-Fetch` regex may need updating if the forum layout
  changes — fall back to `-Key`.
- A **purchased** license is permanent — don't overwrite it with the rotating beta key.
- A registration problem surfaces as a `MSG:` line mentioning registration/expired/shareware
  when `makemkvcon` starts.

## Locating the CLI and drives

`makemkvcon64.exe` installs under `C:\Program Files (x86)\MakeMKV\`. Enumerate drives in robot
mode:

```
makemkvcon -r --cache=1 info disc:9999
```

Each drive is a `DRV:` line:

```
DRV:index,state,flags,drivetype,"drive name","disc name","device path"
```

A drive with media has a non-empty **disc name** (field 6) and/or **device path** (field 7);
its `index` is what you pass as `disc:index` to backup. Empty `DRV:` lines are absent/empty
drives. `MSG:5042 … can't find any usable optical drives` means no drive is attached (laptops
typically use an external USB Blu-ray drive).

## The backup command

```
makemkvcon backup --decrypt -r --progress=-same --cache=16 disc:<index> "<dest folder>"
```

- `--decrypt` removes AACS (Blu-ray) / CSS (DVD) so the output opens in ffmpeg.
- Output is a **folder tree**: Blu-ray → `BDMV/` (with `STREAM/*.m2ts`, `PLAYLIST`, `CLIPINF`),
  DVD → `VIDEO_TS/` (`*.VOB`, `*.IFO`). This matches an unprotected rip, so disc-to-plex needs
  no changes.
- `makemkvcon` exits 0 on success. Reading a whole disc is I/O-bound and slow (drive speed
  limited) — 20–60+ minutes; background it.

## Blu-ray vs DVD

- **Blu-ray**: MakeMKV backup is the primary, well-worn path → clean `BDMV` tree.
- **DVD**: MakeMKV can also back up DVDs to `VIDEO_TS`. If a given disc/version instead yields
  loose `.mkv` titles, that's title mode, not backup — the `backup --decrypt` command avoids it.
  With **libdvdcss** present, ffmpeg/HandBrake can alternatively read a CSS DVD directly, but a
  folder backup keeps the two-stage pipeline uniform.

## Verifying a backup before recycling the disc

```
ffprobe -v error -show_entries format=duration -of csv=p=0 "<dest>\BDMV\STREAM\<largest>.m2ts"
```

Confirm the main titles have sane durations and streams. Then hand the folder to disc-to-plex.
