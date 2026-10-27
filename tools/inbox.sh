#!/bin/zsh
# Runs the inbox pass (LhunShots/LhunInbox.swift) on the iPad, or on its simulator with LHUN_DEST=sim
# (tools/dest.zsh), against real sessions on both hosts, then:
# - prints what the probe saw each time the inbox opened: its rows, the screens it read, one exec per
#   host, or why a host's could not be read, and each summary asked for, with the summaries themselves
#   from the result bundle
# - prints the footprint before the inbox first opened, at its peak while it showed, and after each time it
#   closed, each the median of the once-a-second samples over the 8 seconds the test holds still before the
#   inbox opens (one sample swings by several MB on the iPad), with heap and graphics memory beside it and
#   the open terminal's card (a taller card, with the keyboard down, draws in bigger buffers); it fails when
#   showing the rows keeps more than 2 MB, or a second summary keeps more than 2 MB over what the first
#   left, on the same card
# - photographs each step the test holds still for, upright, into the directory given,
#   /private/var/tmp/lhun-shots/v5/inbox by default
#   tools/inbox.sh [dir]
# The sessions, all named lhun-test-inbox-*, are made fresh and killed afterwards. On this Mac: a shell to
# start from, a test run that failed and says so with an error progress bar, and a sync. On the server: a
# backup, and a deploy that rings the bell to ask before it goes on. The sync and the backup work until
# the test says go, so Lhûn sees them finish.
set -euo pipefail
self="${0:A}"
cd "${0:A:h}/.."
source tools/dest.zsh
dest_require_server
if [[ ${1:-} != --locked ]]; then
  # The build tools/device-test.sh makes. Its locked half runs the test below, inside this script's lock,
  # so the photographer only ever sees this run's requests.
  dest_build
  exec /usr/bin/lockf -k "$dest_lock" "$self" --locked "$@"
fi
shift
out="${1:-/private/var/tmp/lhun-shots/v5/inbox}"
server=$LHUN_SERVER
prefix=lhun-test-inbox
name="inbox-$(date +%Y%m%d-%H%M%S)"
shots=(1-strip 2-inbox 3-catch-up 4-cleared 5-palette-catch-up 6-catch-up-this-session)
photographer=0

cleanup() {
  (( photographer )) && kill "$photographer" 2>/dev/null || true
  # Quoted: zsh would expand a bare =name to the path of a command.
  for session in home build sync; do tmux kill-session -t "=$prefix-$session" 2>/dev/null || true; done
  ssh "$server" "tmux kill-session -t =$prefix-backup 2>/dev/null; tmux kill-session -t =$prefix-deploy 2>/dev/null; true" || true
}
trap 'cleanup; dest_release' EXIT
cleanup

mkdir -p build "$out"
cat >| build/inbox-build.sh <<'EOF'
cat <<'LOG'
% swift test --parallel
Building for debugging...
[1/9] Compiling LhunCore Tmux.swift
[2/9] Compiling LhunCore Inbox.swift
[3/9] Compiling LhunCore CatchUp.swift
Build complete! (14.82s)
Test Suite 'All tests' started
Test Case 'InboxTests.lastLinesPerSession' passed (0.002 seconds)
Test Case 'InboxTests.wordsInLine' passed (0.001 seconds)
Test Case 'InboxTests.excerptKeepsTheNewest' started
Tests/InboxTests.swift:44: error: expected lines.count == 200, got 198
Test Case 'InboxTests.excerptKeepsTheNewest' failed (0.004 seconds)
Test Case 'InboxTests.tidiedSummary' passed (0.003 seconds)
Executed 48 tests, with 1 failure (0 unexpected) in 2.913 seconds
error: 1 of 48 tests failed
LOG
# An error progress bar, the mark a failed run leaves.
printf '\033]9;4;2;100\033\\'
exec env PS1='%# ' zsh -f
EOF
# head waits in front of the shell, a command at work, until the test's go sends it a line.
cat >| build/inbox-sync.sh <<'EOF'
set -m
cat <<'LOG'
% rsync -a --delete --info=stats1 ~/src/example/data/ ~/Backups/example/
sending incremental file list
LOG
head -n 1 >/dev/null
cat <<'LOG'
Number of files: 48,213 (reg: 47,902, dir: 311)
Number of regular files transferred: 1,204
Total transferred file size: 3.21G bytes
sent 3.22G bytes  received 23.10K bytes  64.40M bytes/sec
total size is 412.63G  speedup is 128.11
LOG
exec env PS1='%# ' zsh -f
EOF
backup=$(cat <<'EOF'
set -m
cat <<'LOG'
# restic -r /mnt/backup/restic backup /srv --tag nightly
repository 2f6c1a3e opened (version 2, compression level auto)
using parent snapshot 4f1c2a7e
LOG
head -n 1 >/dev/null
cat <<'LOG'
Files:        1204 new,    37 changed,  9871 unmodified
Dirs:          112 new,    25 changed,   803 unmodified
Added to the repository: 1.204 GiB (1.031 GiB stored)
processed 11112 files, 18.433 GiB in 0:41
snapshot 9b2d71c0 saved
LOG
exec env PS1='\$ ' bash --norc
EOF
)
deploy=$(cat <<'EOF'
cat <<'LOG'
# ./deploy production
Building release 2026.10.08-1... done
Uploading 3 artifacts to production... done
Pending migrations:
  0042_add_inbox_marks
  0043_backfill_marks
  0044_drop_old_flags
LOG
printf 'Apply 3 migrations to the production database? [y/N] \a'
read -r answer
exec env PS1='\$ ' bash --norc
EOF
)

# The status line goes off so tmux never redraws an idle screen by itself.
here() {
  tmux new-session -d -s "$prefix-$1" -x 160 -y 50 "$2"
  tmux set-option -t "=$prefix-$1:" status off
}
# The script goes to the server as base64, so no quoting has to survive the trip.
there() {
  local script=$(print -r -- "$2" | base64 | tr -d '\n')
  ssh "$server" "tmux new-session -d -s $prefix-$1 -x 160 -y 50 'bash --norc -c \"\$(echo $script | base64 -d)\"' && tmux set-option -t =$prefix-$1: status off"
}
# The backup comes first, so the server's watcher keeps it, with no bell, as the session it watches from.
there backup "$backup"
there deploy "$deploy"
# A zsh that keeps no history, so nothing typed here reaches yours.
here home "env PS1='%# ' zsh -f"
here build "/bin/bash --norc $PWD/build/inbox-build.sh"
here sync "/bin/bash --norc $PWD/build/inbox-sync.sh"
sleep 2

# The test asks for each step with an empty file, take-inbox-<step>, in its runner's Documents, and holds
# still until taken-inbox-<step> comes back: a screenshot, or for go, the backup let go and the sync three
# seconds later. Requests without the inbox- prefix belong to other tools and stay unanswered. The picture
# comes out the way the iPad is held; XCTest's come out on their side. Until the runner is installed
# nothing lists.
for shot in $shots; do
  if [[ -e "$out/$shot.png" ]]; then mv "$out/$shot.png" ~/.Trash/"$name-$shot.png"; fi
done
runner=com.aktanazat.lhun.shots.xctrunner
answer="build/$name-taken"
: >| "$answer"
{
  taken=()
  while true; do
    if ! names=$(dest_files $runner Documents); then
      sleep 2
      continue
    fi
    for shot in ${(f)"$(sed -n 's/^take-inbox-//p' <<<"$names")"}; do
      (( ${taken[(Ie)$shot]} )) && continue
      taken+=("$shot")
      if [[ $shot == go ]]; then
        ssh "$server" "tmux send-keys -t =$prefix-backup: Enter" && sleep 3 && tmux send-keys -t "=$prefix-sync:" Enter
      else
        dest_screenshot "$out/$shot.png"
      fi && dest_copy_to $runner "$answer" "Documents/taken-inbox-$shot" || true
    done
    sleep 0.5
  done
} &
photographer=$!

result=0
tools/device-test.sh --locked "$name" LhunShots/LhunInbox || result=$?
kill "$photographer" 2>/dev/null || true
photographer=0
rm -f "$answer"

for shot in $shots; do
  [[ -f "$out/$shot.png" ]] && echo "$out/$shot.png" || { echo "no $shot.png"; result=1; }
done
xcrun xcresulttool get test-results activities --path "build/$name.xcresult" --test-id "LhunInbox/testInbox()" \
  --compact 2>/dev/null | jq -r '.. | objects | .title? // empty | select(startswith("summary of "))' || true

python3 - "build/$name.jsonl" <<'EOF' || result=1
import json
import statistics
import sys

MB = 1024 * 1024
log = [json.loads(line) for line in open(sys.argv[1]) if line.strip()]
launches = [index for index, sample in enumerate(log) if sample.get("event") == "launch"]
samples = log[launches[-1]:] if launches else log
events = [(index, sample["event"]) for index, sample in enumerate(samples) if sample.get("event")]
for index, event in events:
    sample = samples[index]
    if event == "inbox":
        pinned = ", the open session first" if sample.get("inboxPinned") else ""
        print(f"{sample['t']:6.1f} s  inbox opened with {sample['inboxRows']} rows{pinned}")
    elif event == "inbox lines" and "linesError" in sample:
        print(f"{sample['t']:6.1f} s    could not read the screens on {sample['linesHost']}: {sample['linesError']}")
    elif event == "inbox lines":
        print(f"{sample['t']:6.1f} s    read {sample['linesSessions']} screens on {sample['linesHost']} "
              f"in one exec: {sample['linesBytes']} bytes")
    elif event == "catch up":
        details = ", ".join(f"{key[7:]} {sample[key]}" for key in sorted(sample) if key.startswith("catchUp") and key != "catchUp")
        print(f"{sample['t']:6.1f} s    catch up: {sample['catchUp']}; {details}")
    elif event == "inbox closed":
        print(f"{sample['t']:6.1f} s  inbox closed")
opened = [index for index, event in events if event == "inbox"]
closed = [index for index, event in events if event == "inbox closed"]
if len(opened) < 4 or len(closed) < 3 or not opened[0] < closed[0] < opened[1] < closed[1] < opened[2] < closed[2] < opened[3]:
    sys.exit("the probe log lacks the inbox opening and closing three times, then opening again")
if any(event.startswith("open ") for index, event in events if closed[0] < index < opened[3]):
    sys.exit("a session opened between the inbox first closing and opening a fourth time")

def held(index):
    """The once-a-second samples of the 8 seconds the test held still before `index`, which no event caught
    halfway through a change."""
    t = samples[index]["t"]
    found = [s for s in samples[:index] if not s.get("event") and t - 8 <= s["t"] < t]
    if len(found) < 5:
        sys.exit(f"only {len(found)} samples in the 8 seconds before {t:.1f} s; the median needs 5")
    return found

def card(sample):
    """The terminal card on screen, the focused one first, in points: the bigger it is, the bigger the
    buffers Metal draws it in."""
    grids = sorted(sample.get("grids", []), key=lambda grid: not grid.get("focused"))
    return tuple(grids[0]["card"]) if grids else ()

def shown(card):
    return "a " + "x".join(f"{side:.0f}" for side in card) + " pt card" if card else "no card"

def median(rows, key):
    values = [row[key] for row in rows if key in row]
    return statistics.median(values) / MB if values else float("nan")

# Before the inbox first opens; after it opened, read the screens and closed; after it opened again,
# wrote a summary and closed; after it wrote a second summary and closed.
points = [("before the inbox first opened", held(opened[0])), ("after it showed its rows and closed", held(opened[1])),
          ("after it wrote a summary and closed", held(opened[2])), ("after a second summary", held(opened[3]))]
print("footprint, heap and graphics, MB, median of the samples held still at each point (lowest-highest footprint):")
for name, rows in points:
    print(f"  {name:<38} {median(rows, 'footprint'):6.1f} ({min(r['footprint'] for r in rows) / MB:.1f}-"
          f"{max(r['footprint'] for r in rows) / MB:.1f})  {median(rows, 'heap'):6.1f}  {median(rows, 'graphics'):6.1f}  "
          f"{len(rows)} samples, {shown(card(rows[-1]))}")
peak = max(sample["footprint"] for sample in samples[opened[0]:closed[2] + 1])
print(f"  {peak / MB:.1f} MB at most while it showed")
first = card(points[0][1][0])
if any(len(card(sample)) != 2 or any(abs(a - b) > 2 for a, b in zip(first, card(sample))) for _, rows in points for sample in rows):
    sys.exit("the terminal's card changed size between the samples, so their footprints don't compare")
before, rows, after, again = (median(taken, "footprint") for _, taken in points)
if rows - before > 2:
    sys.exit(f"{rows - before:.1f} MB stayed after the inbox closed, past the 2 MB it may")
# The first summary loads the on-device model's framework, which may keep a cache of its own. That may stay
# once, but a second summary must not add to it.
print(f"the first summary left {after - before:.1f} MB")
if again - after > 2:
    sys.exit(f"{again - after:.1f} MB more stayed after a second summary, past the 2 MB it may")
EOF
exit $result
