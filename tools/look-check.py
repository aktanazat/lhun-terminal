#!/usr/bin/env python3
"""Checks a tools/look.sh run.

  python3 tools/look-check.py <probe.jsonl> <hooks.txt> <session>

- Every width tmux took for <session>, as its client-resized hook wrote it ("<epoch> <session> <control>
  <cols>x<rows>"), is a width Lhûn held on screen: a column count the probe reported for the session in
  samples a second or more apart with the screen unchanged between them. A terminal that resized while
  its card moved would send tmux widths from partway through, which the probe never sees held. Each one
  that was not is listed with the probe's events around it. Heights are only counted: the on-screen
  keyboard sends a few in a row each time it moves, as it did before this check.
- With Reduce Motion on, every card arrangement and peek happened without animating. Skipped when the
  run never turned Reduce Motion on.
"""
import json
import sys

samples = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
session = sys.argv[3]
failures = []

held = set()
previous = None
for sample in samples:
    if "grids" not in sample:
        continue
    pose = {grid["session"]: (grid["cols"], grid["rows"]) for grid in sample["grids"]}
    if previous and previous[1] == pose and sample["at"] - previous[0] >= 1 and session in pose:
        held.add(pose[session])
    if not previous or previous[1] != pose:
        previous = (sample["at"], pose)
widths = {cols for cols, _ in held}

sent = []
for line in open(sys.argv[2]):
    fields = line.split()
    # Lhûn's watcher, a control client, has no screen size.
    if len(fields) == 4 and fields[1] == session and fields[2] == "0":
        cols, rows = fields[3].split("x")
        sent.append((float(fields[0]), int(cols), int(rows)))
if not sent:
    failures.append("tmux recorded no sizes for the session")
unheld = [(at, cols, rows) for at, cols, rows in sent if cols not in widths]
passing = [size for size in sent if size[1] in widths and size[1:] not in held]
print(f"tmux took {len(sent)} sizes for {session}, {len({size[1:] for size in sent})} different; "
      f"{len(unheld)} with a width never held on screen; {len(passing)} with a height the keyboard passed through")
for at, cols, rows in unheld:
    near = [f"{sample['at'] - at:+.2f} {sample.get('event', 'tick')}" for sample in samples
            if -1.5 <= sample.get("at", 0) - at <= 0.5]
    print(f"  {cols}x{rows} at {at:.2f}: {', '.join(near)}")
if unheld:
    failures.append("tmux was sent widths Lhûn never held")

if any(sample.get("reduceMotion") for sample in samples):
    still = [sample for sample in samples
             if sample.get("reduceMotion") and sample.get("event") in ("arrange", "peek", "peek show")]
    moved = [sample for sample in still if sample.get("animated") is not False]
    kinds = sorted({sample["event"] for sample in still})
    print(f"with Reduce Motion on: {len(still)} arrangements and peeks ({', '.join(kinds)}), {len(moved)} animated")
    if "arrange" not in kinds or not {"peek", "peek show"} & set(kinds):
        failures.append("the log holds no arrangement or no peek with Reduce Motion on")
    if moved:
        failures.append("something animated with Reduce Motion on")
else:
    print("Reduce Motion was never on in this run")

if failures:
    sys.exit("; ".join(failures))
