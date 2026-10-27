#!/bin/sh
# Checks lhun-tap, lhun-pty and install.sh end to end against tmux itself: private servers (tmux -L
# lhun-test-status-tap and -tap2) and a scratch HOME, so it never touches a server or a file of yours.
# Needs tmux 3.4 or later, cc and pgrep; zsh for the alias checks. Prints one line per contract and
# exits non-zero on a failure.
#   tools/status/tmux-test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d "${TMPDIR:-/var/tmp}/lhun-status-tmux.XXXXXX")
L=lhun-test-status-tap
L2=lhun-test-status-tap2
fails=0
mkdir -p "$work/home/.local/bin"
: > "$work/home/alerts.log"
# Stands in for tools/alerts/lhun-alert: the tap runs it when a pane turns blocked or error.
cat > "$work/home/.local/bin/lhun-alert" <<'EOF'
#!/bin/sh
echo "$*" >> "$HOME/alerts.log"
EOF
cat > "$work/report" <<'EOF'
#!/bin/sh
# report <body> [seconds] [pass]: one OSC 7501 report, then a wait, as a program of its own
if [ "${3-}" = pass ]; then
  printf '\033Ptmux;\033\033]7501;%s\033\033\\\033\\' "$1"
else
  printf '\033]7501;%s\033\\' "$1"
fi
[ -n "${2-}" ] && sleep "$2"
exit 0
EOF
chmod +x "$work/home/.local/bin/lhun-alert" "$work/report"
# Stands in for Claude Code as it starts: asks in one write whether the terminal answers the status
# query, then for the device attributes, which every terminal answers; reads until that answer's end
# (c), for at most 2 s as Claude Code waits; and reports app=answered if the query's answer came first.
# It exits on a key. "canonical" asks with the terminal in canonical mode, a line ending at the c.
cat > "$work/prober.c" <<'EOF'
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <termios.h>
#include <unistd.h>

int
main(int argc, char **argv)
{
	struct termios saved, modes;
	tcgetattr(0, &saved);
	modes = saved;
	modes.c_lflag &= ~(tcflag_t)ECHO;
	if (argc > 1 && strcmp(argv[1], "canonical") == 0) {
		modes.c_cc[VEOL] = 'c';
	} else {
		modes.c_lflag &= ~(tcflag_t)ICANON;
		modes.c_cc[VMIN] = 1;
		modes.c_cc[VTIME] = 0;
	}
	tcsetattr(0, TCSANOW, &modes);
	static const char ask[] = "\033]7501;?\007\033[c";
	if (write(1, ask, sizeof ask - 1) < 0)
		return 1;
	char got[256];
	size_t n = 0;
	struct timeval wait = { 2, 0 };
	while (n < sizeof got && memchr(got, 'c', n) == NULL) {
		fd_set readable;
		FD_ZERO(&readable);
		FD_SET(0, &readable);
		if (select(1, &readable, NULL, NULL, &wait) <= 0)
			break;
		ssize_t r = read(0, got + n, sizeof got - n);
		if (r <= 0)
			break;
		n += (size_t)r;
	}
	int first = n >= 8 && memcmp(got, "\033]7501;?", 8) == 0;
	printf("\033]7501;state=working:app=%s\033\\", first ? "answered" : "unanswered");
	fflush(stdout);
	modes.c_lflag &= ~(tcflag_t)ICANON;
	modes.c_cc[VMIN] = 1;
	modes.c_cc[VTIME] = 0;
	tcsetattr(0, TCSANOW, &modes);
	char key;
	ssize_t r = read(0, &key, 1);
	tcsetattr(0, TCSAFLUSH, &saved);
	return r == 1 ? 0 : 1;
}
EOF
cc -O1 -o "$work/prober" "$work/prober.c"
cat > "$work/sized" <<'EOF'
#!/bin/sh
# sized <dir>: writes the terminal's size to <dir>/size, and on its next change to <dir>/resized.
trap 'stty size > "$1/resized"; kill $!; exit 0' WINCH
stty size > "$1/size"
sleep 30 & wait
EOF
cat > "$work/typed" <<'EOF'
#!/bin/sh
# typed <file>: copies what is typed to <file> until the end of input.
cat > "$1"
EOF
cat > "$work/trapped" <<'EOF'
#!/bin/sh
# trapped <dir>: writes <dir>/ready and waits; SIGTERM ends it with code 7.
trap 'kill $!; exit 7' TERM
echo ready > "$1/ready"
sleep 30 & wait
EOF
cat > "$work/ender" <<'EOF'
#!/bin/sh
# ender <dir>: once <dir>/go is there, reports done as the last thing it writes, and ends.
while [ ! -e "$1/go" ]; do sleep 0.05; done
printf '\033]7501;state=done:app=ended\033\\'
EOF
chmod +x "$work/sized" "$work/typed" "$work/trapped" "$work/ender"
export HOME="$work/home"
printf 'export KEEP=1\n' > "$HOME/.zshrc"
pty="$HOME/.local/bin/lhun-pty"
tap="$HOME/.local/bin/lhun-tap"

t() { tmux -L "$L" "$@"; }
t2() { tmux -L "$L2" "$@"; }
cleanup() {
  t kill-session -t lhun-test-status-a 2>/dev/null
  t kill-session -t lhun-test-status-b 2>/dev/null
  t2 kill-session -t lhun-test-status-c 2>/dev/null
  # Each build leaves an empty lock file beside the server's socket.
  for lock in "${sock-}".lhun-tap-*.lock "${sock2-}".lhun-tap-*.lock; do [ -f "$lock" ] && rm -f "$lock"; done
  rm -r "$work"
}
trap cleanup EXIT
ok() { echo "ok   $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
# want <pane> <glob> <contract>: waits for the legacy summary and validates every full record in its
# atomic extension. A one-record snapshot must carry exactly the same details as that summary.
want() {
  i=0
  while :; do
    got=$(t show -pqv -t "$1" @lhun-status)
    legacy=$got
    valid=1
    case "$got" in
      *:items=*)
        legacy=${got%%:items=*}
        encoded=${got##*:items=}
        decoded=$(printf '%s' "$encoded" | base64 -D 2>/dev/null) || decoded=
        count=${legacy##*:records=}
        number=${count%%:*}
        lines=$(printf '%s\n' "$decoded" | wc -l | tr -d ' ')
        [ -n "$decoded" ] && [ "$lines" = "$number" ] || valid=0
        if [ "$number" = 1 ]; then
          details=${legacy%%:records=*}
          suffix=${count#"$number"}
          [ "$decoded" = "id=:$details$suffix" ] || valid=0
        fi
        ;;
      *) case "$2" in *:records=[1-9]*) valid=0 ;; esac ;;
    esac
    case $legacy in $2) [ "$valid" = 1 ] && { ok "$3"; return; } ;; esac
    i=$((i + 1))
    [ $i -ge 100 ] && break
    sleep 0.1
  done
  fail "$3: want '$2' with complete record details, got '$got'"
}
# holds <file> <text> <contract>: waits up to 10 s for the file to hold that text.
holds() {
  i=0
  while [ "$(cat "$1" 2>/dev/null)" != "$2" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.1; done
  [ "$(cat "$1" 2>/dev/null)" = "$2" ] && ok "$3" || fail "$3: want '$2', got '$(cat "$1" 2>/dev/null)'"
}
# taps <socket>: how many taps run for that server.
taps() { pgrep -f "$tap $1 " | wc -l | tr -d ' '; }
# processes <socket> <count> <contract>: waits up to 10 s for that many.
processes() {
  i=0
  while [ "$(taps "$1")" != "$2" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.1; done
  [ "$(taps "$1")" = "$2" ] && ok "$3" || fail "$3: $(taps "$1") taps"
}
type_in() { t send-keys -t "$1" -l "$2"; t send-keys -t "$1" Enter; }
piped() { [ "$(t display -p -t "$1" '#{pane_pipe}')" = 1 ] && ok "$2" || fail "$2"; }
all_piped() { [ -z "$(t list-panes -a -F '#{pane_pipe}' | grep -v 1)" ] && ok "$1" || fail "$1: $(t list-panes -a -F '#{pane_id}=#{pane_pipe}')"; }
# child <pid>: waits up to 10 s for the process to have a child, and prints the child's pid.
child() {
  i=0
  while [ -z "$(pgrep -P "$1")" ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.1; done
  pgrep -P "$1" | head -n 1
}

t -f /dev/null new-session -d -s lhun-test-status-a -x 100 -y 30 /bin/sh
t set -g allow-passthrough on
sock=$(t display -p '#{socket_path}')
# A hub killed outright, as an earlier run's mutants are, cannot take its socket away, so what such a
# run left goes before this one installs: the last check counts only this run's sockets.
for left in "$sock".lhun-tap-*; do [ -S "$left" ] && rm -f "$left"; done
if TMUX="$sock,0,0" sh "$here/install.sh"; then ok "install.sh runs"; else fail "install.sh"; fi
a=$(t display -p -t lhun-test-status-a '#{pane_id}')
piped "$a" "a pane open before the install is piped"
TMUX="$sock,0,0" sh "$here/install.sh"
[ "$(grep -c 'source-file -q ~/.local/share/lhun-status/tmux.conf' "$HOME/.tmux.conf")" = 1 ] &&
  ok "the conf sources the hooks once, after two installs" || fail "conf: $(cat "$HOME/.tmux.conf")"
[ "$(grep -c '^# Lhûn program status' "$HOME/.zshrc")" = 1 ] && [ "$(cat "$HOME/.zshrc.bak-status")" = 'export KEEP=1' ] &&
  ok "the zshrc gets the alias once, after a backup of what it held" || fail "zshrc: $(cat "$HOME/.zshrc")"
if command -v zsh >/dev/null; then
  printf '#!/bin/sh\n' > "$work/claude"
  chmod +x "$work/claude"
  inside=$(PATH="$work:$PATH" TMUX="$sock,0,0" zsh -c '. ~/.zshrc; alias claude')
  [ "$inside" = "claude='~/.local/bin/lhun-pty claude'" ] && ok "inside tmux, claude runs through lhun-pty" ||
    fail "alias inside tmux: '$inside'"
  outside=$(PATH="$work:$PATH" env -u TMUX zsh -c '. ~/.zshrc; alias claude')
  [ -z "$outside" ] && ok "outside tmux, claude runs as it is" || fail "alias outside tmux: '$outside'"
fi
[ "$(t show-hooks -g | grep -c '\[44\]')" = 3 ] && ok "the server gets three hooks" || fail "live hooks: $(t show-hooks -g | grep '\[44\]')"
piped "$a" "a second install leaves a running tap alone"
processes "$sock" 1 "one tap after two installs"

type_in "$a" "say() { printf '\\033]7501;%s\\033\\\\' \"\$1\"; }"
type_in "$a" "say state=working:app=demo"
want "$a" 'state=working:app=demo:records=1' "a report from the shell shows"
type_in "$a" "say id=download:state=working:progress=25:title=RG93bmxvYWQ=:msg=Q29weWluZyBmaWxlcw=="
want "$a" 'state=working:progress=25:app=demo:title=RG93bmxvYWQ=:msg=Q29weWluZyBmaWxlcw==:records=2' \
  "two reports retain the child title, progress, message and inherited app"
snapshot=$(t show -pqv -t "$a" @lhun-status)
decoded=$(printf '%s' "${snapshot##*:items=}" | base64 -D 2>/dev/null)
case "$decoded" in
  *'id=download:state=working:progress=25:app=demo:title=RG93bmxvYWQ=:msg=Q29weWluZyBmaWxlcw=='*)
    ok "the full child record reaches tmux" ;;
  *) fail "the child record was missing: '$decoded'" ;;
esac
type_in "$a" "say id=download:state=clear"
want "$a" 'state=working:app=demo:records=1' "clearing a child leaves its parent's report"
type_in "$a" "say state=clear"
want "$a" 'records=0' "clearing the root removes its records"
type_in "$a" "$work/report state=blocked:kind=question:msg=V2hpY2ggYnJhbmNoPw 3 pass"
want "$a" 'state=blocked:kind=question:msg=V2hpY2ggYnJhbmNoPw==:records=1' "a report in passthrough shows"
want "$a" 'records=0' "blocked goes once its program ends"
grep -q -- "--pane $a" "$HOME/alerts.log" && ok "blocked runs lhun-alert --pane" || fail "alert: $(cat "$HOME/alerts.log")"
type_in "$a" "$work/report state=done:app=build"
want "$a" 'state=done:app=build:records=1:seq=*' "done outlives its program"
type_in "$a" "sh -c 'echo next; sleep 1'"
want "$a" 'records=0' "done goes once another program writes in front"
[ "$(grep -c -- --pane "$HOME/alerts.log")" = 1 ] && ok "done runs no alert" || fail "alerts: $(cat "$HOME/alerts.log")"
type_in "$a" "say state=working"
want "$a" 'state=working:records=1' "a second report shows"
type_in "$a" "printf '\\033c'"
want "$a" '' "a full reset unsets the status"

# lhun-pty, in a window of its own. Its shell is dash where there is one: bash and zsh put their own
# modes back when a program stops, while dash reads on in whatever modes the terminal was left in, so
# only there does it show whether lhun-pty hands the pane back in the pane's own modes.
job_shell=/bin/sh
[ -x /bin/dash ] && job_shell=/bin/dash
p=$(t new-window -t lhun-test-status-a -P -F '#{pane_id}' "$job_shell")
type_in "$p" "$pty $work/prober"
want "$p" 'state=working:app=answered:records=1' "lhun-pty answers the query before tmux answers the device attributes"
t send-keys -t "$p" q
want "$p" 'records=0' "what a program behind lhun-pty reported goes once it ends"
type_in "$p" "$work/prober"
want "$p" 'state=working:app=unanswered:records=1' "without lhun-pty the query goes unanswered"
t send-keys -t "$p" q
want "$p" 'records=0' "the program without lhun-pty ends"
type_in "$p" "$pty $work/prober canonical"
want "$p" 'state=working:app=unanswered:records=1' "lhun-pty leaves a query from canonical mode unanswered"
t send-keys -t "$p" q
want "$p" 'records=0' "the program in canonical mode ends"
type_in "$p" "$pty sh -c 'exit 3'; echo \$? > $work/exited"
holds "$work/exited" 3 "lhun-pty exits with the program's code"
# lhun-pty held up while the program writes its last and ends, here by a stop: going again, it passes
# on what is still unread before it ends too. The sh between keeps the stop from the shell's job control.
# On macOS the program's side cannot finish ending (E) until its output is read, so only Linux, where it
# ends (Z) with its output still waiting, shows a lhun-pty that leaves that output behind.
type_in "$p" "sh -c '$pty $work/ender $work; echo \$? > $work/ender-code'"
relay=$(child "$(child "$(t display -p -t "$p" '#{pane_pid}')")")
leader=$(child "$relay")
kill -STOP "$relay"
: > "$work/go"
i=0
until ps -o stat= -p "$leader" | grep -q '[ZE]' || [ $i -ge 100 ]; do i=$((i + 1)); sleep 0.1; done
kill -CONT "$relay"
want "$p" 'state=done:app=ended:records=1:seq=*' "the last of what a program writes as it ends reaches the pane"
holds "$work/ender-code" 0 "a program that ended while lhun-pty was held up gives its code"
type_in "$p" "$pty sh -c 'kill -TERM \$\$'; echo \$? > $work/killed"
holds "$work/killed" 143 "lhun-pty ends by the program's signal"
type_in "$p" "$pty $work/trapped $work; echo \$? > $work/forwarded"
holds "$work/ready" ready "a program behind lhun-pty runs"
kill -TERM "$(pgrep -P "$(t display -p -t "$p" '#{pane_pid}')" lhun-pty)"
holds "$work/forwarded" 7 "a signal to lhun-pty goes on to the program"
type_in "$p" "$pty $work/sized $work; echo \$? > $work/sized-code"
holds "$work/size" '30 100' "the program's terminal starts at the pane's size"
t resize-window -t "$p" -x 90 -y 25
holds "$work/resized" '25 90' "the program's terminal follows the pane's size"
holds "$work/sized-code" 0 "the program then ends as usual, with code 0"
type_in "$p" "$pty $work/typed $work/lines"
type_in "$p" "before"
holds "$work/lines" 'before' "what is typed reaches the program"
t send-keys -t "$p" C-z
i=0
while [ "$(t display -p -t "$p" '#{pane_current_command}')" = lhun-pty ] && [ $i -lt 100 ]; do i=$((i + 1)); sleep 0.1; done
type_in "$p" "echo back > $work/back"
holds "$work/back" 'back' "Ctrl-Z stops the program and gives the shell the pane, in its own modes"
type_in "$p" "fg; echo \$? > $work/typed-code"
type_in "$p" "after"
holds "$work/lines" "$(printf 'before\nafter')" "fg continues the program, reading again"
t send-keys -t "$p" C-d
holds "$work/typed-code" 0 "end of input then ends the program, with code 0"
type_in "$p" "env -u TMUX $pty sh -c 'echo \$PPID > $work/parent'"
holds "$work/parent" "$(t display -p -t "$p" '#{pane_pid}')" "outside tmux lhun-pty runs the program in its own place"
t kill-pane -t "$p"

b=$(t split-window -t "$a" -P -F '#{pane_id}' /bin/sh)
piped "$b" "a split pane is piped"
w=$(t new-window -t lhun-test-status-a -P -F '#{pane_id}' /bin/sh)
piped "$w" "a new window is piped"
n=$(t new-session -d -s lhun-test-status-b -P -F '#{pane_id}' /bin/sh)
piped "$n" "a new session is piped"
dw=$(t new-window -d -t lhun-test-status-b -P -F '#{pane_id}' /bin/sh)
piped "$dw" "a window made in the background is piped"
ds=$(t split-window -d -t "$n" -P -F '#{pane_id}' /bin/sh)
piped "$ds" "a pane split off in the background is piped"
t respawn-pane -k -t "$b" /bin/sh
sleep 0.3
piped "$b" "a respawned pane keeps its pipe"
processes "$sock" 1 "one tap serves every pane of the server"

panes="$a $b $w $n $dw $ds"
for pane in $panes; do
  type_in "$pane" "printf '\\033]7501;state=working:app=%s\\033\\\\' $(echo "$pane" | tr -d %)"
done
for pane in $panes; do
  want "$pane" "state=working:app=$(echo "$pane" | tr -d %):records=1" "pane $pane reports at the same time as the others"
done
# The hooks fire again on panes whose taps run: those keep their pipes, and what their taps know.
t set-hook -R after-new-session
t set-hook -R after-new-window
t set-hook -R after-split-window
all_piped "a hook that fires on piped panes leaves their pipes"
sleep 1
lost=
for pane in $panes; do
  snapshot=$(t show -pqv -t "$pane" @lhun-status)
  case "$snapshot" in
    "state=working:app=$(echo "$pane" | tr -d %):records=1:items="*) : ;;
    *) lost="$lost $pane" ;;
  esac
done
[ -z "$lost" ] && ok "a hook that fires on piped panes leaves what their taps know" || fail "hooks reset$lost"
if command -v footprint >/dev/null; then
  for pid in $(pgrep -f "$tap $sock "); do
    echo "     the tap serving $(t list-panes -a | wc -l | tr -d ' ') panes: $(footprint "$pid" 2>/dev/null | grep -o 'Footprint: .*')"
  done
fi

t pipe-pane -t "$a"
want "$a" '' "closing the first pane's pipe unsets its status"
type_in "$b" "printf '\\033]7501;state=blocked:kind=permission\\033\\\\'"
want "$b" 'state=blocked:kind=permission:records=1' "the tap goes on for the other panes"
processes "$sock" 1 "still one tap"

# A pane piped anew, with install.sh --restart's own command, goes by its new pipe: the hub swaps the
# pipe in the pane's entry, and its tmux writes go one at a time, each waited for, so what the old
# pipe left behind never lands after the new pipe's report. (A pane id written into the command as
# %N would not do: tmux drops the %, which is why the command names the pane with #{pane_id}.)
type_in "$b" "printf '\\033]7501;state=blocked:kind=question\\033\\\\'"
want "$b" 'state=blocked:kind=question:records=1' "the pane reports before it is piped anew"
t pipe-pane -O -t "$b" 'exec ~/.local/bin/lhun-tap #{q:socket_path} #{pane_id} #{pane_pid}'
type_in "$b" "printf '\\033]7501;state=working\\033\\\\'"
want "$b" 'state=working:records=1' "a pane piped anew goes by its new pipe"
processes "$sock" 1 "the hub takes the new pipe"

t pipe-pane -t "$n"
want "$n" '' "closing the pipe unsets the status"

# A changed tap: a pane made after it is in place gets a hub of that build, and the panes piped before
# keep the hub they have.
cc -O1 -o "$tap.new" "$here/status.c" "$here/lhun-tap.c" && mv -f "$tap.new" "$tap"
v=$(t new-window -t lhun-test-status-a -P -F '#{pane_id}' /bin/sh)
processes "$sock" 2 "a changed tap starts a hub of its own"
type_in "$v" "printf '\\033]7501;state=working\\033\\\\'"
want "$v" 'state=working:records=1' "the changed tap's hub reports"
type_in "$b" "printf '\\033]7501;state=blocked:kind=auth\\033\\\\'"
want "$b" 'state=blocked:kind=auth:records=1' "a pane piped before the change goes on reporting"

if TMUX="$sock,0,0" sh "$here/install.sh" --restart; then ok "install.sh --restart runs"; else fail "install.sh --restart"; fi
all_piped "after --restart every pane is piped"
processes "$sock" 1 "after --restart, one tap again"
type_in "$w" "printf '\\033]7501;state=done\\033\\\\'"
want "$w" 'state=done:records=1:seq=*' "after --restart a pane reports"
want "$b" '' "--restart unsets what a pane had published"
want "$v" '' "--restart unsets what the changed tap's hub had published"

# A server started after the install, as on a host where none ran: the conf alone pipes its panes.
t2 -f "$HOME/.tmux.conf" new-session -d -s lhun-test-status-c /bin/sh
sock2=$(t2 display -p '#{socket_path}')
[ "$(t2 display -p -t lhun-test-status-c '#{pane_pipe}')" = 1 ] && ok "a fresh server's first pane is piped" || fail "fresh server"
processes "$sock2" 1 "the fresh server gets its own tap"
c=$(t2 display -p -t lhun-test-status-c '#{pane_id}')
t2 send-keys -t "$c" -l "printf '\\033]7501;state=idle\\033\\\\'"
t2 send-keys -t "$c" Enter
i=0
while :; do
  fresh=$(t2 show -pqv -t "$c" @lhun-status)
  case "$fresh" in 'state=idle:records=1:items='*) break ;; esac
  i=$((i + 1))
  [ $i -ge 100 ] && break
  sleep 0.1
done
case "$fresh" in
  'state=idle:records=1:items='*)
    [ "$(printf '%s' "${fresh##*:items=}" | base64 -D 2>/dev/null)" = 'id=:state=idle' ] &&
      ok "its pane reports" || fail "fresh server record: '$fresh'" ;;
  *) fail "fresh server report: '$fresh'" ;;
esac
t2 kill-session -t lhun-test-status-c
processes "$sock2" 0 "its tap exits with it"

t kill-session -t lhun-test-status-b
t kill-session -t lhun-test-status-a
processes "$sock" 0 "the tap exits once no pane is left"
left=$(ls "$sock".lhun-tap-* 2>/dev/null | grep -v '\.lock$')
[ -z "$left" ] && ok "the tap removes its socket" || fail "a hub socket is left: $left"
echo "$fails failed"
[ "$fails" = 0 ]
