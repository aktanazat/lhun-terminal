#!/bin/zsh
# Proves the preview and paste upload on the iPad or a simulator (LHUN_DEST, tools/dest.zsh) against this
# Mac. Builds, then holds the destination's lock for the whole run: serves a page naming a fresh nonce with
# `python3 -m http.server 8765`, runs LhunShots/LhunRemote, empties the clipboard again, and checks this
# Mac's side:
# - the server saw the page requested from this Mac's own loopback, where sshd connects from when it
#   carries a tunnel; a request straight from the device would come from its Tailscale address. A
#   simulator shares this Mac's network, so there a request straight from the app comes from loopback too
#   and these two checks tell nothing; the sshd checks below still do
# - sshd held a connection to 8765 while the preview was open, and nothing of sshd's was connected to it
#   once the preview closed
# - each file the tests copied on the device and pasted at the prompt arrived byte for byte at the path
#   typed there, readable by this user only, including one still on its way while Lhûn left the screen
#   and came back; pasted text ran as typed, and the host's uploads were the same before and after it.
#   A simulator skips the paste tests (LhunShots/LhunRemote.swift says why), so there these checks give
#   way to one that each paste test skipped
# Screenshots and the files the tests copied land in shots/remote/; the run's uploads move from
# ~/.cache/lhun/uploads to /private/var/tmp/lhun-remote-proof/uploads/ once checked.
#   LHUN_DEVICE=<udid> tools/remote.sh    a connected device
#   LHUN_DEST=sim:<name> tools/remote.sh an existing simulator
set -euo pipefail
self="${0:A}"
cd "${0:A:h}/.."
if [[ -n ${1:-} && $1 != --locked ]]; then export LHUN_DEVICE=$1 LHUN_DEST="device:$1"; fi
source tools/dest.zsh
if [[ ${1:-} != --locked ]]; then
  # The build tools/device-test.sh makes. Its locked half runs the tests below, inside this script's lock.
  dest_build
  exec /usr/bin/lockf -k "$dest_lock" "$self" --locked
fi
proof=/private/var/tmp/lhun-remote-proof
out=shots/remote
result=build/remote.xcresult
uploads=$HOME/.cache/lhun/uploads
nonce=$(uuidgen | tr -d - | tr A-Z a-z | cut -c1-12)

# The last run's proof and pictures go to the Trash.
stamp=$(date +%Y%m%d-%H%M%S)
if [[ -e $proof ]]; then mv "$proof" ~/.Trash/"lhun-remote-proof-$stamp"; fi
if [[ -e $out ]]; then mv "$out" ~/.Trash/"lhun-remote-shots-$stamp"; fi
mkdir -p "$proof/site" "$proof/uploads" "$out"
print -r -- "<!doctype html><title>Lhun preview proof</title><h1>Lhun preview $nonce</h1>" > "$proof/site/index.html"

# Upload folders from before the run. Any other one afterwards came from it.
before=($uploads/*(N/))

tmux kill-session -t '=lhun-test-upload-serve' 2>/dev/null || true
tmux new-session -d -s lhun-test-upload-serve -c "$proof/site" "python3 -m http.server 8765 > $proof/server.log 2>&1"
watcher=""
cleanup() {
  tmux kill-session -t '=lhun-test-upload-shell' 2>/dev/null || true
  tmux kill-session -t '=lhun-test-upload-serve' 2>/dev/null || true
  [[ -z $watcher ]] || kill "$watcher" 2>/dev/null || true
  # The tests leave what they copied last on the clipboard.
  if [[ $dest_kind == sim ]]; then
    print -rn -- "" | xcrun simctl pbcopy "$dest_id" 2>/dev/null || true
  else
    print -rn -- "" | xcrun devicectl device pasteboard copy -d "$dest_id" >/dev/null 2>&1 || true
  fi
  dest_release
}
trap cleanup EXIT INT TERM
# Ready once this run's page answers on ::1, where sshd connects first for "localhost": other programs
# may listen on 8765 at other addresses. Asking for the page by name keeps this request out of the
# log check below, which counts requests for /.
served() { [[ $(curl -fsSg --max-time 1 'http://[::1]:8765/index.html' 2>/dev/null) == *"Lhun preview $nonce"* ]]; }
for _ in {1..50}; do
  served && break
  sleep 0.2
done
served || { print "this run's page never answered on [::1]:8765"; exit 1; }

# While the tests run: the first moment sshd holds a connection to the server. It shows lsof sees sshd's
# side of a tunnel, which the after-close check depends on.
(
  until lsof -nP -iTCP:8765 -sTCP:ESTABLISHED > "$proof/during.txt" 2>/dev/null && grep -q sshd "$proof/during.txt"; do
    sleep 0.2
  done
) &
watcher=$!

# The session the tests type in, fresh at an empty prompt.
tmux kill-session -t '=lhun-test-upload-shell' 2>/dev/null || true
tmux new-session -d -s lhun-test-upload-shell

# tools/device-test.sh runs the tests and removes the test runner.
tested=0
TEST_RUNNER_LHUN_NONCE=$nonce TEST_RUNNER_LHUN_PROOF_DIR=$proof \
  tools/device-test.sh --locked remote LhunShots/LhunRemote || tested=$?
xcrun xcresulttool export attachments --path "$result" --output-path "$out" >/dev/null || true
xcrun xcresulttool get test-results tests --path "$result" > "$proof/tests.json" 2>/dev/null || true
kill "$watcher" 2>/dev/null || true
watcher=""

# The exported file of the run's attachment named $1, or nothing.
attachment() {
  local file
  file=$(jq -r --arg name "$1_" \
    'first(.[].attachments[] | select(.suggestedHumanReadableName | startswith($name))) | .exportedFileName' \
    "$out/manifest.json" 2>/dev/null || true)
  if [[ -n $file ]]; then print -r -- "$out/$file"; fi
}

# A device's screenshots are of the screen as mounted, upright in portrait. Turn them the way the iPad is
# held, and name them.
turn=0
if [[ $dest_kind == device ]]; then
  case $(xcrun devicectl device orientation get --device "$dest_id" 2>/dev/null || true) in
    *landscapeLeft*) turn=270 ;;
    *landscapeRight*) turn=90 ;;
  esac
fi
for name in preview pasted-data pasted-image pasted-file pasted-back; do
  file=$(attachment "$name")
  [[ -n $file ]] || continue
  cp "$file" "$out/$name.png"
  wide=$(sips -g pixelWidth -g pixelHeight "$out/$name.png" | awk '/pixelWidth/ {w = $2} /pixelHeight/ {h = $2} END {print (w > h)}')
  if (( turn && ! wide )); then sips -r $turn "$out/$name.png" >/dev/null; fi
done

failed=0
check() {
  if eval "$2"; then print "ok    $1"; else print "FAIL  $1"; failed=1; fi
}

# How a test ended on the device, Passed or Failed, then why it failed.
outcome() {
  jq -r --arg name "$1()" \
    'first(.. | objects | select(.nodeType? == "Test Case" and .name == $name)) | [.result] + [.children[]? | select(.nodeType == "Failure Message") | .name] | join(": ")' \
    "$proof/tests.json" 2>/dev/null || true
}

# A file's SHA-256, size and mode.
describe() {
  if [[ -f $1 ]]; then
    print -r -- "$(shasum -a 256 < "$1" | cut -c1-64) $(stat -f %z "$1") bytes, mode $(stat -f %Lp "$1")"
  else
    print -r -- "missing"
  fi
}

print "server log:"; grep '"GET ' "$proof/server.log" || true
print "while open:"; cat "$proof/during.txt" 2>/dev/null || true
print "after close:"; cat "$proof/after-close.txt" 2>/dev/null || true
for test in testPreview testPastedImageData testPastedImage testPastedFile testPastedText testUploadOutlivesLeaving; do
  print -r -- "$test: $(outcome $test)"
done

check "xcodebuild found every test passed" '(( tested == 0 ))'
check "testPreview passed" '[[ $(outcome testPreview) == Passed ]]'
for test in testPastedImageData testPastedImage testPastedFile testPastedText testUploadOutlivesLeaving; do
  if [[ $dest_kind == sim ]]; then
    check "$test skipped on a simulator" '[[ $(outcome $test) == Skipped* ]]'
  else
    check "$test passed on the device" '[[ $(outcome $test) == Passed ]]'
  fi
done

check "the page was requested through this Mac's loopback" \
  'grep -qE "^(::1|127\.0\.0\.1|::ffff:127\.0\.0\.1) .*\"GET / HTTP/1\.[01]\" 200" "$proof/server.log"'
check "no request came straight from the device" \
  '! grep "\"GET " "$proof/server.log" | grep -qvE "^(::1|127\.0\.0\.1|::ffff:127\.0\.0\.1) "'
check "sshd carried a connection to the server while the preview was open" 'grep -q sshd "$proof/during.txt"'
check "the Mac's side was read after the preview closed" '[[ -f $proof/after-close.txt ]]'
check "nothing of sshd's was connected to 8765 after the preview closed" \
  '[[ -f $proof/after-close.txt ]] && ! grep -q sshd "$proof/after-close.txt"'

# Each pasted file: the path the test typed at the prompt, against the bytes it copied on the device.
if [[ $dest_kind == device ]]; then
  for name in data image file back; do
    typed=$(cat "$proof/typed-$name.txt" 2>/dev/null || true)
    copied=$(attachment "copied-$name")
    print -r -- "pasted $name: typed ${typed:-nothing}"
    print -r -- "  arrived $(describe "$typed"), folder mode $(if [[ -f $typed ]]; then stat -f %Lp "${typed:h}"; else print missing; fi)"
    print -r -- "  copied  $(describe "$copied")"
    check "pasted $name: the typed path is a new upload" \
      '[[ $typed == $uploads/*/* && -f $typed ]] && (( ! ${before[(Ie)${typed:h}]} ))'
    check "pasted $name: it has the copied bytes' SHA-256" \
      '[[ -f $typed && -f $copied && $(shasum -a 256 < "$typed") == $(shasum -a 256 < "$copied") ]]'
    check "pasted $name: it has the copied bytes' size" \
      '[[ -f $typed && -f $copied && $(stat -f %z "$typed") == $(stat -f %z "$copied") ]]'
    check "pasted $name: only this user can read or write it (600)" '[[ -f $typed && $(stat -f %Lp "$typed") == 600 ]]'
    check "pasted $name: its folder is this user's alone (700)" '[[ -f $typed && $(stat -f %Lp "${typed:h}") == 700 ]]'
  done
  check "pasted file: it kept the copied file's name" '[[ $(cat "$proof/typed-file.txt" 2>/dev/null) == */lhun-copied-file.png ]]'

  check "pasted text ran as typed" '[[ $(cat "$proof/pasted-text.txt" 2>/dev/null) == lhun-text-$nonce ]]'
  print -r -- "uploads around the text paste: before [$(paste -sd' ' "$proof/uploads-before-text.txt" 2>/dev/null)]" \
    "after [$(paste -sd' ' "$proof/uploads-after-text.txt" 2>/dev/null)]"
  check "pasted text uploaded nothing: the host's uploads were the same after it" \
    '[[ -f $proof/uploads-before-text.txt && -f $proof/uploads-after-text.txt ]] && cmp -s "$proof/uploads-before-text.txt" "$proof/uploads-after-text.txt"'
fi

# Every upload the run made, checked or cut off, moves out of the way.
after=($uploads/*(N/))
new=(${after:|before})
print -r -- "new upload folders:" ${new:t}
for folder in $new; do mv "$folder" "$proof/uploads/"; done

print "screenshots: $out/preview.png and $out/pasted-*.png; the copied files and the rest of the run's attachments are beside them"
exit $(( failed || tested ))
