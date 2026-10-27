#!/bin/zsh
# Walks through Lhûn's terminal workflow for a few minutes, with the screen recorded
# (LhunShots/LhunWalk.swift), on the iPad or a simulator (LHUN_DEST, tools/dest.zsh), and lays out what it
# leaves for a look frame by frame in /private/var/tmp/lhun-shots/v5/polish/walk-<label>/:
# - walk.mp4, the recording, and steps.tsv, the second of the recording each step began at
# - the screenshots, numbered in the order taken and turned the way the iPad was held
# - audit.tsv, what the accessibility audit found at a few poses: low contrast, small targets, clipped text
# - grids.tsv, each open terminal's columns and rows at a few poses, such as before and over the palette
#   tools/walk.sh [--locked] <label>   with --locked the caller has built Lhûn and holds $dest_lock, as
#                                      with tools/device-test.sh --locked
# The walk holds the iPad sideways, or upright with WALK_HOLD=portrait.
# It makes lhun-test-polish-omp (omp in this repository), -claude (Claude Code in an empty folder) and
# -shell (a shell here whose `drop` ends Lhûn's own connection to it a second later). They, and the
# sessions the walk's splits open beside them, are killed when it ends.
set -euo pipefail
self="${0:A}"
cd "${0:A:h}/.."
source tools/dest.zsh
if [[ "${1:-}" != --locked ]]; then
  label=${1:?usage: tools/walk.sh [--locked] <label>}
  dest_build
  print "built, waiting for the ${dest_name:-device}"
  # omp and Claude Code start only once the destination is free, so they never sit through someone else's run.
  exec /usr/bin/lockf -k "$dest_lock" "$self" --locked "$label"
fi
label=${2:?usage: tools/walk.sh [--locked] <label>}
prefix=lhun-test-polish
run=walk-$label
out=/private/var/tmp/lhun-shots/v5/polish/$run
folder=/private/var/tmp/lhun-polish/claude

cleanup() {
  local session
  for session in ${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"}; do
    # Quoted targets: zsh would expand a bare =name to the path of a command.
    if [[ $session == $prefix-* ]]; then tmux kill-session -t "=$session" 2>/dev/null || true; fi
  done
  dest_release
}
trap cleanup EXIT

# Waits up to 40 s for a session's screen to show a line matching the pattern.
await() {
  local session=$1 pattern=$2 tries=0
  until tmux capture-pane -p -t "=$session:" | grep -q -- "$pattern"; do
    (( ++tries < 200 )) || { print -u2 "$session never showed $pattern"; return 1; }
    sleep 0.2
  done
}

cleanup
mkdir -p build "$folder"
[[ -e $out ]] && mv "$out" ~/.Trash/"$run-$(date +%s)"
mkdir -p "$out"
cat >| build/walk-drop.zsh <<'EOF'
# Ends Lhûn's own connection to this session a second from now, the way a dropped network would: the sshd
# under each tmux client of the session that is not a control-mode client, such as Lhûn's watcher.
drop() {
  local session=$(tmux display-message -p '#{session_name}')
  {
    sleep 1
    tmux list-clients -t "=$session:" -F '#{client_control_mode} #{client_pid}' | while read -r control pid; do
      [[ $control == 0 ]] || continue
      local parent=$(ps -o ppid= -p $pid | tr -d ' ')
      [[ $(ps -o comm= -p $parent) == *sshd* ]] && kill $parent
    done
  } &!
}
EOF
tmux new-session -d -s "$prefix-omp" -c "$PWD"
tmux new-session -d -s "$prefix-claude" -c "$folder"
tmux new-session -d -s "$prefix-shell" -c "$PWD"
for session in omp claude shell; do tmux set-option -t "=$prefix-$session:" status off; done
tmux send-keys -t "=$prefix-omp:" "clear; omp" Enter
# Claude Code asks once whether to trust a folder; the answer stays with the folder.
tmux send-keys -t "=$prefix-claude:" "clear; claude" Enter
tmux send-keys -t "=$prefix-shell:" "source $PWD/build/walk-drop.zsh; clear" Enter
await "$prefix-omp" 'to change thinking effort'
await "$prefix-claude" 'Claude Code'

result=0
export TEST_RUNNER_WALK_PREFIX=$prefix TEST_RUNNER_WALK_HOLD="${WALK_HOLD:-}"
LHUN_RECORD=1 tools/device-test.sh --locked "$run" LhunShots/LhunWalk/testWalkthrough || result=$?

attachments="build/$run-attachments"
# xcresulttool wants a fresh folder; the last one goes to the Trash.
[[ -e $attachments ]] && mv "$attachments" ~/.Trash/"$run-attachments-$(date +%s)"
xcrun xcresulttool export attachments --path "build/$run.xcresult" --output-path "$attachments" >/dev/null
python3 - "$attachments" "$out" <<'EOF' || result=1
import json
import os
import shutil
import sys

attachments, out = sys.argv[1:]
everything = [each for test in json.load(open(f"{attachments}/manifest.json")) for each in test["attachments"]]


def named(prefix):
    return [each for each in everything if each["suggestedHumanReadableName"].startswith(prefix)]


videos = [each for each in everything if each["exportedFileName"].endswith((".mp4", ".mov"))]
if not videos:
    sys.exit("the run kept no recording")
video = videos[0]
shutil.copy(f"{attachments}/{video['exportedFileName']}", f"{out}/walk{os.path.splitext(video['exportedFileName'])[1]}")
began = video.get("timestamp")
for note in ("steps", "audit", "grids"):
    for each in named(f"{note}_"):
        text = open(f"{attachments}/{each['exportedFileName']}").read()
        if note == "steps" and began is not None:
            rows = [line.split("\t") for line in text.splitlines() if line]
            text = "".join(f"{float(at) - began:7.1f}\t{name}\n" for name, at in rows)
        open(f"{out}/{note}.tsv", "w").write(text)
for each in everything:
    name = each["suggestedHumanReadableName"]
    if name[:2].isdigit() and each["exportedFileName"].endswith(".png"):
        shutil.copy(f"{attachments}/{each['exportedFileName']}", f"{out}/{name.split('_')[0]}.png")
print(f"recording: {video['exportedFileName']}, began {began}")
EOF

print -l -- "$out"/*(N)
exit $result
