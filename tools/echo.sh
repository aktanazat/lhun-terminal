#!/bin/zsh
# Proves on the iPad, or with LHUN_DEST=sim on a simulator (tools/dest.zsh), what Lhûn does over a slow
# or broken link. Each check's host side runs in lhun-test-* sessions on this Mac or on the server,
# killed when the check ends. The script builds, then holds the destination's lock for all the checks
# named, in order; each check's probe log lands in build/echo-<check>-<host>.jsonl and its screenshots in
# /private/var/tmp/lhun-shots/v5/echo/, with when each capture began and ended in shots.tsv there.
#   tools/echo.sh <check>...
#   reconnect:<mac|server>
#       Shows a still screen, then ends Lhûn's own connection to it 5 times, each time by ending the sshd
#       under Lhûn's tmux client in the session, which no other client shares, and photographs the device
#       at once. LhunEcho/testReconnectKeepsTheScreen checks that no frame drawn from the drop until 3
#       seconds after Lhûn is back showed the screen cleared or half redrawn.
#   stall:<mac|server>
#       The same, with tmux's redraw stalling partway each time, as over a slow link:
#       LhunEcho/testStalledRedrawKeepsTheScreen has the probe hold each attach's output from its 600th
#       byte on, after tmux's clear and the start of its redraw, for 2.2 s, and checks the same.
#   predict:server
#       At the server's shell, whose echo takes 80 ms or more, LhunEcho/testTypedKeysShowAheadOfTheEcho
#       checks typed keys show ahead of their echo and every one drawn is matched by it;
#       testPasswordKeysNeverShow types at a prompt reading a password, and testFullScreenKeysAreNotGuessed
#       into vim. A program on the server echoing each key as it arrives, but for the phases below where
#       it echoes nothing or letters in the other case, takes the keys testWrongGuessesGoAtOnce types, and
#       the check compares the bytes it read with the ones typed. Last, one echoing each key 8 s late is
#       photographed into predict-underline.png the moment the last key that
#       testTypedKeysShowWhileTheEchoIsAway types reaches it.
#   predict:mac
#       At this Mac's shell, whose echo comes back in about 20 ms, LhunEcho/testFastEchoShowsNothing
#       checks no typed key shows ahead of its echo; testHiddenCursorKeysAreNotGuessed types into omp,
#       which hides the cursor and draws its own, in a profile of its own moved to the Trash after.
#   omp:mac
#       Runs omp, in that profile, in three sessions on this Mac: one Lhûn sizes, one another screen sizes
#       (a client of a tmux server of its own, 107x40), and one whose connection drop_loop ends once.
#       LhunEcho/testOmpStaysInSightAsTheKeyboardComesBack opens each with the keyboard up, puts the
#       keyboard down, taps the terminal once the session is attached, and checks omp shows above the
#       keyboard; its screenshots stay in the result bundle.
set -euo pipefail
zmodload zsh/datetime
self="${0:A}"
cd "${0:A:h}/.."
source tools/dest.zsh
usage="usage: tools/echo.sh <reconnect:mac|reconnect:server|stall:mac|stall:server|predict:server|predict:mac|omp:mac>..."
# --locked: the caller holds the destination's lock, and shuts down a simulator it booted itself.
locked=0
own=0
case "${1:-}" in
  --locked) locked=1; shift ;;
  --own) locked=1 own=1; shift ;;
esac
(( $# )) || { print -u2 -- $usage; exit 64 }
checks=("$@")
for check in $checks; do
  [[ $check == (reconnect:mac|reconnect:server|stall:mac|stall:server|predict:server|predict:mac|omp:mac) ]] || { print -u2 -- $usage; exit 64 }
done
if (( ${checks[(I)*:server]} )); then dest_require_server; fi
if (( ! locked )); then
  # The build tools/device-test.sh makes; its locked half runs each check's tests inside this lock.
  dest_build
  print "built, waiting for the destination"
  exec /usr/bin/lockf -k "$dest_lock" "$self" --own "$@"
fi

shots=/private/var/tmp/lhun-shots/v5/echo
mkdir -p $shots
# Where tools/echo-host.py and its logs sit on the server while the checks run, under the home folder.
cache=.cache/lhun-test-echo

# What LhunEcho/testWrongGuessesGoAtOnce types, phase by phase, how the host answers each phase
# ("echoed": each key echoed as it arrives; "muted": never echoed; "swapped": letters echoed in the other
# case), and what the test expects of the keys guessed in it ("confirmed": shown, and every one shown
# matched; "erased": shown, and all taken away unmatched at once; "hidden": none shown). After keys were
# taken away, nothing shows until the host has echoed a letter typed since, so those phases run longer.
phases='[{"keys":"echo the quick brown fox jumps","echo":"echoed","expect":"confirmed"},{"keys":" over th","echo":"muted","expect":"erased"},{"keys":"e lazy dog","echo":"echoed","expect":"confirmed"},{"keys":"wxyz","echo":"swapped","expect":"erased"},{"keys":" fine again","echo":"echoed","expect":"confirmed"},{"keys":"\r","echo":"echoed","expect":"hidden"},{"keys":"secretword","echo":"muted","expect":"hidden"}]'
# The photograph: keys typed until the echo's delay is known, then keys photographed ahead of their echo.
# The test taps keys about 0.7 s apart on the iPad, so the photographed ones all land well inside the 8 s
# before the first of them echoes.
warmup="echo hello"
photographed=" far away"
# The omp profile testHiddenCursorKeysAreNotGuessed and omp:mac run in, so the real one's settings and
# sessions stay untouched.
omp_profile=lhun-test-predict
# omp in that profile, past its first-run setup, which fills the screen without an input line, to the chat
# he types into.
omp_test="OMP_SKIP_SETUP=1 $(whence -p omp) --profile $omp_profile --no-session --no-extensions --no-skills --no-rules --no-lsp --no-title"
# The other screen omp:mac's watched session has open: a tmux server of its own.
outer=(tmux -L lhun-test-omp-outer -f /dev/null)

made=()
dropper=0
photographer=0
cleanup() {
  if (( dropper )); then kill $dropper 2>/dev/null || true; fi
  if (( photographer )); then kill $photographer 2>/dev/null || true; fi
  $outer kill-server 2>/dev/null || true
  local entry
  for entry in $made; do on_host ${entry%% *} "tmux kill-session -t '=${entry#* }'" 2>/dev/null || true; done
  if (( ${checks[(I)*:server]} )); then
    ssh "$LHUN_SERVER" "rm -f $cache/echo-host.py $cache/phases.log $cache/photo.log && rmdir $cache" 2>/dev/null || true
  fi
  if [[ -d ~/.omp/profiles/$omp_profile ]]; then mv ~/.omp/profiles/$omp_profile ~/.Trash/$omp_profile-$EPOCHSECONDS; fi
  (( ! own )) || dest_release
}
trap cleanup EXIT

# Runs a command on a host: mac or server.
on_host() {
  if [[ $1 == server ]]; then ssh "$LHUN_SERVER" "$2"; else zsh -c "$2"; fi
}

program() {
  if [[ $1 == server ]]; then print -r -- "python3 ~/$cache/echo-host.py"; else print -r -- "python3 $PWD/tools/echo-host.py"; fi
}

# Starts a session on a host running a command, or the host's own shell without one.
start_session() {
  local where=$1 session=$2 command=${3:-}
  on_host $where "tmux kill-session -t '=$session' 2>/dev/null; tmux new-session -d -s '$session' -x 160 -y 48 ${command:+'$command'}"
  made+=("$where $session")
}

end_session() {
  on_host $1 "tmux kill-session -t '=$2'" 2>/dev/null || true
  made=(${made:#"$1 $2"})
}

# Photographs the destination's screen into $shots/<name>.png and notes when the capture began and ended.
photograph() {
  local began=$EPOCHREALTIME
  dest_screenshot "$shots/$1.png" || true
  print -r -- "$1"$'\t'"$began"$'\t'"$EPOCHREALTIME" >> $shots/shots.tsv
}

# The sshd under Lhûn's terminal client in the session, once one is attached there. A Lhûn watcher's
# control-mode client may sit in the same session; it is never the one.
lhun_sshd() {
  on_host $1 "tmux list-clients -t '=$2' -F '#{client_control_mode} #{client_pid}' 2>/dev/null |
  while read control pid; do
    [ \"\$control\" = 0 ] || continue
    parent=\$(ps -o ppid= -p \$pid | tr -d ' ')
    case \$(ps -o comm= -p \$parent) in *sshd*) echo \$parent; break;; esac
  done" 2>/dev/null || true
}

# Waits for Lhûn to attach, lets the screen settle and the probe finish with the drop before, then ends
# the connection's sshd while photographing the device into <check>-<host>-<n>.png, so the picture lands
# during the reconnect when it lasts long enough.
drop_loop() {
  local where=$1 session=$2 drops=$3 check=$4 n=0 last="" sshd
  local giveUp=$(( EPOCHSECONDS + 600 ))
  while (( n < drops && EPOCHSECONDS < giveUp )); do
    sshd="$(lhun_sshd $where $session)"
    if [[ -z $sshd || $sshd == $last ]]; then
      sleep 0.2
      continue
    fi
    sleep 5
    (( n += 1 ))
    photograph $check-$where-$n &
    on_host $where "kill $sshd" || true
    last=$sshd
    print "drop $n of $drops: ended sshd $sshd, the one under Lhûn's tmux client"
    wait
  done
}

# reconnect <host> <check> <test>: ends Lhûn's connection to a still screen 5 times while LhunEcho/<test>
# watches each reconnect, then prints what the probe saw of each.
reconnect() {
  local where=$1 check=$2 test=$3 session=lhun-test-echo-$2 run=echo-$2-$1 drops=5 result=0
  rm -f build/$run.jsonl
  start_session $where $session "$(program $where) screen"
  drop_loop $where $session $drops $check &
  dropper=$!
  TEST_RUNNER_ECHO_SESSION=$session TEST_RUNNER_ECHO_HOST=$where TEST_RUNNER_ECHO_DROPS=$drops \
    tools/device-test.sh --locked $run LhunShots/LhunEcho/$test || result=$?
  kill $dropper 2>/dev/null || true
  dropper=0
  end_session $where $session
  [[ -f build/$run.jsonl ]] || return 1
  python3 - build/$run.jsonl $shots/shots.tsv $where $check <<'EOF' || result=1
import json
import os
import sys

log, shots_path, where, check = sys.argv[1:]
samples = [json.loads(line) for line in open(log) if line.strip()]
reconnects = next((s["reconnects"] for s in reversed(samples) if "reconnects" in s), [])
drops = [s["at"] for s in samples if s.get("event", "").startswith("dropped ")]
shots = {}
if os.path.exists(shots_path):
    for line in open(shots_path):
        name, began, ended = line.rstrip("\n").split("\t")
        shots[name] = (float(began), float(ended))
for index, reconnect in enumerate(reconnects, 1):
    line = (f"reconnect {index}: back after {reconnect['liveMs']:.0f} ms, {reconnect['frames']} frames drawn, "
            f"{reconnect['broken']} cleared or half redrawn, screen as before: {reconnect['matched']}")
    shot = shots.get(f"{check}-{where}-{index}")
    if shot and index <= len(drops):
        began, ended = ((moment - drops[index - 1]) * 1000 for moment in shot)
        line += f"; its photo was taken between {began:.0f} and {ended:.0f} ms after the drop"
    print(line)
print(f"{len(reconnects)} reconnects, {sum(r['broken'] for r in reconnects)} frames drawn cleared or half redrawn")
EOF
  return $result
}

# Photographs the device into $shots/<name>.png once key N, counted from 0, is in a host's echo log,
# while its echo is on its way. Gives up when the session ends.
photograph_at() {
  local where=$1 session=$2 log=$3 index=$4 name=$5
  on_host $where "until grep -q '^r [^ ]* $index ' $log 2>/dev/null; do
    tmux has-session -t '=$session' 2>/dev/null || exit 1
    sleep 0.1
  done" 2>/dev/null || return 0
  photograph $name
}

predict_server() {
  local run=echo-predict-server prefix=lhun-test-predict result=0 part
  local phasesLog=build/$run-phases.log photoLog=build/$run-photo.log
  rm -f build/$run.jsonl $phasesLog $photoLog
  local flags=(${(f)"$(python3 -c '
import json, sys
start = 0
for phase in json.loads(sys.argv[1]):
    end = start + len(phase["keys"].encode())
    if phase["echo"] in ("muted", "swapped"):
        print("--mute" if phase["echo"] == "muted" else "--swap")
        print(f"{start}:{end}")
    start = end
' $phases)"})
  # A shell that keeps no history and reads no settings, for the sessions where the test runs commands.
  local plain="HISTFILE= bash --norc --noprofile"
  start_session server $prefix-shell
  start_session server $prefix-password $plain
  start_session server $prefix-vim $plain
  start_session server $prefix-phases "$(program server) echo --delay 0 --log ~/$cache/phases.log ${flags[*]}"
  start_session server $prefix-photo "$(program server) echo --delay 8000 --log ~/$cache/photo.log"
  photograph_at server $prefix-photo $cache/photo.log $(( ${#warmup} + ${#photographed} - 1 )) predict-underline &
  photographer=$!
  TEST_RUNNER_ECHO_SESSION=$prefix TEST_RUNNER_ECHO_HOST=server TEST_RUNNER_ECHO_PHASES=$phases \
    TEST_RUNNER_ECHO_WARMUP=$warmup TEST_RUNNER_ECHO_PHOTOGRAPHED=$photographed \
    tools/device-test.sh --locked $run LhunShots/LhunEcho/testTypedKeysShowAheadOfTheEcho \
    LhunShots/LhunEcho/testPasswordKeysNeverShow LhunShots/LhunEcho/testFullScreenKeysAreNotGuessed \
    LhunShots/LhunEcho/testWrongGuessesGoAtOnce LhunShots/LhunEcho/testTypedKeysShowWhileTheEchoIsAway || result=$?
  ssh "$LHUN_SERVER" "cat $cache/phases.log" > $phasesLog 2>/dev/null || true
  ssh "$LHUN_SERVER" "cat $cache/photo.log" > $photoLog 2>/dev/null || true
  for part in shell password vim phases photo; do end_session server $prefix-$part; done
  # With its session gone, the photographer's wait ends.
  wait $photographer 2>/dev/null || true
  photographer=0
  [[ -f build/$run.jsonl ]] || return 1
  python3 - build/$run.jsonl $prefix $phases $phasesLog $photoLog $shots/shots.tsv ${#warmup} <<'EOF' || result=1
import json
import os
import statistics
import sys

probe_path, prefix, phases_json, phases_path, photo_path, shots_path, warmup = sys.argv[1:]
warmup = int(warmup)
phases = json.loads(phases_json)
every = [json.loads(line) for line in open(probe_path) if line.strip()]


def run_of(session):
    """The probe's samples of the session's local echo; each test opens its session once."""
    return [s for s in every if "prediction" in s and s.get("selection", {}).get("name") == session]


def host_log(path):
    fields = [line.split() for line in open(path)] if os.path.exists(path) else []
    reads = [(float(f[1]), int(f[3], 16)) for f in fields if f[0] == "r"]
    echoes = {int(f[2]): float(f[1]) for f in fields if f[0] == "e"}
    return reads, echoes


def counts(p):
    return (f"guessed {p['guessed']}, shown {p['shown']}, confirmed {p['confirmed']}, "
            f"erased {p['erased']} in {p['erasures']} goes")


shell = run_of(f"{prefix}-shell")
if shell:
    final = shell[-1]["prediction"]
    delays = final["delaysMs"]
    print(f"server shell: echo delays {delays} ms, median {statistics.median(delays):g}; "
          f"typed keys show early: {final['on']}; {counts(final)}")
    frames, ms = final["drawnFrames"], final["drawnMs"]
    if frames:
        print(f"key down to its guess on screen, over {len(frames)} keys: median {statistics.median(ms):g} ms "
              f"({statistics.median(frames):g} frames), most {max(ms):g} ms ({max(frames)} frames)")
for part in ("password", "vim"):
    samples = run_of(f"{prefix}-{part}")
    if samples:
        final = samples[-1]["prediction"]
        print(f"{part}: {counts(final)}, alternate screen {final['alternateScreen']}")

typed = "".join(phase["keys"] for phase in phases).encode()
reads, _ = host_log(phases_path)
got = bytes(byte for _, byte in reads)
print(f"phases: the host read {len(got)} bytes, exactly the {len(typed)} typed: {got == typed}")
samples = run_of(f"{prefix}-phases")
# Each phase runs from its first key reaching the host (its clock) to the next phase's, read off the
# probe's samples (the iPad's clock); the test waits 3 s between phases, far longer than the clocks differ.
starts, index = [], 0
for phase in phases:
    starts.append(reads[index][0] if index < len(reads) else float("inf"))
    index += len(phase["keys"].encode())
starts.append(float("inf"))
keys = ("shown", "confirmed", "erased", "erasures")


def before(moment):
    earlier = [s for s in samples if s["at"] < moment]
    return earlier[-1]["prediction"] if earlier else dict.fromkeys(keys, 0)


for number, phase in enumerate(phases, 1):
    first, last = before(starts[number - 1]), before(starts[number])
    change = {key: last[key] - first[key] for key in keys}
    print(f"phase {number}, {phase['keys']!r} {phase['echo']}: shown {change['shown']}, "
          f"confirmed {change['confirmed']}, erased {change['erased']} in {change['erasures']} goes")

photo = run_of(f"{prefix}-photo")
if photo:
    print(f"photographed run: {counts(photo[-1]['prediction'])}")
_, echoes = host_log(photo_path)
shots = {}
if os.path.exists(shots_path):
    for line in open(shots_path):
        name, began, ended = line.rstrip("\n").split("\t")
        shots[name] = (float(began), float(ended))
shot, first_echo = shots.get("predict-underline"), echoes.get(warmup)
if shot and first_echo:
    print(f"predict-underline.png done {first_echo - shot[1]:.1f} s before the first photographed key echoed "
          f"(the server's clock against this Mac's)")
else:
    print("predict-underline.png: no photo, or the photographed keys never echoed")
EOF
  return $result
}

predict_mac() {
  local run=echo-predict-mac prefix=lhun-test-predict result=0
  rm -f build/$run.jsonl
  start_session mac $prefix-shell
  # zsh without settings keeps no history of the omp command typed into it.
  start_session mac $prefix-omp "zsh -f"
  TEST_RUNNER_ECHO_SESSION=$prefix TEST_RUNNER_ECHO_HOST=mac TEST_RUNNER_ECHO_OMP=$omp_test \
    tools/device-test.sh --locked $run LhunShots/LhunEcho/testFastEchoShowsNothing \
    LhunShots/LhunEcho/testHiddenCursorKeysAreNotGuessed || result=$?
  end_session mac $prefix-shell
  end_session mac $prefix-omp
  [[ -f build/$run.jsonl ]] || return 1
  python3 - build/$run.jsonl $prefix <<'EOF' || result=1
import json
import statistics
import sys

probe_path, prefix = sys.argv[1:]
samples = [json.loads(line) for line in open(probe_path) if line.strip()]
for part in ("shell", "omp"):
    session = [s for s in samples if "prediction" in s and s.get("selection", {}).get("name") == f"{prefix}-{part}"]
    if not session:
        print(f"{part}: no sample")
        continue
    final = session[-1]["prediction"]
    delays = final["delaysMs"]
    median = f", median {statistics.median(delays):g}" if delays else ""
    print(f"mac {part}: echo delays {delays} ms{median}; typed keys show early: {final['on']}; "
          f"guessed {final['guessed']}, shown {final['shown']}; cursor shown {final['cursorShown']}")
EOF
  return $result
}

omp_mac() {
  local run=echo-omp-mac prefix=lhun-test-omp result=0
  rm -f build/$run.jsonl
  start_session mac $prefix-shell
  local part
  for part in own watched dropped; do
    # zsh without settings keeps no history of the omp command typed into it.
    start_session mac $prefix-$part "zsh -f"
    tmux send-keys -t "=$prefix-$part:" "$omp_test" Enter
  done
  $outer new-session -d -s mac -x 107 -y 40 "env -u TMUX tmux attach -t '=$prefix-watched'"
  drop_loop mac $prefix-dropped 1 omp &
  dropper=$!
  TEST_RUNNER_ECHO_SESSION=$prefix TEST_RUNNER_ECHO_HOST=mac \
    tools/device-test.sh --locked $run LhunShots/LhunEcho/testOmpStaysInSightAsTheKeyboardComesBack || result=$?
  kill $dropper 2>/dev/null || true
  dropper=0
  $outer kill-server 2>/dev/null || true
  for part in shell own watched dropped; do end_session mac $prefix-$part; done
  return $result
}

if (( ${checks[(I)*:server]} )); then
  ssh "$LHUN_SERVER" "mkdir -p $cache && cat > $cache/echo-host.py" < tools/echo-host.py
fi
failed=0
for check in $checks; do
  print "== $check"
  case $check in
    reconnect:*) reconnect ${check#*:} reconnect testReconnectKeepsTheScreen || failed=1 ;;
    stall:*) reconnect ${check#*:} stall testStalledRedrawKeepsTheScreen || failed=1 ;;
    predict:server) predict_server || failed=1 ;;
    predict:mac) predict_mac || failed=1 ;;
    omp:mac) omp_mac || failed=1 ;;
  esac
done
exit $failed
