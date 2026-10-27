/*
 * Finds the program status protocol's feature-detection query in a program's output: ESC ] 7501 ; ?
 * ended by BEL or by ESC \, cut anywhere between reads. A terminal that supports the protocol answers
 * it with the same body. tmux does not answer it, so lhun-pty (lhun-pty.c) answers for the program it
 * runs. A query wrapped for tmux's passthrough, its ESCs doubled, is found too.
 *
 * Nothing here does I/O; the tests are probe-test.c.
 */
#ifndef LHUN_PROBE_H
#define LHUN_PROBE_H

#include <stddef.h>

/* How a query ended, so the answer can end the same way. */
enum probe_end {
	PROBE_NONE,
	PROBE_BEL,
	PROBE_ST,
};

/* Zeroed, it waits for a query. */
struct probe {
	unsigned char state;
};

/*
 * Reads the next bytes of the output and returns how many it read: all of them, or fewer when a query
 * ends inside them, through its last byte, with `*end` saying how it ended. The caller answers, then
 * passes the rest of the bytes in again.
 */
size_t probe_feed(struct probe *, const unsigned char *bytes, size_t length, enum probe_end *end);

#endif
