#!/bin/zsh
# Checks the copy flash, Copy on Select and the kill fade on the iPad or a simulator (LHUN_DEST,
# tools/dest.zsh; LhunShots/CopyFxShots.swift). Makes the Mac sessions the checks use, all named
# lhun-test-copyfx-*: a (the live terminal), h (300 rows of one word, for history), s (a screen to copy
# whole), k1 to k3 (to kill). Then:
# - photographs each effect halfway, upright, into the directory given (the test runs
#   them 20 times slower for this), and turns XCTest's own real-speed screenshots upright beside them
# - checks the probe's copy of s's screen against the screen tmux holds, by size and SHA-256
# - checks the kills took k1 and k3 and left k2
# - prints XCTest's frame counts for the 10 seconds after the real-speed flash and fade
# and kills the sessions, also when the run fails.
#   tools/copyfx.sh [dir] [test...]   e.g. tools/copyfx.sh out LhunShots/CopyFxShots/test5FadeOnKill
set -euo pipefail
self="${0:A}"
cd "${0:A:h}/.."
source tools/dest.zsh
if [[ ${1:-} != --locked ]]; then
  out="${1:-shots/copyfx}"
  (( $# )) && shift
  # The build tools/device-test.sh makes. Everything after runs inside the destination's lock, so the
  # photographer below is only ever live while these tests have it.
  dest_build
  exec /usr/bin/lockf -k "$dest_lock" "$self" --locked "$out" "$@"
fi
out="$2"
shift 2
tests=("$@")
(( $#tests )) || tests=(LhunShots/CopyFxShots)
fixtures=(a h s k1 k2 k3)
name="copyfx-$(date +%Y%m%d-%H%M%S)"
photographer=0

cleanup() {
  (( photographer )) && kill "$photographer" 2>/dev/null || true
  # Quoted targets: zsh would expand a bare =name to the path of a command.
  for suffix in $fixtures; do tmux kill-session -t "=lhun-test-copyfx-$suffix" 2>/dev/null || true; done
}
trap 'cleanup; dest_release' EXIT
cleanup
mkdir -p build "$out"
for suffix in $fixtures; do
  # A zsh that keeps no history, so what the test types stays out of yours.
  tmux new-session -d -s "lhun-test-copyfx-$suffix" -x 160 -y 50 zsh -f
  # The status line goes off so tmux never redraws an idle screen by itself.
  tmux set-option -t "=lhun-test-copyfx-$suffix:" status off
done
tmux send-keys -t "=lhun-test-copyfx-h:" "yes copyfxword | head -300" Enter
# Rows of text across the cards that fade, so the photographs show the fade.
for suffix in k1 k3; do
  tmux send-keys -t "=lhun-test-copyfx-$suffix:" \
    "yes 'the card fades away and what comes next shows through' | head -60" Enter
done

# The test asks for each screenshot with take-copyfx-<shot> and holds still until it is taken
# (dest_photographer). Other checks share the runner, so only asks with this prefix are answered.
dest_photographer copyfx- "$out" &
photographer=$!

result=0
tools/device-test.sh --locked "$name" $tests || result=$?
kill "$photographer" 2>/dev/null || true
photographer=0

# XCTest's own screenshots come out on their side, named by UUID; they go to the output folder upright,
# under the names the test gave them.
attachments="build/$name-attachments"
mkdir -p "$attachments"
xcrun xcresulttool export attachments --path "build/$name.xcresult" --output-path "$attachments" >/dev/null || true
if [[ -f "$attachments/manifest.json" ]]; then
  jq -r '.[].attachments[] | [.exportedFileName, (.suggestedHumanReadableName | sub("_[0-9]+_[0-9A-F-]+[.]"; "."))]
    | select(.[1] | test("^[0-9]{2}-")) | @tsv' "$attachments/manifest.json" |
    while IFS=$'\t' read -r file label; do sips -r 270 "$attachments/$file" --out "$out/$label" >/dev/null; done
fi
mv "$attachments" ~/.Trash/"$name-attachments"

# Each check runs when the probe log shows its test ran: the screen when s was opened, a kill when its
# card faded.
log="build/$name.jsonl"
[[ -f "$log" ]] || : >"$log"
screen="build/$name-screen.txt"
tmux capture-pane -p -J -t "=lhun-test-copyfx-s:" >"$screen" 2>/dev/null || : >"$screen"
if grep -q '"event":"open lhun-test-copyfx-s"' "$log"; then
  python3 - "$screen" "$log" <<'EOF' || result=1
import hashlib
import json
import sys

# As Lhûn's Tmux.screenText gives it: no blanks at the end of a line, no empty lines below the last one.
lines = [line.rstrip() for line in open(sys.argv[1]).read().split("\n")]
while lines and not lines[-1]:
    lines.pop()
text = "\n".join(lines).encode()
copies = [sample["copy"] for sample in map(json.loads, filter(str.strip, open(sys.argv[2])))
          if sample.get("event") == "copy"]
want = (len(text), hashlib.sha256(text).hexdigest())
if not any((copy["bytes"], copy["sha256"]) == want for copy in copies):
    sys.exit(f"no copy matched s's screen ({want[0]} bytes); the probe saw {len(copies)} copies")
print(f"Copy Screen copied s's screen as tmux holds it: {want[0]} bytes, SHA-256 {want[1][:16]}…")
print(f"copies the probe saw: {len(copies)}")
EOF
fi

faded=0
for suffix in k1 k3; do
  grep -q "\"event\":\"fade lhun-test-copyfx-$suffix\"" "$log" || continue
  faded=1
  if tmux has-session -t "=lhun-test-copyfx-$suffix" 2>/dev/null; then
    echo "lhun-test-copyfx-$suffix faded but survived its kill"
    result=1
  else
    echo "lhun-test-copyfx-$suffix faded and was killed"
  fi
done
if (( faded )); then
  if tmux has-session -t "=lhun-test-copyfx-k2" 2>/dev/null; then
    echo "lhun-test-copyfx-k2 is still there"
  else
    echo "lhun-test-copyfx-k2 went with another's kill"
    result=1
  fi
fi

print "frame counts:"
xcrun xcresulttool get test-results metrics --path "build/$name.xcresult" | tee "build/$name-metrics.json" |
  jq -r '.[] | .testIdentifier as $test | .testRuns[]?.metrics[]? | "\($test)\t\(.displayName)\t\(.measurements)\t\(.unitOfMeasurement)"' || true
print "results in $out"
exit $result
