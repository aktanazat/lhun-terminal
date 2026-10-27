# Where the scripts in tools/ run Lhûn: a connected device or a simulator. Each sources this after it
# changes to the repository's folder.
#   LHUN_DEST=sim          an existing simulator named "Lhun iPad Pro 11"
#   LHUN_DEST=sim:<name>   an existing simulator, by its name in `xcrun simctl list devices`
#   LHUN_DEVICE=<udid>     a connected device, when LHUN_DEST is unset
#   LHUN_DEST=device:<udid> also selects a connected device
# Source validation reads the selection only. Pair your own Mac or Server in Lhûn before host-connected
# checks. A run holds $dest_lock while it uses the destination, and never shuts down another simulator.
# LHUN_XCODEBUILD_HELD=1: the caller holds /private/var/tmp/omp-xcodebuild.lock, shared by build tools
# on this Mac, so a batch does not queue for it again between steps.

dest_shared_sim="Lhun iPad Pro 11"
case ${LHUN_DEST:-} in
  sim) dest_kind=sim dest_name=$dest_shared_sim ;;
  sim:?*) dest_kind=sim dest_name=${LHUN_DEST#sim:} ;;
  device:?*) dest_kind=device dest_name= dest_id=${LHUN_DEST#device:} ;;
  '')
    [[ -n ${LHUN_DEVICE:-} ]] || {
      print -u2 "set LHUN_DEVICE=<udid> or LHUN_DEST=sim:<name> before running this tool"
      exit 64
    }
    dest_kind=device dest_name= dest_id=$LHUN_DEVICE
    ;;
  *) print -u2 "LHUN_DEST must be sim, sim:<name> or device:<udid>, not $LHUN_DEST"; exit 64 ;;
esac

if [[ $dest_kind == sim ]]; then
  dest_id=$(xcrun simctl list devices available -j |
    jq -r --arg name "$dest_name" 'first(.devices[][] | select(.name == $name) | .udid) // empty')
  if [[ -z $dest_id ]]; then
    print -u2 "no available simulator is named $dest_name; create it in Xcode or set LHUN_DEST=sim:<existing-name>"
    exit 64
  fi
  dest_lock=/private/var/tmp/lhun-sim.lock
  dest_products=build/DerivedData/Build/Products/Release-iphonesimulator
else
  export LHUN_DEVICE=$dest_id
  dest_lock=/private/var/tmp/lhun-device.lock
  dest_products=build/DerivedData/Build/Products/Release-iphoneos
fi
export LHUN_DEST="${dest_kind}:${dest_name:-$dest_id}"

# Server fixtures use only the caller's SSH target, paired separately in Lhûn's Server slot.
dest_require_server() {
  [[ -n ${LHUN_SERVER:-} ]] || {
    print -u2 "set LHUN_SERVER=<your-ssh-target> and pair that server in Lhûn before running this tool"
    exit 64
  }
}

# Runs xcodebuild inside the lock every xcodebuild on this Mac takes, unless the caller holds it.
dest_xcodebuild() {
  if [[ -n ${LHUN_XCODEBUILD_HELD:-} ]]; then
    xcodebuild "$@"
  else
    /usr/bin/lockf -k /private/var/tmp/omp-xcodebuild.lock xcodebuild "$@"
  fi
}

# Builds Lhûn and its UI tests for the destination, one xcodebuild on this Mac at a time.
dest_build() {
  xcodegen generate --quiet
  local only=()
  # A simulator build would otherwise compile every slice the simulator runs, Intel's included.
  [[ $dest_kind == sim ]] && only=(ONLY_ACTIVE_ARCH=YES)
  dest_xcodebuild build-for-testing \
    -project Lhun.xcodeproj -scheme Lhun -configuration Release \
    -destination "id=$dest_id" -derivedDataPath build/DerivedData \
    -skipPackagePluginValidation -quiet $only
}

# Boots only the selected simulator. Runs inside $dest_lock.
dest_boot() {
  [[ $dest_kind == sim ]] || return 0
  xcrun simctl bootstatus "$dest_id" -b >/dev/null
}

# Shuts down a simulator other than the shared one before the lock goes.
dest_release() {
  [[ $dest_kind == sim && $dest_name != $dest_shared_sim ]] || return 0
  xcrun simctl shutdown "$dest_id" 2>/dev/null || true
}

# Light or dark, on a simulator. A device's appearance is set on the device, in Settings.
dest_appearance() {
  [[ $dest_kind == sim ]] || { print -u2 "only a simulator's appearance can be set from this Mac"; return 64; }
  xcrun simctl ui "$dest_id" appearance "$1"
}

dest_install() {
  if [[ $dest_kind == sim ]]; then
    xcrun simctl install "$dest_id" "$1"
  else
    xcrun devicectl device install app --device "$dest_id" "$1" >/dev/null
  fi
}

dest_uninstall() {
  if [[ $dest_kind == sim ]]; then
    xcrun simctl uninstall "$dest_id" "$1" 2>/dev/null || true
  else
    xcrun devicectl device uninstall app --device "$dest_id" "$1" >/dev/null 2>&1 || true
  fi
}

# dest_launch <link> [argument...]: starts Lhûn afresh with the arguments, then hands it the lhun:// link
# when there is one.
dest_launch() {
  local link=$1
  shift
  if [[ $dest_kind == sim ]]; then
    xcrun simctl launch --terminate-running-process "$dest_id" com.aktanazat.lhun "$@" >/dev/null
    [[ -z $link ]] || xcrun simctl openurl "$dest_id" "$link"
  else
    local url=()
    [[ -z $link ]] || url=(--payload-url "$link")
    xcrun devicectl device process launch --device "$dest_id" --terminate-existing $url com.aktanazat.lhun \
      -- "$@" >/dev/null
  fi
}

# Saves a picture of the destination's screen as <png>, upright.
dest_screenshot() {
  if [[ $dest_kind == sim ]]; then
    xcrun simctl io "$dest_id" screenshot --type=png "$1" >/dev/null 2>&1
  else
    xcrun devicectl device capture screenshot --device "$dest_id" --destination "$1" >/dev/null 2>&1
  fi
}

# An installed app's data container on the simulator, a folder on this Mac.
dest_container() {
  xcrun simctl get_app_container "$dest_id" "$1" data 2>/dev/null
}

# dest_copy_to <bundle id> <file> <path in its data container>
dest_copy_to() {
  if [[ $dest_kind == sim ]]; then
    local root
    root=$(dest_container "$1") && cp "$2" "$root/$3"
  else
    xcrun devicectl device copy to --device "$dest_id" --domain-type appDataContainer \
      --domain-identifier "$1" --source "$2" --destination "$3" >/dev/null 2>&1
  fi
}

# dest_copy_from <bundle id> <path in its data container> <file>
dest_copy_from() {
  if [[ $dest_kind == sim ]]; then
    local root
    root=$(dest_container "$1") && [[ -f $root/$2 ]] && cp "$root/$2" "$3"
  else
    xcrun devicectl device copy from --device "$dest_id" --domain-type appDataContainer \
      --domain-identifier "$1" --source "$2" --destination "$3" >/dev/null 2>&1
  fi
}

# dest_files <bundle id> <folder in its data container>: every path below the folder, one a line, a
# folder's with a slash at its end; fails when the app or the folder is not there yet.
dest_files() {
  if [[ $dest_kind == sim ]]; then
    local root entry
    root=$(dest_container "$1") && [[ -d $root/$2 ]] || return 1
    for entry in "$root/$2"/**/*(DN); do
      if [[ -d $entry ]]; then print -r -- "${entry#$root/$2/}/"; else print -r -- "${entry#$root/$2/}"; fi
    done
  else
    local listing
    listing=$(xcrun devicectl device info files --device "$dest_id" --domain-type appDataContainer \
      --domain-identifier "$1" --subdirectory "$2" --json-output - 2>/dev/null) || return 1
    jq -r '.result.files[]?.name' <<<"$listing"
  fi
}

# dest_photographer <prefix> <dir>: answers a test's requests for pictures of the screen until it is
# killed. Each empty file take-<prefix><shot> the test leaves in its runner's Documents gets
# <dir>/<shot>.png, then an empty taken-<prefix><shot> beside it, which lets the test move on. The
# runner is shared by every test, so the prefix keeps other tests' requests out. Until the runner is
# installed nothing lists. An earlier picture under the same name goes to the Trash first; a caller that
# knows its shots moves them all away before the run, so a missing one shows. Run it in the background
# inside $dest_lock.
dest_photographer() {
  local prefix=$1 dir=$2 runner=com.aktanazat.lhun.shots.xctrunner answer=build/dest-taken names shot
  local taken=()
  mkdir -p build
  : >|"$answer"
  while true; do
    if ! names=$(dest_files $runner Documents); then
      sleep 2
      continue
    fi
    for shot in ${(f)"$(sed -n "s/^take-$prefix//p" <<<"$names")"}; do
      (( ${taken[(Ie)$shot]} )) && continue
      taken+=("$shot")
      if [[ -e $dir/$shot.png ]]; then mv "$dir/$shot.png" ~/.Trash/"$shot-$(date +%s).png"; fi
      dest_screenshot "$dir/$shot.png" && dest_copy_to $runner "$answer" "Documents/taken-$prefix$shot" || true
    done
    sleep 0.3
  done
}

