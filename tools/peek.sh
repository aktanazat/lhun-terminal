#!/bin/zsh
# Checks session peek on the iPad or a simulator (LHUN_DEST, tools/dest.zsh) against real sessions.
# Starts sessions worth a look (a diff, a history and a color chart on this Mac, htop on the server),
# records the size of every tmux client on this Mac five times a second while LhunShots/LhunPeek runs,
# then checks with tools/peek-check.py that the session on screen kept its size while the peek was open,
# and that the keyboard stepped aside for it and came back. The sessions it started are killed after.
#   tools/peek.sh <label>               results in build/peek-<label>.*
#   tools/peek.sh <label> <shots-dir>   also saves the run's screenshots there, and the device's own pictures
#                                       of the poses the test holds, each checked against the app's log
set -euo pipefail
cd "${0:A:h}/.."
source tools/dest.zsh
dest_require_server
label="${1:?usage: tools/peek.sh <label> [shots-dir]}"
shots="${2:-}"
name="peek-$label"
record="build/$name.tmux"
zmodload zsh/datetime
mkdir -p build

mac=(lhun-test-peek-diff lhun-test-peek-log lhun-test-peek-colors)
server=lhun-test-peek-top
poller=
finish() {
  [[ -n "$poller" ]] && kill "$poller" 2>/dev/null
  local session
  for session in $mac; do tmux kill-session -t "=$session" 2>/dev/null || true; done
  ssh "$LHUN_SERVER" "tmux kill-session -t '=$server'" 2>/dev/null || true
}
trap finish EXIT

for session in $mac; do
  tmux kill-session -t "=$session" 2>/dev/null || true
  # LHUN_DEST reaches tools/snap.sh, which the test starts in the first of them.
  tmux new-session -d -s "$session" -x 120 -y 36 -c "$PWD" -e "LHUN_DEST=${LHUN_DEST-}"
done
# The test types `shoot <name> <seconds>...` here before the poses it holds, so the device photographs
# each from this Mac that many seconds later.
if [[ -n "$shots" ]]; then
  mkdir -p "$shots"
  : >| "$shots/shots.tsv"
  tmux send-keys -t "=lhun-test-peek-diff:" \
    "shoot() { while (( \$# > 1 )); do $PWD/tools/snap.sh ${shots:A}/\$1.png \$2; shift 2; done; }" Enter
  export TEST_RUNNER_PEEK_SHOOT=shoot
fi
tmux send-keys -t "=lhun-test-peek-diff:" \
  "clear; git --no-pager show --stat --patch --color=always HEAD | head -n 40" Enter
tmux send-keys -t "=lhun-test-peek-log:" \
  "clear; git --no-pager log --graph --decorate --color=always --format='%C(auto)%h%d %s %C(dim)%ar' -n 40" Enter
tmux send-keys -t "=lhun-test-peek-colors:" \
  "clear; for i in {0..255}; do printf '\\e[48;5;%dm %3d \\e[0m' \$i \$i; (( i % 16 == 15 )) && print; done" Enter
ssh "$LHUN_SERVER" "tmux kill-session -t '=$server' 2>/dev/null; tmux new-session -d -s $server -x 120 -y 36 htop"

# One line with the time, then one line per terminal client: session, size as the client reported it,
# terminal. Control-mode clients, the app's session watcher among them, take no size and are left out.
: >| "$record"
{
  while true; do
    print -r -- "$EPOCHREALTIME"
    tmux list-clients -f '#{?client_control_mode,0,1}' \
      -F $'\t#{session_name}\t#{client_width}x#{client_height}\t#{client_termname}' 2>/dev/null || true
    sleep 0.2
  done
} >> "$record" &
poller=$!

result=0
tools/device-test.sh "$name" LhunShots/LhunPeek || result=$?
if [[ -n "$shots" && -d "build/$name.xcresult" ]]; then
  xcrun xcresulttool export attachments --path "build/$name.xcresult" --output-path "$shots" >/dev/null
  # Exported files are named by UUID; give each the name the test kept it under.
  jq -r '.[].attachments[] | [.exportedFileName, (.suggestedHumanReadableName | sub("_[0-9]+_[0-9A-F-]+[.]"; "."))] | @tsv' \
    "$shots/manifest.json" | while IFS=$'\t' read -r file label; do mv "$shots/$file" "$shots/$label"; done
  cp "$record" "$shots/tmux-clients.txt"
fi
if [[ -f "build/$name.jsonl" ]]; then
  if [[ -n "$shots" ]]; then
    cp "build/$name.jsonl" "$shots/probe.jsonl"
    python3 tools/peek-check.py "build/$name.jsonl" "$record" "$shots/shots.tsv" || result=1
  else
    python3 tools/peek-check.py "build/$name.jsonl" "$record" || result=1
  fi
fi
exit $result
