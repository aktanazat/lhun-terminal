#!/bin/zsh
# Checks Lhûn's session work on the iPad or a simulator (LHUN_DEST, tools/dest.zsh;
# LhunShots/SessionsShots.swift) through tools/device-test.sh. The Mac session lhun-test-sessions-shell
# takes the screenshots: a test types tools/snap.sh into its shell, and the Mac keeps the screen, upright,
# in /private/var/tmp/lhun-shots/v5/sessions. lhun-test-sessions-win has windows alpha, beta and gamma,
# alpha shown; what tmux says of them is printed before and after the run. Afterwards, pass or fail, the
# lhun-test-sessions-* sessions go on both hosts, and so do the server sessions the run opened;
# tools/device-test.sh kills the Mac's.
#   tools/sessions.sh <name> <test>...   e.g. tools/sessions.sh names LhunShots/SessionsShots/testNewSessionsGetTwoWordNames
set -euo pipefail
cd "${0:A:h}/.."
source tools/dest.zsh
dest_require_server
(( $# >= 2 )) || { print -u2 "usage: tools/sessions.sh <name> <test>..."; exit 64; }
name="sessions-$1"
shift
prefix=lhun-test-sessions
out=/private/var/tmp/lhun-shots/v5/sessions
mkdir -p "$out"

server_sessions() {
  ssh "$LHUN_SERVER" "tmux list-sessions -F '#{session_name}' 2>/dev/null || true"
}
server_before=(${(f)"$(server_sessions)"})

windows() {
  tmux list-windows -t "=$prefix-win" -F '#{window_index} #{window_name}#{?window_active, (shown),}' | paste -sd, -
}

cleanup() {
  print "windows after: $(windows 2>&1)"
  local session gone=()
  for session in ${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"}; do
    if [[ $session == $prefix-* ]]; then tmux kill-session -t "=$session"; fi
  done
  local opened=(${(f)"$(grep -o '"event":"open [^"]*"' "build/$name.jsonl" 2>/dev/null | sed -e 's/^"event":"open //' -e 's/"$//' || true)"})
  for session in ${(f)"$(server_sessions)"}; do
    if [[ $session == $prefix-* ]] || { (( ${opened[(Ie)$session]} )) && (( ! ${server_before[(Ie)$session]} )); }; then
      gone+=("$session")
    fi
  done
  if (( $#gone )); then
    local list=${(j: :)${(q)gone}}
    ssh "$LHUN_SERVER" "for s in $list; do tmux kill-session -t \"=\$s\"; done" || true
  fi
  print "killed on the server: ${gone:-none}"
}
trap cleanup EXIT

tmux new-session -d -s "$prefix-shell" -c "$PWD" -e "LHUN_DEST=${LHUN_DEST-}"
tmux new-session -d -s "$prefix-win" -n alpha -c "$PWD"
tmux new-window -d -t "=$prefix-win:" -n beta -c "$PWD"
tmux new-window -d -t "=$prefix-win:" -n gamma -c "$PWD"
print "windows before: $(windows)"
export TEST_RUNNER_SESSIONS_SNAP="$PWD/tools/snap.sh" TEST_RUNNER_SESSIONS_SHOTS="$out"
tools/device-test.sh "$name" "$@"
