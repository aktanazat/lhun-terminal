/*
 * Table tests for probe.c: which OSC 7501 queries lhun-pty finds in a program's output, and how each
 * ended, B for BEL and S for ESC \. Every example runs twice, read whole and a byte at a time.
 *
 *   tools/status/test.sh
 */
#include "probe.h"

#include <stdio.h>
#include <string.h>

#define ESC "\x1b"

struct example {
	const char *contract;
	const char *output;
	const char *found;
};

static const struct example examples[] = {
	{ "a query ended by BEL is found, ended by BEL", ESC "]7501;?\a", "B" },
	{ "a query ended by ESC \\ is found, ended by ESC \\", ESC "]7501;?" ESC "\\", "S" },
	/* Claude Code 2.1.295's first requests, as one write: its query sits between other requests. */
	{ "Claude Code's query among its other requests is found",
	    ESC "[>0q" ESC "[?u" ESC "]7501;?\a" ESC "[c", "B" },
	{ "a query among text is found", "plain " ESC "]7501;?\a text", "B" },
	{ "two queries are found once each, each ended its own way",
	    ESC "]7501;?\a" "text" ESC "]7501;?" ESC "\\", "BS" },
	{ "a query wrapped for tmux's passthrough is found",
	    ESC "Ptmux;" ESC ESC "]7501;?\a" ESC "\\", "B" },
	{ "a wrapped query ended by a doubled ESC \\ is found once",
	    ESC "Ptmux;" ESC ESC "]7501;?" ESC ESC "\\" ESC "\\", "S" },
	{ "a report is no query", ESC "]7501;state=working:app=demo\a", "" },
	{ "a query with more after its ? is no query", ESC "]7501;?x\a", "" },
	{ "an empty 7501 is no query", ESC "]7501;\a", "" },
	{ "another code's query is no query", ESC "]7502;?\a" ESC "]17501;?\a", "" },
	{ "a query without its ESC is no query", "]7501;?\a", "" },
	{ "a query cut off by another sequence is no query", ESC "]7501;?" ESC "[c", "" },
	{ "a query cut off by another query leaves that query", ESC "]7501;?" ESC "]7501;?\a", "B" },
	{ "an unfinished query cut off by a whole one leaves the whole one", ESC "]75" ESC "]7501;?" ESC "\\", "S" },
};

static int checked, failures;

/* The queries found in `output`, read whole or a byte at a time. */
static void
find(const char *output, int bytewise, char *found, size_t room)
{
	struct probe p = { 0 };
	const unsigned char *bytes = (const unsigned char *)output;
	size_t length = strlen(output), at = 0, count = 0;
	while (at < length) {
		enum probe_end end;
		size_t piece = bytewise ? 1 : length - at;
		size_t read = probe_feed(&p, bytes + at, piece, &end);
		at += read;
		if (end != PROBE_NONE && count + 1 < room)
			found[count++] = end == PROBE_BEL ? 'B' : 'S';
	}
	found[count] = '\0';
}

int
main(void)
{
	for (size_t i = 0; i < sizeof examples / sizeof examples[0]; i++) {
		const struct example *e = &examples[i];
		for (int bytewise = 0; bytewise <= 1; bytewise++) {
			char found[16];
			find(e->output, bytewise, found, sizeof found);
			checked++;
			if (strcmp(found, e->found) != 0) {
				failures++;
				printf("FAIL %s%s\n  want \"%s\"\n  got  \"%s\"\n", e->contract,
				    bytewise ? ", read a byte at a time" : "", e->found, found);
			}
		}
	}
	if (failures > 0) {
		printf("%d of %d query examples failed\n", failures, checked);
		return 1;
	}
	printf("all %d query examples pass\n", checked);
	return 0;
}
