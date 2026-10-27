#!/bin/zsh
# Runs every check in LhunShots/LhunChecks in one run on a connected device: the arrow keys, the keyboard
# shortcuts, the command palette, a program's copy reaching the clipboard and taps on web addresses.
# The checks need three sessions on the Mac; this makes them as lhun-test-checks-1 to -3, each a zsh that
# keeps no history, with tmux's status line off, and serves a page titled "Lhun checks page" on this
# Mac's port 8779 from a fourth, lhun-test-checks-page, for the link that opens in Lhûn's preview. Every
# lhun-test-checks-* session is killed afterwards, the ones the checks started included, also when the run
# fails. The checks' screenshots land in the output folder and the result's summary prints at the end.
#   tools/checks.sh <output dir>          every check
#   tools/checks.sh <output dir> <test>   one of them, e.g. testLinks
# Set LHUN_DEVICE=<udid> or LHUN_DEST=sim:<name>, and pair this Mac in Lhûn first.
set -euo pipefail
cd "${0:A:h}/.."
source tools/dest.zsh
out="${1:?usage: tools/checks.sh <output dir> [test]}"
page=/private/var/tmp/lhun-test-checks-page
export TEST_RUNNER_LHUN_CHECKS_PORT=8779

cleanup() {
  local session
  for session in ${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"}; do
    if [[ "$session" == lhun-test-checks-* ]]; then
      tmux kill-session -t "=$session" 2>/dev/null || true
    fi
  done
  rm -rf "$page"
}
trap cleanup EXIT
cleanup
for session in lhun-test-checks-{1..3}; do
  tmux new-session -d -s "$session" zsh -f
  tmux set-option -t "=$session:" status off
done
mkdir -p "$page"
print -r -- "<!doctype html><title>Lhun checks page</title><h1>Lhun checks page</h1>" > "$page/index.html"
tmux new-session -d -s lhun-test-checks-page -c "$page" "python3 -m http.server $TEST_RUNNER_LHUN_CHECKS_PORT"
served() { [[ $(curl -fsS --max-time 1 "http://localhost:$TEST_RUNNER_LHUN_CHECKS_PORT/" 2>/dev/null) == *"Lhun checks page"* ]]; }
for _ in {1..50}; do
  served && break
  sleep 0.2
done
served || { print "the page never answered on port $TEST_RUNNER_LHUN_CHECKS_PORT"; exit 1; }

name="checks-$(date +%Y%m%d-%H%M%S)"
code=0
tools/device-test.sh "$name" "LhunShots/LhunChecks${2:+/$2}" || code=$?
result="build/$name.xcresult"
[[ -d "$result" ]] || exit $code
attachments="build/$name-attachments"
mkdir -p "$out" "$attachments"
xcrun xcresulttool export attachments --path "$result" --output-path "$attachments" >/dev/null
# Exported files are named by UUID. The checks' own screenshots (01-…) go to the output folder under the
# name they were kept by; the rest stays in the result bundle.
jq -r '.[].attachments[] | [.exportedFileName, (.suggestedHumanReadableName | sub("_[0-9]+_[0-9A-F-]+[.]"; "."))]
  | select(.[1] | test("^[0-9]{2}-")) | @tsv' "$attachments/manifest.json" |
  while IFS=$'\t' read -r file label; do mv "$attachments/$file" "$out/$label"; done
rm -rf "$attachments"
xcrun xcresulttool get test-results summary --path "$result" |
  jq -r '"\(.result): \(.passedTests) passed, \(.failedTests) failed, \(.skippedTests) skipped of \(.totalTestCount)",
    (.testFailures[] | "  \(.testName): \(.failureText)")'
print "result in $result, screenshots in $out"
exit $code
