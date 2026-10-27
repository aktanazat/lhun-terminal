"""Sums up the keys a tools/typing.sh run timed: the median and 95th percentile of each part of a key's
trip to the screen, in milliseconds.

    delivered  the key went down until the terminal view got it (iOS)
    texted     the view got it until the system's text input handed its text back (UIKit; zero for keys
               Lhûn or SwiftTerm take straight from the press)
    handled    then until its bytes went to the SSH channel (SwiftTerm, Lhûn)
    network    the bytes went out until the echo came back (encryption, network, sshd, tmux, zsh)
    queued     the echo came off the network until the main thread took it (Lhûn)
    drawn      the main thread took it until the frame showing it was on screen (SwiftTerm, Metal, display)

    python3 tools/typing.py build/typing-<label>.jsonl
"""
import json
import math
import statistics
import sys

PARTS = ["delivered", "texted", "handled", "network", "queued", "drawn"]
GROUPS = {
    "key to channel": ["delivered", "texted", "handled"],
    "network and host": ["network"],
    "echo to screen": ["queued", "drawn"],
    "total": PARTS,
}

samples = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
keys = [sample for sample in samples if sample.get("event") == "key"]
if not keys:
    sys.exit("no keys were timed")


def p95(values):
    ordered = sorted(values)
    return ordered[math.ceil(0.95 * len(ordered)) - 1]


def row(name, values):
    print(f"{name:>17}  median {statistics.median(values):6.1f}  p95 {p95(values):6.1f}  max {max(values):6.1f}")


direct = sum(1 for key in keys if key.get("direct"))
print(f"{len(keys)} keys, {direct} typed straight from the press, milliseconds")
for part in PARTS:
    row(part, [key[part] for key in keys])
for group, parts in GROUPS.items():
    row(group, [sum(key[part] for part in parts) for key in keys])
