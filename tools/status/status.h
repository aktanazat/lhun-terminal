/*
 * One tmux pane's program status: the records programs in the pane report about themselves through
 * OSC 7501 (Program Status Protocol, revision 0.4,
 * https://www.superlogical.com/rex/docs/build/program-status), kept from the pane's raw output.
 *
 * tmux drops OSC 7501, so lhun-tap reads each pane's output through `pipe-pane -O`, feeds it here and
 * publishes status_snapshot() for Lhûn. Nothing here does I/O; what it needs to know about the pane's
 * terminal it asks through struct status_terminal.
 */
#ifndef LHUN_STATUS_H
#define LHUN_STATUS_H

#include <stddef.h>
#include <stdint.h>

struct status;

/* The pane's terminal, as lhun-tap sees it. The tests stand in for it. */
struct status_terminal {
	/* The pane's own process, its first process group: its shell, or a program run in its place. */
	long shell;
	/* The process group in front on the pane's terminal, or -1 when that is unknown. */
	long (*front)(void *context);
	void *context;
};

/* NULL when out of memory. */
struct status *status_new(void);
void status_free(struct status *);

/*
 * Reads the next bytes of the pane's output, cut anywhere, and returns whether the summary may have
 * changed. `now`, in microseconds since 1970, stamps each record a report replaces.
 *
 * A record belongs to the process group in front when its report is read. Output is also when records
 * of programs that have ended go: working, blocked and idle once the shell is back in front of the group
 * that reported them, as the protocol has them go at process exit and at the next prompt, whether or not
 * the shell marks its prompts with OSC 133. A program may hand the terminal to a helper of its own and
 * take it back; only the shell's return counts. Done and error outlive their program and the prompt; they
 * go once another program is in front. Records the shell made itself, such as a printf typed at its
 * prompt, follow the protocol: working, blocked and idle go at the shell's next OSC 133 A. A mark drawn
 * while a program is in front, as omp marks each message, is that program's, not the shell's prompt.
 */
int status_feed(struct status *, const unsigned char *bytes, size_t length, uint64_t now,
    const struct status_terminal *);

/*
 * The pane's summary, NUL-terminated, in `out`, which holds STATUS_SUMMARY_MAX bytes. It is empty
 * when nothing in the pane has reported since it started or since its last full reset; "records=0"
 * once something reported but no record is left; otherwise the record to show, in the protocol's own
 * pair syntax:
 *
 *   state=<state>[:kind=<kind>][:progress=<0-100>][:app=<app>][:title=<base64>][:msg=<base64>]
 *     :records=<count>[:seq=<stamp>]
 *
 * The record shown is the most urgent, blocked before error before working before done before idle,
 * and the latest of those. Its app is inherited from its nearest ancestor when it has none, its msg is
 * cut to 256 bytes, and only a done or an error carries seq: the microsecond it was reported, new for
 * every report, so Lhûn tells a new finish from one he has seen.
 */
#define STATUS_SUMMARY_MAX 1024
void status_summary(const struct status *, char *out);

/*
 * The same summary followed by :items=<base64>, containing newline-separated records in the same
 * pair syntax, each with an explicit id= (empty for root), inherited app, full title and full msg.
 * No records are omitted or shortened: :items=unavailable means the complete set did not fit.
 * Empty and records=0 stay unchanged. One option carries the summary and records atomically.
 *
 * tmux 3.4 packs command arguments into a 16384-byte imsg (client.c, compat/imsg.h). The snapshot
 * stays below 12288 bytes, leaving more than 4 KiB for the command, pane target and optional alert.
 */
#define STATUS_ITEMS_MAX 8192
#define STATUS_SNAPSHOT_MAX 12288
void status_snapshot(const struct status *, char *out);

#endif
