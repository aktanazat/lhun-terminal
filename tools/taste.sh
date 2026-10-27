#!/bin/zsh
# Photographs every surface of Lhûn outside the terminal's own grid, in light and then in dark, on the
# destination tools/dest.zsh names (LHUN_DEST; unset, the iPad): the device key, the empty screen, a
# session, two cards, the key row, the menus, renaming and killing a session, the palette, its fonts, the
# themes, renaming a window, the port to preview, the inbox and a catch-up, the path pickers, the
# pulled-down pictures and, on an iPad, the sidebar (LhunShots/TasteShots.swift). The sessions it shows are
# its own, made on this Mac and killed when it ends: lhun-test-taste-shell, a shell in a small project with
# a second window, lhun-test-taste-job, running sleep, and lhun-test-taste-done, which printed a test run
# and reported it done. Pictures land in dir, build/taste unless named, as
# <order>-<surface>-<light|dark>.png; the ones a run before left there go to the Trash. Prints the
# pictures taken, then the result bundle's path. --locked runs under the lock its caller holds and does
# not build.
#
#   tools/taste.sh [--locked] [dir]
set -euo pipefail
cd "${0:A:h}/.."
self="${0:A}"
source tools/dest.zsh

if [[ ${1:-} != --locked ]]; then
  dest_build
  exec /usr/bin/lockf -k "$dest_lock" "$self" --locked "${1:-build/taste}"
fi
out=${${2:-build/taste}:A}
mkdir -p "$out"

prefix=lhun-test-taste
name="taste-$(date +%Y%m%d-%H%M%S)"
scratch=/private/var/tmp/lhun-taste-run
work=$scratch/work
photographer=0

kill_sessions() {
  local session
  for session in ${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null | grep "^$prefix-" || true)"}; do
    tmux kill-session -t "=$session" 2>/dev/null || true
  done
}

cleanup() {
  if (( photographer )); then kill $photographer 2>/dev/null || true; fi
  kill_sessions
  dest_release
}
trap cleanup EXIT

# Sessions a run before left behind.
kill_sessions

rm -rf "$work"
mkdir -p "$work/src" "$work/tests" "$scratch/bin"
print -r -- '# Notes

- Summary card: tighten the spacing after the contrast pass.
- Inbox: keep the order stable while a screen is read.' >"$work/notes.md"
print -r -- 'Compiling app.swift, model.swift
Linking app
Build complete (4.81s)' >"$work/build.log"
print -r -- 'import Foundation

@main
struct App {
    static func main() {
        print(Model().greeting)
    }
}' >"$work/src/app.swift"
print -r -- 'struct Model {
    var greeting: String { "hello" }
}' >"$work/src/model.swift"
print -r -- 'import XCTest

final class AppTests: XCTestCase {
    func testGreeting() {
        XCTAssertEqual(Model().greeting, "hello")
    }
}' >"$work/tests/app-tests.swift"
print -r -- "Building for debugging...
Build complete! (3.92s)
Test Suite 'All tests' started.
Test Suite 'AppTests' started.
Test Case 'AppTests.testGreeting' passed (0.004 seconds).
Test Case 'AppTests.testLaunch' passed (0.412 seconds).
Test Case 'AppTests.testSummaryCard' passed (0.118 seconds).
Test Suite 'AppTests' passed.
	 Executed 48 tests, with 0 failures (0 unexpected) in 6.204 (6.311) seconds
Test Suite 'All tests' passed.
	 Executed 48 tests, with 0 failures (0 unexpected) in 6.204 (6.312) seconds" >"$scratch/done.log"

# The done session reports its state as a program would, through lhun-tap (tools/status).
cc -O2 -o "$scratch/bin/lhun-tap" tools/status/status.c tools/status/lhun-tap.c

tmux new-session -d -s "$prefix-shell" -x 160 -y 50 -c "$work" "env PS1='%1~ %# ' zsh -f"
tmux set-option -t "=$prefix-shell:" status off
tmux send-keys -t "=$prefix-shell:" 'clear; ls' Enter
tmux new-window -d -t "=$prefix-shell:" -c "$work" "env PS1='%1~ %# ' zsh -f"

tmux new-session -d -s "$prefix-job" -x 160 -y 50 -c "$work" "env PS1='%1~ %# ' zsh -f"
tmux set-option -t "=$prefix-job:" status off
tmux send-keys -t "=$prefix-job:" 'sleep 3600' Enter

tmux new-session -d -s "$prefix-done" -x 160 -y 50 -c "$work" \
  "sleep 1; cat $scratch/done.log; printf '\\033]7501;%s\\007' 'state=done:msg=$(print -rn -- 'All 48 tests passed' | base64)'; exec env PS1='%# ' zsh -f"
tmux set-option -t "=$prefix-done:" status off
tmux pipe-pane -O -t "=$prefix-done:" "exec $scratch/bin/lhun-tap #{q:socket_path} #{pane_id} #{pane_pid}"
sleep 2

for f in "$out"/[0-9][0-9]-*-(light|dark).png(N); do
  mv "$f" ~/.Trash/"$name-${f:t}"
done

began=$(mktemp "$scratch/began.XXXXXX")
dest_photographer taste- "$out" &
photographer=$!
result=0
TEST_RUNNER_TASTE_PREFIX="$prefix" tools/device-test.sh --locked "$name" LhunShots/TasteShots || result=$?
kill $photographer 2>/dev/null || true
photographer=0

for f in "$out"/*.png(N); do
  if [[ $f -nt $began ]]; then print -r -- "$f"; fi
done
rm -f "$began"
print -r -- "$PWD/build/$name.xcresult"
exit $result
