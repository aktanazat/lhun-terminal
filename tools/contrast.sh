#!/bin/zsh
# Screenshots of light-mode contrast correction on a connected device (LhunShots/LhunContrastShots).
# Starts two fixture sessions on this Mac, runs the test through tools/device-test.sh, copies the
# screenshots and the probe log into the output folder, and removes the sessions. The test switches the
# device to light appearance and back to dark, also when it fails.
#   LHUN_DEVICE=<udid> tools/contrast.sh <output dir>    a connected device
#   LHUN_DEST=sim:<name> tools/contrast.sh <output dir> an existing simulator
set -euo pipefail
cd "${0:A:h}/.."
out="${1:?usage: tools/contrast.sh <output dir> [udid]}"
[[ -z ${2:-} ]] || export LHUN_DEVICE=$2 LHUN_DEST="device:$2"
source tools/dest.zsh

# Quoted targets: zsh would expand a bare =name to the path of a command.
tmux kill-session -t '=contrast' 2>/dev/null || true
tmux kill-session -t '=contrast-bat' 2>/dev/null || true
tmux new-session -d -s contrast "zsh $PWD/tools/contrast-pattern.sh; exec sleep 86400"
tmux new-session -d -s contrast-bat \
  "COLORTERM=truecolor bat --theme='Monokai Extended' --color=always --paging=never --terminal-width=80 --line-range=:18 $PWD/Lhun/Contrast.swift; exec sleep 86400"
for session in contrast contrast-bat; do tmux set-option -t "=$session:" status off; done

name="contrast-$(date +%Y%m%d-%H%M%S)"
code=0
tools/device-test.sh "$name" LhunShots/LhunContrastShots || code=$?
mkdir -p "$out"
xcrun xcresulttool export attachments --path "build/$name.xcresult" --output-path "$out" >/dev/null
# Exported files are named by UUID; give each the name the test kept it under.
jq -r '.[].attachments[] | [.exportedFileName, (.suggestedHumanReadableName | sub("_[0-9]+_[0-9A-F-]+[.]"; "."))] | @tsv' \
  "$out/manifest.json" | while IFS=$'\t' read -r file label; do mv "$out/$file" "$out/$label"; done
[[ -f "build/$name.jsonl" ]] && cp "build/$name.jsonl" "$out/probe.jsonl"
tmux kill-session -t '=contrast'
tmux kill-session -t '=contrast-bat'
echo "screenshots in $out"
exit $code
