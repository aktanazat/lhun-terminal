#!/bin/zsh
# Runs the look pass on the iPad or a simulator (LHUN_DEST, tools/dest.zsh; LhunShots/LhunLook.swift):
# the compact layout, every terminal font, the palette's loose matching and Reduce Motion. It makes a
# tmux session on this Mac showing numbered lines then a sample of letters, styles and Nerd Font icons,
# then:
# - checks tmux was only ever sent sizes Lhûn held on screen for a second or more, so no terminal resized
#   while a layout moved
# - checks every pose fits with tools/fit-check.py
# - checks every card arrangement and peek with Reduce Motion on happened without animating
# - photographs each step the test holds still for, upright, into the directory given, shots/look by
#   default; it answers only this test's requests, take-look-*, and only while it holds the destination
#   tools/look.sh [dir]
# The test turns Reduce Motion on in Settings and off again, whether it passed or not.
set -euo pipefail
cd "${0:A:h}/.."
self="${0:A}"
source tools/dest.zsh
if [[ ${1:-} != --locked ]]; then
  # The build tools/device-test.sh makes. Everything after it runs inside this script's hold on the
  # destination.
  dest_build
  exec /usr/bin/lockf -k "$dest_lock" "$self" --locked "${1:-shots/look}"
fi
out="$2"
prefix=lhun-test-look
name="look-$(date +%Y%m%d-%H%M%S)"
sample="$PWD/build/look-sample.txt"
hooks="$PWD/build/$name-hooks.txt"
record="build/$name.tmux"
shots=(compact-before compact palette-nwsn font-neon font-argon font-krypton font-radon font-sfMono font-menlo
  font-xenon font-peek-menlo font-history-menlo zoom-reduce-motion peek-reduce-motion)
poller=0
photographer=0

cleanup() {
  (( poller )) && kill "$poller" 2>/dev/null || true
  (( photographer )) && kill "$photographer" 2>/dev/null || true
  # Quoted: zsh would expand a bare =name to the path of a command.
  for session in ${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^$prefix-" || true)"}; do
    tmux kill-session -t "=$session" 2>/dev/null || true
  done
  dest_release
}
trap cleanup EXIT

mkdir -p build "$out"
python3 - "$sample" <<'EOF'
import sys

CSI = "\x1b["
lines = [
    "",
    "Lhûn font sample   0O 1lI |!  {} [] ()  => != === -> <= >= :: ~~ /* */ www",
    f"{CSI}1mbold{CSI}0m  {CSI}3mitalic{CSI}0m  {CSI}1;3mbold italic{CSI}0m  {CSI}4munderlined{CSI}0m  "
    f"{CSI}31mred{CSI}0m {CSI}32mgreen{CSI}0m {CSI}34mblue{CSI}0m {CSI}33myellow{CSI}0m",
    "Nerd Font icons:  \ue0b0 \ue0b2 \ue0a0  \uf07b \uf07c \uf15b  \ue725 \ue7a8 \uf489  \U000f0219 \U000f02a2",
    "box and blocks:   ┌──┬──┐ │ab│cd│ └──┴──┘  ▁▂▃▄▅▆▇█  ⣿⣶⣤⣀  ●○◆◇",
    "wide:             漢字 かな 한글",
    "",
]
with open(sys.argv[1], "w") as file:
    file.write("\n".join(lines) + "\n")
EOF

: >| "$hooks"
for suffix in a; do
  session="$prefix-$suffix"
  tmux kill-session -t "=$session" 2>/dev/null || true
done
# A zsh that keeps no history, so what the test types stays out of yours.
tmux new-session -d -s "$prefix-a" -x 160 -y 50 zsh -f
# The status line goes off so tmux never redraws an idle screen by itself.
tmux set-option -t "=$prefix-a:" status off
# Every size a client of the sample session asks tmux for, as tmux takes it, with the time.
hook="$PWD/build/$name-hook.zsh"
print -r -- "#!/bin/zsh -f
zmodload zsh/datetime
print -r -- \"\$EPOCHREALTIME \$*\" >>${(q)hooks}" >|"$hook"
chmod +x "$hook"
tmux set-hook -t "=$prefix-a:" client-resized \
  "run-shell -b '${(q)hook} #{session_name} #{client_control_mode} #{client_width}x#{client_height}'"
tmux send-keys -t "=$prefix-a:" "clear; seq 1 300; cat ${(q)sample}" Enter
sleep 2

# tmux's clients and their sizes, five times a second, for tools/fit-check.py. Lhûn's watcher is a control
# client, with no screen, and is left out.
zmodload zsh/datetime
while true; do
  print -r -- "$EPOCHREALTIME"
  tmux list-clients -f '#{?client_control_mode,0,1}' \
    -F $'\t#{session_name}\t#{client_width}x#{client_height}\t#{client_termname}' 2>/dev/null || true
  sleep 0.2
done >>"$record" &
poller=$!

# The test asks for each screenshot with take-look-<step> and holds still until it is taken
# (dest_photographer).
for shot in $shots; do
  if [[ -e "$out/$shot.png" ]]; then mv "$out/$shot.png" ~/.Trash/"$name-$shot.png"; fi
done
dest_photographer look- "$out" &
photographer=$!

result=0
TEST_RUNNER_LOOK_PREFIX="$prefix" \
  tools/device-test.sh --locked "$name" ${LHUN_LOOK_TESTS:-LhunShots/LhunLook} || result=$?
kill "$poller" "$photographer" 2>/dev/null || true
poller=0
photographer=0

python3 tools/fit-check.py "build/$name.jsonl" "$record" >"build/$name-fit.txt" || result=1
grep -E 'FAIL|poses,' "build/$name-fit.txt" || true

python3 tools/look-check.py "build/$name.jsonl" "$hooks" "$prefix-a" || result=1

for shot in $shots; do
  if [[ -s "$out/$shot.png" ]]; then
    echo "$out/$shot.png"
  else
    echo "no screenshot of $shot"
    result=1
  fi
done
exit $result
