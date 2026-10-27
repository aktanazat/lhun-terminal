#!/bin/zsh
# Times keys typed into Lhûn on a connected device, at a zsh prompt in a new session on this Mac. Runs
# LhunProbe/testTypingLatency, then sums up the probe's log of each key with tools/typing.py.
#   tools/typing.sh <label>    results in build/typing-<label>.*
#   LHUN_DEST=sim:<name> tools/typing.sh <label>    an existing simulator (tools/dest.zsh); its times
#                                                   only compare runs on the same simulator
set -euo pipefail
cd "${0:A:h}/.."
source tools/dest.zsh
label="${1:?usage: tools/typing.sh <label>}"

result=0
tools/device-test.sh "typing-$label" LhunShots/LhunProbe/testTypingLatency || result=$?
if [[ -f "build/typing-$label.jsonl" ]]; then
  python3 tools/typing.py "build/typing-$label.jsonl" || result=1
fi
exit $result
