#!/bin/zsh
# Builds Lhûn and its UI tests, then installs this build of Lhûn and runs the named tests on the destination
# while holding its lock, so no other agent installs over the run. The test runner app is removed
# afterwards, pass or fail, so only Lhûn stays. The result bundle lands in build/<name>.xcresult and the
# app's probe log, when the run made one, in build/<name>.jsonl.
#   tools/device-test.sh <name> <test>...   e.g. tools/device-test.sh fit LhunShots/LhunProbe/testTerminalFitsItsCard
# Set LHUN_DEVICE=<udid> or LHUN_DEST=sim:<name> explicitly (tools/dest.zsh), then pair your own hosts
# in the installed app before host-connected checks. LHUN_APPEARANCE is light or dark, light by default.
# LHUN_APP installs another build of Lhûn in place of this one, built for the same kind of destination. A
# variable named TEST_RUNNER_<X> reaches the tests as <X>; LHUN_DEST reaches them as itself, for the scripts
# they type on this Mac. LHUN_RECORD=1 keeps XCTest recordings.
set -euo pipefail
self="${0:A}"
cd "${0:A:h}/.."
source tools/dest.zsh
export TEST_RUNNER_LHUN_DEST="${LHUN_DEST-}"
export TEST_RUNNER_LHUN_TOOLS="$PWD/tools"

# --locked: the caller holds the destination's lock, and shuts down a simulator it booted itself.
# LHUN_DEST_HELD=1 in the environment does the same for every run below a caller that has built and holds
# the lock across several tools, so a batch keeps the destination from one tool to the next.
locked=0
own=0
case "${1:-}" in
  --locked) locked=1; shift ;;
  --own) locked=1 own=1; shift ;;
esac
if [[ -n ${LHUN_DEST_HELD:-} ]]; then locked=1; fi
(( $# >= 2 )) || { print -u2 "usage: tools/device-test.sh <name> <test>..."; exit 64; }
name="$1"
shift
only=()
for test in "$@"; do only+=("-only-testing:$test"); done

if (( ! locked )); then
  rm -f "build/$name.jsonl"
  dest_build
  exec /usr/bin/lockf -k "$dest_lock" "$self" --own "$name" "$@"
fi

# tmux sessions the run opened that were not there before it are killed afterwards; the others stay.
before=(${(f)"$(tmux list-sessions -F '#{session_name}' 2>/dev/null || true)"})
recording=""
finish() {
  dest_uninstall com.aktanazat.lhun.shots.xctrunner
  (( ! own )) || dest_release
  [[ -z "$recording" ]] || rm -f "$recording"
  [[ -f "build/$name.jsonl" ]] || return 0
  local session
  for session in ${(f)"$(grep -o '"event":"open [^"]*"' "build/$name.jsonl" | sed -e 's/^"event":"open //' -e 's/"$//')"}; do
    (( ${before[(Ie)$session]} )) || tmux kill-session -t "=$session" 2>/dev/null || true
  done
}
trap finish EXIT
dest_boot
if [[ $dest_kind == sim ]]; then
  dest_appearance "${LHUN_APPEARANCE:-light}"
elif [[ -n ${LHUN_APPEARANCE:-} ]]; then
  print -u2 "LHUN_APPEARANCE needs a simulator; set a device's appearance on it"
  exit 64
fi
# xcodebuild refuses to overwrite a result bundle, so the last one goes to the Trash.
if [[ -e "build/$name.xcresult" ]]; then
  mv "build/$name.xcresult" ~/.Trash/"$name-$(date +%s).xcresult"
fi
# A probe log left by an earlier run lists the sessions that run opened, and the cleanup above would kill
# those too; empty it, so only sessions this run opened are killed.
empty="$(mktemp /private/var/tmp/lhun-probe.XXXXXX)"
dest_copy_to com.aktanazat.lhun "$empty" Documents/probe.jsonl || true
rm -f "$empty"
dest_install "${LHUN_APP:-$dest_products/Lhun.app}"
run=(-project Lhun.xcodeproj -scheme Lhun -configuration Release -derivedDataPath build/DerivedData)
if [[ "${LHUN_RECORD:-0}" == 1 || -n "${LHUN_APP:-}" ]]; then
  products="$PWD/build/DerivedData/Build/Products"
  # Device and simulator builds share DerivedData; only this destination's plan counts.
  sdk=iphoneos
  [[ $dest_kind == sim ]] && sdk=iphonesimulator
  runs=("$products"/Lhun_$sdk*.xctestrun(N))
  (( $#runs == 1 )) || { print -u2 "expected one built Lhûn xctestrun for $sdk, found $#runs"; exit 1; }
  # Beside the original so __TESTROOT__ still resolves to these built products.
  recording="$products/recording-$name.xctestrun"
  cp "$runs[1]" "$recording"
  if [[ "${LHUN_RECORD:-0}" == 1 ]]; then
    /usr/libexec/PlistBuddy -c "Set :LhunShots:SystemAttachmentLifetime keepAlways" "$recording"
  fi
  if [[ -n "${LHUN_APP:-}" ]]; then
    # xcodebuild installs and launches the Lhûn that DependentProductPaths names, whatever UITargetAppPath
    # says, so both name LHUN_APP.
    deps=$(plutil -extract LhunShots.DependentProductPaths json -o - "$recording" |
      jq -c --arg app "${LHUN_APP:A}" 'map(if endswith("/Lhun.app") then $app else . end)')
    plutil -replace LhunShots.DependentProductPaths -json "$deps" "$recording"
    /usr/libexec/PlistBuddy -c "Set :LhunShots:UITargetAppPath ${LHUN_APP:A}" "$recording"
  fi
  run=(-xctestrun "$recording")
fi
result=0
# After a failure xcodebuild would gather a sysdiagnose from a simulator, which here takes ten minutes and
# then times out.
diagnostics=()
[[ $dest_kind == sim ]] && diagnostics=(-collect-test-diagnostics never)
dest_xcodebuild test-without-building \
  "${run[@]}" -destination "id=$dest_id" \
  "${only[@]}" -resultBundlePath "build/$name.xcresult" $diagnostics -quiet || result=$?
dest_copy_from com.aktanazat.lhun Documents/probe.jsonl "build/$name.jsonl" || true
exit $result
