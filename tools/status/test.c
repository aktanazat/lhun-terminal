/*
 * Table tests for status.c: the OSC 7501 rules lhun-tap applies to a pane's output (status.h).
 * Each example feeds output to a fresh pane and reads the summary Lhûn would get.
 *
 *   tools/status/test.sh
 */
#include "status.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ESC "\x1b"
#define ST ESC "\\"
#define REPORT(body) ESC "]7501;" body ST
/* A report wrapped for the terminal outside tmux: ESC P tmux; ... ESC \, its own ESCs doubled. */
#define PASSTHROUGH(body) ESC "Ptmux;" ESC ESC "]7501;" body ESC ESC "\\" ST
#define PROMPT ESC "]133;A" ST

/* The pane's shell, and the process groups it starts. */
#define SHELL 10
#define BUILD 100
#define CHILD 200
#define OTHER 300

static long in_front;

static long
fake_front(void *context)
{
	(void)context;
	return in_front;
}

static const struct status_terminal terminal = { SHELL, fake_front, NULL };

struct step {
	const char *output;
	long front;	/* the group in front as it is read */
	int bytewise;	/* fed a byte at a time */
};

/* Output read with the shell in front. */
#define OUT(text) { text, SHELL, 0 }
/* Output read with `group` in front. */
#define FROM(text, group) { text, group, 0 }
/* Output read a byte at a time. */
#define BYTEWISE(text) { text, SHELL, 1 }

struct example {
	const char *contract;
	struct step steps[6];
	const char *summary;
};

static const struct example examples[] = {
	/* Finding reports in the output. */
	{ "a report ended by ESC \\ sets the root record",
	    { OUT(REPORT("state=working:app=demo")) }, "state=working:app=demo:records=1" },
	{ "a report ended by BEL counts the same",
	    { OUT(ESC "]7501;state=working:app=demo\a") }, "state=working:app=demo:records=1" },
	{ "a report cut between reads at every byte counts the same",
	    { BYTEWISE("plain " REPORT("state=working:app=demo") " text") }, "state=working:app=demo:records=1" },
	{ "a report in tmux passthrough counts",
	    { OUT(PASSTHROUGH("state=working:app=demo")) }, "state=working:app=demo:records=1" },
	{ "a report in passthrough cut at every byte counts",
	    { BYTEWISE(PASSTHROUGH("state=working:app=demo")) }, "state=working:app=demo:records=1" },
	{ "a report in passthrough inside passthrough counts",
	    { OUT(ESC "Ptmux;" ESC ESC "Ptmux;" ESC ESC ESC ESC "]7501;state=working" ESC ESC ESC ESC "\\" ESC ESC "\\" ST) },
	    "state=working:records=1" },
	{ "a sequence a passthrough cut off does not go on in the next one",
	    { OUT(ESC "Ptmux;" ESC ESC "]7501;state=working" ST), OUT(ESC "Ptmux;:app=demo" ESC ESC "\\" ST) }, "" },
	{ "other sequences report nothing",
	    { OUT(ESC "]0;title\a" ESC "]9;4;1;50\a" ESC "]75010;state=working\a" ESC "[31mred" ESC "P1$r" ST) }, "" },
	{ "an ESC that is not ST drops the report and starts the next sequence",
	    { OUT(ESC "]7501;state=blocked:" ESC "]7501;state=working" ST) }, "state=working:records=1" },
	{ "CAN drops the report",
	    { OUT(ESC "]7501;state=working\x18\a") }, "" },
	{ "the feature query is not a report",
	    { OUT(REPORT("?")) }, "" },

	/* Pairs. */
	{ "whitespace around keys and values is removed",
	    { OUT(REPORT(" state = working : app = demo ")) }, "state=working:app=demo:records=1" },
	{ "a pair without = is skipped and the rest applies",
	    { OUT(REPORT("state=working:junk:app=demo")) }, "state=working:app=demo:records=1" },
	{ "a value with a byte outside the value set skips its pair",
	    { OUT(REPORT("state=working:app=de!mo")) }, "state=working:records=1" },
	{ "a key with a byte other than a-z skips its pair",
	    { OUT(REPORT("State=blocked:state=working")) }, "state=working:records=1" },
	{ "the last value of a key wins",
	    { OUT(REPORT("state=idle:app=one:state=working:app=two")) }, "state=working:app=two:records=1" },
	{ "unknown keys are ignored",
	    { OUT(REPORT("state=working:color=red:app=demo")) }, "state=working:app=demo:records=1" },
	{ "a report without a state is ignored",
	    { OUT(REPORT("app=demo")) }, "" },
	{ "a report with an unknown state is ignored",
	    { OUT(REPORT("state=working:app=demo")), OUT(REPORT("state=sleeping")) }, "state=working:app=demo:records=1" },
	{ "a 16-byte key is a key",
	    { OUT(REPORT("state=working")), OUT(REPORT("state=blocked:abcdefghijklmnop=1")) }, "state=blocked:records=1" },
	{ "a key over 16 bytes discards the report",
	    { OUT(REPORT("state=working")), OUT(REPORT("state=blocked:abcdefghijklmnopq=1")) }, "state=working:records=1" },
	{ "msg and title decode from base64 with or without padding",
	    { OUT(REPORT("state=blocked:kind=permission:progress=40:app=terraform:msg=V2hpY2ggYnJhbmNoPw:title=QnVpbGQ=")) },
	    "state=blocked:kind=permission:progress=40:app=terraform:title=QnVpbGQ=:msg=V2hpY2ggYnJhbmNoPw==:records=1" },
	{ "base64 of a length no text has discards the report",
	    { OUT(REPORT("state=working")), OUT(REPORT("state=blocked:msg=V2hpY")) }, "state=working:records=1" },
	{ "a value byte that is not base64 discards the report",
	    { OUT(REPORT("state=working")), OUT(REPORT("state=blocked:msg=V2h.")) }, "state=working:records=1" },
	{ "a decoded line break discards the report",
	    { OUT(REPORT("state=working")), OUT(REPORT("state=blocked:msg=YQpi")) }, "state=working:records=1" },
	{ "a decoded C1 control discards the report",
	    { OUT(REPORT("state=working")), OUT(REPORT("state=blocked:title=woU=")) }, "state=working:records=1" },
	{ "decoded bytes that are not UTF-8 discard the report",
	    { OUT(REPORT("state=working")), OUT(REPORT("state=blocked:msg=/w==")) }, "state=working:records=1" },
	{ "a decoded broken UTF-8 sequence discards the report",
	    { OUT(REPORT("state=working")), OUT(REPORT("state=blocked:msg=wyg=")) }, "state=working:records=1" },
	{ "a 32-byte app is kept",
	    { OUT(REPORT("state=working:app=abcdefghijklmnopqrstuvwxyz012345")) },
	    "state=working:app=abcdefghijklmnopqrstuvwxyz012345:records=1" },
	{ "an app over 32 bytes discards the report",
	    { OUT(REPORT("state=working")), OUT(REPORT("state=blocked:app=abcdefghijklmnopqrstuvwxyz0123456")) },
	    "state=working:records=1" },
	{ "an app outside its own character set is absent",
	    { OUT(REPORT("state=working:app=a,b")) }, "state=working:records=1" },
	{ "kind is kept with blocked only",
	    { OUT(REPORT("state=working:kind=question")) }, "state=working:records=1" },
	{ "a kind the protocol does not name is absent",
	    { OUT(REPORT("state=blocked:kind=coffee")) }, "state=blocked:records=1" },
	{ "progress runs 0 to 100",
	    { OUT(REPORT("state=working:progress=100")) }, "state=working:progress=100:records=1" },
	{ "progress past 100 is absent",
	    { OUT(REPORT("state=working:progress=101")) }, "state=working:records=1" },
	{ "progress that is not a whole number is absent",
	    { OUT(REPORT("state=working:progress=1.5")) }, "state=working:records=1" },
	{ "progress is kept with working and blocked only",
	    { OUT(REPORT("state=done:progress=40")) }, "state=done:records=1:seq=1000" },

	/* Ids. */
	{ "an id with 8 segments of 32 bytes is kept",
	    { OUT(REPORT("state=blocked:id=abcdefghijklmnopqrstuvwxyz012345/b/c/d/e/f/g/h")) }, "state=blocked:records=1" },
	{ "an id segment over 32 bytes discards the report",
	    { OUT(REPORT("state=working")), OUT(REPORT("state=blocked:id=abcdefghijklmnopqrstuvwxyz0123456")) },
	    "state=working:records=1" },
	{ "an id over 8 segments discards the report",
	    { OUT(REPORT("state=working")), OUT(REPORT("state=blocked:id=a/b/c/d/e/f/g/h/i")) }, "state=working:records=1" },
	{ "an id with an empty segment is ignored",
	    { OUT(REPORT("state=working")), OUT(REPORT("state=blocked:id=a//b")) }, "state=working:records=1" },
	{ "an empty id is ignored rather than taken for the root",
	    { OUT(REPORT("state=working")), OUT(REPORT("state=blocked:id=")) }, "state=working:records=1" },
	{ "an id starting with / is ignored",
	    { OUT(REPORT("state=working")), OUT(REPORT("state=blocked:id=/a")) }, "state=working:records=1" },

	/* Records. */
	{ "a report replaces its record whole",
	    { OUT(REPORT("state=blocked:kind=question:app=demo:msg=SGk")), OUT(REPORT("state=working")) },
	    "state=working:records=1" },
	{ "a child without app takes the root's",
	    { OUT(REPORT("state=working:app=demo")), OUT(REPORT("state=blocked:id=build/test")) },
	    "state=blocked:app=demo:records=2" },
	{ "a child without app takes its nearest ancestor's",
	    { OUT(REPORT("state=working:app=demo")), OUT(REPORT("state=working:id=build:app=cargo")),
		OUT(REPORT("state=blocked:id=build/test/unit")) },
	    "state=blocked:app=cargo:records=3" },
	{ "blocked shows over error", { OUT(REPORT("state=blocked:id=a")), OUT(REPORT("state=error:id=b")) },
	    "state=blocked:records=2" },
	{ "error shows over working", { OUT(REPORT("state=error:id=a")), OUT(REPORT("state=working:id=b")) },
	    "state=error:records=2:seq=1000" },
	{ "working shows over done", { OUT(REPORT("state=working:id=a")), OUT(REPORT("state=done:id=b")) },
	    "state=working:records=2" },
	{ "done shows over idle", { OUT(REPORT("state=done:id=a")), OUT(REPORT("state=idle:id=b")) },
	    "state=done:records=2:seq=1000" },
	{ "of two records in one state the later shows",
	    { OUT(REPORT("state=working:id=a:app=one")), OUT(REPORT("state=working:id=b:app=two")) },
	    "state=working:app=two:records=2" },
	{ "two reports read in the same microsecond get different seqs",
	    { OUT(REPORT("state=done:id=a") REPORT("state=done:id=b:app=two")) }, "state=done:app=two:records=2:seq=1001" },
	{ "clear with an id removes it and what is below it, not its namesakes",
	    { OUT(REPORT("state=blocked:id=build")), OUT(REPORT("state=blocked:id=build/test")),
		OUT(REPORT("state=working:id=buildx")), OUT(REPORT("state=clear:id=build")) },
	    "state=working:records=1" },
	{ "clear without an id removes every record",
	    { OUT(REPORT("state=blocked:id=build")), OUT(REPORT("state=working")), OUT(REPORT("state=clear")) },
	    "records=0" },
	{ "a discarded clear removes nothing",
	    { OUT(REPORT("state=working:app=demo")), OUT(REPORT("state=clear:msg=YQpi")) },
	    "state=working:app=demo:records=1" },

	/* Lifetime. */
	{ "a full reset removes every record and the summary",
	    { OUT(REPORT("state=done:id=a") REPORT("state=working")), OUT(ESC "c") }, "" },
	{ "a soft reset keeps records",
	    { OUT(REPORT("state=working")), OUT(ESC "[!p") }, "state=working:records=1" },
	{ "the alternate screen keeps records",
	    { OUT(REPORT("state=working")), OUT(ESC "[?1049h" ESC "[?1049l") }, "state=working:records=1" },
	{ "the next prompt drops working, blocked and idle and keeps done and error",
	    { OUT(REPORT("state=working:id=a")), OUT(REPORT("state=blocked:id=b")), OUT(REPORT("state=idle:id=c")),
		OUT(REPORT("state=done:id=d")), OUT(PROMPT) },
	    "state=done:records=1:seq=4000" },
	{ "a prompt mark with options is a prompt",
	    { OUT(REPORT("state=working")), OUT(ESC "]133;A;cl=m\a") }, "records=0" },
	{ "133;AB is not a prompt",
	    { OUT(REPORT("state=working")), OUT(ESC "]133;AB\a") }, "state=working:records=1" },
	{ "working goes once the shell is back in front of the program that reported it",
	    { FROM(REPORT("state=working:app=make"), BUILD), FROM("$ ", SHELL) }, "records=0" },
	{ "working stays while its program lives behind another in front",
	    { FROM(REPORT("state=working:app=make"), BUILD), FROM("child output", CHILD) },
	    "state=working:app=make:records=1" },
	{ "working read while a helper of its program had the terminal stays once the program has it back",
	    { FROM(REPORT("state=working:app=omp"), CHILD), FROM("frame", BUILD) }, "state=working:app=omp:records=1" },
	{ "done outlives its program and the prompt",
	    { FROM(REPORT("state=done:app=make"), BUILD), FROM("$ ", SHELL) },
	    "state=done:app=make:records=1:seq=1000" },
	{ "done goes once another program is in front",
	    { FROM(REPORT("state=done:app=make"), BUILD), FROM("$ ", SHELL), FROM("ls output", OTHER) },
	    "records=0" },
	{ "what the shell reported itself outlives the programs it runs",
	    { OUT(REPORT("state=working")), OUT("$ "), FROM("ls output", OTHER), OUT("$ ") },
	    "state=working:records=1" },
	{ "what the shell reported itself goes at the next prompt mark",
	    { OUT(REPORT("state=working")), FROM("ls output", OTHER), OUT(PROMPT) }, "records=0" },
	{ "a prompt mark drawn by the program in front leaves its records",
	    { FROM(REPORT("state=working:app=omp"), BUILD), FROM(PROMPT, BUILD) }, "state=working:app=omp:records=1" },

	/* Representative Claude Code 2.1.295 reports: ended by BEL, app before kind. */
	{ "Claude Code asking to approve a write reads as blocked on permission, with its message",
	    { OUT(ESC "]7501;state=working:app=claude-code\a"),
		OUT(ESC "]7501;state=blocked:app=claude-code:kind=permission:"
		    "msg=YXBwcm92ZSBXcml0ZTogL3RtcC9saHVuLWV4YW1wbGUvaGVsbG8udHh0\a") },
	    "state=blocked:kind=permission:app=claude-code:"
	    "msg=YXBwcm92ZSBXcml0ZTogL3RtcC9saHVuLWV4YW1wbGUvaGVsbG8udHh0:records=1" },
	{ "Claude Code's exit, three clears at once, removes its done",
	    { OUT(ESC "]7501;state=working:app=claude-code\a"), OUT(ESC "]7501;state=done:app=claude-code\a"),
		OUT(ESC "]7501;state=clear\a" ESC "]7501;state=clear\a" ESC "]7501;state=clear\a") },
	    "records=0" },
};

static int checked, failures;

static void
expect(const char *contract, const struct status *st, const char *summary)
{
	char got[STATUS_SUMMARY_MAX];
	status_summary(st, got);
	checked++;
	if (strcmp(got, summary) != 0) {
		failures++;
		printf("FAIL %s\n  want \"%s\"\n  got  \"%s\"\n", contract, summary, got);
	}
}

static void
feed(struct status *st, const char *output, size_t length, uint64_t now)
{
	status_feed(st, (const unsigned char *)output, length, now, &terminal);
}

static void
run(const struct example *e)
{
	struct status *st = status_new();
	for (size_t i = 0; i < sizeof e->steps / sizeof e->steps[0] && e->steps[i].output != NULL; i++) {
		const struct step *s = &e->steps[i];
		in_front = s->front;
		uint64_t now = (i + 1) * 1000;
		size_t length = strlen(s->output);
		if (s->bytewise)
			for (size_t k = 0; k < length; k++)
				feed(st, s->output + k, 1, now);
		else
			feed(st, s->output, length, now);
	}
	expect(e->contract, st, e->summary);
	status_free(st);
}

/* Text that repeats `piece` `times` times between `head` and `tail`. */
static char *
repeat(const char *head, const char *piece, size_t times, const char *tail)
{
	size_t h = strlen(head), p = strlen(piece), t = strlen(tail);
	char *text = malloc(h + p * times + t + 1);
	memcpy(text, head, h);
	for (size_t i = 0; i < times; i++)
		memcpy(text + h + p * i, piece, p);
	memcpy(text + h + p * times, tail, t + 1);
	return text;
}

/* One report to a fresh pane, built at run time; `summary` is freed when `owned`. */
static void
single(const char *contract, char *output, const char *summary, int owned)
{
	struct status *st = status_new();
	in_front = SHELL;
	feed(st, output, strlen(output), 1000);
	expect(contract, st, summary);
	status_free(st);
	free(output);
	if (owned)
		free((char *)summary);
}

static void
limits(void)
{
	/* ESC ] 7501;state=working:x= is 23 bytes and ESC \ 2 more, so 4071 A's make 4096. */
	single("a report of 4096 bytes counts", repeat(ESC "]7501;state=working:x=", "A", 4071, ST),
	    "state=working:records=1", 0);
	single("a report over 4096 bytes is discarded", repeat(ESC "]7501;state=working:x=", "A", 4072, ST), "", 0);
	/* YWFh is "aaa": 682 of them and YWE= make 2048 bytes, 683 make 2049. */
	single("a msg of 2048 bytes is kept, cut to 256 in the summary",
	    repeat(ESC "]7501;state=working:msg=", "YWFh", 682, "YWE=" ST),
	    repeat("state=working:msg=", "YWFh", 84, "YeKApg==:records=1"), 1);
	single("a msg over 2048 bytes discards the report", repeat(ESC "]7501;state=working:msg=", "YWFh", 683, ST),
	    "", 0);
	/* A limit is checked before the value's bytes: one byte more turns a skipped pair into a discarded report. */
	single("a msg value of 2732 bytes with a byte outside the value set skips its pair",
	    repeat(ESC "]7501;state=working:msg=", "YWFh", 682, "YWE!" ST), "state=working:records=1", 0);
	single("a msg value over 2732 bytes discards the report",
	    repeat(ESC "]7501;state=working:msg=", "YWFh", 683, "!" ST), "", 0);
	/* 252 a's, then é (w6lh carries é and an a): the 256-byte cut falls inside é and backs off it. */
	single("the summary cuts a msg on a character boundary",
	    repeat(ESC "]7501;state=working:msg=", "YWFh", 84, "w6lhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFh" ST),
	    repeat("state=working:msg=", "YWFh", 84, "4oCm:records=1"), 1);
	single("a title of 192 bytes is kept", repeat(ESC "]7501;state=working:title=", "YWFh", 64, ST),
	    repeat("state=working:title=", "YWFh", 64, ":records=1"), 1);
	single("a title value of 256 bytes with a byte outside the value set skips its pair",
	    repeat(ESC "]7501;state=working:title=", "YWFh", 63, "YWE!" ST), "state=working:records=1", 0);
	single("a title value over 256 bytes discards the report",
	    repeat(ESC "]7501;state=working:title=", "YWFh", 64, "!" ST), "", 0);
	/* Four segments, three of 32 bytes: within the segment limits, one byte past the total. */
	single("an id over 128 bytes discards the report",
	    repeat(ESC "]7501;state=working:id=", "abcdefghijklmnopqrstuvwxyz012345/", 3,
		"abcdefghijklmnopqrstuvwxyz0123" ST),
	    "", 0);
	single("an id of 128 bytes is kept",
	    repeat(ESC "]7501;state=working:id=", "abcdefghijklmnopqrstuvwxyz012345/", 3,
		"abcdefghijklmnopqrstuvwxyz012" ST),
	    "state=working:records=1", 0);
}

/* 256 records, the first blocked; then one more, after refreshing the first or not. */
static void
cap(const char *contract, int refresh, const char *summary)
{
	struct status *st = status_new();
	in_front = SHELL;
	char report[64];
	uint64_t now = 1;
	feed(st, REPORT("state=blocked:id=r0"), strlen(REPORT("state=blocked:id=r0")), now++);
	for (int i = 1; i < 256; i++) {
		snprintf(report, sizeof report, REPORT("state=working:id=r%d"), i);
		feed(st, report, strlen(report), now++);
	}
	if (refresh)
		feed(st, REPORT("state=blocked:id=r0"), strlen(REPORT("state=blocked:id=r0")), now++);
	feed(st, REPORT("state=working:id=r256"), strlen(REPORT("state=working:id=r256")), now++);
	expect(contract, st, summary);
	status_free(st);
}

int
main(void)
{
	for (size_t i = 0; i < sizeof examples / sizeof examples[0]; i++)
		run(&examples[i]);
	limits();
	cap("past 256 records the one updated least recently goes", 0, "state=working:records=256");
	cap("a record updated again is not the least recent", 1, "state=blocked:records=256");
	if (failures > 0) {
		printf("%d of %d examples failed\n", failures, checked);
		return 1;
	}
	printf("all %d examples pass\n", checked);
	return 0;
}
