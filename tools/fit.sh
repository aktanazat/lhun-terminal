#!/bin/zsh
# Checks on a connected device that Lhûn's terminal fits its card and that tmux on this Mac was sent the
# size the app reports. Runs LhunProbe/testTerminalFitsItsCard while recording the size of every tmux
# client five times a second, then lines the two records up with tools/fit-check.py.
#   tools/fit.sh <label>                results in build/fit-<label>.*
#   tools/fit.sh <label> <shots-dir>    also captures the screen at each pose, into <shots-dir>/<label>-*.png
#   LHUN_LAUNCH_ARGS="-compactLayout YES" tools/fit.sh <label>    launches Lhûn with those arguments too
# tools/device-test.sh kills the session the test opens afterwards; sessions that were already there stay.
set -euo pipefail
cd "${0:A:h}/.."
source tools/dest.zsh
label="${1:?usage: tools/fit.sh <label> [shots-dir]}"
zmodload zsh/datetime

record="build/fit-$label.tmux"
mkdir -p build
: >| "$record"
poller=
trap '[[ -n "$poller" ]] && kill "$poller" 2>/dev/null' EXIT

# One line with the time, then one line per client: session, size as the client reported it, terminal.
{
  while true; do
    print -r -- "$EPOCHREALTIME"
    tmux list-clients -F $'\t#{session_name}\t#{client_width}x#{client_height}\t#{client_termname}' 2>/dev/null || true
    sleep 0.2
  done
} >> "$record" &
poller=$!

if [[ -n "${2:-}" ]]; then
  mkdir -p "$2"
  export TEST_RUNNER_LHUN_SHOTS="${2:A}/$label"
fi
if [[ -n "${LHUN_LAUNCH_ARGS:-}" ]]; then
  export TEST_RUNNER_LHUN_LAUNCH_ARGS="$LHUN_LAUNCH_ARGS"
fi
result=0
tools/device-test.sh "fit-$label" LhunShots/LhunProbe/testTerminalFitsItsCard || result=$?
if [[ -f "build/fit-$label.jsonl" ]]; then
  python3 tools/fit-check.py "build/fit-$label.jsonl" "$record" || result=1
fi
exit $result
