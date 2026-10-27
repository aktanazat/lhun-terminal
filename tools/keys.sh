#!/bin/zsh
# Checks Option as Meta on a connected device (LhunShots/KeysShots.swift). Makes the Mac session the
# checks type into, lhun-test-keys-a, runs them through tools/device-test.sh, copies their screenshots and
# notes into the output folder, prints what zsh ended up with, and kills the session, also when the run
# fails.
#   tools/keys.sh <output dir> [test...]   e.g. tools/keys.sh out LhunShots/KeysShots/testOptionAsMeta
# With no tests named, runs KeysShots.
set -euo pipefail
cd "${0:A:h}/.."
source tools/dest.zsh
out="${1:?usage: tools/keys.sh <output dir> [test...]}"
shift
tests=("$@")
(( $#tests )) || tests=(LhunShots/KeysShots)
fixtures=(a)

cleanup() {
  # Quoted targets: zsh would expand a bare =name to the path of a command.
  for suffix in $fixtures; do tmux kill-session -t "=lhun-test-keys-$suffix" 2>/dev/null || true; done
}
trap cleanup EXIT
cleanup
# The status line goes off so tmux never redraws an idle screen by itself.
for suffix in $fixtures; do
  tmux new-session -d -s "lhun-test-keys-$suffix"
  tmux set-option -t "=lhun-test-keys-$suffix:" status off
done

name="keys-$(date +%Y%m%d-%H%M%S)"
code=0
tools/device-test.sh "$name" $tests || code=$?
attachments="build/$name-attachments"
mkdir -p "$out" "$attachments"
xcrun xcresulttool export attachments --path "build/$name.xcresult" --output-path "$attachments" >/dev/null
# Exported files are named by UUID. The test's own attachments, named from a two-digit number (03-…), go
# to the output folder under the name it kept them by; what XCTest adds on a failure stays in the result
# bundle.
jq -r '.[].attachments[] | [.exportedFileName, (.suggestedHumanReadableName | sub("_[0-9]+_[0-9A-F-]+[.]"; "."))]
  | select(.[1] | test("^[0-9]{2}-")) | @tsv' "$attachments/manifest.json" |
  while IFS=$'\t' read -r file label; do mv "$attachments/$file" "$out/$label"; done
rm -rf "$attachments"
print "what zsh has in lhun-test-keys-a:"
tmux capture-pane -p -t "=lhun-test-keys-a:" | grep -v '^$' || true
print "results in $out"
exit $code
