"""Lines up the probe log of a tools/peek.sh run with its record of tmux's clients, and with the pictures
the run took of the device's screen.

For each time the peek was out, from the app's "peek" event to its "peek closed", it checks that the
session on screen kept the size it had as the peek opened: in the app's own count of the sizes it sent
tmux, which must not move, in the app's own samples, and in every size tmux's clients of that session
reported from half a second after the peek opened (tmux takes that long to show a size the app sent)
until it closed. The card keeps its height while the peek is out, whatever the keyboard does. For a
second from half a second after the peek closed, and not once it opened again, tmux's sizes count only
while the on-screen keyboard sits where it sat before the peek opened, and not within SETTLE seconds of
a move of it after the close: every key XCTest sends hides the keyboard for a moment, and the terminal
follows it then. They must be the size the session had in the app's last sample before the opening that
showed it on screen with the keyboard settled there: the card is home and the keyboard where it was. That
is not the size the card kept while out when the key that opened the peek moved the keyboard too. A
session the peek took off the screen keeps the size it had.

It checks the keyboard too, against where it sat before the peek opened: the app's last sample before
then that shows the keyboard where it had rested for SETTLE seconds by the opening, not within BACK
seconds of an earlier peek beginning to close (the keyboard is on its way back then). When a peek opens
again that soon, the keyboard is where it sat before the earlier one.
A keyboard that was down sat as low as the keyboard had gone in that launch before the peek began to
close. From SETTLE seconds after the peek opened until it began to close, every sample has a keyboard
that was up lower on the screen than it sat, and one that was down still down: the keyboard and its key
row step aside for the peek. Within BACK seconds of the peek beginning to close, the keyboard comes back
where it sat: a keyboard that was up shows there at least once, one that was down stays down throughout.
Neither need hold when the peek opened again sooner, or when XCTest typed a key as it closed: iOS takes
typed keys for a hardware keyboard's, and moves the on-screen keyboard as it would for one. Then the
app's memory footprint as the peek opened, at its largest while open, and three seconds after it closed,
or just before it opened again when that came sooner, and at the end of the run.

Given the record of the pictures (shots.tsv: each picture's name, and when its capture began and when it
ended), it checks that each picture whose name holds the word "pulling", "row", "grid" or "closed" caught
the peek in that state, settled for SETTLED seconds before the capture began and unchanged until it
ended. Exits 1 when a check fails, when no tmux size could be compared, or when the peek never opened.

    python3 tools/peek-check.py build/peek-<label>.jsonl build/peek-<label>.tmux [<shots>/shots.tsv]
"""
import bisect
import json
import sys

SETTLE = 1.5  # seconds the app and tmux take to follow a move of the keyboard
BACK = 2.5  # seconds after the peek began to close by which the keyboard is back where it was
SETTLED = 0.6  # seconds the card takes to come to rest after the peek moves
LAG = 0.5  # seconds tmux takes to show a size the app sent

samples = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
stamps = [sample["at"] for sample in samples]
moves = [sample["at"] for sample in samples if sample.get("event") == "keyboard"]


def lowest_before(stamp):
    """The lowest the keyboard's top went on the screen in the launch of `stamp`, before then."""
    return max(
        (
            sample["keyboard"] for sample in samples
            if "keyboard" in sample and sample["at"] < stamp and launch_of(sample["at"]) == launch_of(stamp)
        ),
        default=None,
    )


polls = []  # (wall-clock time, {session: {"<cols>x<rows>", ...}})
for line in open(sys.argv[2]):
    fields = line.rstrip("\n").split("\t")
    if fields[0]:
        polls.append((float(fields[0]), {}))
    elif polls and len(fields) >= 3:
        polls[-1][1].setdefault(fields[1], set()).add(fields[2])


def megabytes(sample):
    return f"{sample['footprint'] / 1048576:.1f} MB"


def size(grid):
    return f"{grid['cols']}x{grid['rows']}"


def keyboard_at(stamp):
    """Where the keyboard's top was at `stamp`, by the app's last sample before then."""
    index = bisect.bisect_right(stamps, stamp) - 1
    return samples[index].get("keyboard") if index >= 0 else None


def last_move(stamp):
    """When the keyboard last moved at or before `stamp`, if it did."""
    index = bisect.bisect_right(moves, stamp) - 1
    return moves[index] if index >= 0 else None


def rested(stamp, until):
    """Whether the keyboard, where it sat at `stamp`, stayed there for more than SETTLE seconds after the
    move that put it there, by `until`: a place it rested in, not one it passed through."""
    moved = last_move(stamp)
    if moved is None:
        return True
    index = bisect.bisect_right(moves, moved)
    left = moves[index] if index < len(moves) else float("inf")
    return min(left, until) - moved > SETTLE


def launch_of(stamp):
    """Which launch of the app `stamp` falls in: the log runs on across launches."""
    return bisect.bisect_right(launches, stamp)


def state_at(stamp):
    """The peek's state at `stamp`, and since when: "pulling" from a pull's first move until the finger
    lets go, "closing" while the card slides home, otherwise where the peek rests."""
    state, since = "closed", None
    for sample in samples[:bisect.bisect_right(stamps, stamp)]:
        event = sample.get("event")
        if event == "launch" or event == "peek closed":
            state, since = "closed", sample["at"]
        elif event == "peek":
            state, since = sample.get("state", "pulling"), sample["at"]
        elif event == "peek show":
            state, since = "closing" if sample["state"] == "closed" else sample["state"], sample["at"]
    return state, since


windows, opened, closing = [], None, None  # (opened, began to close, closed), indices into samples
for index, sample in enumerate(samples):
    event = sample.get("event")
    if event == "peek":
        opened, closing = index, None
    elif event == "peek show" and sample["state"] == "closed" and opened is not None:
        closing = index
    elif event == "peek closed" and opened is not None:
        windows.append((opened, index if closing is None else closing, index))
        opened = closing = None
inside = [False] * len(samples)
for start, _, end in windows:
    inside[start:end + 1] = [True] * (end + 1 - start)
launches = [sample["at"] for sample in samples if sample.get("event") == "launch"]
typed = [sample["at"] for sample in samples if sample.get("event") in ("key", "peek key")]


def keyboard_before(number):
    """Where the keyboard's top sat before window `number` opened; None when no keyboard was seen."""
    start = windows[number][0]
    first = samples[start]
    previous = windows[number - 1] if number and launch_of(samples[windows[number - 1][0]]["at"]) == launch_of(first["at"]) else None
    floor = samples[previous[1]]["at"] + BACK if previous else float("-inf")
    for index in range(start - 1, -1, -1):
        sample = samples[index]
        if sample["at"] < floor or launch_of(sample["at"]) != launch_of(first["at"]):
            break
        if not inside[index] and rested(sample["at"], first["at"]):
            return sample.get("keyboard")
    return references[number - 1] if previous else first.get("keyboard")


def home_size(number, session, keyboard):
    """The size `session` comes home at after window `number` with the keyboard back at `keyboard`: its size
    in the app's last sample by the opening, in no earlier peek, that showed it on screen with the keyboard
    there and still for SETTLE seconds. None when no sample did."""
    start = windows[number][0]
    launch = launch_of(samples[start]["at"])
    for index in range(start, -1, -1):
        sample = samples[index]
        if launch_of(sample["at"]) != launch:
            break
        grids = sample.get("grids") or []
        if (index == start or not inside[index]) and grids and grids[0]["session"] == session and sample.get("keyboard") == keyboard:
            moved = last_move(sample["at"])
            if moved is None or sample["at"] - moved > SETTLE:
                return size(grids[0])
    return None


failures = compared = sent_while_out = 0
references = []
for number, (start, closing, end) in enumerate(windows):
    first, close, last = samples[start], samples[closing], samples[end]
    keyboard = keyboard_before(number)
    references.append(keyboard)
    grids = first.get("grids") or []
    if not grids:
        failures += 1
        print(f"t {first['t']:6.1f}: no session on screen as the peek opened  FAIL")
        continue
    session, expected = grids[0]["session"], size(grids[0])
    following = samples[windows[number + 1][0]]["at"] if number + 1 < len(windows) else float("inf")

    on_screen = [
        sample["grids"][0] for sample in samples[start:end + 1]
        if sample.get("grids") and sample["grids"][0]["session"] == session
    ]
    app = {size(grid) for grid in on_screen}
    sent = on_screen[-1]["resizes"] - on_screen[0]["resizes"]
    sent_while_out += sent
    home_grids = last.get("grids") or []
    home = home_size(number, session, keyboard) if home_grids and home_grids[0]["session"] == session else expected
    seen, settled, used, skipped = set(), set(), 0, 0
    for stamp, sizes in polls:
        if first["at"] + LAG <= stamp <= last["at"]:
            seen |= sizes.get(session, set())
            used += 1
        elif last["at"] + LAG <= stamp <= min(last["at"] + LAG + 1, following):
            # The card keeps its height until the peek has closed, so only a move after then can resize it.
            moved = last_move(stamp)
            if home is not None and keyboard_at(stamp) == keyboard and (moved is None or moved <= last["at"] or stamp - moved > SETTLE):
                settled |= sizes.get(session, set())
                used += 1
            else:
                skipped += 1
    compared += used
    kept = sent == 0 and app <= {expected} and seen <= {expected} and settled <= {home} and (used == 0 or seen or settled)

    aside = {
        sample["keyboard"] for sample in samples[start:closing + 1]
        if "keyboard" in sample and sample["at"] >= first["at"] + SETTLE
    }
    down = keyboard is not None and keyboard >= lowest_before(close["at"])
    stepped = keyboard is None or all(top >= keyboard if down else top > keyboard for top in aside)
    until = min(close["at"] + BACK, following)
    readings = [
        (sample["at"], sample["keyboard"]) for sample in samples[closing:bisect.bisect_left(stamps, until)]
        if "keyboard" in sample
    ]
    if keyboard is None:
        back, back_text = True, "no keyboard seen"
    elif down:
        back = all(top >= keyboard for _, top in readings)
        back_text = f"{', '.join(sorted({f'{top:g}' for _, top in readings}))} until {until - close['at']:.1f} s after it began to close"
    else:
        returned = next((stamp for stamp, top in readings if top == keyboard), None)
        back = returned is not None
        back_text = f"back {returned - close['at']:.1f} s after it began to close" if back else f"not back {BACK} s after it began to close"
    if not back and following < close["at"] + BACK:
        back, back_text = True, f"{back_text}, but the peek opened again first"
    elif not back and any(close["at"] - 1 <= stamp < close["at"] + BACK for stamp in typed):
        back, back_text = True, f"{back_text}, but a key was typed as it closed"

    verdict = "ok" if kept and stepped and back else "FAIL"
    failures += verdict != "ok"
    shown = [
        sample["state"] for sample in samples[start:end + 1]
        if sample.get("event") in ("peek", "peek show") and "state" in sample
    ]
    largest = max(samples[start:end + 1], key=lambda sample: sample["footprint"])
    after = [
        sample for sample in samples[end:windows[number + 1][0] if number + 1 < len(windows) else len(samples)]
        if launch_of(sample["at"]) == launch_of(last["at"])
    ]
    later = next((sample for sample in after if sample["at"] >= last["at"] + 3), after[-1])
    print(
        f"t {first['t']:6.1f}-{last['t']:6.1f}  {session}  shows {', '.join(shown) or 'nothing'}  "
        f"kept {expected}: {sent} sizes sent tmux, app {', '.join(sorted(app))}, tmux {', '.join(sorted(seen)) or 'no client'}; "
        f"home {home or 'unknown'}: tmux {', '.join(sorted(settled)) or 'none'}; {used} polls, "
        f"{skipped} after the close skipped while the keyboard moved  "
        f"keyboard {keyboard} before, {', '.join(f'{top:g}' for top in sorted(aside)) or 'no sample'} while out, "
        f"{back_text}  {verdict}  footprint {megabytes(first)} at open, {megabytes(largest)} at most, "
        f"{megabytes(later)} {later['at'] - last['at']:.1f} s after close"
    )
if samples:
    print(f"footprint at the end, t {samples[-1]['t']:.1f}: {megabytes(samples[-1])}")
print(f"{len(windows)} peeks, {failures} failing, {sent_while_out} sizes sent tmux while out, {compared} tmux polls compared")

pictures = 0
if len(sys.argv) > 3:
    for line in open(sys.argv[3]):
        name, began, ended = line.rstrip("\n").split("\t")
        began, ended = float(began), float(ended)
        state, since = state_at(began)
        later, changed = state_at(ended)
        wanted = next((word for word in ("pulling", "row", "grid", "closed") if word in name.split("-")), None)
        rested = since is None or began - since >= SETTLED or state == "pulling"
        verdict = "ok" if wanted is None or (state == wanted and rested and (later, changed) == (state, since)) else "FAIL"
        pictures += verdict != "ok"
        held = "" if since is None else f" for {began - since:.1f} s"
        print(
            f"picture {name}: the peek {state}{held} as its capture began, {later} as it ended "
            f"{ended - began:.1f} s later, keyboard at {keyboard_at(began)}  {verdict}"
        )
    print(f"{pictures} pictures failing")
sys.exit(1 if failures or pictures or not windows or not compared else 0)
