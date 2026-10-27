#!/bin/sh
# Installs lhun-tap (status.h, and "Program status" in the repo's README.md): builds it into
# ~/.local/bin, writes the tmux hooks that run it for every new pane to ~/.local/share/lhun-status,
# sources those from ~/.tmux.conf and the running server, and runs it for the panes already open.
# Also builds lhun-pty (lhun-pty.c) beside it and, where ~/.zshrc exists, backs that up to
# ~/.zshrc.bak-status and adds an alias that runs claude through lhun-pty inside tmux.
# Running it again replaces the builds and the hooks; a pane whose tap runs keeps it.
#   tools/status/install.sh                     this Mac
#   tools/status/install.sh <ssh-host>          a caller-selected host over ssh, built there with its cc
#   tools/status/install.sh --restart [host]    also moves every pane to the new build; what the old
#                                               one knew goes, and programs report again as they go on
set -eu
here=$(cd "$(dirname "$0")" && pwd)
restart=no
host=
for arg in "$@"; do
  case $arg in
    --restart) restart=yes ;;
    --here) host= ;;
    *) host=$arg ;;
  esac
done

if [ -n "$host" ]; then
  ssh "$host" 'mkdir -p ~/.local/share/lhun-status'
  scp -q "$here/status.h" "$here/status.c" "$here/lhun-tap.c" "$here/probe.h" "$here/probe.c" \
    "$here/lhun-pty.c" "$here/install.sh" "$host:.local/share/lhun-status/"
  if [ $restart = yes ]; then
    ssh "$host" 'sh ~/.local/share/lhun-status/install.sh --here --restart'
  else
    ssh "$host" 'sh ~/.local/share/lhun-status/install.sh --here'
  fi
  exit
fi

bin="$HOME/.local/bin/lhun-tap"
share="$HOME/.local/share/lhun-status"
mkdir -p "$HOME/.local/bin" "$share"
# A running tap keeps the build it started with; the rename hands the taps that start later this one.
cc -O2 -o "$bin.new" "$here/status.c" "$here/lhun-tap.c"
mv -f "$bin.new" "$bin"
# A running lhun-pty keeps its build too.
cc -O2 -o "$HOME/.local/bin/lhun-pty.new" "$here/probe.c" "$here/lhun-pty.c"
mv -f "$HOME/.local/bin/lhun-pty.new" "$HOME/.local/bin/lhun-pty"

# pipe-pane hands the tap what the pane's programs write, before tmux drops what it does not know.
tap='pipe-pane -O "exec ~/.local/bin/lhun-tap #{q:socket_path} #{pane_id} #{pane_pid}"'
# pipe-pane takes down the pane's pipe before anything else, even with -o, which then opens none. So a
# hook that fires on a pane whose tap already runs looks first.
{
  echo "# Written by tools/status/install.sh in the Lhûn repo, which rewrites it."
  for hook in after-new-session after-new-window after-split-window; do
    printf "set-hook -g '%s[44]' {\n  if -F '#{?pane_pipe,,1}' '%s'\n}\n" "$hook" "$tap"
  done
} > "$share/tmux.conf"
if ! grep -q '^# Lhûn program status' "$HOME/.tmux.conf" 2>/dev/null; then
  printf '%s\n' "# Lhûn program status (tools/status in the Lhûn repo): ~/.local/bin/lhun-tap reads each" \
    "# pane's output for the status programs report (OSC 7501), which tmux drops, for Lhûn." \
    "# Turn off: README.md in the Lhûn repo, under Program status." \
    "source-file -q ~/.local/share/lhun-status/tmux.conf" >> "$HOME/.tmux.conf"
fi
# Claude Code reports its status only once its query is answered, which tmux leaves to lhun-pty.
if [ -f "$HOME/.zshrc" ] && ! grep -q '^# Lhûn program status' "$HOME/.zshrc"; then
  cp -p "$HOME/.zshrc" "$HOME/.zshrc.bak-status"
  printf '%s\n' "# Lhûn program status (tools/status in the Lhûn repo): inside tmux, claude runs through" \
    "# ~/.local/bin/lhun-pty, which answers Claude Code's status query (OSC 7501) as tmux does not," \
    "# so Claude Code reports its status to Lhûn. Turn off: README.md in the Lhûn repo, under Program status." \
    'if [[ -n $TMUX && -x ~/.local/bin/lhun-pty ]] && (( $+commands[claude] )); then' \
    "  alias claude='~/.local/bin/lhun-pty claude'" \
    'fi' >> "$HOME/.zshrc"
fi
if tmux list-sessions >/dev/null 2>&1; then
  tmux source-file "$share/tmux.conf"
  tmux list-panes -a -F '#{pane_id} #{pane_pipe}' | while read -r pane piped; do
    if [ "$piped" = 0 ] || [ $restart = yes ]; then
      tmux pipe-pane -O -t "$pane" 'exec ~/.local/bin/lhun-tap #{q:socket_path} #{pane_id} #{pane_pid}'
    fi
  done
fi
