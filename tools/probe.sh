#!/bin/zsh
# Measures Lhûn on a connected device: footprint at each point, idle frames, scrollback after a burst
# of emoji-heavy output, and the cost of each extra open session. Ends with the guards in
# LhunShots/LhunProbe.swift.
#   LHUN_DEVICE=<udid> tools/probe.sh <slug>    a device; the log lands in build/probe-<slug>.jsonl
#   tools/probe.sh <slug> <udid>               the explicitly named device
#   LHUN_DEST=sim:<name> tools/probe.sh <slug> an existing simulator (tools/dest.zsh), whose memory and
#                                              frame numbers only compare runs on the same simulator
#   LHUN_LAUNCH_ARGS="-layout sidebar -sidebar YES" tools/probe.sh <slug>    launches Lhûn with those
#                                          arguments too, here in the sidebar layout with the sidebar shown
# The fixture sessions carry the caller's slug (lhun-test-<slug>-proof, -proof2 and -proof3), so runs by
# different builders never share or kill each other's sessions. They are killed when the run ends.
set -euo pipefail
cd "${0:A:h}/.."
label="${1:?usage: tools/probe.sh <slug> [udid]}"
[[ -z ${2:-} ]] || export LHUN_DEVICE=$2 LHUN_DEST="device:$2"
source tools/dest.zsh
prefix="lhun-test-$label"
fixtures=("$prefix-proof" "$prefix-proof2" "$prefix-proof3")
export TEST_RUNNER_PROBE_PREFIX="$prefix"
if [[ -n "${LHUN_LAUNCH_ARGS:-}" ]]; then
  export TEST_RUNNER_LHUN_LAUNCH_ARGS="$LHUN_LAUNCH_ARGS"
fi

cleanup() {
  # Quoted targets: zsh would expand a bare =name to the path of a command.
  for name in $fixtures; do tmux kill-session -t "=$name" 2>/dev/null || true; done
}
trap cleanup EXIT
# The status line goes off so tmux never redraws an idle screen by itself.
for name in $fixtures; do
  tmux has-session -t "=$name" 2>/dev/null || tmux new-session -d -s "$name"
  tmux set-option -t "=$name:" status off
done

result=0
tools/device-test.sh "probe-$label" LhunShots/LhunProbe/testFootprintAndGuards || result=$?
python3 tools/probe-summary.py "build/probe-$label.jsonl"
exit $result
