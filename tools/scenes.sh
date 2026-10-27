#!/bin/zsh
# Photographs Lhûn for the side-by-side sheet and in the iPad's own windows (LhunShots/LhunScenes.swift):
# - scenes: in landscape and then in portrait, as <dir>/<scene>-<landscape|portrait>.png: 1-omp, an omp
#   session; 2-claude, Claude Code at its idle screen; 3-split, two cards side by side; 4-palette, the
#   palette open over them
# - windows: Lhûn in a window sized by dragging its corner handle, the smallest it goes, a third of the screen
#   wide and half of it, with omp and a session split off it with ⌘D side by side, in landscape and then in
#   portrait, as <dir>/window-<smallest|third|half>[-palette]-<landscape|portrait>.png; the test chooses
#   Windowed Apps in Settings. Afterwards, pass or fail, and before the lock goes, Full Screen Apps is chosen
#   again and Lhûn comes back filling the screen, as <dir>/full-screen.png
# The sessions it makes on this Mac go afterwards. They are named lhun-test-sim-*, as the sheet's pictures
# show them, or lhun-test-win-* when only the windows run, so those never meet the sessions of scenes
# another destination runs at the same time:
# - <prefix>-omp: omp in this checkout, in an empty profile of its own, so it signs in nowhere, starts no
#   servers and saves no session
# - <prefix>-claude, for the scenes: Claude Code in an empty folder, which it is told to trust; nothing is
#   typed into it, so it sends no prompt
# - <prefix>-log, for the scenes: git's log of this checkout
# - <prefix>-omp-2, in the windows: a shell in omp's folder, which Lhûn opens as it splits omp's card
# - <prefix>-bell, in the windows: a shell that rang a bell nobody has seen, so the strip carries the inbox's
#   glyph and leaves the host chip the least room it gets
#   tools/scenes.sh <dir> [light|dark] [scenes|windows]...   both by default; the appearance needs a
#                                                             simulator (LHUN_DEST, tools/dest.zsh)
# LHUN_SCENES_PREFIX gives this run its own tmux session names.
set -euo pipefail
cd "${0:A:h}/.."
self="${0:A}"
source tools/dest.zsh
usage="usage: tools/scenes.sh <dir> [light|dark] [scenes|windows]..."
locked=0
if [[ ${1:-} == --locked ]]; then
  locked=1
  shift
fi
out="${1:?$usage}"
appearance=${2:-}
parts=(${@[3,-1]})
(( $#parts )) || parts=(scenes windows)
[[ -z $appearance || $appearance == (light|dark) ]] || { print -u2 "$usage"; exit 64; }
tests=()
shots=()
for part in $parts; do
  case $part in
    scenes)
      tests+=(LhunShots/LhunScenes/testScenes)
      shots+=({1-omp,2-claude,3-split,4-palette}-{landscape,portrait}) ;;
    windows)
      tests+=(LhunShots/LhunScenes/testWindows)
      shots+=(window-{smallest,third,half}{,-palette}-{landscape,portrait} full-screen) ;;
    *) print -u2 "$usage"; exit 64 ;;
  esac
done
if (( ! locked )); then
  dest_build
  exec /usr/bin/lockf -k "$dest_lock" "$self" --locked "${out:A}" "$appearance" $parts
fi
[[ -z $appearance ]] || export LHUN_APPEARANCE=$appearance
if (( ${parts[(Ie)scenes]} )); then prefix=lhun-test-sim; else prefix=lhun-test-win; fi
prefix=${LHUN_SCENES_PREFIX:-$prefix}
profile=$prefix
empty=/private/var/tmp/lhun-sim/claude-empty
# omp and the log show this checkout.
work=$PWD
name="scenes-$(date +%Y%m%d-%H%M%S)"
photographer=0

# Quoted targets: zsh would expand a bare =name to the path of a command. A split card's session is named
# after the one it split, with a number.
clear_fixtures() {
  local session
  for session in ${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"}; do
    [[ $session == $prefix-(omp|claude|log|bell)(|-<->) ]] && tmux kill-session -t "=$session" 2>/dev/null || true
  done
  if [[ -d ~/.omp/profiles/$profile ]]; then mv ~/.omp/profiles/$profile ~/.Trash/"$profile-$(date +%s)"; fi
}
# The windows leave Windowed Apps chosen and Lhûn's window short of the screen, and every later test would
# meet both; this puts Full Screen Apps back with Lhûn filling the screen, pass or fail, while the lock is
# still held. It runs once, after the tests or else on the way out.
restored=1
(( ${parts[(Ie)windows]} )) && restored=0
full_screen() {
  restored=1
  TEST_RUNNER_SCENES_PREFIX=$prefix tools/device-test.sh --locked "$name-full-screen" LhunShots/LhunScenes/testFullScreen
}
cleanup() {
  (( restored )) || full_screen || print -u2 "Full Screen Apps may not be chosen again; run LhunScenes/testFullScreen"
  (( photographer )) && kill "$photographer" 2>/dev/null || true
  clear_fixtures
  dest_release
}
clear_fixtures
trap cleanup EXIT
# zsh runs the cleanup on a signal only through an exit of its own.
trap 'exit 130' INT TERM HUP
mkdir -p "$out" "$empty"
for shot in $shots; do
  if [[ -e $out/$shot.png ]]; then mv "$out/$shot.png" ~/.Trash/"$name-$shot.png"; fi
done

tmux new-session -d -s "$prefix-omp" -x 160 -y 50 -c "$work" \
  "omp --profile=$profile --no-session --no-extensions --no-skills --no-rules --no-lsp"
(( ${parts[(Ie)scenes]} )) && tmux new-session -d -s "$prefix-log" -x 160 -y 50 -c "$work" "git --no-pager log --oneline --graph -30; exec zsh"
(( ${parts[(Ie)scenes]} )) && tmux new-session -d -s "$prefix-claude" -x 160 -y 50 -c "$empty" claude
(( ${parts[(Ie)windows]} )) && tmux new-session -d -s "$prefix-bell" -x 160 -y 50 -c "$work" "printf '\a'; exec zsh -f"
for suffix in omp claude log; do
  # The status line goes off so tmux never redraws an idle screen by itself.
  tmux set-option -t "=$prefix-$suffix:" status off 2>/dev/null || true
done
# A new profile opens omp's setup; Escape skips each step until the input line shows.
for _ in {1..20}; do
  tmux capture-pane -p -t "=$prefix-omp:" | grep -q 'thinking effort' && break
  tmux send-keys -t "=$prefix-omp:" Escape
  sleep 1
done
tmux capture-pane -p -t "=$prefix-omp:" | grep -q 'thinking effort' || { print -u2 "omp never showed its input line"; exit 1; }
if (( ${parts[(Ie)scenes]} )); then
  # Claude Code first asks whether to trust a folder it has not seen, with "No, exit" chosen; Down picks
  # "Yes, I trust this folder".
  claude_shows() { tmux capture-pane -p -t "=$prefix-claude:" | grep -qE "$1"; }
  for _ in {1..20}; do
    claude_shows 'trust this folder|Claude Code v' && break
    sleep 1
  done
  if claude_shows 'trust this folder'; then
    tmux send-keys -t "=$prefix-claude:" Down
    sleep 1
    tmux send-keys -t "=$prefix-claude:" Enter
  fi
  for _ in {1..20}; do
    claude_shows 'Claude Code v' && break
    sleep 1
  done
  claude_shows 'Claude Code v' || { print -u2 "Claude Code never showed its idle screen"; exit 1; }
fi

dest_photographer scenes- "$out" &
photographer=$!
result=0
TEST_RUNNER_SCENES_PREFIX=$prefix tools/device-test.sh --locked "$name" $tests || result=$?
(( restored )) || full_screen || result=$?
for shot in $shots; do
  if [[ -s $out/$shot.png ]]; then print -r -- "$out/$shot.png"; else print "no picture of $shot"; result=1; fi
done
exit $result
