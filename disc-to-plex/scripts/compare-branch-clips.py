"""Do two Blu-ray playlists that LOOK like twins actually carry the same pictures?

WHY THIS EXISTS
---------------
2026-09-21, Blake's 7 Series 1 Disc 1. Both episodes were delivered as TWO playlists each, and the
dispositions excluded one of each as `exclude|duplicate` - reasoning from identical runtime and
identical audioMd5 per clip pair. They were the MODERNIZED-VFX branches. Half the disc's content
was about to be discarded, and the same logic would have run over 26 episodes across Series 1 and 2.

The agent was not wrong given what it had. It was given the wrong thing: PROSE ABOUT CLIP LISTS -
which clips are shared, which runtimes match, which audio fingerprints agree. From that input
"duplicate" is a sound conclusion. It is unsound only because, on a seamless-branching VFX remaster,
duration and audioMd5 match BY CONSTRUCTION: re-rendering an effects shot does not touch the
soundtrack. The evidence offered cannot distinguish "identical episode" from "same episode,
different pictures", so no amount of care applied to it would have helped.

So this measures the VIDEO and hands the answer to the brief. The disposition then reasons from a
measurement instead of from arithmetic, which is cheaper than an agent and checkable afterwards.

WHAT IT REPORTS, AND WHAT IT REFUSES TO SAY
  - the clips the two playlists SHARE (identical file - definitionally the same pictures), and the
    positional pairs that differ;
  - for each differing pair, a FULL per-frame SSIM pass and the SUSTAINED divergence windows;
  - with --published, which branch matches the copy already in the library.

  It never concludes "duplicate". Finding no divergence is reported as
  "no sustained divergence in N frames compared", which is a measurement. Absence of evidence in a
  sampled window is exactly the mistake this tool exists to stop being made.

WHY FULL FRAMES AND NOT SAMPLING
  A 2-second effects shot hides between samples. On the case above, sampling 13 offsets across a
  361 s clip found dips of 0.82-0.93 that turned out to be FRAME-ALIGNMENT NOISE on motion - the
  frames were the same picture - while the real difference sat in four clean-edged windows. Only the
  full pass separates the two, because what distinguishes them is not the depth of the dip but
  whether it is SUSTAINED and sharply bounded.

USAGE
  python compare-branch-clips.py <STREAM dir> --a <a.mpls> --b <b.mpls> [--published <file.mkv>]
                                 [--json out.json] [--frames <dir>]

  <STREAM dir> is BDMV/STREAM. The .mpls paths are usually BDMV/PLAYLIST/xxxxx.mpls.
"""
import argparse, json, os, re, subprocess, sys, tempfile

SUSTAINED_FRAMES = 25     # ~1 s at 25fps. Shorter runs are alignment noise, not a shot.
SSIM_FLOOR = 0.85         # below this a frame is "different"; tuned on the Blake's 7 case, where
                          # the encode baseline sat at ~0.99 and real swaps ran 0.68-0.78.


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True)


def clips_of(mpls, stream_dir, helper):
    """The playlist's clips in order, via the existing mpls-clips.py - never a second parser.

    CARRIES in/out/dur, WHICH ARE NOT THE FILE'S. A playlist TRIMS its clips: 00228 runs 717.0 s
    from an in-point of 11.65 s inside a longer .m2ts. Anchoring a moment by probing the file would
    be off by the in-point, and the published-copy comparison would land on the wrong shot."""
    r = run([sys.executable, helper, mpls, '--json', '--stream-dir', stream_dir])
    if r.returncode != 0:
        raise SystemExit(f"mpls-clips.py failed on {mpls}: {r.stderr.strip()[:300]}")
    data = json.loads(r.stdout)
    out = []
    for c in data.get('clips', []):
        cid = str(c.get('clip') or '').strip()
        if cid:
            out.append({'id': os.path.splitext(os.path.basename(cid))[0],
                        'in': float(c.get('inSec') or 0.0),
                        'dur': float(c.get('durSec') or 0.0)})
    return out


def ssim_windows(a_path, b_path):
    """Full per-frame SSIM. Returns (windows, frames_compared, worst). Windows are (start, end)
    frame indices of SUSTAINED runs below the floor."""
    with tempfile.TemporaryDirectory() as td:
        # A BARE FILENAME, WITH ffmpeg RUN INSIDE THE TEMP DIR.
        #
        # An ffmpeg FILTER ARGUMENT is not a shell argument. Inside a filterchain ":" separates
        # options and backslash escapes, so a Windows path parses as garbage - the first attempt
        # died with "No option name near 'temptmp69u9kqhpssim.txt'" because the backslashes were
        # eaten and the drive colon split the option. Forward slashes alone do NOT fix it: "D:" is
        # still an option break. Running in the directory and naming the file plainly sidesteps
        # every escaping rule instead of trying to satisfy them.
        stats = os.path.join(td, 'ssim.txt')
        # ABSOLUTE INPUTS, because cwd moved. Relative paths resolve against the TEMP dir, where
        # nothing exists - ffmpeg then wrote an EMPTY stats file and this returned "0 frames, no
        # divergence", which reads as "they are duplicates". A broken measurement that looks like a
        # clean result is the precise failure this tool was written to prevent, so it must not be
        # possible to produce one here.
        r = subprocess.run(['ffmpeg', '-v', 'error', '-i', os.path.abspath(a_path),
                            '-i', os.path.abspath(b_path),
                            '-lavfi', '[0:v][1:v]ssim=stats_file=ssim.txt', '-f', 'null', '-'],
                           capture_output=True, text=True, cwd=td)
        vals = []
        if os.path.exists(stats):
            with open(stats, encoding='utf-8', errors='replace') as fh:
                for line in fh:
                    m = re.search(r'\bn:(\d+)\b.*?\bAll:([\d.]+)', line)
                    if m:
                        vals.append((int(m.group(1)), float(m.group(2))))
    # FAIL LOUDLY ON NO MEASUREMENT. Zero frames is not "no difference"; it is "nothing was
    # compared", and the two must never be reported the same way.
    if not vals:
        raise SystemExit(
            f"MEASUREMENT FAILED - 0 frames compared for {os.path.basename(a_path)} vs "
            f"{os.path.basename(b_path)}. This is NOT a finding of 'no divergence'. "
            f"ffmpeg exit {r.returncode}: {(r.stderr or '').strip()[:400]}")
    low = [n for n, v in vals if v < SSIM_FLOOR]
    windows, start, prev = [], None, None
    for n in low:
        if start is None:
            start = n
        elif n != prev + 1:
            windows.append((start, prev))
            start = n
        prev = n
    if start is not None:
        windows.append((start, prev))
    windows = [w for w in windows if w[1] - w[0] + 1 >= SUSTAINED_FRAMES]
    # Depth matters as much as length. A shallow, short dip is alignment noise on motion; a real
    # shot swap is DEEP and SUSTAINED. Carry the minimum so the caller can say which it is instead
    # of the threshold silently deciding.
    by_n = dict(vals)
    deep = [(a, b, min(by_n[i] for i in range(a, b + 1) if i in by_n)) for a, b in windows]
    return deep, len(vals), min(v for _, v in vals)


def frame_at(path, seconds, out_png):
    run(['ffmpeg', '-v', 'error', '-y', '-ss', f'{seconds:.2f}', '-i', path,
         '-frames:v', '1', '-vf', 'scale=960:-1', out_png])
    return out_png if os.path.exists(out_png) else None


# frame_ssim() was removed 2026-09-21. It scored a published DVD still against each Blu-ray branch
# to name the original automatically. Matching shots scored 0.19-0.39 because the format difference
# (720x576 vs 1920x1080, different aspect handling) swamps the content difference, so the number
# could not separate a match from a mismatch. The frames are handed to a human instead. Do not
# reintroduce it without a measurement showing it discriminates.


def duration(path):
    r = run(['ffprobe', '-v', 'quiet', '-show_entries', 'format=duration', '-of', 'csv=p=0', path])
    try:
        return float((r.stdout or '').strip())
    except ValueError:
        return 0.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('stream_dir')
    ap.add_argument('--a', required=True, help='first playlist (.mpls)')
    ap.add_argument('--b', required=True, help='second playlist (.mpls)')
    ap.add_argument('--published', help='the copy already in the library, to settle WHICH branch is original')
    ap.add_argument('--fps', type=float, default=25.0)
    ap.add_argument('--frames', help='directory to write evidence frames into')
    ap.add_argument('--json', dest='json_out')
    args = ap.parse_args()

    helper = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mpls-clips.py')
    a_info = clips_of(args.a, args.stream_dir, helper)
    b_info = clips_of(args.b, args.stream_dir, helper)
    a_clips = [c['id'] for c in a_info]
    b_clips = [c['id'] for c in b_info]
    inof = {c['id']: c['in'] for c in a_info + b_info}
    durof = {c['id']: c['dur'] for c in a_info + b_info}

    shared = [c for c in a_clips if c in b_clips]
    a_only = [c for c in a_clips if c not in b_clips]
    b_only = [c for c in b_clips if c not in a_clips]

    print(f"playlist A {os.path.basename(args.a)}: {len(a_clips)} clip(s)")
    print(f"playlist B {os.path.basename(args.b)}: {len(b_clips)} clip(s)")
    print(f"  shared outright (same file, same pictures by definition): {len(shared)}  {' '.join(shared)}")
    print(f"  A-only: {' '.join(a_only) or '-'}")
    print(f"  B-only: {' '.join(b_only) or '-'}")
    if len(a_only) != len(b_only):
        print("  NOTE: unequal swap counts - these playlists are not a simple branch pair; read them by hand.")

    frames_dir = args.frames or tempfile.mkdtemp(prefix='branchcmp-')
    os.makedirs(frames_dir, exist_ok=True)

    result = {'a': args.a, 'b': args.b, 'shared': shared, 'pairs': [], 'verdict': None}
    total_div = 0.0
    biggest = None

    for ac, bc in zip(a_only, b_only):
        ap_ = os.path.join(args.stream_dir, ac + '.m2ts')
        bp_ = os.path.join(args.stream_dir, bc + '.m2ts')
        if not (os.path.exists(ap_) and os.path.exists(bp_)):
            print(f"  {ac} <-> {bc}: clip missing on disk - skipped")
            continue
        wins, n, worst = ssim_windows(ap_, bp_)
        secs = sum((e - s + 1) for s, e, d in wins
                   if (e - s + 1) / args.fps >= 4.0 and d < 0.80) / args.fps
        total_div += secs
        print(f"\n  {ac} <-> {bc}   {n} frames compared, worst SSIM {worst:.4f}")
        if not wins:
            print(f"      no sustained divergence (>= {SUSTAINED_FRAMES} frames below {SSIM_FLOOR})")
        for s, e, depth in wins:
            secs_w = (e - s + 1) / args.fps
            # STRONG = long enough and deep enough that it cannot be frame-alignment noise.
            # Measured on Blake's 7: real shot swaps ran 10-12s at 0.69-0.78, while same-picture
            # dips on motion sat around 0.81-0.93 and lasted about a second.
            strong = secs_w >= 4.0 and depth < 0.80
            tag = 'DIFFERENT ' if strong else 'marginal  '
            print(f"      {tag} frames {s}-{e}   {s/args.fps:7.1f}s - {e/args.fps:7.1f}s   "
                  f"({secs_w:.1f}s, min SSIM {depth:.3f}){'' if strong else '  <- check by eye, may be alignment noise'}")
            if strong and (biggest is None or (e - s) > (biggest[2] - biggest[1])):
                biggest = (ac, s, e, bc)
        result['pairs'].append({'a': ac, 'b': bc, 'frames': n, 'worstSsim': worst,
                                'windows': [{'from': s / args.fps, 'to': e / args.fps,
                                             'seconds': (e - s + 1) / args.fps, 'minSsim': d,
                                             'strong': (e - s + 1) / args.fps >= 4.0 and d < 0.80}
                                            for s, e, d in wins]})

    print(f"\ntotal sustained divergence: {total_div:.1f}s across {len(result['pairs'])} swapped pair(s)")
    if total_div == 0:
        print("MEASURED: no sustained divergence found. That is a measurement, NOT a finding of")
        print("'duplicate' - say what was compared and let the disposition conclude.")

    # WHICH BRANCH IS THE ORIGINAL? Only the library can say, and only where it already holds a copy.
    if args.published and biggest:
        ac, s, e, bc = biggest
        mid = ((s + e) / 2) / args.fps
        # Anchor the clip inside the episode: everything before it in playlist A.
        # TWO COORDINATE SYSTEMS, AND THEY MUST NOT BE MIXED.
        #
        # The SSIM pass decodes the WHOLE .m2ts, so `mid` is FILE time. The published anchor needs
        # PLAYLIST time, which is file time minus the clip's in-point, plus the playlist durations
        # of everything before it.
        #
        # Getting this backwards produced two silent failures at once: extracting at
        # in-point + mid (= 719.3s) overshot a 717s clip and returned no frame at all, and the
        # published estimate was inflated by the same in-point. "branch A: None" was the only
        # visible symptom, and a missing frame reads as nothing worth looking at.
        in_a = inof.get(ac, 0.0)
        playlist_pos = max(0.0, mid - in_a)
        before = sum(durof.get(c, 0.0) for c in a_clips[:a_clips.index(ac)])
        pub_at = before + playlist_pos
        # File time for the A clip; the B clip's own in-point may differ, so convert through the
        # playlist position rather than reusing A's seconds directly.
        fa = frame_at(os.path.join(args.stream_dir, ac + '.m2ts'), mid, os.path.join(frames_dir, f'A-{ac}.png'))
        fb = frame_at(os.path.join(args.stream_dir, bc + '.m2ts'), inof.get(bc, 0.0) + playlist_pos, os.path.join(frames_dir, f'B-{bc}.png'))
        if not fa or not fb:
            print(f"    (could not extract a frame at {mid:.1f}s - clip shorter than that? no verdict possible)")
        # WHICH BRANCH IS THE ORIGINAL IS NOT SCORED HERE - THE FRAMES ARE HANDED OVER INSTEAD.
        #
        # Two attempts at scoring it failed, and the reason is structural rather than fixable by
        # tuning. The published copy is a 720x576 DVD master; the branches are 1920x1080 Blu-ray.
        # Scaled to a common size, MATCHING shots score 0.19-0.39 - the difference between a match
        # and a mismatch is smaller than the difference made by the format. A threshold over those
        # numbers would be a coin toss wearing a decimal point, and this whole tool exists because
        # a confident-looking wrong answer cost half a disc.
        #
        # Worse, the anchor itself is only an estimate: the two masters do not share a zero, and a
        # search around it picked a frame 30s away that matched neither branch. That was reported as
        # "too close to call" when the truth was "landed on another shot".
        #
        # So: extract the three frames at the strongest window and say plainly that a human or an
        # agent must LOOK. That is a few seconds of attention against an hour of decoding, and it is
        # the step that actually settled it on Blake's 7.
        fp = frame_at(args.published, pub_at, os.path.join(frames_dir, 'published.png'))
        print(f"\nWHICH BRANCH IS THE ORIGINAL - LOOK AT THESE THREE FRAMES:")
        print(f"    strongest divergence: clip {ac} vs {bc} at {mid:.1f}s into the clip")
        print(f"    branch A  {ac}   {fa}")
        print(f"    branch B  {bc}   {fb}")
        print(f"    published (est. {pub_at:.1f}s, the two masters do not share a zero - if this is")
        print(f"              a different shot, step through nearby seconds)   {fp}")
        print(f"    The branch matching the PUBLISHED copy is the ORIGINAL; the other is the REMASTER.")
        print(f"    NOT scored: at these resolutions a matching shot and a mismatched one score alike.")
        result['verdict'] = 'look-at-frames'
        result['frames'] = {'a': fa, 'b': fb, 'published': fp, 'clipSeconds': mid, 'publishedEstimate': pub_at}

    if args.json_out:
        with open(args.json_out, 'w', encoding='utf-8') as fh:
            json.dump(result, fh, indent=2)
        print(f"\njson: {args.json_out}")


if __name__ == '__main__':
    main()
