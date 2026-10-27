"""Prints the motion traces in tools/motion.sh logs, one line each, in the order they ran: the scene the
test launched (its `run`), the display frames traced and those the main thread missed, reversals, snaps,
grids taken after each terminal's first, how many frames each terminal's bottom set off and stopped after
the visible key row (or the announced keyboard without it), each terminal's grids in order, and the duration and curve UIKit gave each keyboard move.
Given several logs, the same scene's traces from each are printed one under another.

    python3 tools/motion-summary.py build/motion-<slug>.jsonl...
    python3 tools/motion-summary.py --frames <scene> <n> build/motion-<slug>.jsonl

--frames prints the n-th trace of a scene frame by frame: every part's position, in points, at each frame.
"""
import json
import sys
from collections import defaultdict


def traces(path):
    """Each trace in the log as (scene, summary, frames), in the order they ran."""
    run = ""
    found = []
    for line in open(path):
        if not line.strip():
            continue
        sample = json.loads(line)
        if sample.get("event") == "launch":
            run = sample.get("run", "")
        elif sample.get("event") == "motion trace":
            found.append((run, sample.get("lastMotion", {}), sample.get("motionFrames", {})))
    return found


def move(m):
    """One keyboard move: the frame UIKit told of it, its duration and curve, and the keyboard top's ends.
    Logs from before 2026-10-12 kept the duration and curve alone."""
    if len(m) == 2:
        return f"{m[0]}s curve {int(m[1])}"
    frame, duration, curve, start, end = m
    return f"f{int(frame)} {duration}s curve {int(curve)} {int(start)}>{int(end)}"


def line(summary):
    lag = " ".join(f"{name} {v['start']:+d}/{v['end']:+d}" for name, v in sorted(summary.get("keyboardLag", {}).items()))
    grids = " ".join(f"{name} {'>'.join(g)}" for name, g in sorted(summary.get("grids", {}).items()))
    reference = summary.get("keyboardReference", "keyboard")
    keyboard = summary.get("moved", {}).get(reference)
    timings = ", ".join(move(m) for m in summary.get("keyboardMoves", []))
    return (
        f"frames {summary.get('frames', 0):4d}  dropped {summary.get('dropped', 0):3d}  "
        f"reversals {summary.get('reversals', 0):2d}  snaps {summary.get('snaps', 0):2d}  "
        f"regrids {summary.get('regrids', 0):2d}  keyboard ({reference}) {'moved ' + str(keyboard['travel']) + ' pt' if keyboard else 'still'}"
        + (f"  lag {lag}" if lag else "")
        + (f"  grids {grids}" if grids else "")
        + (f"  moves {timings}" if timings else "")
    )


def moves(summary):
    """The parts that went back or jumped, with how."""
    bad = []
    for part, move in sorted(summary.get("moved", {}).items()):
        if move.get("reversals") or move.get("snaps"):
            bad.append(f"{part}: {move['travel']} pt, {move['reversals']} back, {move['snaps']} jumps, frames {move.get('first')}-{move.get('last')}")
    return bad


def main(args):
    if args[:1] == ["--frames"]:
        scene, n, paths = args[1], int(args[2]), args[3:]
        for path in paths:
            matching = [frames for run, _, frames in traces(path) if run == scene]
            if len(matching) < n:
                sys.exit(f"{path}: {scene} has {len(matching)} traces")
            frames = matching[n - 1]
            parts = sorted(frames.get("parts", {}))
            print("frame " + "  ".join(parts))
            for tick, frame in enumerate(frames.get("frameAt", [])):
                values = [frames["parts"][part][tick] for part in parts]
                print(f"{frame:5d} " + "  ".join("-" if v is None else f"{v:.1f}" for v in values))
        return
    if not args:
        sys.exit(__doc__)
    by_scene = defaultdict(lambda: defaultdict(list))
    order = []
    for path in args:
        for run, summary, _ in traces(path):
            if run not in order:
                order.append(run)
            by_scene[run][path].append(summary)
    for run in order:
        print(run)
        for path in args:
            for n, summary in enumerate(by_scene[run][path], 1):
                prefix = f"  {n}" + (f" {path}" if len(args) > 1 else "")
                print(f"{prefix}  {line(summary)}")
                for bad in moves(summary):
                    print(f"      {bad}")


main(sys.argv[1:])
