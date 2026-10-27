#!/bin/zsh
# Checks the cards on the iPad or a simulator (LHUN_DEST, tools/dest.zsh; LhunShots/LhunSplit.swift)
# against three tmux sessions on this Mac, recording the size of every tmux client five times a second and
# each new size a client gives tmux, then:
# - lines each card's grid up with the size tmux was sent (tools/fit-check.py)
# - checks that each drag of the gap between two cards gave tmux one size per card, the one it settled at
# - prints the footprint while two cards sat idle, and how long they went without a frame
# - keeps, for each pill dropped on the cards, the last picture of the screen taken before it landed
# - turns the screenshots the way the iPad is held and puts them in /private/var/tmp/lhun-shots/v5/<slug>
#   tools/split.sh [--locked] [slug] [test…]   slug split by default; tests cards, drop, stack, gap and pill,
#   all by default. With --locked the caller has built Lhûn and holds the destination's lock across every test,
#   as with tools/device-test.sh --locked.
# It makes lhun-test-<slug>-a, -b and -c for the run. They, and the session Split Right or Split Down
# opens, are killed when it ends.
set -euo pipefail
cd "${0:A:h}/.."
source tools/dest.zsh
zmodload zsh/datetime
locked=()
if [[ "${1:-}" == --locked ]]; then
  locked=(--locked)
  shift
fi
slug=${1:-split}
if (( $# )); then shift; fi
tests=("$@")
(( $#tests )) || tests=(cards drop stack gap pill workspaces)
typeset -A methods=(
  cards testCardsTradeFocusAndZoom
  drop testDroppedPillOpensBesideTheCard
  stack testCardsStack
  gap testGapResizes
  pill testActivityHandsItsCardTheKeyboard
  workspaces testTabsKeepIndependentTerminalGroups
)
# The screenshots each test leaves.
typeset -A outputs=(
  cards "zoom portrait landscape"
  drop "split drop-right drop-left"
  stack "stacked"
  gap "drop-bottom resize-30-70 header-buttons"
  pill ""
  workspaces ""
)
for test in $tests; do
  (( ${+methods[$test]} )) || { print -u2 "usage: tools/split.sh [--locked] [slug] [cards|drop|stack|gap|pill|workspaces …]"; exit 64; }
done
out=/private/var/tmp/lhun-shots/v5/$slug
prefix=lhun-test-$slug
fixtures=("$prefix-a" "$prefix-b" "$prefix-c")
# What each card shows. git writes straight to the terminal: its pager would take the keys the test types.
listings=("git --no-pager log --oneline -30" "ls -l Lhun" "ls -l tools")
record=build/$slug.tmux
# tmux runs this each time a client of a test session gives it a new size. It notes when, the session and
# that client's size in build/<slug>-sized.log. The hook's own client_width can be another client's, so it
# looks the client up by name. A control-mode client, such as Lhûn's watcher passing through, has no size
# of its own and is left out.
sized=build/$slug-sized.sh
poller=0

cleanup() {
  (( poller )) && kill "$poller" 2>/dev/null || true
  # Quoted targets: zsh would expand a bare =name to the path of a command.
  for name in $fixtures "$prefix-a-2" "$prefix-b-2"; do tmux kill-session -t "=$name" 2>/dev/null || true; done
}
trap cleanup EXIT

mkdir -p build "$out"
for test in $tests; do
  for name in ${=outputs[$test]}; do rm -f "$out/$name.png" "$out/$name"-<->.png(N); done
done
: >| "$out/shots.tsv"
cat >| "$sized" <<'EOF'
#!/bin/zsh
zmodload zsh/datetime
when=$EPOCHREALTIME
size=$(tmux list-clients -t "=$1:" -f "#{&&:#{==:#{client_name},$2},#{==:#{client_control_mode},0}}" -F '#{client_width}x#{client_height}')
[[ -z $size ]] || print -r -- "$when"$'\t'"$1"$'\t'"$size" >> "${0:r}.log"
EOF
chmod +x "$sized"
: >| "${sized:r}.log"
for i in {1..$#fixtures}; do
  name=$fixtures[$i]
  tmux kill-session -t "=$name" 2>/dev/null || true
  # LHUN_DEST reaches tools/snap.sh, which the test starts in this session.
  tmux new-session -d -s "$name" -c "$PWD" -e "LHUN_DEST=${LHUN_DEST-}"
  # The status line goes off so tmux never redraws an idle screen by itself.
  tmux set-option -t "=$name:" status off
  tmux set-hook -t "=$name:" client-resized "run-shell -b '$PWD/$sized #{session_name} #{hook_client}'"
  # `shoot <name> <seconds> …` puts the listing back and photographs the device's screen into
  # $out/<name>.png that many seconds on, for each pair (tools/snap.sh): the test types it just before
  # a pose it cannot photograph itself, such as a dragged pill held over the cards.
  tmux send-keys -t "=$name:" "shoot() { clear; $listings[$i]; while (( \$# > 1 )); do tools/snap.sh $out/\$1.png \$2; shift 2; done; }; clear; $listings[$i]" Enter
done

# One line with the time, then one line per client: session, size as the client reported it, terminal.
: >| "$record"
{
  while true; do
    print -r -- "$EPOCHREALTIME"
    tmux list-clients -F $'\t#{session_name}\t#{client_width}x#{client_height}\t#{client_termname}' 2>/dev/null || true
    sleep 0.2
  done
} >> "$record" &
poller=$!

result=0
export TEST_RUNNER_SPLIT_PREFIX=$prefix
# Each test runs on its own and keeps its own probe log.
runs=()
for test in $tests; do
  runs+=("$slug-$test")
  rm -f "build/$slug-$test.jsonl"
  tools/device-test.sh $locked "$slug-$test" "LhunShots/LhunSplit/$methods[$test]" || result=$?
  for name in "$prefix-a-2" "$prefix-b-2"; do tmux kill-session -t "=$name" 2>/dev/null || true; done
done
kill "$poller" 2>/dev/null || true
poller=0

for run in $runs; do
  print "$run:"
  if [[ -f "build/$run.jsonl" ]]; then
    python3 tools/fit-check.py "build/$run.jsonl" "$record" || result=1
  else
    print "the run left no probe log"
    result=1
  fi
done
python3 - "$out/shots.tsv" "$prefix" "${sized:r}.log" $runs <<'EOF' || result=1
import json
import os
import shutil
import sys
import time

MB = 1024 * 1024
shots, prefix, sized, *runs = sys.argv[1:]
failed = False


def samples(run):
    path = f"build/{run}.jsonl"
    return [json.loads(line) for line in open(path) if line.strip()] if os.path.exists(path) else []


# The longest stretch with two terminals on screen and the count of presented frames unchanged.
for run in runs:
    best, stretch = [], []
    for sample in samples(run):
        two = len(sample.get("grids", [])) == 2
        if two and stretch and sample["frames"] == stretch[-1]["frames"]:
            stretch.append(sample)
        else:
            stretch = [sample] if two else []
        if len(stretch) > len(best):
            best = stretch
    if best:
        last = best[-1]
        print(f"{run}: two cards at rest {last['t'] - best[0]['t']:.0f} s without a frame, "
              f"footprint {last['footprint'] / MB:.1f} MB, {last['metal']} terminals drawing")
    else:
        print(f"{run}: two cards were never on screen together")
        failed = True

# A dropped session opens the moment the pill lands. Of the pictures taken while it hung over the cards,
# the last one finished half a second before then (the device's clock and this Mac's can differ a
# little) shows the drop zone; the others go to the Trash.
folder = os.path.dirname(shots)
taken = [line.rstrip("\n").split("\t") for line in open(shots) if line.strip()]
drops = {"drop": (("drop-right", "b"), ("drop-left", "c")), "gap": (("drop-bottom", "b"),)}
for run in runs:
    opened = {}
    for sample in samples(run):
        event = sample.get("event", "")
        if event.startswith("open "):
            opened.setdefault(event.removeprefix("open "), sample["at"])
    for kept, letter in drops.get(run.rsplit("-", 1)[1], ()):
        session = f"{prefix}-{letter}"
        pictures = [(float(ended), name) for name, began, ended in taken if name.rsplit("-", 1)[0] == kept]
        landed = opened.get(session)
        before = [picture for picture in pictures if landed is not None and picture[0] < landed - 0.5]
        if not before:
            print(f"{kept}: no picture finished before {session} opened")
            failed = True
            continue
        ended, name = max(before)
        print(f"{kept}: the picture finished {landed - ended:.1f} s before {session} opened")
        os.replace(f"{folder}/{name}.png", f"{folder}/{kept}.png")
        for _, other in pictures:
            if other != name and os.path.exists(f"{folder}/{other}.png"):
                shutil.move(f"{folder}/{other}.png", os.path.expanduser(f"~/.Trash/{other}-{time.time():.0f}.png"))

# Each time the gap between two cards let go, each card's client gave tmux exactly one size, the one its
# terminal settled at, and nothing else did from 1.5 s before to 2.5 s after (the test holds still then).
sizes = [line.rstrip("\n").split("\t") for line in open(sized) if line.strip()]
for run in runs:
    if not run.endswith("-gap"):
        continue
    log = samples(run)
    lets = [sample for sample in log if sample.get("event") == "gap let go"]
    if not lets:
        print(f"{run}: the gap never let go")
        failed = True
    for let in lets:
        at = let["at"]
        took = {}
        for when, session, size in sizes:
            if at - 1.5 <= float(when) <= at + 2.5:
                took.setdefault(session, []).append(size)
        rest = next((sample for sample in log if sample["at"] >= at + 1.5 and len(sample.get("grids", [])) == 2), None)
        settled = {grid["session"]: f"{grid['cols']}x{grid['rows']}" for grid in rest["grids"]} if rest else {}
        good = bool(settled) and took == {session: [size] for session, size in settled.items()}
        sent = "; ".join(f"{session} took {', '.join(each)}" for session, each in sorted(took.items())) or "tmux took no size"
        print(f"{run}: the gap let go at {let['share']:.2f}: {sent}" + ("" if good else f"; wanted one each: {settled}"))
        failed |= not good
sys.exit(1 if failed else 0)
EOF

# The test's shots come off the device as its screen is mounted, upright in portrait. The ones taken
# while it was held sideways are turned the way it was held; the Mac's own come out upright.
for run in $runs; do
  attachments="build/$run-attachments"
  # xcresulttool wants a fresh folder; the last one goes to the Trash.
  [[ -e $attachments ]] && mv "$attachments" ~/.Trash/"$run-attachments-$(date +%s)"
  xcrun xcresulttool export attachments --path "build/$run.xcresult" --output-path "$attachments" >/dev/null 2>&1 || continue
  for name in split zoom portrait landscape; do
    file=$(jq -r --arg name "${name}_" \
      'first(.[].attachments[] | select(.suggestedHumanReadableName | startswith($name))) | .exportedFileName' \
      "$attachments/manifest.json" 2>/dev/null || true)
    if [[ -n $file && $file != null ]]; then cp "$attachments/$file" "$out/$name.png"; fi
  done
done
wide() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ {w = $2} /pixelHeight/ {h = $2} END {exit !(w > h)}'; }
turn=0
if [[ $dest_kind == device ]]; then
  case $(xcrun devicectl device orientation get --device "$dest_id" 2>/dev/null || true) in
    *landscapeLeft*) turn=270 ;;
    *landscapeRight*) turn=90 ;;
  esac
fi
for name in split zoom; do
  [[ -f "$out/$name.png" ]] || continue
  if (( turn )) && ! wide "$out/$name.png"; then sips -r $turn "$out/$name.png" >/dev/null; fi
done
if [[ -f "$out/landscape.png" ]] && ! wide "$out/landscape.png"; then sips -r 270 "$out/landscape.png" >/dev/null; fi
print -l -- "$out"/*.png(N)
exit $result
