/*
 * lhun-tap: reads tmux panes' output for the program status reports tmux drops (OSC 7501, status.h)
 * and publishes each pane's summary in its pane option @lhun-status, where Lhûn reads it. tmux runs it
 * for each pane (install.sh beside this file):
 *
 *   pipe-pane -O "exec ~/.local/bin/lhun-tap #{q:socket_path} #{pane_id} #{pane_pid}"
 *
 * A process costs over a megabyte on macOS before it does anything, so one serves every pane of a tmux
 * server: the first tap for the server stays on as its hub, and each later one hands the hub its pane's
 * pipe over a socket beside tmux's own, then exits. The socket's name carries a hash of the tap's own
 * bytes, so installing the same source again finds the running hub, and a changed tap starts a hub of
 * its own rather than handing panes to an old one.
 *
 * The hub sleeps while its panes are quiet. It publishes a pane only when its summary changes, at most
 * twice a second, one tmux client at a time, and unsets what it published when the pane closes or its
 * pipe is taken down. It exits once it has no pane left. When a pane's summary turns blocked or error
 * it also runs ~/.local/bin/lhun-alert (tools/alerts), if installed, at most once a minute a pane.
 */
#include "status.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <libproc.h>
#endif

extern char **environ;

/* The shortest time between two publishes of a pane, and between two of its alerts, in microseconds. */
#define PUBLISH_SPACING 500000
#define ALERT_SPACING 60000000
/* How often to look whether the tmux client publishing has exited, in milliseconds. */
#define REAP_INTERVAL 20
/* "%<pane> <pid>" as a tap hands a pane over. */
#define HANDOFF_MAX 48

struct pane {
	int fd;			/* its pipe from tmux, or -1 once that has closed */
	long shell;		/* its first process */
	char id[16];		/* %<number> */
	struct status *status;	/* NULL once the pipe has closed */
	char *summary;		/* the latest: what @lhun-status should hold, empty for unset */
	char *published;	/* what @lhun-status holds */
	uint64_t published_at, alerted_at; /* on the monotonic clock; 0 for never */
};

struct hub {
	const char *socket;	/* tmux's */
	char path[sizeof(((struct sockaddr_un *)0)->sun_path)]; /* the hub's own socket */
	int listener;		/* where taps hand panes over, or -1 for a tap serving only its own pane */
	int lock;		/* held while a hub starts or stops listening, and while a tap hands over */
	char alert_path[1024];	/* ~/.local/bin/lhun-alert */
	pid_t client;		/* the tmux client publishing, while it runs */
	struct pane *panes;
	size_t count, capacity;
};

static char nothing[] = "";

static uint64_t
clock_us(clockid_t clock)
{
	struct timespec ts;
	clock_gettime(clock, &ts);
	return (uint64_t)ts.tv_sec * 1000000 + (uint64_t)ts.tv_nsec / 1000;
}

/* The process group in front on the terminal of the pane's first process. */
static long
front(void *context)
{
	long shell = *(const long *)context;
#ifdef __APPLE__
	struct proc_bsdinfo info;
	if (proc_pidinfo((int)shell, PROC_PIDTBSDINFO, 0, &info, PROC_PIDTBSDINFO_SIZE) != PROC_PIDTBSDINFO_SIZE)
		return -1;
	return info.e_tpgid > 0 ? (long)info.e_tpgid : -1;
#else
	char path[64], text[512];
	snprintf(path, sizeof path, "/proc/%ld/stat", shell);
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return -1;
	ssize_t n = read(fd, text, sizeof text - 1);
	close(fd);
	if (n <= 0)
		return -1;
	text[n] = '\0';
	/* The command name, in parentheses, may hold anything; then state ppid pgrp session tty tpgid. */
	char *after = strrchr(text, ')');
	long group;
	if (after == NULL || sscanf(after + 1, " %*c %*d %*d %*d %*d %ld", &group) != 1)
		return -1;
	return group > 0 ? group : -1;
#endif
}

static int
is_pane(const char *text)
{
	if (text[0] != '%' || text[1] == '\0')
		return 0;
	for (const char *c = text + 1; *c != '\0'; c++)
		if (*c < '0' || *c > '9')
			return 0;
	return strlen(text) < sizeof((struct pane *)0)->id;
}

/* Points `slot` at a copy of `text`, or at `nothing` for an empty one. */
static void
set_text(char **slot, const char *text)
{
	if (strcmp(*slot, text) == 0)
		return;
	char *copy = *text != '\0' ? strdup(text) : nothing;
	if (copy == NULL)
		return;
	if (*slot != nothing)
		free(*slot);
	*slot = copy;
}

static int
alerting(const char *summary)
{
	return strncmp(summary, "state=blocked:", 14) == 0 || strncmp(summary, "state=error:", 12) == 0;
}

/* Sets the pane's @lhun-status to its summary, or unsets it when that is empty, without waiting. */
static void
publish(struct hub *hub, struct pane *p, uint64_t now)
{
	char alert[96];
	char *argv[16];
	int n = 0;
	argv[n++] = "tmux";
	argv[n++] = "-S";
	argv[n++] = (char *)hub->socket;
	argv[n++] = "set-option";
	argv[n++] = "-p";
	if (*p->summary == '\0')
		argv[n++] = "-u";
	argv[n++] = "-t";
	argv[n++] = p->id;
	argv[n++] = "@lhun-status";
	if (*p->summary != '\0')
		argv[n++] = p->summary;
	if (alerting(p->summary) && !alerting(p->published) &&
	    (p->alerted_at == 0 || now - p->alerted_at >= ALERT_SPACING) && access(hub->alert_path, X_OK) == 0) {
		snprintf(alert, sizeof alert, "~/.local/bin/lhun-alert --pane %s >/dev/null 2>&1 || true", p->id);
		argv[n++] = ";";
		argv[n++] = "run-shell";
		argv[n++] = "-b";
		argv[n++] = alert;
		p->alerted_at = now;
	}
	argv[n] = NULL;

	posix_spawn_file_actions_t files;
	posix_spawn_file_actions_init(&files);
	posix_spawn_file_actions_addopen(&files, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
	if (posix_spawnp(&hub->client, "tmux", &files, NULL, argv, environ) != 0)
		hub->client = 0;
	posix_spawn_file_actions_destroy(&files);
	set_text(&p->published, p->summary);
	p->published_at = now;
}

static void
reap(struct hub *hub, int options)
{
	if (hub->client != 0 && waitpid(hub->client, NULL, options) != 0)
		hub->client = 0;
}

/* Returns 0 when the hub serves the pane from now on. A pipe for a pane the hub already has replaces the
 * old one, which tmux has closed (install.sh --restart), keeping what was published so it gets unset. */
static int
add_pane(struct hub *hub, int fd, const char *id, long shell)
{
	struct status *status = status_new();
	if (status == NULL)
		return -1;
	struct pane *p = NULL;
	for (size_t i = 0; i < hub->count && p == NULL; i++)
		if (strcmp(hub->panes[i].id, id) == 0)
			p = &hub->panes[i];
	if (p != NULL) {
		if (p->fd >= 0)
			close(p->fd);
		status_free(p->status);
		set_text(&p->summary, "");
	} else {
		if (hub->count == hub->capacity) {
			size_t capacity = hub->capacity > 0 ? hub->capacity * 2 : 8;
			struct pane *grown = realloc(hub->panes, capacity * sizeof *grown);
			if (grown == NULL) {
				status_free(status);
				return -1;
			}
			hub->panes = grown;
			hub->capacity = capacity;
		}
		p = &hub->panes[hub->count++];
		memset(p, 0, sizeof *p);
		strcpy(p->id, id);
		p->summary = nothing;
		p->published = nothing;
	}
	p->fd = fd;
	p->shell = shell;
	p->status = status;
	fcntl(fd, F_SETFD, FD_CLOEXEC);
	return 0;
}

/* FNV-1a over the file: the same source built the same way names the same hub. 0 if unreadable. */
static uint64_t
build_hash(const char *path)
{
	int fd = open(path, O_RDONLY | O_CLOEXEC);
	if (fd < 0)
		return 0;
	unsigned char chunk[4096];
	uint64_t hash = 14695981039346656037ULL;
	ssize_t n;
	while ((n = read(fd, chunk, sizeof chunk)) > 0)
		for (ssize_t i = 0; i < n; i++)
			hash = (hash ^ chunk[i]) * 1099511628211ULL;
	close(fd);
	return n == 0 ? hash : 0;
}

static void
forget(struct hub *hub, size_t i)
{
	struct pane *p = &hub->panes[i];
	status_free(p->status);
	set_text(&p->summary, "");
	set_text(&p->published, "");
	hub->panes[i] = hub->panes[--hub->count];
}

/* One fd and its words travel in a message of this shape. */
union control {
	struct cmsghdr header;
	char space[CMSG_SPACE(sizeof(int))];
};

/* Hands the pane's pipe, our stdin, to the hub at `path`. Returns 0 once the hub has it. */
static int
hand_off(const char *path, const char *pane, long shell)
{
	int s = socket(AF_UNIX, SOCK_STREAM, 0);
	if (s < 0)
		return -1;
	struct sockaddr_un address;
	memset(&address, 0, sizeof address);
	address.sun_family = AF_UNIX;
	strcpy(address.sun_path, path);
	char words[HANDOFF_MAX];
	int length = snprintf(words, sizeof words, "%s %ld", pane, shell) + 1;
	struct iovec part = { words, (size_t)length };
	union control control;
	memset(&control, 0, sizeof control);
	struct msghdr message;
	memset(&message, 0, sizeof message);
	message.msg_iov = &part;
	message.msg_iovlen = 1;
	message.msg_control = control.space;
	message.msg_controllen = sizeof control.space;
	struct cmsghdr *c = CMSG_FIRSTHDR(&message);
	c->cmsg_level = SOL_SOCKET;
	c->cmsg_type = SCM_RIGHTS;
	c->cmsg_len = CMSG_LEN(sizeof(int));
	int fd = STDIN_FILENO;
	memcpy(CMSG_DATA(c), &fd, sizeof fd);
	int handed = connect(s, (struct sockaddr *)&address, sizeof address) == 0 &&
	    sendmsg(s, &message, 0) == (ssize_t)length;
	close(s);
	return handed ? 0 : -1;
}

/* Takes the pane a tap hands over. */
static void
take_pane(struct hub *hub)
{
	int s = accept(hub->listener, NULL, NULL);
	if (s < 0)
		return;
	char words[HANDOFF_MAX];
	struct iovec part = { words, sizeof words - 1 };
	union control control;
	memset(&control, 0, sizeof control);
	struct msghdr message;
	memset(&message, 0, sizeof message);
	message.msg_iov = &part;
	message.msg_iovlen = 1;
	message.msg_control = control.space;
	message.msg_controllen = sizeof control.space;
	ssize_t n = recvmsg(s, &message, 0);
	close(s);
	int fd = -1;
	if (n > 0 && message.msg_controllen > 0)
		for (struct cmsghdr *c = CMSG_FIRSTHDR(&message); c != NULL; c = CMSG_NXTHDR(&message, c))
			if (c->cmsg_level == SOL_SOCKET && c->cmsg_type == SCM_RIGHTS && c->cmsg_len == CMSG_LEN(sizeof(int)))
				memcpy(&fd, CMSG_DATA(c), sizeof fd);
	if (fd < 0)
		return;
	words[n] = '\0';
	char *space = strchr(words, ' '), *end = NULL;
	long shell = space != NULL ? strtol(space + 1, &end, 10) : 0;
	if (space != NULL)
		*space = '\0';
	if (space == NULL || !is_pane(words) || shell <= 0 || *end != '\0' || add_pane(hub, fd, words, shell) != 0)
		close(fd);
}

static int
listen_at(const char *path)
{
	int s = socket(AF_UNIX, SOCK_STREAM, 0);
	if (s < 0)
		return -1;
	fcntl(s, F_SETFD, FD_CLOEXEC);
	struct sockaddr_un address;
	memset(&address, 0, sizeof address);
	address.sun_family = AF_UNIX;
	strcpy(address.sun_path, path);
	/* A tap holding the lock found nobody listening, so whatever is there is a dead hub's. */
	unlink(path);
	if (bind(s, (struct sockaddr *)&address, sizeof address) != 0 || listen(s, 64) != 0) {
		close(s);
		return -1;
	}
	return s;
}

/* Whether the hub may exit: no pane is left, and no tap is handing one over. */
static int
done(struct hub *hub)
{
	if (hub->listener < 0)
		return 1;
	flock(hub->lock, LOCK_EX);
	struct pollfd waiting = { hub->listener, POLLIN, 0 };
	if (poll(&waiting, 1, 0) > 0) {
		flock(hub->lock, LOCK_UN);
		take_pane(hub);
		return 0;
	}
	unlink(hub->path);
	close(hub->listener);
	hub->listener = -1;
	flock(hub->lock, LOCK_UN);
	return 1;
}

static void
serve(struct hub *hub)
{
	static unsigned char buffer[16384];
	static char summary[STATUS_SNAPSHOT_MAX];
	struct pollfd *fds = NULL;
	size_t *owners = NULL;
	size_t room = 0;

	for (;;) {
		reap(hub, WNOHANG);
		/* A pane whose pipe has closed goes once what it published is unset. */
		for (size_t i = hub->count; i-- > 0;)
			if (hub->panes[i].fd < 0 && *hub->panes[i].published == '\0')
				forget(hub, i);
		if (hub->count == 0 && hub->client == 0) {
			if (done(hub))
				break;
			continue;
		}

		uint64_t now = clock_us(CLOCK_MONOTONIC);
		int timeout = hub->client != 0 ? REAP_INTERVAL : -1;
		int published = 0;
		for (size_t i = 0; i < hub->count && !published; i++) {
			struct pane *p = &hub->panes[i];
			if (strcmp(p->summary, p->published) == 0 || hub->client != 0)
				continue;
			if (p->published_at == 0 || now - p->published_at >= PUBLISH_SPACING) {
				publish(hub, p, now);
				published = 1;
				continue;
			}
			int due = (int)((p->published_at + PUBLISH_SPACING - now + 999) / 1000);
			if (timeout < 0 || due < timeout)
				timeout = due;
		}
		if (published)
			continue;

		if (room < hub->count + 1) {
			room = hub->count + 8;
			struct pollfd *more = realloc(fds, room * sizeof *fds);
			size_t *owned = more != NULL ? realloc(owners, room * sizeof *owners) : NULL;
			if (more != NULL)
				fds = more;
			if (owned == NULL)
				break;
			owners = owned;
		}
		nfds_t count = 0;
		for (size_t i = 0; i < hub->count; i++)
			if (hub->panes[i].fd >= 0) {
				fds[count] = (struct pollfd){ hub->panes[i].fd, POLLIN, 0 };
				owners[count++] = i;
			}
		nfds_t panes = count;
		if (hub->listener >= 0)
			fds[count++] = (struct pollfd){ hub->listener, POLLIN, 0 };

		int ready = poll(fds, count, timeout);
		if (ready < 0 && errno != EINTR)
			break;
		if (ready <= 0)
			continue;
		for (nfds_t k = 0; k < panes; k++) {
			if (fds[k].revents == 0)
				continue;
			struct pane *p = &hub->panes[owners[k]];
			ssize_t n = read(p->fd, buffer, sizeof buffer);
			if (n < 0 && (errno == EINTR || errno == EAGAIN))
				continue;
			if (n > 0) {
				const struct status_terminal terminal = { p->shell, front, &p->shell };
				if (status_feed(p->status, buffer, (size_t)n, clock_us(CLOCK_REALTIME), &terminal)) {
					status_snapshot(p->status, summary);
					set_text(&p->summary, summary);
				}
				continue;
			}
			/* The pane closed or its pipe was taken down. */
			close(p->fd);
			p->fd = -1;
			status_free(p->status);
			p->status = NULL;
			set_text(&p->summary, "");
		}
		if (hub->listener >= 0 && fds[panes].revents != 0)
			take_pane(hub);
	}
	free(fds);
	free(owners);
}

int
main(int argc, char **argv)
{
	char *end = NULL;
	long shell = argc == 4 ? strtol(argv[3], &end, 10) : 0;
	if (argc != 4 || argv[1][0] == '\0' || !is_pane(argv[2]) || shell <= 0 || *end != '\0') {
		fputs("usage: lhun-tap <tmux socket> <pane id> <pane pid>\n", stderr);
		return 2;
	}
	signal(SIGPIPE, SIG_IGN);
	/* tmux hands pipe-pane its own PATH, which may not reach Homebrew. */
	const char *path = getenv("PATH");
	char joined[4096];
	snprintf(joined, sizeof joined, "/opt/homebrew/bin:/usr/local/bin:%s", path != NULL ? path : "/usr/bin:/bin");
	setenv("PATH", joined, 1);

	static struct hub hub;
	hub.socket = argv[1];
	hub.listener = -1;
	hub.lock = -1;
	const char *home = getenv("HOME");
	snprintf(hub.alert_path, sizeof hub.alert_path, "%s/.local/bin/lhun-alert", home != NULL ? home : "");

	/* Beside tmux's socket, in a folder only its user may enter, named for this build. */
	uint64_t build = build_hash(argv[0]);
	if (build != 0 &&
	    snprintf(hub.path, sizeof hub.path, "%s.lhun-tap-%016llx", argv[1], (unsigned long long)build) <
		(int)sizeof hub.path) {
		char lock_path[sizeof hub.path + 5];
		snprintf(lock_path, sizeof lock_path, "%s.lock", hub.path);
		hub.lock = open(lock_path, O_RDWR | O_CREAT | O_CLOEXEC, 0600);
		if (hub.lock >= 0) {
			flock(hub.lock, LOCK_EX);
			if (hand_off(hub.path, argv[2], shell) == 0)
				return 0;
			hub.listener = listen_at(hub.path);
			flock(hub.lock, LOCK_UN);
		}
	}
	if (add_pane(&hub, STDIN_FILENO, argv[2], shell) != 0)
		return 1;
	serve(&hub);
	return 0;
}
