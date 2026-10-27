"""Lines up the probe log of a tools/fit.sh run with its record of tmux's clients.

For each pose the app held still, it prints every terminal on screen with its grid, whether it fits its
card, and the sizes tmux's clients of that session reported. A pose is a run of two or more probe samples
with the same grids, and every terminal in it fits its card. tmux is read at the run's last sample, and
one of the session's clients has the terminal's size there once the pose has lasted HELD seconds: tmux
shows a size the app sent about half a second later, so a briefer pose, such as one the keyboard passes
through as it comes up, can be gone before tmux catches up, and its sizes are only shown.
A terminal the probe reports as keeping its grid ("held": the cards are moving, or the keyboard is away
with the palette, a picker or the inbox) fits once they rest, so it need not fit its card meanwhile; tmux
still has to have its size.
Exits 1 when a terminal does not fit and keeps no grid, or no client of its session has its size after a
pose of HELD seconds or more.

A terminal that shows a window another screen sizes (the probe's "window") is checked against that
screen instead: tmux keeps the window at the size of a client that sets sizes, so one such client must
have the window's size. A record line may end with the client's flags; a client flagged ignore-size or
control-mode sets no size. Without flags every client counts.

    python3 tools/fit-check.py build/fit-<label>.jsonl build/fit-<label>.tmux
"""
import json
import sys

HELD = 1.0

samples = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]

polls = []  # (wall-clock time, {session: {("<cols>x<rows>", sets the size), ...}})
for line in open(sys.argv[2]):
    fields = line.rstrip("\n").split("\t")
    if fields[0]:
        polls.append((float(fields[0]), {}))
    elif polls and len(fields) >= 3:
        flags = fields[4].split(",") if len(fields) >= 5 else []
        sets_size = "ignore-size" not in flags and "control-mode" not in flags
        polls[-1][1].setdefault(fields[1], set()).add((fields[2], sets_size))

poses, run = [], []
for sample in samples:
    if run and sample.get("grids") == run[-1].get("grids"):
        run.append(sample)
        continue
    if len(run) >= 2 and run[0].get("grids"):
        poses.append(run)
    run = [sample]
if len(run) >= 2 and run[0].get("grids"):
    poses.append(run)

failures = 0
for run in poses:
    last = run[-1]
    lasted = last["at"] - run[0]["at"] >= HELD
    clients = next((sizes for stamp, sizes in reversed(polls) if stamp <= last["at"]), None)
    for grid in last["grids"]:
        size = f"{grid['cols']}x{grid['rows']}"
        listed = (clients or {}).get(grid["session"], set())
        sent = sorted({client_size for client_size, _ in listed})
        window = grid.get("window")
        if window:
            matches = (window, True) in listed
            shown = f"{size} of {window}"
        else:
            matches = size in sent
            shown = size
        fits = grid["fit"] == "ok"
        if not fits and not grid.get("held"):
            verdict = "FAIL"
        elif not matches:
            verdict = "FAIL" if lasted else "passing through"
        else:
            verdict = "ok" if fits else "held"
        failures += verdict == "FAIL"
        print(
            f"t {run[0]['t']:6.1f}-{last['t']:6.1f}  session {grid['session']}  {shown}  font {grid['font']:g}  "
            f"card {grid['card'][0]:g}x{grid['card'][1]:g}  view {grid['view']}  fit: {grid['fit']}  "
            f"tmux: {', '.join(sent) if sent else 'no client' if clients is not None else 'no record'}  {verdict}"
        )
print(f"{len(poses)} poses, {failures} failing")
sys.exit(1 if failures or not poses else 0)
