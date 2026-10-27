#!/bin/zsh
# Builds Lhûn, installs it on the iPad, another device or a simulator (LHUN_DEST, tools/dest.zsh) and
# opens it. A simulator other than "Lhun iPad Pro 11" is shut down again once Lhûn has opened there.
#   LHUN_DEVICE=<udid> tools/install.sh    a connected device (xcrun devicectl list devices)
#   tools/install.sh <udid>               the explicitly named connected device
#   LHUN_DEST=sim:<name> tools/install.sh an existing simulator
set -euo pipefail
self="${0:A}"
cd "${0:A:h}/.."
if [[ -n ${1:-} && $1 != --locked ]]; then export LHUN_DEVICE=$1 LHUN_DEST="device:$1"; fi
source tools/dest.zsh
if [[ ${1:-} != --locked ]]; then
  dest_build
  # One agent at a time uses the destination; the lock covers installing and opening.
  exec /usr/bin/lockf -k "$dest_lock" "$self" --locked
fi
trap dest_release EXIT
dest_boot
dest_install "$dest_products/Lhun.app"
dest_launch ""
