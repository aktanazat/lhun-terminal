#!/bin/zsh
# Proves tools/sessions without a restart, on this Mac and on the server, then shows the result in Lhûn
# on the iPad or a simulator (LHUN_DEST, tools/dest.zsh), where Lhûn is already installed. On each host it
# makes a session named lhun-test-restore-<host> with two windows (the second split in two), folders and
# output, saves it with the test flag, kills only it and restores it, then checks its windows, pane sizes,
# folders, old screens and the restored line. The server restores from a systemd job the way its boot
# unit does, so a tmux server started there must outlive the job. Then each restored session opens in Lhûn
# through a lhun:// link, and the screen is photographed on each window into
# /private/var/tmp/lhun-shots/v5/restore/. The test sessions and their saved state go at the end. Needs
# tools/sessions/install.sh on both hosts.
#   tools/restore.sh
set -euo pipefail
cd "${0:A:h}/.."
source tools/dest.zsh
dest_require_server
shots=/private/var/tmp/lhun-shots/v5/restore
prefix=lhun-test-restore-
stamp="saved-$(date +%H%M%S)"
mkdir -p "$shots" /private/var/tmp/lhun-restore

on() {
  local host=$1
  shift
  if [[ $host == mac ]]; then sh -c "$*"; else ssh "$LHUN_SERVER" "$*"; fi
}

# The host's folders: window 0, then the two panes of window 1.
typeset -A folders=(
  mac "$PWD /private/var/tmp/lhun-restore /tmp"
  server "/etc/systemd/system /var/log /root"
)

shape() {
  on $1 "tmux list-windows -t =$prefix$1 -F '#{window_index} #{window_name} #{window_active}' &&
    tmux list-panes -s -t =$prefix$1 -F '#{window_index}.#{pane_index} #{pane_left},#{pane_top} #{pane_width}x#{pane_height} #{pane_active} #{pane_current_path}'"
}

prove() {
  local host=$1 name=$prefix$1
  local f=(${=folders[$host]})
  on $host "tmux kill-session -t =$name 2>/dev/null || true
    tmux new-session -d -s $name -x 160 -y 45 -n build -c ${f[1]}
    tmux new-window -d -t =$name:1 -n logs -c ${f[2]}
    tmux split-window -h -d -t =$name:1 -c ${f[3]}
    tmux select-window -t =$name:1"
  sleep 1
  on $host "tmux send-keys -t =$name:0 'printf \"before restart on $host: $stamp\\n\\033[32mgreen\\033[0m, \\033[1;35mbold magenta\\033[0m\\n\"; ls | head -12' Enter
    tmux send-keys -t =$name:1.0 'pwd; seq 1 40 | paste -sd\" \" -; echo left pane, $stamp' Enter
    tmux send-keys -t =$name:1.1 'pwd; uname -sr; echo right pane, $stamp' Enter"
  sleep 1
  local before="$(shape $host)"
  print -r -- "$host before:"$'\n'"$before"
  on $host "~/.local/bin/lhun-sessions save --test $prefix && tmux kill-session -t =$name"
  print "$host: saved and killed; running now: $(on $host "tmux ls -F '#{session_name}' 2>/dev/null | grep -c '^$name\$' || true")"
  on $host "~/.local/bin/lhun-sessions restore --test $prefix --dry-run"
  if [[ $host == server ]] && ! on server 'tmux ls >/dev/null 2>&1'; then
    print "server: no tmux server running; restoring from a systemd job like the boot unit"
    on server "systemd-run --wait --pipe --quiet --collect --unit=lhun-test-restore-boot -p User=root \
      -p EnvironmentFile=-/etc/default/locale --setenv=HOME=/root /root/.local/bin/lhun-sessions restore --test $prefix
      systemctl list-units --no-pager --no-legend 'lhun-tmux-*'"
  else
    on $host "~/.local/bin/lhun-sessions restore --test $prefix"
  fi
  local after="$(shape $host)"
  # Pane ids and the shell's own folder resolution aside, the shape must match exactly.
  if [[ "$after" != "$before" ]]; then
    print -r -- "FAIL $host shape after:"$'\n'"$after"
    return 1
  fi
  print "PASS $host: windows, names, pane sizes, active pane and folders match"
  local pane screen
  for pane in 0 1.0 1.1; do
    screen="$(on $host "tmux capture-pane -p -S -600 -t =$name:$pane")"
    if [[ "$screen" != *"$stamp"* || "$screen" != *"restored after restart, screen saved at"* ]]; then
      print -r -- "FAIL $host pane $pane:"$'\n'"$screen"
      return 1
    fi
    print "PASS $host pane $pane: old screen ($stamp) and the restored line are back"
  done
}

cleanup() {
  for host in mac server; do
    on $host "tmux kill-session -t =$prefix$host 2>/dev/null || true"
  done
  if [[ -d ~/.local/state/lhun/sessions/${prefix}mac ]]; then
    mv ~/.local/state/lhun/sessions/${prefix}mac ~/.Trash/${prefix}mac-state-$(date +%s)
  fi
  on server "if [ -d ~/.local/state/lhun/sessions/${prefix}server ]; then rm -r -- ~/.local/state/lhun/sessions/${prefix}server; fi"
}

# Opens the restored session in Lhûn through its link and photographs both windows. Runs holding the
# destination's lock, through the script itself.
photograph() {
  local host=$1 name=$prefix$1 empty
  # A probe log from an earlier run could already name the session; start from an empty one.
  empty="$(mktemp /private/var/tmp/lhun-restore/probe.XXXXXX)"
  dest_copy_to com.aktanazat.lhun "$empty" Documents/probe.jsonl
  mv "$empty" ~/.Trash/
  dest_launch "lhun://open?host=$host&session=$name" -keySeen YES -host "$host" -probe YES
  sleep 9
  dest_screenshot "$shots/$host-window1.png"
  on $host "tmux select-window -t =$name:0"
  sleep 3
  dest_screenshot "$shots/$host-window0.png"
  [[ ! -e "build/restore-$host.jsonl" ]] || mv "build/restore-$host.jsonl" ~/.Trash/"restore-$host-$(date +%s).jsonl"
  dest_copy_from com.aktanazat.lhun Documents/probe.jsonl "build/restore-$host.jsonl"
  if grep -q "\"event\":\"open $name\"" "build/restore-$host.jsonl"; then
    print "PASS Lhûn opened $name; shots $shots/$host-window1.png and $host-window0.png"
  else
    print "FAIL Lhûn: no open event for $name in build/restore-$host.jsonl"
    return 1
  fi
}

if [[ ${1:-} == --photos ]]; then
  trap dest_release EXIT
  dest_boot
  photograph mac
  photograph server
  exit
fi
trap cleanup EXIT
prove mac
prove server
mkdir -p build
/usr/bin/lockf -k "$dest_lock" "${0:A}" --photos
