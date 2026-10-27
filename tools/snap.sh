#!/bin/zsh
# Photographs the screen of the iPad or a simulator (LHUN_DEST, tools/dest.zsh) into <png> <seconds> from
# now, in the background, and returns at once. A test types this into a session on this Mac just before a
# pose it holds, since XCTest cannot take a screenshot while a finger is down, and its own come out turned;
# the script that made the session gives it LHUN_DEST (tmux new-session -e). The picture's name and when
# its capture began and ended go on a line of shots.tsv beside it, for tools/peek-check.py to line up with
# the app's log. The test run already holds the destination's lock, so this takes none.
#   tools/snap.sh <png> [seconds]
zmodload zsh/datetime
out="${1:?usage: tools/snap.sh <png> [seconds]}"
delay="${2:-3}"
source "${0:A:h}/dest.zsh"
{
  sleep "$delay"
  began=$EPOCHREALTIME
  dest_screenshot "$out"
  print -r -- "${out:t:r}"$'\t'"$began"$'\t'"$EPOCHREALTIME" >> "${out:h}/shots.tsv"
} </dev/null >/dev/null 2>&1 &!
