#!/bin/zsh
# Runs the screenshot pass on a connected device against a real tmux session named "proof" on this
# Mac, then copies the screenshots into shots/.
#   LHUN_DEVICE=<udid> tools/shots.sh    a connected device
#   tools/shots.sh <udid>               the explicitly named device
#   LHUN_DEST=sim:<name> tools/shots.sh an existing simulator (tools/dest.zsh)
set -euo pipefail
cd "${0:A:h}/.."
[[ -z ${1:-} ]] || export LHUN_DEVICE=$1 LHUN_DEST="device:$1"
source tools/dest.zsh

# Quoted: zsh would expand a bare =proof to the path of a command named proof.
tmux has-session -t '=proof' 2>/dev/null || tmux new-session -d -s proof
name="shots-$(date +%Y%m%d-%H%M%S)"
tools/device-test.sh "$name" LhunShots/LhunShots
mkdir -p shots
xcrun xcresulttool export attachments --path "build/$name.xcresult" --output-path shots
echo "screenshots in shots/"
