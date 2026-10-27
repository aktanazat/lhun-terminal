#!/bin/zsh
# A screenshot of text a dark theme can lose, on the iPad or a simulator (LHUN_DEST, tools/dest.zsh;
# LhunShots/LhunVisibleShots).
# The tmux session lhun-test-themes-visible on this Mac shows tools/visible-pattern.sh in its top pane and
# omp's input line in its bottom one. omp runs in an empty profile of its own, so it signs in nowhere,
# starts no servers and saves no session. The test switches the device to dark and back, and the screenshot
# lands at <dir>/<name>.png. The session, omp and its profile are removed afterwards.
#   tools/visible.sh <dir> <name>    e.g. tools/visible.sh /private/var/tmp/lhun-shots/v5/themes visible-after
set -euo pipefail
cd "${0:A:h}/.."
source tools/dest.zsh
out="${1:?usage: tools/visible.sh <dir> <name>}"
name="${2:?usage: tools/visible.sh <dir> <name>}"
session=lhun-test-themes-visible
profile=lhun-test-themes
mkdir -p "$out"

# Quoted targets: zsh would expand a bare =name to the path of a command.
cleanup() {
  tmux kill-session -t "=$session" 2>/dev/null || true
  if [[ -d ~/.omp/profiles/$profile ]]; then mv ~/.omp/profiles/$profile ~/.Trash/"$profile-$(date +%s)"; fi
}
cleanup
trap cleanup EXIT

# LHUN_DEST reaches tools/snap.sh, which the test starts in this session.
tmux new-session -d -s "$session" -x 150 -y 44 -c "$PWD" -e "LHUN_DEST=${LHUN_DEST-}"
tmux set-option -t "=$session:" status off
# `shoot <name> <seconds>` reprints the pattern and photographs the device that many seconds later.
tmux send-keys -t "=$session:" \
  "shoot() { clear; zsh tools/visible-pattern.sh; tools/snap.sh ${out:A}/\$1.png \$2; }; clear; zsh tools/visible-pattern.sh" Enter
tmux split-window -v -l 55% -t "=$session:" -c "$PWD" \
  "omp --profile=$profile --no-session --no-extensions --no-skills --no-rules --no-lsp"
tmux select-pane -t "=$session:.0"
# A new profile opens omp's setup; Escape skips each step until the input line shows.
for _ in {1..20}; do
  tmux capture-pane -p -t "=$session:.1" | grep -q 'thinking effort' && break
  tmux send-keys -t "=$session:.1" Escape
  sleep 1
done
tmux capture-pane -p -t "=$session:.1" | grep -q 'thinking effort' || { print -u2 "omp never showed its input line"; exit 1; }

code=0
TEST_RUNNER_VISIBLE_SHOT="$name" tools/device-test.sh "visible-$name" LhunShots/LhunVisibleShots || code=$?
if [[ -f "build/visible-$name.jsonl" ]]; then
  # The floor's lookups: none at all means no color went through it.
  jq -sc 'last | {contrastHits, contrastMisses}' "build/visible-$name.jsonl"
fi
[[ -f "$out/$name.png" ]] && echo "screenshot: $out/$name.png"
exit $code
