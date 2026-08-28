# Blu-ray gotchas

Playlists, streams, cropping, PGS, and why the biggest .m2ts is not the feature.

Part of the `disc-to-plex` gotchas set — see [gotchas.md](gotchas.md) for the full index.

## A raw `.m2ts` title is only a duplicate if it MATCHES AN EPISODE PLAYLIST

MakeMKV lists both playlist titles (`00800.mpls`) and raw stream titles (`00002.m2ts`). On a
Newsroom disc the raw `00002.m2ts` ran 1:12:44 — exactly the same as the `00800.mpls` episode — so
it was that episode listed twice, 19 GB of pure duplicate. But the SAME disc also exposed
`00045.m2ts`, `00046.m2ts` and `00047.m2ts` as raw titles, and those were **genuine extras**,
including the "Inside the Episode" featurette.

So the rule is narrow:

> Exclude a raw `.m2ts` title **only** when its duration matches an episode playlist on that disc.
> Every other raw stream is an extra until identified otherwise.

**Do not "optimise" a rip by passing MakeMKV an explicit title list that omits raw streams**, and do
not skip them wholesale to save space or time. It saves ~15 GB per disc and costs you the extras —
which is the failure this project keeps paying for, in a new disguise. Rip `all`, then delete the
proven duplicate once its duration is confirmed against the playlist title.


## Contents

- [`crop: "auto"` cropped the SIDES off a letterboxed widescreen film](#crop-auto-cropped-the-sides-off-a-letterboxed-widescreen-film)
- [m2ts audio streams are double-counted by ffprobe](#m2ts-audio-streams-are-double-counted-by-ffprobe)
- [ENUMERATE BLU-RAYS WITH MakeMKV — "the biggest .m2ts" is not the feature](#enumerate-blu-rays-with-makemkv-the-biggest-m2ts-is-not-the-feature)
- [The CLPI clip-info file is the authoritative stream list on a Blu-ray — better than the MPLS](#the-clpi-clip-info-file-is-the-authoritative-stream-list-on-a-blu-ray-better-than-the-mpls)
- [Blu-ray m2ts carry no language tags — use the PLAYLIST, and `audioTracks`](#blu-ray-m2ts-carry-no-language-tags-use-the-playlist-and-audiotracks)
- [A Blu-ray encode dies in ~1 second: "Error opening input file ..._fixed.sup"](#a-blu-ray-encode-dies-in-1-second-error-opening-input-file-_fixedsup)
- [Seamless-branching Blu-rays, and why `crop: "auto"` lies on them](#seamless-branching-blu-rays-and-why-crop-auto-lies-on-them)
- [`crop: "auto"` on a non-1080p Blu-ray stream produces an impossible crop](#crop-auto-on-a-non-1080p-blu-ray-stream-produces-an-impossible-crop)
- [A `.mpls` need NOT contain the stream that shares its number](#a-mpls-need-not-contain-the-stream-that-shares-its-number)
- [MakeMKV title indices shift with `--minlength` — enumerate and rip with the SAME value](#makemkv-title-indices-shift-with-minlength-enumerate-and-rip-with-the-same-value)
- [Ripping extras: never `all`, never in the foreground](#ripping-extras-never-all-never-in-the-foreground)
- [On a catalogue Blu-ray, HD vs SD separates the trailers from the legacy featurettes](#on-a-catalogue-blu-ray-hd-vs-sd-separates-the-trailers-from-the-legacy-featurettes)

## MakeMKV title indices shift with `--minlength` — enumerate and rip with the SAME value

The title numbers MakeMKV prints are positions in the **filtered** list, not stable disc identifiers.
Enumerating In the Line of Fire with `--minlength=60` and then ripping with `--minlength=50`
produced eleven files whose durations did not match the eleven titles enumerated: two ~1-minute
items appeared that the enumeration had never listed, and the 1:34 title was gone.

Nothing errors. The rip succeeds, the count matches, and every downstream name is wrong — which is
the same shape as every other expensive failure here.

Either pass the identical `--minlength` to both calls, or (better) **identify the ripped files from
their own content and durations** and ignore the index entirely. The second is what this pipeline
does anyway for naming, so the index only ever needs to be right enough to fetch the file.

## Ripping extras: never `all`, never in the foreground

Two failure modes, both hit on the same disc:

- **`all` includes the feature.** Ripping a disc's extras with `mkv "file:<disc>" all` copies the
  90-minute feature first — tens of GB you already have — and on Goats that blew the agent
  harness's 10-minute foreground timeout, leaving a 12 GB partial `title_t00.mkv`.
- **Foreground invocation gets killed by the tool timeout**, exactly as with `transcode.ps1`.

Rip only the titles you need, **sequentially inside one background command**:

```powershell
foreach($i in 1..8){
  & $mk -r --cache=1 --minlength=60 --noscan mkv "file:$disc" $i $out 2>&1 |
    Select-String 'titles saved'
}
```

Sequential-in-one-shell is what the "one disc at a time" rule means — it is *concurrent*
`makemkvcon` processes that silently save 0 files, not successive ones. Delete any partial from a
killed run before re-running: a 12 GB partial looks entirely plausible on disk.

## On a catalogue Blu-ray, HD vs SD separates the trailers from the legacy featurettes

A useful shortcut when classifying a pile of ripped extras: probe `width,height` on each. On
catalogue re-releases the **trailers are re-mastered HD (1920×1080, 16:9)** while the **featurettes
and deleted scenes are the original SD (720×480 or 720×576, 4:3)** carried over from the DVD.

In the Line of Fire split exactly that way — 4 SD featurettes plus SD deleted scenes, and 2 HD
trailers — and the split resolved two items whose content alone was ambiguous (a silent 56-second
close-up turned out to be the teaser, not a deleted scene).

It also drives the manifest: SD items need `kind: "MKV"` (deinterlace + source DAR), HD items
`kind: "BD"`. Getting that backwards squishes a 4:3 featurette or leaves an SD one interlaced.

## `crop: "auto"` cropped the SIDES off a letterboxed widescreen film

`Get-Crop` had two faults that combined to mangle a 2.35:1 Blu-ray (`An Education`, 2009):

1. It collected cropdetect candidates into a hashtable as `$crops[$v]=1` — **discarding frequency**
   — then chose the candidate with the largest *area*. One dark or close-up scene is enough to
   emit a bogus tight crop, and nothing outvoted it.
2. Its sanity check `if($w -lt 1400 -or $h -lt 1060){ return '1440:1080:240:0' }` **rejected every
   legitimate letterbox crop** (a 2.35:1 frame is 1920×816, so `h` is always < 1060) and replaced
   it with the hard-coded 4:3 pillarbox default.

Result: `crop=1440:1080:240:0` on a full-width letterboxed film — the black bars were **kept** and
the left and right thirds of the picture **thrown away**. It prints a plausible-looking
`crop=` line, so the only tell is reading that number and sanity-checking it against the film's
actual aspect ratio. **Always do that before letting a BD run to completion.**

Fixed in `transcode.ps1`: cropdetect now votes across 6 sample points and takes the **mode**, and
the guard accepts a frame that is full-width (letterbox) **or** full-height (pillarbox), rejecting
only crops inset on both axes. `crop` now also accepts an explicit `"W:H:X:Y"` string to override
auto entirely — the safest option when you have already measured it:

```
for t in 600 1500 2400 3300 4200; do
  ffmpeg -hide_banner -ss $t -i "$m2ts" -vf cropdetect=limit=24:round=2 -frames:v 200 -an -f null - 2>&1 \
    | grep -oE "crop=[0-9:]+" | sort | uniq -c | sort -rn | head -3
done
```

The dominant value across timestamps is the true frame. Batch-1 output was audited and is
unaffected — those BDs were all 4:3 or full-frame, so the bug never bit until batch 2.

## m2ts audio streams are double-counted by ffprobe

On MPEG-TS/m2ts, `ffprobe -select_streams a -show_entries stream=index` lists each audio stream
**twice** and emits a blank line (e.g. `1,2,,1,2`). A naive count gives 2× and produces an
invalid `-map 0:a:N`. Count **distinct numeric** indices:
`... | Where-Object {$_ -match '^\d+$'} | Sort-Object -Unique | Measure`. DVD VOB does not
double-count.

## ENUMERATE BLU-RAYS WITH MakeMKV — "the biggest .m2ts" is not the feature

Picking the largest file in `BDMV/STREAM` and reading it with ffmpeg is the obvious approach and it
is wrong often enough to matter. On The Italian Job it produced THREE faults at once, none of them
visible from the m2ts:

1. **The wrong cut.** `00001.mpls` is 1:34:58; `00033.mpls` and `00034.mpls` are **1:39:30**. The
   film's UK theatrical runtime is 99 minutes — the 95-minute version shipped.
2. **Two invisible commentaries.** The disc declares two, CLPI lists two extra English entries, and
   ffmpeg exposes NEITHER on the raw clip. MakeMKV exposes all nine audio tracks.
3. **No language tags at all**, which forces guessing the audio layout from metadata order — the
   root of every audio mistake on this drive.

```
makemkvcon64.exe -r --cache=1 info "file:<disc folder>"
   TINFO:<id>,9,0,"H:MM:SS"    title runtime
   TINFO:<id>,16,0,"00033.mpls" its source playlist
   SINFO:<id>,<n>,30,0,"..."    per-stream description
```

Then rip the chosen title and transcode from the MKV with `kind: "BD"` (NOT `"MKV"`, which applies
the SD deinterlace path). MakeMKV writes **proper language tags**, so `subTrack: "eng"` and
`audioLangs` resolve on their own instead of by inference.

`scripts/audit-bd-titles.ps1` runs this comparison across a whole drive. Doing so found 9 of 10
discs correct — so this is not a reason to distrust every transfer, but it IS a reason to enumerate
with MakeMKV rather than by file size. (It also disproved a runtime I had flagged from memory: The
Men Who Stare at Goats is genuinely 89.7 min, not the ~94 I half-remembered. Measure, don't recall.)

**A playlist can also PREPEND clips.** Ratatouille's playlists run 111.07 min against 110.55 for
the raw m2ts — 31 s of studio idents at the head. Harmless there, but it means raw-m2ts encoding
silently drops whatever the playlist adds.

**Deleting a superseded .mkv does NOT remove its sidecar .srt.** After re-encoding a longer cut,
the orphaned subtitle file looked correct at the head and ended five minutes early. Regenerate and
check the LAST cue timestamp, not the first.

## The CLPI clip-info file is the authoritative stream list on a Blu-ray — better than the MPLS

For picking audio and subtitle tracks on an untagged BD, `BDMV/CLIPINF/<clip>.clpi` beats both the
m2ts (no tags at all) and a regex sweep of the `.mpls`. Its stream entries sit at a **24-byte
stride** with the ISO-639 code in plain ASCII, so they read cleanly and IN ORDER:

```powershell
$b=[IO.File]::ReadAllBytes("$stage\BDMV\CLIPINF\00001.clpi")
for($i=3;$i -lt $b.Length-3;$i++){
  $t=[Text.Encoding]::ASCII.GetString($b,$i,3)
  if($t -in @('eng','deu','fra','spa','ita','nld','dan','swe','nor','fin','por')){ "$i $t" } }
```

The Italian Job returned `eng eng deu spa fra ita eng eng` for audio, then the subtitle list
beginning `dan deu eng…`. That immediately shows two things worth knowing:

- **The two trailing `eng` entries are the two commentaries** the disc declares. A first pass had
  assumed the five AC3 2.0 tracks were deu/spa/fra/ita/eng and kept only one — silently dropping a
  commentary. The CLPI makes the real layout obvious.
- **Subtitles start with Danish.** A habitual `subTrack: 0` would ship Danish subtitles.

Loudness profiling (`volumedetect` at two quiet points) is a useful CROSS-CHECK but not proof: the
2.0 tracks all sit above the 5.1 mix simply because they are stereo downmixes. What confirmed the
commentaries here was that each stood out at a *different* timestamp — two tracks with independent
talking patterns — while the dubs tracked the film mix together.

## Blu-ray m2ts carry no language tags — use the PLAYLIST, and `audioTracks`

Catalogue Blu-rays routinely ship `.m2ts` with **no `language` tag on any stream**. `Keep-AudioIdx`
maps untagged to English on purpose (English-original discs often leave the tag empty), so on a
multi-language BD it keeps **every** track — the French and Spanish dubs ride along, and a 4.6 Mb/s
5.1 LPCM dub gets FLAC-encoded into the output. Enemy of the State (1998) exposes six audio
streams this way: LPCM, AC3, DTS, AC3, DTS, AC3, all untagged.

**The languages live in the `.mpls` playlist, not the stream.** Read them straight out of the
binary — the ISO-639 codes are plain ASCII:

```powershell
$b=[System.IO.File]::ReadAllBytes("$stage\BDMV\PLAYLIST\00045.mpls")
$s=[System.Text.Encoding]::ASCII.GetString($b)
([regex]::Matches($s,'(eng|fre|fra|spa|ger|deu|ita|jpn|nld|swe|nor|dan|fin)')|%{$_.Value}) -join ' '
```

Enemy of the State returned `eng eng fra fra spa spa …` for its six audio streams — English gets
LPCM + AC3, French and Spanish each get DTS + AC3. Then pin the choice explicitly in the manifest:

```json
{ "kind": "BD", "src": "…\00000.m2ts", "audioTracks": [0], "crop": "1920:812:0:134" }
```

`audioTracks` is an explicit list of audio ordinals to keep, in order (first = default), and
overrides the automatic pick entirely. The script prints `audioTracks explicit -> a:0` so you can
see it took effect. Use it on any BD whose streams are untagged; the automatic path is still right
for DVDs and for tagged sources.

**The same `.mpls` also gives the feature's clip ORDER.** A feature is often split across several
m2ts (Enemy of the State = `00000` + `00008` + `00009`, 56.23 + 57.30 + 18.65 = 132.18 min = the
film's runtime). Don't guess the order from file numbering — pull it from the playlist:

```powershell
([regex]::Matches($s,'\d{5}(?=M2TS)')|%{$_.Value}) -join ' -> '
```

Encode each part, then stream-copy concat, exactly as for a compilation disc. Ignore the 2-second
clips that trail the playlist — those are logo/ident stubs, not content.

## A Blu-ray encode dies in ~1 second: "Error opening input file ..._fixed.sup"

Symptom: the item prints its `crop=` line, then `!! FAILED (1 s)` (or `0 s`), and the stderr file
holds:

```
Error opening input file D:<VT>ideo\.transcode-tools\work\...\s2_fixed.sup.
Error opening input files: No such file or directory
```

Cause: the PGS repositioning step ran `SupMover` and then passed `s<i>_fixed.sup` to ffmpeg
**without checking SupMover had written it**. When cropdetect returns a full-frame crop
(`1920:1080:0:0`) every offset is zero, there is nothing to reposition, SupMover produces no
output — and ffmpeg is handed a path that does not exist.

Why it is easy to misread: on the same disc the *extras* encode fine, because they are 4:3
featurettes with a real pillarbox crop (`1440:1080:240:0`), so SupMover does write a file. Only
the full-frame items die, which looks like the episodes being special rather than the crop being
a no-op. Two BD lanes running together is a coincidence, not the cause — do not chase it.

The run still prints `MANIFEST DONE`, so nothing in the log summary flags the loss. **Always size-
check outputs after a manifest**; five episodes went missing here behind a clean-looking log.

Fix (in `scripts/transcode.ps1`): skip repositioning entirely when the crop is full-frame, and
never assign `$subInput` unless the fixed `.sup` actually exists and is non-trivial. `$work` is
also per-process (`work\pid<PID>`) so two lanes cannot share `.sup` scratch names.

## Seamless-branching Blu-rays, and why `crop: "auto"` lies on them

Some Blu-rays (Warner discs especially) hold **no single feature stream**. `Sherlock Holmes` (2009)
splits its 128-minute film across 23 clips in `BDMV/STREAM`, the largest only 17 minutes, assembled
by a `.mpls` playlist. Picking "the biggest m2ts" gets you a fragment.

Find the feature by parsing the playlist: `.mpls` files list their clips as plain ASCII, so

```powershell
$s = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($mpls))
[regex]::Matches($s,'(\d{5})M2TS') | ForEach-Object { $_.Groups[1].Value }
```

gives the clip order. Sum the clip durations and check the total against the known runtime before
trusting it. Feed the ordered clips to the encoder as a **concat-demuxer list** (`src` pointing at a
`.txt` of `file '...'` lines); `InSpec` detects the `.txt` and reads it as one input, so no 25 GB+
intermediate copy is needed.

**`crop: "auto"` must NOT be used on a concat list.** cropdetect samples by seeking to timestamps,
and those seeks do not work reliably through the concat demuxer, so `Get-Crop` falls through to its
`1440:1080:240:0` pillarbox default — which would slice 240 px off each side of a widescreen film.
The tell is a 4:3 crop on a film you know is scope or 1.85:1. Run cropdetect against a couple of
individual mid-film clips instead, then pass the answer explicitly (or `"none"`, which is right
whenever the clips are full-frame 1920x1080).

## `crop: "auto"` on a non-1080p Blu-ray stream produces an impossible crop

`Get-Crop`'s fallback returns the 4:3 pillarbox `1440:1080:240:0`. On a Blu-ray whose stream is NOT
1920x1080 that crop is larger than the source, and ffmpeg refuses it outright:

```
[Parsed_crop_0] Invalid too big or non positive size for width '1440' or height '1080'
[vf#0:0] Error reinitializing filters!
```

Blu-ray extras are frequently **720x480 / 720x576 SD** even though they sit in `BDMV/STREAM` as
`.m2ts` — all eight Superman Returns featurettes were SD while the feature was 1080p. Probe
`stream=width,height` before assuming a stream is HD just because of where it lives.

Those SD extras also want the SD treatment, not the BD one: use `kind: "MKV"` (deinterlace +
preserve DAR) with no `crop`, rather than `kind: "BD"`.

Same root cause as the concat-list case: whenever `Get-Crop` cannot sample properly it falls back to
a hard-coded 4:3 crop. Treat any `1440:1080:240:0` on a widescreen or non-HD source as a bug signal,
not a measurement.

## A `.mpls` need NOT contain the stream that shares its number

Zulu's `00020.mpls` contains clips **00019 and 00021** — not `00020.m2ts` at all. `00020.m2ts` is a
separate 73 s teaser that no playlist references under its own name.

This produced a two-stage mistake worth remembering as one story:

1. MakeMKV reported title 1 (`00020.mpls`) as **3:38** while `00020.m2ts` probed at **1:23**. That
   looks exactly like the playlist-truncation failure, so the "fix" was to rip title 1 and encode
   that instead.
2. Title 1 is the *theatrical trailer plus a 1-second ident* — i.e. the same content as title 6
   (`00019.m2ts`, 3:37). The result was **two identical trailers shipped**, and the genuine teaser
   deleted. A frame from each at t=30 s, hstacked, showed the same title card in both halves.

**A length mismatch between a stream and a same-numbered playlist is NOT evidence of truncation.**
Prove containment before acting — the clip list is plain ASCII in the `.mpls`:

```powershell
$txt = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($mpls))
[regex]::Matches($txt,'(\d{5})(?=M2TS)') | ForEach-Object { $_.Groups[1].Value }
```

If the stream's own number is absent from that list, the playlist is a *different item* and the raw
stream was right all along. `transcode.ps1`'s preflight now does exactly this check and aborts with
the offending playlist named; set `"allowRawStream": true` on an item to override it deliberately.

**And always frame-compare two outputs you believe are different items.** Duplicate content is
invisible in every structural check — both files had plausible, different durations.

