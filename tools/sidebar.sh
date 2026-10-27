#!/bin/zsh
# Checks the sidebar layout and the hover picture (LhunShots/SidebarShots.swift) on the destination
# tools/dest.zsh picks, the iPad or with LHUN_DEST=sim its simulator, through tools/device-test.sh.
# Sessions named lhun-test-sidebar-* go on both hosts first, in folders, most running a program (python3,
# vim, htop), one with a second window and one on each host that rang its bell. Two Mac sessions stand in
# for Claude Code: each prints a synthetic status report for lhun-tap built from this checkout
# (tools/status) to keep, whatever tap the host runs, then sits in a copy of cat named claude.
# ask is blocked on a question; agent works. Each scene a test holds still for is photographed into
# /private/var/tmp/lhun-shots/v5/sidebar/<sim|ipad>. Afterwards, pass or fail, the lhun-test-sidebar-*
# sessions go on both hosts.
#   tools/sidebar.sh <name> <test>...   e.g. tools/sidebar.sh hover LhunShots/SidebarShots/testHoverShowsAPictureOfTheSession
set -euo pipefail
cd "${0:A:h}/.."
self="${0:A}"
source tools/dest.zsh
dest_require_server
if [[ ${1:-} != --locked ]]; then
  (( $# >= 2 )) || { print -u2 "usage: tools/sidebar.sh <name> <test>..."; exit 64; }
  dest_build
  exec /usr/bin/lockf -k "$dest_lock" "$self" --locked "$@"
fi
shift
name="sidebar-$1"
shift
prefix=lhun-test-sidebar
out=/private/var/tmp/lhun-shots/v5/sidebar/${${dest_kind:#device}:-ipad}
scratch=/private/var/tmp/lhun-sidebar
work=$scratch/work
mkdir -p "$out" "$work" "$scratch/claude" "$scratch/bin"
photographer=0

cleanup() {
  (( photographer )) && kill "$photographer" 2>/dev/null || true
  local session
  for session in ${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"}; do
    if [[ $session == $prefix-* ]]; then tmux kill-session -t "=$session"; fi
  done
  ssh "$LHUN_SERVER" "tmux list-sessions -F '#{session_name}' 2>/dev/null | while read -r s; do case \$s in $prefix-*) tmux kill-session -t \"=\$s\";; esac; done" || true
  dest_release
}
trap cleanup EXIT

# <session> <folder> [command]
mac() {
  tmux new-session -d -s "$prefix-$1" -c "$2" ${3:+$3}
}
mac shell "$PWD"
mac vim "$PWD" 'vim -R project.yml'
mac logs "$PWD"
mac python "$work" python3
mac bell "$work"
tmux new-window -d -t "=$prefix-logs:" -c "$PWD"
tmux send-keys -t "=$prefix-bell:" "printf '\\a'" Enter
# The reports Claude Code sent while it asked a question and while it worked, its message in base64.
question='answer: Do you prefer red or blue? (Red · Blue)'
asked="state=blocked:app=claude-code:kind=question:msg=$(print -rn -- $question | base64)"
working="state=working:app=claude-code:msg=$(print -rn -- 'Running the test suite' | base64)"
cp /bin/cat "$scratch/bin/claude"
codesign --force --sign - "$scratch/bin/claude" 2>/dev/null
cc -O2 -o "$scratch/bin/lhun-tap" tools/status/status.c tools/status/lhun-tap.c
# <session> <report>: the tap takes the pane over as the session starts, so the report waits a second for it.
claude() {
  mac "$1" "$scratch/claude" "sleep 1; printf '\\033]7501;%s\\007' '$2'; exec $scratch/bin/claude"
  tmux pipe-pane -O -t "=$prefix-$1:" "exec $scratch/bin/lhun-tap #{q:socket_path} #{pane_id} #{pane_pid}"
}
claude ask "$asked"
claude agent "$working"
ssh "$LHUN_SERVER" "tmux new-session -d -s $prefix-python -c \"\$HOME\" python3; tmux new-session -d -s $prefix-htop -c \"\$HOME\" htop; \
tmux new-session -d -s $prefix-notes -c /tmp; tmux new-session -d -s $prefix-bell -c /tmp; \
tmux send-keys -t '=$prefix-bell:' \"printf '\\\\a'\" Enter"

began=$(mktemp "$scratch/began.XXXXXX")
dest_photographer sidebar- "$out" &
photographer=$!
result=0
# The folder the shell, vim and logs sessions show under: the checkout's own name.
TEST_RUNNER_SIDEBAR_CHECKOUT="${PWD:t}" tools/device-test.sh --locked "$name" "$@" || result=$?
for shot in "$out"/*.png(N); do
  [[ $shot -nt $began ]] && print -r -- "$shot"
done
rm -f "$began"
exit $result
