#!/bin/zsh
# Checks a session's shared size on the iPad or a simulator (LHUN_DEST, tools/dest.zsh;
# LhunShots/LhunSize.swift). Two tmux sessions on this Mac stand in for the iPad's; the other screen is a
# tmux client of the Mac's tmux running in a window of a tmux server of its own (-L lhun-test-size-outer),
# so its size is set exactly. Every client of the two sessions is recorded five times a second, with its
# flags and the window's size, then:
# - each pose the app held is lined up with what tmux had then: while the iPad shows another screen's
#   window, the window keeps that screen's size and the iPad's client ignores sizes; while the iPad sets
#   the size, the window has the iPad's size
# - each card's grid is checked against tmux (tools/fit-check.py)
# - the screenshots the test asked for land in /private/var/tmp/lhun-shots/v5/size
#   tools/size.sh
# It makes lhun-test-size-a and -b for the run and kills them, and the other screen, when it ends.
# The test drives the other screen by typing these into the session it has open, each a shell function
# there that runs this script with its name and arguments:
#   mac <session> <cols> <rows>   the other screen opens the session at that size
#   macsize <cols> <rows>         the other screen's window changes size
#   mackeys                       someone types on the other screen
#   macquit                       the other screen leaves
#   shoot <name> <seconds>        photographs the device's screen that many seconds on
set -euo pipefail
self=${0:A}
cd "${0:A:h}/.."
source tools/dest.zsh
zmodload zsh/datetime
prefix=lhun-test-size
outer=(tmux -L $prefix-outer -f build/size-outer.conf)
out=/private/var/tmp/lhun-shots/v5/size

case ${1-} in
  mac)
    # TERM tells the other screen's client from the iPad's in the record.
    $outer new-session -d -s mac -x "$3" -y "$4" "env -u TMUX TERM=screen-256color tmux attach -t '=$2'"
    exit ;;
  macsize) $outer resize-window -t mac -x "$2" -y "$3"; exit ;;
  mackeys) $outer send-keys -t mac x BSpace; exit ;;
  macquit) $outer kill-session -t mac; exit ;;
  shoot) exec tools/snap.sh "$out/$2.png" "$3" ;;
esac

fixtures=("$prefix-a" "$prefix-b")
record=build/size.tmux
poller=0

cleanup() {
  (( poller )) && kill "$poller" 2>/dev/null || true
  $outer kill-session -t mac 2>/dev/null || true
  # Quoted targets: zsh would expand a bare =name to the path of a command.
  for name in $fixtures; do tmux kill-session -t "=$name" 2>/dev/null || true; done
}
trap cleanup EXIT

mkdir -p build "$out"
rm -f "$out"/{watching,taken,shrunk}.png
: >| "$out/shots.tsv"
# The other screen's tmux shows no status line, so its window is exactly the size the test sets.
print -r -- 'set -g status off' >| build/size-outer.conf
for name in $fixtures; do
  tmux kill-session -t "=$name" 2>/dev/null || true
  # LHUN_DEST reaches tools/snap.sh, which `shoot` starts.
  tmux new-session -d -s "$name" -c "$PWD" -e "LHUN_DEST=${LHUN_DEST-}"
  # The status line goes off so tmux never redraws an idle screen by itself.
  tmux set-option -t "=$name:" status off
  tmux send-keys -t "=$name:" 'for v in mac macsize mackeys macquit shoot; do eval "$v() { tools/size.sh $v \"\$@\"; clear; }"; done; clear' Enter
done

# One line with the time, then one line per client of the two sessions: session, size, terminal, flags,
# the window's size and the client's name.
: >| "$record"
{
  while true; do
    print -r -- "$EPOCHREALTIME"
    for name in $fixtures; do
      tmux list-clients -t "=$name" \
        -F $'\t#{session_name}\t#{client_width}x#{client_height}\t#{client_termname}\t#{client_flags}\t#{window_width}x#{window_height}\t#{client_name}' \
        2>/dev/null || true
    done
    sleep 0.2
  done
} >> "$record" &
poller=$!

result=0
export TEST_RUNNER_SIZE_PREFIX=$prefix
runs=(size-join size-later)
# The other screen has the first session open before the app does.
"$self" mac "$prefix-a" 160 45
sleep 1
tools/device-test.sh size-join LhunShots/LhunSize/testJoinsASessionAnotherScreenSizes || result=$?
$outer kill-session -t mac 2>/dev/null || true
tools/device-test.sh size-later LhunShots/LhunSize/testLetsAScreenThatComesLaterHaveTheSize || result=$?
kill "$poller" 2>/dev/null || true
poller=0

for run in $runs; do
  print "$run:"
  if [[ ! -f "build/$run.jsonl" ]]; then
    print "the run left no probe log"
    result=1
    continue
  fi
  python3 tools/fit-check.py "build/$run.jsonl" "$record" || result=1
  python3 - "build/$run.jsonl" "$record" <<'EOF' || result=1
import json
import sys

HELD = 1.0
samples = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
polls = []  # (wall-clock time, [(session, size, terminal, flags, window, name)])
for line in open(sys.argv[2]):
    fields = line.rstrip("\n").split("\t")
    if fields[0]:
        polls.append((float(fields[0]), []))
    elif polls and len(fields) >= 7:
        polls[-1][1].append(fields[1:7])

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


def who(client):
    session, size, terminal, flags, window, name = client
    flags = flags.split(",")
    if "control-mode" in flags:
        return "control"
    return ("ipad" if terminal == "xterm-256color" else "mac") + f" {size}" + (" ignore-size" if "ignore-size" in flags else "")


failures = 0
print("each pose the app held, and tmux's clients of the session then:")
for run in poses:
    last = run[-1]
    held = last["at"] - run[0]["at"] >= HELD
    clients = next((listed for stamp, listed in reversed(polls) if stamp <= last["at"]), [])
    for grid in last["grids"]:
        mine = [client for client in clients if client[0] == grid["session"]]
        windows = sorted({client[4] for client in mine})
        ipads = [client for client in mine if who(client).startswith("ipad")]
        others = [who(client) for client in mine if who(client).startswith("mac")]
        size = f"{grid['cols']}x{grid['rows']}"
        watched = grid.get("window")
        if watched:
            state = f"shows the other screen's {watched}"
            ok = (windows == [watched] and f"mac {watched}" in others
                  and all("ignore-size" in who(client) for client in ipads))
        else:
            state = "sets the size"
            ok = windows == [size] and all("ignore-size" not in who(client) for client in ipads)
        verdict = "ok" if ok else "passing through" if not held else "FAIL"
        failures += verdict == "FAIL"
        listed = ", ".join(sorted(who(client) for client in mine)) or "no client"
        print(f"t {run[0]['t']:6.1f}-{last['t']:6.1f}  {grid['session']}  {state}  grid {size}  font {grid['font']:g}  "
              f"shared {grid.get('shared')}  tmux: window {', '.join(windows) or '-'}; {listed}  {verdict}")
print(f"{len(poses)} poses, {failures} failing")
sys.exit(1 if failures or not poses else 0)
EOF
done
print -l -- "$out"/*.png(N)
exit $result
