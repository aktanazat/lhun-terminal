# Lhûn sessions

tmux loses every session when its host restarts. `lhun-sessions` brings them back: each session with
its windows, their names and layout, each pane in its old folder showing its old screen and history,
then one dim line, "restored after restart, screen saved at 14:05", and a fresh shell. The programs
that were running are not started again. A session that is already running is never touched.

## What it saves

- Every session's name, and each window's index, name and layout. A window tmux names after its
  program keeps doing so; a user-renamed window keeps that name.
- Each pane's folder, its size, and its screen with up to 500 lines of history, colors included.
- Everything under `~/.local/state/lhun/sessions/`, one folder per session: `session.json` and a
  text file per pane. A file is only rewritten when its screen changed.
- A session that is closed while others keep running is dropped from the saved state on the next
  save. When tmux finds no session at all, at a restart or a logout, a save keeps what it has.
- Sessions named `lhun-test-*` are left out. `--test <prefix>` (the prefix must start with
  `lhun-test-`) saves and restores only the sessions whose names start with it, which is how
  `tools/restore.sh` proves the whole cycle without a restart.

## When it runs

- Save: tmux runs it when a session or window opens, closes or is renamed, and when a pane is split
  or killed (hooks with index 43 in `~/.tmux.conf`). A timer runs it every five minutes for the
  screens. Saves that pile up during a burst of hooks run once.
- Restore: at boot on the server and at login on the Mac. A save that finds the state written
  before the restart, with restore not yet run, restores first, so a tmux started early by hand
  cannot wipe the saved state.
- On the Mac, restore also starts the tmux server and keeps it running with no sessions
  (`exit-empty off`). Running tmux in the login session lets programs in its panes use the login
  keychain, including tools that need saved signing or authentication credentials.

| Host | Restore | Save |
| --- | --- | --- |
| Mac | launch agent `com.aktanazat.lhun.sessions-restore`, at login | launch agent `com.aktanazat.lhun.sessions-save`, every 300 s |
| Server | `lhun-sessions-restore.service`, enabled for `multi-user.target` | `lhun-sessions-save.timer`, every 5 minutes |

On Linux the tmux server starts in its own systemd scope (`lhun-tmux-<time>.scope`), so it keeps
running after the restore job ends. On the Mac the agents log to `~/.local/state/lhun/sessions.log`;
on Linux, use `journalctl -u lhun-sessions-restore`.

Use one session-restoration tool on each host. Disable any overlapping tmux-resurrect or
tmux-continuum restore job before enabling this one.

## Commands

```sh
lhun-sessions save [--test <prefix>]
lhun-sessions restore [--test <prefix>] [--dry-run]   # --dry-run lists what it would bring back
```

## Install

The Linux installer requires a root account on a host using systemd. Set `LHUN_SERVER` to your own
SSH target before a remote install. These commands install host-side jobs; they do not pair the app.

```sh
tools/sessions/install.sh
tools/sessions/install.sh "${LHUN_SERVER:?set LHUN_SERVER to your own SSH target}"
```

It copies the script to `~/.local/bin/lhun-sessions`, appends the hook block to `~/.tmux.conf` once,
sets the hooks in the running tmux, and writes and loads the launch agents or the systemd units.
Running it again updates each piece in place.

## Turning it off

- Mac: `launchctl bootout gui/$(id -u)/com.aktanazat.lhun.sessions-restore`, the same for
  `sessions-save`, then delete both plists from `~/Library/LaunchAgents`.
- Server: `systemctl disable --now lhun-sessions-save.timer lhun-sessions-restore.service`, then
  delete the three `lhun-sessions-*` files from `/etc/systemd/system` and `systemctl daemon-reload`.
- Both: run `tmux set-hook -gu '<hook>[43]'` for each hook in the block, delete the block from
  `~/.tmux.conf`, and move `~/.local/state/lhun/sessions` away.

## Limits

- The last session closed before a restart comes back after it, since tmux closing its last session
  looks the same as tmux shutting down. Starting any session again first drops it.
- Windows of a session take the first window's size until a client attaches; Lhûn's attach resizes
  the selected window to its card.
