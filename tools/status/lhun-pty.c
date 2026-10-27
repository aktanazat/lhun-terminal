/*
 * lhun-pty: runs one program on a terminal of its own and relays between it and the tmux pane, so it can
 * answer the program's OSC 7501 query (probe.h), which tmux leaves unanswered. A program such as Claude
 * Code that asks before it reports its status then reports, and lhun-tap reads the reports from the
 * pane's output as it reads any other program's.
 *
 *   lhun-pty <program> [argument...]
 *
 * The answer goes into the program's input before tmux sees anything the program wrote after the query,
 * so it comes before tmux's answer to the device-attributes request (ESC [ c) a program sends right after
 * the query to learn that no answer is coming. Every byte passes through unchanged both ways, the query
 * included, and nothing waits on a timer. A program whose terminal is in canonical mode gets no answer:
 * it could not read one, and the answer would be typed into whatever reads next, as at a shell prompt.
 * Outside tmux, or without a terminal on standard input and output, it runs the program in its place.
 *
 * Three processes: this one, the relay, which stays in the shell's job; a leader for the new terminal's
 * session, which only waits on the program, so that the program's process group has a parent in its
 * session and stops when the program asks to (Ctrl-Z); and the program, in front on the new terminal.
 * The new terminal starts with the pane's modes and size and follows its size. When the program stops,
 * the relay gives the pane its modes back and stops too, so the shell's job control goes on as without
 * it; continued, it continues the program. Signals sent to the relay go on to the program, and the relay
 * exits as the program did.
 */
#define _GNU_SOURCE /* glibc: posix_openpt, grantpt, unlockpt, ptsname and cfmakeraw */
#include "probe.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/select.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

/* The answer: the query's own body, ended as the query was. */
#define ANSWER "\x1b]7501;?"
/* The most of the pane's input read at a time; the input buffer has room behind it for answers. */
#define INPUT_READ 4096

/* Signals sent to the relay that go on to the program. */
static const int forwarded[] = { SIGHUP, SIGINT, SIGQUIT, SIGTERM, SIGUSR1, SIGUSR2, SIGTSTP };

static int signals[2];			/* the relay's self-pipe: each caught signal's number */
static int master = -1;			/* the relay's side of the new terminal */
static int program_side_open = 1;	/* some process still has the program's side open */
static int pane_open = 1;		/* the pane's terminal still reads and writes */
static int raw;				/* the pane's terminal is in raw mode */
static pid_t leader;			/* the new terminal's session leader, to the relay */
static pid_t program;			/* the program, to the leader */
static struct termios pane_modes;	/* the pane's own, for the program's terminal and to restore */
static struct probe probe;
static unsigned char input[INPUT_READ + 512];
static size_t input_at, input_end;	/* what still has to go to the program */
static unsigned char output[16384];

static void
on(int sig, void (*handler)(int))
{
	struct sigaction action;
	memset(&action, 0, sizeof action);
	action.sa_handler = handler;
	sigemptyset(&action.sa_mask);
	sigaction(sig, &action, NULL);
}

static void
caught(int sig)
{
	int saved = errno;
	unsigned char number = (unsigned char)sig;
	ssize_t written = write(signals[1], &number, 1);
	(void)written;
	errno = saved;
}

static void
forward(int sig)
{
	kill(-program, sig);
}

static void
set_modes(const struct termios *modes)
{
	while (tcsetattr(STDIN_FILENO, TCSADRAIN, modes) != 0 && errno == EINTR)
		continue;
}

static void
restore_pane(void)
{
	if (raw)
		set_modes(&pane_modes);
	raw = 0;
}

static void
fail(const char *what)
{
	int saved = errno;
	restore_pane();
	fprintf(stderr, "lhun-pty: %s: %s\n", what, strerror(saved));
	exit(1);
}

/* Exits the way `status` says a process did: with its code, or by its signal. */
static void
end_as(int status)
{
	if (WIFEXITED(status))
		_exit(WEXITSTATUS(status));
	int sig = WTERMSIG(status);
	on(sig, SIG_DFL);
	sigset_t set;
	sigemptyset(&set);
	sigaddset(&set, sig);
	sigprocmask(SIG_UNBLOCK, &set, NULL);
	kill(getpid(), sig);
	_exit(128 + sig);
}

static void
run_in_place(char **argv)
{
	execvp(argv[0], argv);
	int saved = errno;
	fprintf(stderr, "lhun-pty: %s: %s\n", argv[0], strerror(saved));
	exit(saved == ENOENT ? 127 : 126);
}

/* The session leader: starts the program in front on the new terminal and mirrors what becomes of it. */
static void
lead(const char *name, const struct winsize *size, char **argv)
{
	on(SIGCHLD, SIG_DFL);
	on(SIGWINCH, SIG_DFL);
	on(SIGCONT, SIG_DFL);
	for (size_t i = 0; i < sizeof forwarded / sizeof forwarded[0]; i++)
		on(forwarded[i], SIG_DFL);
	close(signals[0]);
	close(signals[1]);
	close(master);
	if (setsid() < 0)
		fail("setsid");
	int slave = open(name, O_RDWR | O_NOCTTY);
	if (slave < 0 || ioctl(slave, TIOCSCTTY, 0) != 0)
		fail(name);
	tcsetattr(slave, TCSANOW, &pane_modes);
	ioctl(slave, TIOCSWINSZ, size);
	for (int fd = 0; fd <= 2; fd++)
		if (dup2(slave, fd) < 0)
			fail("dup2");
	if (slave > 2)
		close(slave);

	program = fork();
	if (program < 0)
		fail("fork");
	if (program == 0) {
		setpgid(0, 0);
		on(SIGTTOU, SIG_IGN);
		tcsetpgrp(STDIN_FILENO, getpid());
		on(SIGTTOU, SIG_DFL);
		run_in_place(argv);
	}
	setpgid(program, program);
	for (size_t i = 0; i < sizeof forwarded / sizeof forwarded[0]; i++)
		on(forwarded[i], forward);
	for (;;) {
		int status;
		if (waitpid(program, &status, WUNTRACED) < 0) {
			if (errno == EINTR)
				continue;
			_exit(1);
		}
		if (WIFSTOPPED(status)) {
			/* Stopped until the relay, stopped in turn, is continued. */
			raise(SIGSTOP);
			kill(-program, SIGCONT);
			continue;
		}
		end_as(status);
	}
}

static void
to_pane(const unsigned char *bytes, size_t length)
{
	while (pane_open && length > 0) {
		ssize_t n = write(STDOUT_FILENO, bytes, length);
		if (n > 0) {
			bytes += n;
			length -= (size_t)n;
		} else if (n < 0 && errno == EAGAIN) {
			fd_set writable;
			FD_ZERO(&writable);
			FD_SET(STDOUT_FILENO, &writable);
			select(STDOUT_FILENO + 1, NULL, &writable, NULL, NULL);
		} else if (n < 0 && errno != EINTR) {
			pane_open = 0;
		}
	}
}

static void
to_program(void)
{
	while (input_at < input_end) {
		ssize_t n = write(master, input + input_at, input_end - input_at);
		if (n > 0)
			input_at += (size_t)n;
		else if (n < 0 && errno == EAGAIN)
			return;
		else if (n < 0 && errno != EINTR)
			input_at = input_end;
	}
	input_at = input_end = 0;
}

static void
answer(enum probe_end end)
{
	struct termios modes;
	if (tcgetattr(master, &modes) != 0 || (modes.c_lflag & ICANON))
		return;
	const char *tail = end == PROBE_BEL ? "\a" : "\x1b\\";
	size_t body = sizeof ANSWER - 1, ending = strlen(tail);
	memmove(input, input + input_at, input_end - input_at);
	input_end -= input_at;
	input_at = 0;
	if (input_end + body + ending > sizeof input)
		return;
	memcpy(input + input_end, ANSWER, body);
	memcpy(input + input_end + body, tail, ending);
	input_end += body + ending;
}

static void
from_program(void)
{
	ssize_t n = read(master, output, sizeof output);
	if (n < 0 && (errno == EINTR || errno == EAGAIN))
		return;
	if (n <= 0) {
		program_side_open = 0;
		return;
	}
	size_t at = 0;
	int answered = 0;
	while (at < (size_t)n) {
		enum probe_end end;
		at += probe_feed(&probe, output + at, (size_t)n - at, &end);
		if (end != PROBE_NONE) {
			answer(end);
			answered = 1;
		}
	}
	if (answered)
		to_program();
	to_pane(output, (size_t)n);
}

static void
from_pane(void)
{
	ssize_t n = read(STDIN_FILENO, input, INPUT_READ);
	if (n > 0) {
		input_at = 0;
		input_end = (size_t)n;
		to_program();
	} else if (n == 0 || (errno != EINTR && errno != EAGAIN)) {
		pane_open = 0;
	}
}

/* Passes on what the program wrote and has not been read, as it stops or ends. */
static void
drain(void)
{
	ssize_t n;
	while (program_side_open && (n = read(master, output, sizeof output)) > 0)
		to_pane(output, (size_t)n);
}

static void
resize(void)
{
	struct winsize size;
	if (ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0)
		ioctl(master, TIOCSWINSZ, &size);
}

static void
go_raw(void)
{
	struct termios modes = pane_modes;
	cfmakeraw(&modes);
	set_modes(&modes);
	raw = 1;
}

static void
resume(void)
{
	go_raw();
	resize();
	kill(leader, SIGCONT);
}

static void
suspend(void)
{
	drain();
	restore_pane();
	on(SIGTSTP, SIG_DFL);
	raise(SIGTSTP);
	on(SIGTSTP, caught);
	resume();
}

static void
reap(void)
{
	int status;
	while (waitpid(leader, &status, WNOHANG | WUNTRACED) == leader) {
		if (WIFSTOPPED(status)) {
			suspend();
			continue;
		}
		drain();
		restore_pane();
		end_as(status);
	}
}

static void
handle_signals(void)
{
	unsigned char numbers[32];
	ssize_t n;
	while ((n = read(signals[0], numbers, sizeof numbers)) > 0)
		for (ssize_t i = 0; i < n; i++)
			switch (numbers[i]) {
			case SIGCHLD:
				reap();
				break;
			case SIGWINCH:
				resize();
				break;
			case SIGCONT:
				resume();
				break;
			default:
				kill(leader, numbers[i]);
			}
}

static void
relay(void)
{
	for (;;) {
		fd_set readable, writable;
		FD_ZERO(&readable);
		FD_ZERO(&writable);
		FD_SET(signals[0], &readable);
		int top = signals[0];
		if (program_side_open) {
			FD_SET(master, &readable);
			if (input_at < input_end)
				FD_SET(master, &writable);
			if (master > top)
				top = master;
		}
		/* The pane's next input waits until the last has gone, answers included. */
		if (pane_open && input_at == input_end)
			FD_SET(STDIN_FILENO, &readable);
		if (select(top + 1, &readable, &writable, NULL, NULL) < 0) {
			if (errno == EINTR)
				continue;
			fail("select");
		}
		if (FD_ISSET(signals[0], &readable))
			handle_signals();
		if (pane_open && input_at == input_end && FD_ISSET(STDIN_FILENO, &readable))
			from_pane();
		if (program_side_open && FD_ISSET(master, &writable))
			to_program();
		if (program_side_open && FD_ISSET(master, &readable))
			from_program();
	}
}

int
main(int argc, char **argv)
{
	if (argc < 2) {
		fputs("usage: lhun-pty <program> [argument...]\n", stderr);
		return 64;
	}
	struct winsize size;
	if (getenv("TMUX") == NULL || !isatty(STDOUT_FILENO) || tcgetattr(STDIN_FILENO, &pane_modes) != 0 ||
	    ioctl(STDIN_FILENO, TIOCGWINSZ, &size) != 0)
		run_in_place(argv + 1);

	master = posix_openpt(O_RDWR | O_NOCTTY);
	if (master < 0 || grantpt(master) != 0 || unlockpt(master) != 0)
		fail("a new terminal");
	const char *slave = ptsname(master);
	char name[256];
	if (slave == NULL || strlen(slave) >= sizeof name)
		fail("a new terminal's name");
	strcpy(name, slave);
	if (pipe(signals) != 0)
		fail("pipe");
	for (int i = 0; i < 2; i++)
		fcntl(signals[i], F_SETFL, O_NONBLOCK);
	on(SIGCHLD, caught);
	on(SIGWINCH, caught);
	on(SIGCONT, caught);
	for (size_t i = 0; i < sizeof forwarded / sizeof forwarded[0]; i++)
		on(forwarded[i], caught);

	leader = fork();
	if (leader < 0)
		fail("fork");
	if (leader == 0)
		lead(name, &size, argv + 1);
	fcntl(master, F_SETFL, O_NONBLOCK);
	go_raw();
	relay();
}
