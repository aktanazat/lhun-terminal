#!/bin/zsh
# Checks session marks on a connected device after leaving a session (LhunShots/LhunRemark.swift),
# against three quiet zsh sessions on this Mac, lhun-test-remark-a, -b and -c, made fresh and killed
# afterwards. The result bundle and the probe log land in build/remark.*.
#   tools/remark.sh [--locked] [test]...    every LhunRemark test unless tests are named
# --locked: the caller already holds the iPad lock and has built, as tools/device-test.sh --locked expects.
set -euo pipefail
cd "${0:A:h}/.."
source tools/dest.zsh
prefix=lhun-test-remark
sessions=(a b c)
locked=()
if [[ ${1:-} == --locked ]]; then
  locked=(--locked)
  shift
fi
tests=("$@")
(( $#tests )) || tests=(LhunShots/LhunRemark)

cleanup() {
  # Quoted: zsh would expand a bare =name to the path of a command.
  for session in $sessions; do tmux kill-session -t "=$prefix-$session" 2>/dev/null || true; done
}
trap cleanup EXIT
cleanup
# A zsh that reads no startup files and saves no history, so fixture commands stay out of yours. The
# status line goes off so tmux never redraws an idle screen by itself.
for session in $sessions; do
  tmux new-session -d -s "$prefix-$session" -x 160 -y 50 "env PS1='%# ' zsh -f"
  tmux set-option -t "=$prefix-$session:" status off
done
tools/device-test.sh $locked remark "${tests[@]}"
