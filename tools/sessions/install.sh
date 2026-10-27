#!/bin/sh
# Installs lhun-sessions (README.md beside this file): the script in ~/.local/bin, the tmux hooks in
# ~/.tmux.conf and the running server, and the jobs that save every five minutes and restore at boot.
# Running it again replaces each piece in place.
#   tools/sessions/install.sh          this Mac: two launchd agents
#   tools/sessions/install.sh <ssh-host>   a caller-selected Linux host over ssh, as root: systemd units
set -eu
here=$(cd "$(dirname "$0")" && pwd)

if [ $# -eq 1 ] && [ "$1" != --here ]; then
  ssh "$1" 'mkdir -p ~/.local/bin'
  scp -q "$here/lhun-sessions" "$1:.local/bin/lhun-sessions"
  ssh "$1" 'sh -s -- --here' < "$here/install.sh"
  exit
fi

bin="$HOME/.local/bin/lhun-sessions"
if [ $# -eq 0 ]; then
  mkdir -p "$HOME/.local/bin"
  cp "$here/lhun-sessions" "$bin"
fi
chmod 755 "$bin"
mkdir -p "$HOME/.local/state/lhun/sessions"

# tmux runs a save when sessions and windows come, go or change name. At shutdown tmux closes every
# session at once, and a save that finds none keeps the saved state.
hooks="session-created session-closed session-renamed window-linked window-unlinked after-split-window
after-kill-pane after-rename-window"
run='run-shell -b "~/.local/bin/lhun-sessions save >/dev/null 2>&1 || true"'
if ! grep -q '^# Lhûn sessions' "$HOME/.tmux.conf" 2>/dev/null; then
  {
    printf '%s\n' "# Lhûn sessions (tools/sessions in the Lhûn repo): ~/.local/bin/lhun-sessions saves each" \
      "# session's windows, folders and screens, so they come back after a restart." \
      "# Turn off: tools/sessions/README.md in the Lhûn repo."
    for hook in $hooks; do printf "set-hook -g '%s[43]' '%s'\n" "$hook" "$run"; done
  } >> "$HOME/.tmux.conf"
fi
if tmux list-sessions >/dev/null 2>&1; then
  for hook in $hooks; do tmux set-hook -g "${hook}[43]" "$run"; done
fi

if [ "$(uname)" = Darwin ]; then
  agents="$HOME/Library/LaunchAgents"
  log="$HOME/.local/state/lhun/sessions.log"
  mkdir -p "$agents"
  for job in restore save; do
    label="com.aktanazat.lhun.sessions-$job"
    if [ $job = restore ]; then
      # At login. The tmux server it starts outlives the job.
      when='<key>RunAtLoad</key><true/><key>AbandonProcessGroup</key><true/>'
    else
      when='<key>StartInterval</key><integer>300</integer><key>ProcessType</key><string>Background</string>'
    fi
    cat > "$agents/$label.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>$bin</string><string>$job</string></array>
  $when
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    <key>LANG</key><string>en_US.UTF-8</string>
  </dict>
  <key>StandardOutPath</key><string>$log</string>
  <key>StandardErrorPath</key><string>$log</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$agents/$label.plist"
  done
  exit
fi

units=/etc/systemd/system
cat > "$units/lhun-sessions-restore.service" <<EOF
[Unit]
Description=Bring back the tmux sessions saved before a restart (Lhûn)
After=local-fs.target network.target

[Service]
Type=oneshot
User=root
Environment=HOME=$HOME
EnvironmentFile=-/etc/default/locale
ExecStart=$bin restore

[Install]
WantedBy=multi-user.target
EOF
cat > "$units/lhun-sessions-save.service" <<EOF
[Unit]
Description=Save the tmux sessions' windows and screens (Lhûn)

[Service]
Type=oneshot
User=root
Environment=HOME=$HOME
EnvironmentFile=-/etc/default/locale
Nice=10
ExecStart=$bin save
EOF
cat > "$units/lhun-sessions-save.timer" <<EOF
[Unit]
Description=Save the tmux sessions every five minutes (Lhûn)

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=1min

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable lhun-sessions-restore.service
systemctl enable --now lhun-sessions-save.timer
