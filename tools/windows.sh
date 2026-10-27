#!/bin/zsh
# Screenshots of a session's tmux windows in the palette on a connected device (LhunShots/WindowShots).
# Makes the Mac session lhun-test-windows-a with three windows, runs the walk through tools/device-test.sh,
# prints what tmux lists for the session afterwards, copies the screenshots into the output folder, and
# kills the session and its folder, also when the run fails.
#   LHUN_DEVICE=<udid> tools/windows.sh <output dir>    a connected device
#   LHUN_DEST=sim:<name> tools/windows.sh <output dir> an existing simulator
set -euo pipefail
cd "${0:A:h}/.."
out="${1:?usage: tools/windows.sh <output dir> [udid]}"
[[ -z ${2:-} ]] || export LHUN_DEVICE=$2 LHUN_DEST="device:$2"
source tools/dest.zsh
session=lhun-test-windows-a
folder=/private/var/tmp/lhun-test-windows

cleanup() {
  # Quoted targets: zsh would expand a bare =name to the path of a command.
  tmux kill-session -t "=$session" 2>/dev/null || true
  rmdir "$folder" 2>/dev/null || true
}
trap cleanup EXIT
cleanup

mkdir -p "$folder"
tmux new-session -d -s "$session" -n editor -c "$PWD"
tmux new-window -d -t "=$session:" -n logs -c "$folder"
tmux new-window -d -t "=$session:" -n build -c "$folder" 'tail -f /dev/null'
tmux select-window -t "=$session:0"
print "before:"
tmux list-windows -t "=$session"

name="windows-$(date +%Y%m%d-%H%M%S)"
code=0
tools/device-test.sh "$name" LhunShots/WindowShots || code=$?
print "after:"
tmux list-windows -t "=$session" -F '#{window_index}: #{window_name} #{pane_current_command} #{pane_current_path}#{?window_active, (active),}' || true
attachments="build/$name-attachments"
mkdir -p "$out" "$attachments"
xcrun xcresulttool export attachments --path "build/$name.xcresult" --output-path "$attachments" >/dev/null
# Exported files are named by UUID; the test's own shots (01-…) go to the output folder by their names.
jq -r '.[].attachments[] | [.exportedFileName, (.suggestedHumanReadableName | sub("_[0-9]+_[0-9A-F-]+[.]"; "."))]
  | select(.[1] | test("^[0-9]{2}-")) | @tsv' "$attachments/manifest.json" |
  while IFS=$'\t' read -r file label; do mv "$attachments/$file" "$out/$label"; done
rm -rf "$attachments"
echo "screenshots in $out"
exit $code
