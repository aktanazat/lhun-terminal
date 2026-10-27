#include "probe.h"

#include <string.h>

#define ESC 0x1b

/* The query up to its end. The state is how many of its bytes have been read, and two more follow. */
static const char query[] = "\x1b]7501;?";
enum {
	QUERY_READ = sizeof query - 1,	/* all of it: BEL or ESC \ ends it */
	END_ESC,			/* then ESC: a backslash ends it */
};

size_t
probe_feed(struct probe *p, const unsigned char *bytes, size_t length, enum probe_end *end)
{
	*end = PROBE_NONE;
	size_t i = 0;
	while (i < length) {
		if (p->state == 0) {
			const unsigned char *esc = memchr(bytes + i, ESC, length - i);
			if (esc == NULL)
				return length;
			i = (size_t)(esc - bytes);
		}
		unsigned char c = bytes[i++];
		switch (p->state) {
		case QUERY_READ:
			if (c == '\a') {
				p->state = 0;
				*end = PROBE_BEL;
				return i;
			}
			p->state = c == ESC ? END_ESC : 0;
			break;
		case END_ESC:
			if (c == '\\') {
				p->state = 0;
				*end = PROBE_ST;
				return i;
			}
			/* tmux's passthrough doubles the ESC; ESC ] begins another sequence. */
			p->state = c == ESC ? END_ESC : c == ']' ? 2 : 0;
			break;
		default:
			if (c == (unsigned char)query[p->state])
				p->state++;
			else
				p->state = c == ESC ? 1 : 0;
		}
	}
	return length;
}
