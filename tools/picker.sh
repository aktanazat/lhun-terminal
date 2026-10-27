#!/bin/zsh
# Screenshots of the path picker, saved actions, the palette's create row and the screen copy on a
# connected device (LhunShots/PickerShots). Sets up the fixtures, runs the test through
# tools/device-test.sh, copies the screenshots into the output folder, and removes every fixture and
# session the run made, also when it fails. They are all named lhun-test-palette-*:
#   - a Mac session lhun-test-palette-picker in this checkout and a folder
#     /private/var/tmp/lhun-test-palette-folder;
#   - a Mac action "lhun-test-palette mac echo" and a server action "lhun-test-palette server logs",
#     added to each host's ~/.config/lhun/actions.json for the run only;
#   - the sessions the run starts: lhun-test-palette-folder and lhun-test-palette-new on the Mac,
#     lhun-test-palette-server-logs on the server.
#   LHUN_DEVICE=<udid> LHUN_SERVER=<ssh-target> tools/picker.sh <output dir>    a device
#   LHUN_DEST=sim:<name> LHUN_SERVER=<ssh-target> tools/picker.sh <output dir> a simulator
set -euo pipefail
cd "${0:A:h}/.."
out="${1:?usage: tools/picker.sh <output dir> [udid]}"
[[ -z ${2:-} ]] || export LHUN_DEVICE=$2 LHUN_DEST="device:$2"
source tools/dest.zsh
dest_require_server
server=$LHUN_SERVER
actions='~/.config/lhun/actions.json'
mac_actions="$HOME/.config/lhun/actions.json"

cleanup() {
  # Quoted targets: zsh would expand a bare =name to the path of a command.
  for session in lhun-test-palette-picker lhun-test-palette-folder lhun-test-palette-new; do
    tmux kill-session -t "=$session" 2>/dev/null || true
  done
  rmdir /private/var/tmp/lhun-test-palette-folder 2>/dev/null || true
  rm -f /private/var/tmp/lhun-test-palette-paste.txt
  if [[ -f "$mac_actions.before-lhun-test-palette" ]]; then
    mv "$mac_actions.before-lhun-test-palette" "$mac_actions"
  elif [[ -f "$mac_actions.absent-lhun-test-palette" ]]; then
    rm -f "$mac_actions" "$mac_actions.absent-lhun-test-palette"
  fi
  ssh -o ConnectTimeout=10 "$server" "tmux kill-session -t '=lhun-test-palette-server-logs' 2>/dev/null; \
    if [ -f $actions.before-lhun-test-palette ]; then mv $actions.before-lhun-test-palette $actions; \
    elif [ -f $actions.absent-lhun-test-palette ]; then rm -f $actions $actions.absent-lhun-test-palette; fi" || true
}
trap cleanup EXIT
cleanup

tmux new-session -d -s lhun-test-palette-picker -c "$PWD"
mkdir -p /private/var/tmp/lhun-test-palette-folder
python3 - "$mac_actions" <<'PY'
import json, os, shutil, sys
path = sys.argv[1]
if os.path.exists(path):
    with open(path) as file:
        entries = json.load(file)
    shutil.copy2(path, path + ".before-lhun-test-palette")
else:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    entries = []
    open(path + ".absent-lhun-test-palette", "x").close()
entries.append({"title": "lhun-test-palette mac echo", "command": "printf 'example mac action\\n'", "where": "here"})
with open(path, "w") as file:
    json.dump(entries, file, indent=2)
PY
ssh -o ConnectTimeout=10 "$server" "python3 - $actions" <<'PY'
import json, os, shutil, sys
path = os.path.expanduser(sys.argv[1])
if os.path.exists(path):
    with open(path) as file:
        entries = json.load(file)
    shutil.copy2(path, path + ".before-lhun-test-palette")
else:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    entries = []
    open(path + ".absent-lhun-test-palette", "x").close()
entries.append({"title": "lhun-test-palette server logs", "command": "printf 'example server log\\n'; sleep 3600", "where": "session"})
with open(path, "w") as file:
    json.dump(entries, file, indent=2)
PY

name="picker-$(date +%Y%m%d-%H%M%S)"
code=0
tools/device-test.sh "$name" LhunShots/PickerShots || code=$?
attachments="build/$name-attachments"
mkdir -p "$out" "$attachments"
xcrun xcresulttool export attachments --path "build/$name.xcresult" --output-path "$attachments" >/dev/null
# Exported files are named by UUID. The test's own shots (01-…) go to the output folder under the name
# it kept them by; what XCTest adds on a failure stays in the result bundle.
jq -r '.[].attachments[] | [.exportedFileName, (.suggestedHumanReadableName | sub("_[0-9]+_[0-9A-F-]+[.]"; "."))]
  | select(.[1] | test("^[0-9]{2}-")) | @tsv' "$attachments/manifest.json" |
  while IFS=$'\t' read -r file label; do mv "$attachments/$file" "$out/$label"; done
rm -rf "$attachments"
# What Copy Screen put on the clipboard, as the test pasted it into a file here.
print "pasted screen:"
cat /private/var/tmp/lhun-test-palette-paste.txt 2>/dev/null || print "(nothing was pasted)"
echo "screenshots in $out"
exit $code
