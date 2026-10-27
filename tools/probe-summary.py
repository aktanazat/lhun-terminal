"""Reads a probe log from tools/probe.sh and prints the numbers at each measurement point, with the card
each was measured on: memory follows the card's size, so a footprint compares only with one taken on the
same card (tools/perf-summary.py --against checks).

Samples come about every second. The stress burst is the unbroken run of samples with output around the
biggest jump in output before the app goes to the background, and ends once nothing has arrived for
three samples in a row. The idle row is the longest stretch, from 5 seconds after the first session
opens until the stress burst, in which nothing arrived and nothing happened on the device (the keyboard
coming up for the stress command resizes the card), counted from the sample after its first: tmux
repaints every attached client whenever a pane on its server sets an option, so on a Mac where agents
work, output reaches an idle session now and then (LhunShots/LhunProbe.swift).
"""
import json
import sys

samples = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
MB = 1024 * 1024


def at(predicate, start=0):
    return next(i for i in range(start, len(samples)) if predicate(samples[i]))


def card(sample):
    """The cards on screen, the focused one first, while a terminal draws with Metal."""
    grids = sorted(sample.get("grids", []), key=lambda grid: not grid.get("focused"))
    shown = " + ".join(f"{width:.0f}x{height:.0f}" for width, height in (grid["card"] for grid in grids))
    return shown if shown and sample.get("metal", 1) > 0 else "no card"


opened = [i for i, s in enumerate(samples) if s.get("event", "").startswith("open ")]
background = at(lambda s: s.get("event") == "background")
active_again = at(lambda s: s.get("event") == "active", background)
launch = samples[at(lambda s: s["t"] >= 5)]

idle_from = at(lambda s: s["t"] >= samples[opened[0]]["t"] + 5, opened[0])


def growth(i):
    return samples[i]["bytesFed"] - samples[i - 1]["bytesFed"]


stress_from = max(range(idle_from + 1, background), key=growth)
while stress_from - 1 > idle_from and growth(stress_from - 1) > 0:
    stress_from -= 1
quiet_stretches = []
for first in range(idle_from, stress_from - 1):
    last = first
    while (last + 1 < stress_from and "event" not in samples[last + 1]
           and samples[last + 1]["bytesFed"] == samples[first]["bytesFed"]):
        last += 1
    if last > first:
        quiet_stretches.append((samples[last]["t"] - samples[first + 1]["t"], first + 1, last))
idle_seconds, idle_start, idle_end = max(quiet_stretches, default=(0, idle_from, idle_from))
quiet = at(lambda s: True, stress_from)
while quiet + 3 < background and len({samples[j]["bytesFed"] for j in range(quiet, quiet + 4)}) > 1:
    quiet += 1
away = samples[at(lambda s: s["t"] >= samples[background]["t"] + 10, background)]
assert away["t"] < samples[active_again]["t"], "the app came back before 10 s in the background"
one_open = samples[opened[1] - 1]
last = samples[-1]

idle, burst, done = samples[idle_start], samples[stress_from - 1], samples[quiet]
rows = [
    ("launch, nothing open", launch, ""),
    ("one session idle", samples[idle_end],
     f"{samples[idle_end]['frames'] - idle['frames']} frames in {idle_seconds:.0f} s with nothing arriving"),
    ("after the stress burst", done,
     f"{(done['bytesFed'] - burst['bytesFed']) / 1024:.0f} KB reached the device in {done['t'] - burst['t']:.0f} s; "
     f"local scrollback {done['scrollbackLines']} lines, {done['scrollbackBytes'] / 1024:.0f} KB"),
    ("10 s in the background", away, f"{away['metal']} of {away['terminals']} terminals on Metal"),
    ("three sessions open", last,
     f"{(last['footprint'] - one_open['footprint']) / 2 / MB:.1f} MB per extra session, on a {card(one_open)} card "
     f"with one; {last['metal']} of {last['terminals']} on Metal"),
]
for name, sample, note in rows:
    print(f"{name:<24} {sample['footprint'] / MB:7.1f} MB  {card(sample):<12} {note}")
