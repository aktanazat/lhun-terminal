"""Prints what Lhûn cost in a tools/perf.sh run, in plain units, from the app's probe log and XCTest's
result bundle. A tools/probe.sh log works too, for its memory points alone. Given the runs of two builds,
it sets them side by side instead: the median of each side's runs, with each log's result bundle read
from beside it.

    python3 tools/perf-summary.py build/perf-<slug>.jsonl [build/perf-<slug>.xcresult]
    python3 tools/perf-summary.py <before>.jsonl... --against <after>.jsonl...

Each launch of the app starts a part of the log. The launch line names the scene a test measured
(`run`); the memory run and the typing run are told apart by what they log (a trip to the background,
timed keys). Memory points are medians of the samples at each point, so no one sample's swing moves
them. Rates come from the probe's 30-second windows, in which the probe takes no samples of its own:
the second window of each scene, as XCTest reports the second of its two runs.

Memory follows the size of the terminal's card, since Metal draws into buffers that size: held upright,
the card is taller and the same build reads about 14 MB more with three sessions open. Every point and
scene prints the card it was measured on, and a comparison stops with an error when two runs measured
one on different cards.
"""
import json
import math
import signal
import statistics
import subprocess
import sys
from pathlib import Path

# A reader that stops early, as `| head` does, ends the summary as it ends any Unix tool. Python would raise
# BrokenPipeError and exit 1, the status a comparison's refusal exits with, and under 2>&1 its traceback
# went into the same closed pipe, so a cut-off table looked like a refusal with no reason given.
signal.signal(signal.SIGPIPE, signal.SIG_DFL)

MB = 1024 * 1024
# iPad Pro 11-inch (4th generation): Apple's rating of its battery, for an energy estimate.
BATTERY_WH = 28.65
SCENES = [
    ("quiet", "testQuietSessions", "three sessions open, the one on screen quiet"),
    ("stream", "testOutputStream", "a session streaming a build log"),
    ("spinner", "testWorkingSpinner", "a session showing an agent at work, one status line redrawn 20 times a second"),
    ("scroll", "testScrollingHistory", "history scrolled back with fast swipes"),
]
HITCHES = ("Frame Count", "Frame Rate", "Hitch Time Ratio", "Number of Hitches", "Hitches Total Duration")


def load(path):
    """The log's samples, cut into one part per launch of the app."""
    samples = [json.loads(line) for line in open(path) if line.strip()]
    if not samples:
        sys.exit(f"{path}: the probe logged nothing; did the run reach the app?")
    parts = []
    for sample in samples:
        if sample.get("event") == "launch" or not parts:
            parts.append([])
        parts[-1].append(sample)
    return parts


def kind(part):
    run = part[0].get("run", "")
    if run:
        return run
    events = {sample.get("event") for sample in part}
    if "background" in events:
        return "memory"
    if "key" in events:
        return "typing"
    return "other"


def median(rows, key="footprint"):
    values = [row[key] for row in rows if key in row]
    return statistics.median(values) if values else None


def between(part, start, end):
    return [s for s in part if start <= s["t"] < end]


def first(part, predicate, start=0):
    return next((i for i in range(start, len(part)) if predicate(part[i])), None)


def mb(value):
    return "    -" if value is None else f"{value / MB:5.1f}"


def p95(values):
    ordered = sorted(values)
    return ordered[math.ceil(0.95 * len(ordered)) - 1]


def cards(rows):
    """The cards most of `rows` show while a terminal draws with Metal, each (width, height) in points, the
    focused one first. With no terminal on Metal, as in the background, no card sets what memory holds."""
    seen = [tuple(tuple(grid["card"]) for grid in sorted(row.get("grids", []), key=lambda grid: not grid.get("focused")))
            for row in rows if row.get("metal", 1) > 0]
    seen = [shown for shown in seen if shown]
    return statistics.mode(seen) if seen else None


def named(shown):
    return "no card" if shown is None else " + ".join(f"{width:.0f}x{height:.0f}" for width, height in shown)


def same(one, other):
    """Whether two points showed the same cards, to within 2 points either way."""
    if one is None or other is None:
        return one is other
    return len(one) == len(other) and all(
        abs(a - b) <= 2 for card, other_card in zip(one, other) for a, b in zip(card, other_card))


def metrics(bundle):
    """XCTest's measurements by test and metric name: the median of each, with its unit."""
    try:
        raw = subprocess.run(
            ["xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", bundle],
            capture_output=True, text=True, check=True,
        ).stdout
    except (subprocess.CalledProcessError, FileNotFoundError):
        return {}
    found = {}
    for test in json.loads(raw or "[]"):
        name = test["testIdentifier"].split("/")[-1].rstrip("()")
        for run in test.get("testRuns", []):
            for metric in run.get("metrics", []):
                if metric.get("measurements"):
                    found.setdefault(name, {})[metric["displayName"]] = (
                        statistics.median(metric["measurements"]), metric["unitOfMeasurement"])
    return found


class Run:
    """One run's log, cut into its parts, with XCTest's measurements from its result bundle."""

    def __init__(self, log, bundle=None):
        self.name = Path(log).stem
        self.parts = load(log)
        self.measured = metrics(bundle) if bundle else {}

    def part(self, name):
        return next((part for part in self.parts if kind(part) == name), None)

    def warm_launches(self):
        return [s["sinceExec"] for part in self.parts if kind(part) == "launch"
                for s in part[:3] if s.get("event") == "active" and "sinceExec" in s]

    def readable_launches(self):
        """Each cold launch with a session open: the milliseconds from the process starting to the first frame
        that shows the session with text, and to the first that shows tmux's own redraw of it. The first
        launch of the scene opens the session from its pill and is left out."""
        pick = lambda part, event: next((s["sinceExec"] for s in part if s.get("event") == event), None)
        return [(pick(part, "readable"), pick(part, "current"))
                for part in [part for part in self.parts if kind(part) == "readable"][1:]]

    def memory(self):
        """The memory run's points, each with the samples taken at it, and where its idle stretch and its
        stress burst ran. As tools/probe-summary.py finds them: the stress burst is the unbroken run of
        samples with output around the biggest jump in output before the background, and the idle stretch
        the longest one between 5 seconds after the first session opened and the burst in which nothing
        arrived and nothing happened on the device (the keyboard coming up for the stress command resizes
        the card), counted from the sample after its first. tmux repaints every attached client whenever a
        pane on its server sets an option, so on a Mac where agents work, output reaches an idle session now
        and then, and the first output after the idle start need not be the burst."""
        memory = self.part("memory")
        if not memory:
            return None
        opened = [i for i, s in enumerate(memory) if s.get("event", "").startswith("open ")]
        background = first(memory, lambda s: s.get("event") == "background")
        active = first(memory, lambda s: s.get("event") == "active", background)
        t = lambda i: memory[i]["t"]
        fed = lambda i: memory[i]["bytesFed"]
        idle_from = first(memory, lambda s: s["t"] >= t(opened[0]) + 5, opened[0])
        stress = max(range(idle_from + 1, background), key=lambda i: fed(i) - fed(i - 1))
        while stress - 1 > idle_from and fed(stress - 1) > fed(stress - 2):
            stress -= 1
        stretches = []
        for start in range(idle_from, stress - 1):
            end = start
            while end + 1 < stress and "event" not in memory[end + 1] and fed(end + 1) == fed(start):
                end += 1
            if end > start:
                stretches.append((t(end) - t(start + 1), start + 1, end))
        _, still_from, still_to = max(stretches, default=(0, idle_from, idle_from))
        quiet = stress
        while quiet + 3 < background and len({fed(j) for j in range(quiet, quiet + 4)}) > 1:
            quiet += 1
        return {
            "samples": memory, "idle": (still_from, still_to), "burst": (stress - 1, quiet),
            "points": [
                ("launch, nothing open", between(memory, 5, t(opened[0]))),
                ("one session idle", memory[idle_from:stress]),
                ("after the stress burst", memory[quiet:background]),
                ("10 s in the background", between(memory, t(background) + 8, t(background) + 12)),
                ("one open, back again", between(memory, t(active) + 2, t(opened[1]))),
                ("three sessions open", between(memory, t(opened[2]) + 5, memory[-1]["t"] + 1)),
            ],
        }

    def places(self):
        """Each memory point and measured scene, with the cards it was measured on."""
        found = {}
        memory = self.memory()
        for name, rows in memory["points"] if memory else []:
            found[f"memory: {name}"] = cards(rows)
        for scene, _, _ in SCENES + [("typing", None, None)]:
            part = self.part(scene)
            if part:
                found[scene] = cards(part)
        return found

    def numbers(self):
        """The numbers a comparison sets side by side, by row, each in the unit its row names."""
        found = {}
        warm = self.warm_launches()
        if warm:
            found["launch, process start to active (ms)"] = statistics.median(warm)
        for name, (value, unit) in self.measured.get("testLaunch", {}).items():
            if unit == "s":
                found[f"launch, XCTest {name} (ms)"] = value * 1000
        readable = self.readable_launches()
        for index, label in [(0, "launch to a readable session (ms)"), (1, "launch to tmux's redraw on screen (ms)")]:
            values = [launch[index] for launch in readable if launch[index] is not None]
            if values:
                found[label] = statistics.median(values)
        memory = self.memory()
        if memory:
            for name, rows in memory["points"]:
                for key, label in [("footprint", "memory"), ("heap", "heap"), ("graphics", "graphics memory")]:
                    if median(rows, key) is not None:
                        found[f"{label}, {name} (MB)"] = median(rows, key) / MB
            samples, (start, end) = memory["samples"], memory["idle"]
            found["frames drawn by one idle session while nothing arrived, 10 s (frames)"] = (
                (samples[end]["frames"] - samples[start]["frames"]) * 10 / max(samples[end]["t"] - samples[start]["t"], 1))
        for scene, test, _ in SCENES:
            part = self.part(scene)
            found_window = window(part) if part else None
            if found_window:
                opened, closed, seconds = found_window
                spent = lambda key: closed.get(key, 0) - opened.get(key, 0)
                if "cpuMs" in closed:
                    found[f"{scene}: CPU (% of one core)"] = spent("cpuMs") / seconds / 10
                    found[f"{scene}: CPU energy (mW)"] = spent("energyMj") / seconds
                    found[f"{scene}: wakeups (a minute)"] = spent("wakeups") * 60 / seconds
                found[f"{scene}: terminal frames (a second)"] = spent("frames") / seconds
            for metric, (value, unit) in self.measured.get(test, {}).items():
                if metric.startswith(HITCHES):
                    found[f"{scene}: XCTest {metric} ({unit})"] = value
        typing = self.part("typing")
        if typing:
            totals = key_totals(typing)
            found["typing, key down to echo on screen, median (ms)"] = statistics.median(totals)
            found["typing, key down to echo on screen, p95 (ms)"] = p95(totals)
        return found


def window(part):
    """The last window the probe logged in a part: its two samples and the seconds between."""
    ends = [i for i, s in enumerate(part) if s.get("event") == "window end"]
    if not ends:
        return None
    end = ends[-1]
    start = max(i for i in range(end) if part[i].get("event") == "window")
    return part[start], part[end], part[end]["t"] - part[start]["t"]


def key_totals(typing):
    return [sum(key[p] for p in ["delivered", "texted", "handled", "network", "queued", "drawn"])
            for key in typing if key.get("event") == "key"]


def report(run):
    print("launch, process start to active")
    cold = next((s["sinceExec"] for s in run.parts[0] if s.get("event") == "active" and "sinceExec" in s), None)
    warm = run.warm_launches()
    # The first launch of a run follows the install, so nothing of Lhûn is cached yet.
    if cold is not None:
        print(f"  first after install   {cold:6.0f} ms")
    if warm:
        print(f"  again, median of {len(warm)}   {statistics.median(warm):6.0f} ms")
    for name, (value, unit) in run.measured.get("testLaunch", {}).items():
        print(f"  XCTest {name}: {value * 1000 if unit == 's' else value:.0f} {'ms' if unit == 's' else unit}")
    readable = run.readable_launches()
    if readable:
        shown = lambda value: "never" if value is None else f"{value:.0f} ms"
        print("\nlaunch with a session open, from the process starting")
        for number, (text, redraw) in enumerate(readable, 1):
            print(f"  launch {number}: readable {shown(text)}, tmux's redraw on screen {shown(redraw)}")

    memory = run.memory()
    if memory:
        samples, points = memory["samples"], memory["points"]
        print("\nmemory, MB (median of the samples at each point)   footprint   heap  graphics  samples  card, points")
        for name, rows in points:
            print(f"  {name:<46} {mb(median(rows))}  {mb(median(rows, 'heap'))}    {mb(median(rows, 'graphics'))}  "
                  f"{len(rows):4d}     {named(cards(rows))}")
        one, three = median(points[4][1]), median(points[5][1])
        if one is not None and three is not None:
            print(f"  each extra session: {(three - one) / 2 / MB:.1f} MB, with the card on screen "
                  f"{named(cards(points[4][1]))} for one and {named(cards(points[5][1]))} for three")
        start, end = memory["burst"]
        print(f"  the stress burst: {(samples[end]['bytesFed'] - samples[start]['bytesFed']) / 1024:.0f} KB reached the "
              f"device in {samples[end]['t'] - samples[start]['t']:.0f} s")
        peak = samples[-1].get("peak")
        if peak:
            print(f"  the most the footprint reached: {mb(peak).strip()} MB")
        built = samples[-1]
        if "rendererMetal" in built:
            print(f"  building a terminal's renderer took {mb(built['rendererMetal']).strip()} MB of Metal memory"
                  f" and {mb(built['rendererHeap']).strip()} MB of heap")

    for scene, test, title in SCENES:
        part = run.part(scene)
        if not part:
            continue
        found = window(part)
        if found:
            opened, closed, seconds = found
            spent = lambda key: closed.get(key, 0) - opened.get(key, 0)
            per_minute = lambda key: spent(key) * 60 / seconds
            print(f"\n{title}, over {seconds:.0f} s, on a {named(cards(part))} card")
            if "cpuMs" in closed:
                print(f"  CPU {spent('cpuMs') / seconds / 10:5.1f}% of one core   ({per_minute('cpuMs') / 1000:.2f} CPU seconds "
                      f"a minute, {per_minute('instructions') / 1e6:.0f} million instructions a minute)")
                print(f"  wakeups {per_minute('wakeups'):.0f} a minute, {per_minute('idleWakeups'):.0f} of them out of idle")
                milliwatts = spent("energyMj") / seconds
                print(f"  CPU energy {milliwatts:.1f} mW by the kernel's estimate: {milliwatts / 10 / BATTERY_WH:.2f}% of a "
                      f"full charge an hour [estimate; the screen's own power not included]")
                print(f"  GPU {per_minute('gpuMs') / 1000:.2f} s a minute")
            print(f"  terminal frames {spent('frames') / seconds:.1f} a second; output {spent('bytesFed') / seconds / 1024:.1f} "
                  f"KB a second")
            if spent("bytesFed") > 0 and "cpuMs" in closed:
                print(f"  {spent('cpuMs') / (spent('bytesFed') / MB):.0f} ms of CPU per MB of output")
            print(f"  footprint {mb(closed['footprint']).strip()} MB at the end"
                  + (f", heap {mb(closed.get('heap')).strip()} MB, graphics {mb(closed.get('graphics')).strip()} MB"
                     if "heap" in closed else ""))
        if scene == "stream":
            fed = [s for s in part if s.get("event") is None]
            done = first(fed, lambda s: s["bytesFed"] == fed[-1]["bytesFed"])
            if done is not None:
                print(f"  after the stream: {fed[done]['bytesFed'] / MB:.2f} MB reached the device; footprint "
                      f"{mb(median(fed[done:])).strip()} MB, the most it reached {mb(fed[-1].get('peak')).strip()} MB")
        for metric, (value, unit) in sorted(run.measured.get(test, {}).items()):
            if metric.startswith(HITCHES + ("CPU Time", "CPU Instructions Retired")):
                print(f"  XCTest {metric}: {value:g} {unit}")

    typing = run.part("typing")
    if typing:
        totals = key_totals(typing)
        screen = [key["queued"] + key["drawn"] for key in typing if key.get("event") == "key"]
        print(f"\ntyping, {len(totals)} keys, key down to the echo on screen, on a {named(cards(typing))} card")
        print(f"  median {statistics.median(totals):.0f} ms, p95 {p95(totals):.0f} ms; "
              f"echo to screen median {statistics.median(screen):.0f} ms, p95 {p95(screen):.0f} ms")


def compare(before, after):
    """Sets the runs of two builds side by side, once every run measured each point on the same cards."""
    runs = [(side, run) for side, runs in [("before", before), ("after", after)] for run in runs]
    places = [(side, run, run.places()) for side, run in runs]
    differ = []
    for place in dict.fromkeys(name for _, _, found in places for name in found):
        measured = [(side, run, found[place]) for side, run, found in places if place in found]
        if any(not same(measured[0][2], shown) for _, _, shown in measured[1:]):
            differ.append(f"  {place}: " + ", ".join(f"{side} {run.name} {named(shown)}" for side, run, shown in measured))
    if differ:
        sys.exit("perf-summary: these were measured on different cards, and memory and drawing follow the card's size, "
                 "so they do not compare. Run every build in the same orientation (LhunProbe holds the iPad in "
                 "landscape) and with the same keyboard state.\n" + "\n".join(differ))

    numbers = [(side, run.numbers()) for side, run in runs]
    print(f"before: {', '.join(run.name for run in before)}\nafter:  {', '.join(run.name for run in after)}")
    print(f"{'':<64} {'before':>23} {'after':>23} {'change':>8}")
    for row in dict.fromkeys(row for _, found in numbers for row in found):
        sides = [[found[row] for named_side, found in numbers if named_side == side and row in found]
                 for side in ("before", "after")]
        shown = [f"{statistics.median(values):.1f} ({min(values):.1f}-{max(values):.1f})" if values else "-"
                 for values in sides]
        change = f"{statistics.median(sides[1]) - statistics.median(sides[0]):+8.1f}" if all(sides) else ""
        print(f"{row:<64} {shown[0]:>23} {shown[1]:>23} {change}")


def bundle_beside(log):
    bundle = Path(log).with_suffix(".xcresult")
    return str(bundle) if bundle.exists() else None


if "--against" in sys.argv:
    split = sys.argv.index("--against")
    before, after = sys.argv[1:split], sys.argv[split + 1:]
    if not before or not after:
        sys.exit("usage: perf-summary.py <before>.jsonl... --against <after>.jsonl...")
    compare([Run(log, bundle_beside(log)) for log in before], [Run(log, bundle_beside(log)) for log in after])
else:
    report(Run(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None))
