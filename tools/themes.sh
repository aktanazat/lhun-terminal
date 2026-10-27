#!/bin/zsh
# Runs the themes pass on the iPad or a simulator (LHUN_DEST, tools/dest.zsh; LhunShots/LhunThemeShots.swift):
# the theme picker trying each theme as its highlight reaches it, Esc and Return, each appearance's own
# pick kept through a relaunch, the Mac's Ghostty theme, the appearance rows and each host's look. It
# makes lhun-test-themes-a on this Mac and lhun-test-themes-h on the server, both showing
# tools/visible-pattern.sh, writes a Ghostty config naming Rose Pine Dawn and Rose Pine for the picker to
# read in place of the Mac's own, and photographs each step the test holds still for, upright, into the
# directory given, shots/themes by default; it answers only this test's requests, take-themes-*, and only
# while it holds the destination.
#   tools/themes.sh [dir]
# The tests save Mies, Match iPad and each host's usual look again when they end, and put the
# appearance back, whether they passed or not.
set -euo pipefail
cd "${0:A:h}/.."
self="${0:A}"
source tools/dest.zsh
dest_require_server
if [[ ${1:-} != --locked ]]; then
  # The build tools/device-test.sh makes. Everything after it runs inside this script's hold on the
  # destination.
  dest_build
  exec /usr/bin/lockf -k "$dest_lock" "$self" --locked "${1:-shots/themes}"
fi
out="$2"
prefix=lhun-test-themes
server=$LHUN_SERVER
name="themes-$(date +%Y%m%d-%H%M%S)"
ghostty="$PWD/build/$name-ghostty.conf"
# On the server, from its home folder.
pattern=".cache/$prefix-pattern.sh"
shots=(picker-dark kept-dark picker-light kept-light ghostty-dark ghostty-light appearance-dark appearance-light
  host-mac-dark host-server-dark host-server-light host-mac-theme-light)
photographer=0

cleanup() {
  (( photographer )) && kill "$photographer" 2>/dev/null || true
  # Quoted: zsh would expand a bare =name to the path of a command.
  tmux kill-session -t "=$prefix-a" 2>/dev/null || true
  ssh "$server" "tmux kill-session -t '=$prefix-h' 2>/dev/null; rm -f $pattern" 2>/dev/null || true
  dest_release
}
trap cleanup EXIT

mkdir -p build "$out"
print -r -- "theme = light:Rose Pine Dawn,dark:Rose Pine" >|"$ghostty"

# A zsh that keeps no history, so what the test types stays out of yours. The status line goes off so
# tmux never redraws an idle screen by itself.
tmux kill-session -t "=$prefix-a" 2>/dev/null || true
tmux new-session -d -s "$prefix-a" -x 160 -y 50 zsh -f
tmux set-option -t "=$prefix-a:" status off
tmux send-keys -t "=$prefix-a:" "clear; zsh -f tools/visible-pattern.sh" Enter
ssh "$server" "mkdir -p .cache && cat >$pattern" <tools/visible-pattern.sh
ssh "$server" "tmux kill-session -t '=$prefix-h' 2>/dev/null
  tmux new-session -d -s $prefix-h -x 160 -y 50 'bash --norc --noprofile' &&
  tmux set-option -t '=$prefix-h:' status off &&
  tmux send-keys -t '=$prefix-h:' 'clear; bash $pattern' Enter"
sleep 2

# The test asks for each screenshot with take-themes-<step> and holds still until it is taken
# (dest_photographer).
for shot in $shots; do
  if [[ -e "$out/$shot.png" ]]; then mv "$out/$shot.png" ~/.Trash/"$name-$shot.png"; fi
done
dest_photographer themes- "$out" &
photographer=$!

result=0
TEST_RUNNER_THEMES_PREFIX="$prefix" TEST_RUNNER_THEMES_GHOSTTY="$ghostty" \
  tools/device-test.sh --locked "$name" ${LHUN_THEMES_TESTS:-LhunShots/LhunThemeShots} || result=$?
kill "$photographer" 2>/dev/null || true
photographer=0

for shot in $shots; do
  if [[ -s "$out/$shot.png" ]]; then
    echo "$out/$shot.png"
  else
    echo "no screenshot of $shot"
    result=1
  fi
done
exit $result
