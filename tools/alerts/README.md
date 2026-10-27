# Lhûn alerts

A host can send a notification when an unseen tmux session rings its bell or a program reports that
it needs an answer or has failed. Tapping the notification opens that session in Lhûn.

This is an optional setup using your own ntfy server, accounts and topic. The source contains no
running service or credentials. Every `example.invalid` address below must be replaced with your
own server's HTTPS address.

## Requirements

- tmux on each host, with `tools/status` installed for program-status alerts.
- curl with `--variable` and `--expand-data` support on each sending host.
- An authenticated ntfy server reachable from the sending hosts and your iPad or iPhone.
- The ntfy iOS app, with notifications allowed.
- Your Mac or Server already paired through Lhûn's normal pairing screen. Alert links use the
  `mac` and `server` slots; they do not configure SSH access.

## Your ntfy server

Install ntfy using its [installation guide](https://docs.ntfy.sh/install/). Configure authenticated
HTTPS access before enabling alerts. For example, an ntfy instance behind your own HTTPS proxy can
use this `/etc/ntfy/server.yml`:

```yaml
base-url: "https://alerts.example.invalid"
listen-http: "127.0.0.1:2586"
behind-proxy: true
cache-file: "/var/cache/ntfy/cache.db"
auth-file: "/var/lib/ntfy/user.db"
auth-default-access: "deny-all"
upstream-base-url: "https://ntfy.sh"
web-root: "disable"
```

The loopback listener requires a proxy on the same machine. Configure that proxy with your actual
hostname and a valid certificate. A private VPN such as Tailscale is another way to restrict access;
the phone must be connected to it to fetch messages.

Create your own user, a random private topic and an access token. On a Linux installation whose ntfy
service runs as user `ntfy`, the administrative commands are:

```sh
topic="lhun-alerts-$(openssl rand -hex 12)"
runuser -u ntfy -- ntfy user add lhun-alerts
runuser -u ntfy -- ntfy access lhun-alerts "$topic" read-write
runuser -u ntfy -- ntfy token add --label 'lhun alerts' lhun-alerts
```

Keep the topic, account password and token private. The password is for signing in to the ntfy app;
the token is for each sending host. Provision your own settings on each host rather than copying
credentials from another person's account or server.

The upstream setting supports iOS push delivery for self-hosted ntfy. Review ntfy's
[iOS configuration](https://docs.ntfy.sh/config/#ios-instant-notifications) and privacy implications
before enabling it.

## Each sending host

Create `~/.config/lhun-alert/env` with permissions 600. It contains four lines of data, with no shell
syntax or inline comments:

```text
url=https://alerts.example.invalid
topic=your-private-topic
token=your-created-access-token
host=mac
```

Replace the first three values with your settings. Use `host=server` on the host paired in Lhûn's
Server slot. Keep this file out of version control.

From a checkout on each host:

```sh
umask 077
mkdir -p ~/.config/lhun-alert ~/.local/bin
${EDITOR:-vi} ~/.config/lhun-alert/env
chmod 600 ~/.config/lhun-alert/env
install -m 755 tools/alerts/lhun-alert ~/.local/bin/lhun-alert
```

Add this block once to `~/.tmux.conf`:

```tmux
# Lhûn alerts: an unseen session's bell can open a notification on that session.
set-hook -g 'alert-bell[42]' {
    run-shell -b "~/.local/bin/lhun-alert '#{session_id}' '#{window_id}' >/dev/null 2>&1 || true"
}
```

For a running tmux server, save just this block in a temporary file and run `tmux source-file` on
that file. Index 42 replaces the same hook when loaded again. Avoid reloading unrelated configuration.
`lhun-tap` uses the installed alert script automatically for program-status reports.

## The ntfy app

Subscribe to your private topic using your server's actual HTTPS address. Sign in with the account
and password you created. Confirm the phone can reach that address, including any required VPN.

Test from a disposable session on a paired host. Leave it unseen for two minutes, then send its bell:

```sh
tmux new-session -d -s lhun-test-alert
# Wait two minutes without attaching, then:
tmux send-keys -t '=lhun-test-alert:' "printf '\\a'" Enter
```

After checking the notification and its link, remove the fixture with
`tmux kill-session -t '=lhun-test-alert'`.

## Delivery rules

- A notification is sent only when no attached client shows the window, or every attached client has
  had no input for two minutes. Control-mode watchers do not count as viewers.
- Bells are limited to one notification per minute per session. Program reports are limited to one
  per minute per pane, when status turns to waiting or failed. Finishing sends none.
- Notifications contain the session name and a short status such as "Waiting for approval" or
  "Failed". The program's own report message stays on the host.
- A bell requires the session's `bell-action` to differ from `none` and the window's `monitor-bell`
  to be on. These are tmux's defaults.
- Each host logs sends and skips to `~/.local/state/lhun-alert/log`.

tmux cannot distinguish reading from being away, so a session still visible in Lhûn may notify after
two minutes without input. Background attachments suppress bells for two minutes after their last
input. Your ntfy server and its upstream can impose additional limits.

## Turn it off

- Pause a host by moving `~/.config/lhun-alert/env` aside.
- Silence one session with `tmux set -t <session> bell-action none`; Lhûn still keeps its own marks.
- Remove a host's hook with `tmux set-hook -gu 'alert-bell[42]'`, delete the block from
  `~/.tmux.conf`, and remove `~/.local/bin/lhun-alert`.
- Revoke the sending token or delete your alert user using ntfy's account administration commands.
