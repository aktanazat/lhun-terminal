#!/bin/zsh
# Measures what Lhûn costs on a connected device, in one install: memory at each point and its guards
# (tools/probe.sh's run), launch, a quiet screen, a session streaming a build log, one showing an agent at
# work, history scrolled back, and typing. tools/perf-summary.py then prints the numbers in plain units
# from the app's probe log and XCTest's result bundle.
#   LHUN_DEVICE=<udid> tools/perf.sh <slug>    a device; the log lands in build/perf-<slug>.jsonl
#   tools/perf.sh <slug> <udid>               the explicitly named device
#   LHUN_DEST=sim:<name> tools/perf.sh <slug> an existing simulator (tools/dest.zsh), whose numbers
#                                             only compare runs on the same simulator
# LHUN_APP measures another build of Lhûn with this checkout's tests (tools/device-test.sh), and
# `python3 tools/perf-summary.py <before>.jsonl... --against <after>.jsonl...` sets the runs of two builds
# side by side, refusing any point measured on different cards. LHUN_TESTS="testLaunchToReadable" runs
# only the named LhunProbe tests, for a quicker before and after of one point.
# The fixture sessions carry the caller's slug (lhun-test-<slug>-proof, -proof2, -proof3 and -history),
# so runs by different builders never share or kill each other's sessions. They are killed at the end.
set -euo pipefail
cd "${0:A:h}/.."
label="${1:?usage: tools/perf.sh <slug> [udid]}"
[[ -z ${2:-} ]] || export LHUN_DEVICE=$2 LHUN_DEST="device:$2"
source tools/dest.zsh
prefix="lhun-test-$label"
fixtures=("$prefix-proof" "$prefix-proof2" "$prefix-proof3")
past="$prefix-history"
export TEST_RUNNER_PROBE_PREFIX="$prefix"
export TEST_RUNNER_PERF_HISTORY="$past"
export TEST_RUNNER_PERF_TOOLS="$PWD/tools"
seed="build/perf-$label-history.txt"

cleanup() {
  # Quoted targets: zsh would expand a bare =name to the path of a command.
  for name in $fixtures $past; do tmux kill-session -t "=$name" 2>/dev/null || true; done
}
trap cleanup EXIT
# The status line goes off so tmux never redraws an idle screen by itself.
for name in $fixtures; do
  tmux has-session -t "=$name" 2>/dev/null || tmux new-session -d -s "$name"
  tmux set-option -t "=$name:" status off
done
# 3,000 numbered lines in eight colors, for history to read back.
mkdir -p build
python3 -c '
import sys
with open(sys.argv[1], "w") as seed:
    for i in range(1, 3001):
        seed.write(f"\x1b[3{i % 8}m{i:05d}\x1b[0m history line {i}, \x1b[1mbold\x1b[0m and plain words to wrap the row\n")
' "$seed"
tmux kill-session -t "=$past" 2>/dev/null || true
# A zsh that keeps no history, so what runs here stays out of yours.
tmux new-session -d -s "$past" zsh -f
tmux set-option -t "=$past:" status off
tmux send-keys -t "=$past:" "cat ${(q)PWD}/${(q)seed}" Enter

tests=(${=LHUN_TESTS:-testFootprintAndGuards testLaunch testLaunchToReadable testOutputStream testWorkingSpinner
  testQuietSessions testScrollingHistory testTypingLatency})
result=0
tools/device-test.sh "perf-$label" ${tests/#/LhunShots/LhunProbe/} || result=$?
python3 tools/perf-summary.py "build/perf-$label.jsonl" "build/perf-$label.xcresult"
exit $result
