#!/bin/zsh
# Runs the history pass on the iPad or a simulator (LHUN_DEST, tools/dest.zsh; LhunShots/LhunHistory.swift)
# against a tmux session on this Mac filled with 3,000 numbered, colored lines, and a second, empty one for
# selecting on the live terminal, then:
# - checks tmux never entered copy mode while the device scrolled back, searched and copied
# - prints the footprint before history opened, at its peak while reading and while the find bar showed,
#   in the first second from closing it and from then while UIKit still held it, and once it went, and on
#   the iPad fails when reading added more than 22 MB at its peak, finding more than 45 MB, or the
#   footprint has not come back to within 5 MB of before; a simulator prints those
# - checks the shell echoed the word last copied from history, pasted after the "e" that closed history,
#   and ran the line typed after a tap on the terminal brought the keyboard back, and the line typed once
#   the find bar closed, with no tap
# - the test checks a paste of two lines into cat asks first and one at the prompt does not
# - photographs each step the test holds still for, upright, into the directory given, shots/history by
#   default
#   tools/history.sh [dir]
set -euo pipefail
cd "${0:A:h}/.."
source tools/dest.zsh
out="${1:-shots/history}"
session=lhun-test-history-shots
live=lhun-test-history-live
name="history-$(date +%Y%m%d-%H%M%S)"
seed="$PWD/build/history-seed.txt"
shots=(1-history 2-find 3-selection 4-typed 5-word 6-line 7-find-typed 8-paste-asks)
watcher=0
photographer=0

cleanup() {
  (( watcher )) && kill "$watcher" 2>/dev/null || true
  (( photographer )) && kill "$photographer" 2>/dev/null || true
  # Quoted: zsh would expand a bare =name to the path of a command.
  tmux kill-session -t "=$session" 2>/dev/null || true
  tmux kill-session -t "=$live" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p build "$out"
python3 - "$seed" <<'EOF'
import sys

CSI = "\x1b["
lines = []
for n in range(1, 3001):
    number = f"{CSI}2m{n:05d}{CSI}0m "
    if n == 2600:
        lines.append(number + f"{CSI}1mthe needle is here{CSI}0m among the hay")
        continue
    kind = n % 8
    if kind == 0:
        body = "plain words in the default color, quick brown foxes over lazy dogs"
    elif kind == 1:
        body = f"{CSI}31mred{CSI}0m then {CSI}1;32mbold green{CSI}0m then {CSI}34mblue{CSI}0m and {CSI}1;33mbold yellow{CSI}0m"
    elif kind == 2:
        body = f"{CSI}38;5;208morange{CSI}0m {CSI}38;5;33mazure{CSI}0m {CSI}38;5;141mlilac{CSI}0m from the 256-color cube"
    elif kind == 3:
        body = f"{CSI}38;2;220;120;255mviolet{CSI}0m {CSI}38;2;80;200;160mmint{CSI}0m in 24-bit color"
    elif kind == 4:
        body = f"{CSI}41m red behind {CSI}0m {CSI}7m inverse {CSI}0m {CSI}44;97m white on blue {CSI}0m"
    elif kind == 5:
        body = "wide 漢字 かな 한글 cells take two columns each"
    elif kind == 6:
        body = "a long line that wraps " + " ".join(f"word{i:02d}" for i in range(40))
    else:
        body = f"{CSI}3mitalic{CSI}0m {CSI}4munderlined{CSI}0m {CSI}9mstruck{CSI}0m {CSI}1;3mbold italic{CSI}0m"
    lines.append(number + body)
with open(sys.argv[1], "w") as file:
    file.write("\n".join(lines) + "\n")
EOF

for fresh in "$session" "$live"; do
  tmux kill-session -t "=$fresh" 2>/dev/null || true
  # A zsh that keeps no history, so what the test types stays out of yours.
  tmux new-session -d -s "$fresh" -x 160 -y 50 zsh -f
  # The status line goes off so tmux never redraws an idle screen by itself.
  tmux set-option -t "=$fresh:" status off
done
tmux send-keys -t "=$session:" "cat ${(q)seed}" Enter
sleep 3

# Samples tmux's copy-mode flag five times a second for the whole run.
mode="build/$name-mode.txt"
while tmux display -p -t "=$session:" '#{pane_in_mode}' >>"$mode" 2>/dev/null; do sleep 0.2; done &
watcher=$!

# The test asks for each screenshot with take-<step> and holds still until it is taken
# (dest_photographer).
for shot in $shots; do
  if [[ -e "$out/$shot.png" ]]; then mv "$out/$shot.png" ~/.Trash/"$name-$shot.png"; fi
done
dest_photographer "" "$out" &
photographer=$!

result=0
TEST_RUNNER_HISTORY_SESSION="$session" TEST_RUNNER_LIVE_SESSION="$live" \
  tools/device-test.sh "$name" LhunShots/LhunHistory || result=$?
kill "$watcher" "$photographer" 2>/dev/null || true
watcher=0
photographer=0

samples=$(wc -l <"$mode" | tr -d ' ')
entered=$(grep -c -v '^0$' "$mode" || true)
echo "copy mode: $entered of $samples samples"
(( entered == 0 )) || result=1

python3 - "build/$name.jsonl" "$dest_kind" <<'EOF' || result=1
import json
import sys

MB = 1024 * 1024
log = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
# The log holds every launch of the run. XCTest runs the tests in name order, so the history pass's
# launch, which held thousands of rows rather than the live terminal's screen, is the last.
launches = [index for index, sample in enumerate(log) if sample.get("event") == "launch"]
samples = log[launches[-1]:] if launches else log
opened = [index for index, sample in enumerate(samples) if sample.get("history")]
if not opened:
    sys.exit("history never showed up in the probe log")
first, last = opened[0], opened[-1]
before = samples[first - 1]["footprint"]
# History stays in the probe from when it opens until the view goes, which after a Copy menu is about a
# minute after it closes: UIKit keeps the view its edit menu last showed from until a 60-second timer
# clears it. Reading and finding count only while history showed. The first second from closing holds
# the terminal coming back and history leaving the screen, the footprint falling about 30 MB as they do.
# From then until the view goes is what UIKit holding the closed view costs: 53.4 MB at most, against
# 52.9 MB once it went, on 11 October 2026, where one figure for both had read 83.8 MB.
shown = [sample for sample in samples[first:last + 1] if not sample["history"].get("closed")]
closed = [sample for sample in samples[first:last + 1] if sample["history"].get("closed")]
closing = [sample for sample in closed if sample["t"] < closed[0]["t"] + 1]
held = [sample for sample in closed if sample["t"] >= closed[0]["t"] + 1]
reading = max(sample["footprint"] for sample in shown if not sample["history"].get("finding"))
finding = [sample["footprint"] for sample in shown if sample["history"].get("finding")]
after = [sample["footprint"] for sample in samples[last + 1:]]
history = [sample["history"] for sample in shown]
if max(h.get("rows", 0) for h in history) <= 500:
    sys.exit("the last launch in the probe log is not the history pass's")
summary = [f"{before / MB:.1f} MB before", f"{reading / MB:.1f} MB at most while reading"]
if finding:
    summary.append(f"{max(finding) / MB:.1f} MB at most while finding")
if closing and after:
    summary.append(f"{max(sample['footprint'] for sample in closing) / MB:.1f} MB at most in the first "
                   "second from closing")
if held and after:
    summary.append(f"{max(sample['footprint'] for sample in held) / MB:.1f} MB at most in the "
                   f"{samples[last + 1]['t'] - held[0]['t']:.0f} s after it until UIKit let it go")
summary.append(f"{after[0] / MB:.1f} MB once it went, {after[-1] / MB:.1f} MB at the end" if after else "never let go")
print("footprint: " + ", ".join(summary))
print(f"rows held at most {max(h.get('rows', 0) for h in history)}, "
      f"furthest back {max(h.get('back', 0) for h in history)} rows, "
      f"slowest older stretch {max(h.get('slowestRead', 0) for h in history)} ms")
# The budgets are the iPad's. A simulator draws through the Mac and its footprint runs higher (35.1 MB
# over before at reading's peak, on 8 October 2026), so there they are printed, not held.
over = []
# Hiding the terminal under history (its drawing surfaces) and reading out only the rows on screen to
# accessibility brought the peak from 39.7 MB over before to 11.2 MB.
if reading - before > 22 * MB:
    over.append(f"history added {(reading - before) / MB:.1f} MB at its peak, past the 22 MB it may")
# The find bar's search as the word goes in costs more for a moment: 29.2 and 37.7 MB over before in the
# first two runs, on 8 October 2026.
if not finding:
    sys.exit("the find bar never showed in the probe log")
if max(finding) - before > 45 * MB:
    over.append(f"history added {(max(finding) - before) / MB:.1f} MB at its peak while finding, past the 45 MB it may")
if not after:
    sys.exit("history never let go")
if after[-1] - before > 5 * MB:
    over.append(f"the footprint stayed {(after[-1] - before) / MB:.1f} MB above where it was before history opened")
if over and sys.argv[2] == "device":
    sys.exit("; ".join(over))
for problem in over:
    print(f"on a simulator, not held: {problem}")
EOF

echo "the session's last lines:"
tmux capture-pane -p -J -t "=$session:" | grep -v '^$' | tail -n 6
# Without -J, tmux leaves off the blanks at each line's end.
pane="build/$name-pane.txt"
tmux capture-pane -p -S -50 -t "=$session:" >"$pane"
python3 - "$pane" "build/$name.jsonl" <<'EOF' || result=1
import hashlib
import json
import re
import sys

lines = [line.rstrip() for line in open(sys.argv[1]) if line.strip()]
copies = [sample["copy"] for sample in map(json.loads, filter(str.strip, open(sys.argv[2])))
          if sample.get("event") == "copy"]
# The "e" that closed history, the "cho " after it and the pasted word ran as one echo, after zsh -f's
# prompt, which ends in "% ". The lines typed after a tap and once the find bar closed are checked on
# their own.
typed = [index for index, line in enumerate(lines)
         if re.search(r"% echo \S+$", line) and not line.endswith((" typed-after-tap", " typed-after-find"))]
if not typed or typed[-1] + 1 >= len(lines):
    sys.exit("the shell never ran echo with the pasted word: the key that closed history never reached it")
word = lines[typed[-1]].rsplit(" ", 1)[1]
if lines[typed[-1] + 1] != word:
    sys.exit(f"the shell echoed {lines[typed[-1] + 1]!r} for {word!r}")
if not copies:
    sys.exit("the probe saw nothing copied")
copy = copies[-1]
if (len(word.encode()), hashlib.sha256(word.encode()).hexdigest()) != (copy["bytes"], copy["sha256"]):
    sys.exit(f"the shell echoed {word!r}, not the {copy['bytes']} bytes copied last")
print(f"the key that closed history reached the shell, which echoed the copied word {word!r}")
EOF
if grep -qx 'typed-after-tap' "$pane"; then
  echo "the shell ran the line typed after a tap on the terminal"
else
  echo "the shell never ran the line typed after a tap on the terminal"
  result=1
fi
if grep -qx 'typed-after-find' "$pane"; then
  echo "the shell ran the line typed once the find bar closed"
else
  echo "the shell never ran the line typed once the find bar closed"
  result=1
fi
for shot in $shots; do
  if [[ -s "$out/$shot.png" ]]; then
    echo "$out/$shot.png"
  else
    echo "no screenshot of $shot"
    result=1
  fi
done
exit $result
