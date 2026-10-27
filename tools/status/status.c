/*
 * The OSC 7501 records of one pane (status.h).
 *
 * A scanner follows the pane's output the way a terminal does, only as far as it takes to find program
 * status reports, prompt marks (OSC 133;A) and full resets (RIS, ESC c), including the ones a program
 * wrapped in tmux's passthrough (ESC P tmux; ... ESC \, its ESCs doubled) for the terminal outside.
 * A sequence ends at BEL or ESC \; an ESC followed by anything else drops it and starts anew, and CAN
 * or SUB drop it, as in a terminal.
 */
#include "status.h"

#include <stdlib.h>
#include <string.h>

/* The protocol's limits. A report that breaks one is discarded whole. */
#define SEQUENCE_MAX 4096 /* the whole sequence, ESC ] through its terminator */
#define KEY_MAX 16
#define MSG_ENCODED_MAX 2732
#define MSG_MAX 2048
#define TITLE_ENCODED_MAX 256
#define TITLE_MAX 192
#define APP_MAX 32
#define ID_MAX 128
#define SEGMENT_MAX 32
#define SEGMENTS_MAX 8
#define RECORDS_MAX 256

/* "7501;" and "133;A" are both this long. */
#define PREFIX_LEN 5
/* A report's pairs: what is left of the sequence after ESC ] 7501; and the shortest terminator, BEL. */
#define BODY_MAX (SEQUENCE_MAX - 2 - PREFIX_LEN - 1)

/* How much of a msg the summary carries: Lhûn shows one line of it. */
#define SUMMARY_MSG_MAX 256

/* How deep passthrough inside passthrough is followed. */
#define NESTING_MAX 3

enum { BEL = 0x07, CAN = 0x18, SUB = 0x1a, ESC = 0x1b };

/* States, in the order a pane shows them; clear is a request, never a record's state. */
enum state { NONE, IDLE, DONE, WORKING, ERROR, BLOCKED, CLEAR };
static const char *const state_names[] = { "", "idle", "done", "working", "error", "blocked", "clear" };

enum kind { NO_KIND, PERMISSION, QUESTION, AUTH };
static const char *const kind_names[] = { "", "permission", "question", "auth" };

struct record {
	uint64_t stamp;		/* when a report last replaced it, in µs since 1970 */
	long owner;		/* the process group in front when it was reported, or -1 */
	unsigned char *text;	/* its title, then its msg, decoded; NULL when both are empty */
	unsigned short msg_len;
	unsigned char title_len;
	unsigned char state;
	unsigned char kind;
	signed char progress;	/* -1 when it has none */
	unsigned char app_len;
	unsigned char id_len;	/* 0 for the root record */
	char app[APP_MAX];
	char id[ID_MAX];
};

enum scan { GROUND, ESCAPE, OSC, OSC_ESCAPE, DCS_HEAD, DCS, DCS_ESCAPE, PASS, PASS_ESCAPE };
enum osc { OSC_UNSURE, OSC_OTHER, OSC_REPORT, OSC_PROMPT, OSC_PROMPT_OPTIONS };

static const char report_prefix[] = "7501;";
static const char prompt_prefix[] = "133;A";
static const char passthrough_prefix[] = "tmux;";

struct scanner {
	unsigned char state;
	unsigned char osc;	/* what the OSC being read is */
	unsigned char match;	/* while that is unsure: 1, it may be a report; 2, a prompt mark */
	unsigned char depth;	/* 0 for the pane's own output, 1 inside one passthrough, ... */
	unsigned int len;	/* bytes of the OSC string or the DCS head so far, counted to SEQUENCE_MAX + 1 */
	unsigned char *body;	/* a report's pairs, BODY_MAX bytes, allocated when first needed */
	struct scanner *inner;	/* what passthrough carries, allocated when first needed */
};

struct status {
	struct scanner scanner;
	struct record *records;
	size_t count, capacity;
	uint64_t last_stamp;
	int reported;		/* something reported since the start or the last full reset */
};

/* One call to status_feed. */
struct feed {
	uint64_t now;
	const struct status_terminal *terminal;
	long front;		/* the group in front, asked once, when first needed */
	int asked;
};

struct slice {
	const unsigned char *at; /* NULL when absent */
	size_t len;
};

struct status *
status_new(void)
{
	return calloc(1, sizeof(struct status));
}

static void
scanner_free(struct scanner *sc)
{
	if (sc->inner != NULL) {
		scanner_free(sc->inner);
		free(sc->inner);
	}
	free(sc->body);
}

void
status_free(struct status *st)
{
	if (st == NULL)
		return;
	for (size_t i = 0; i < st->count; i++)
		free(st->records[i].text);
	free(st->records);
	scanner_free(&st->scanner);
	free(st);
}

static long
front(struct feed *f)
{
	if (!f->asked) {
		f->front = f->terminal->front(f->terminal->context);
		f->asked = 1;
	}
	return f->front;
}

/* Records. */

static struct record *
find(const struct status *st, const char *id, size_t len)
{
	for (size_t i = 0; i < st->count; i++) {
		struct record *r = &st->records[i];
		if (r->id_len == len && memcmp(r->id, id, len) == 0)
			return r;
	}
	return NULL;
}

/* Removes record i; the last record takes its place. */
static void
drop(struct status *st, size_t i)
{
	free(st->records[i].text);
	st->records[i] = st->records[--st->count];
}

/* Whether the record is `id` or below it. */
static int
within(const struct record *r, const unsigned char *id, size_t len)
{
	return r->id_len >= len && memcmp(r->id, id, len) == 0 && (r->id_len == len || r->id[len] == '/');
}

static int
lasting(const struct record *r)
{
	return r->state == DONE || r->state == ERROR;
}

static int
reset(struct status *st)
{
	int changed = st->reported || st->count > 0;
	while (st->count > 0)
		drop(st, st->count - 1);
	st->reported = 0;
	return changed;
}

/* The shell's next prompt ends what was working, blocked or idle. */
static int
prompt(struct status *st)
{
	int changed = 0;
	for (size_t i = 0; i < st->count;) {
		if (!lasting(&st->records[i])) {
			drop(st, i);
			changed = 1;
		} else
			i++;
	}
	return changed;
}

/* Drops the records of programs that have ended (status_feed). */
static int
settle(struct status *st, struct feed *f)
{
	const struct status_terminal *t = f->terminal;
	int changed = 0;
	for (size_t i = 0; i < st->count;) {
		const struct record *r = &st->records[i];
		long now = r->owner > 0 ? front(f) : -1;
		/* Done and error go once another program is in front; the rest once the shell is back. */
		int ended = now > 0 && (lasting(r) ? now != t->shell && now != r->owner
						   : now == t->shell && r->owner != t->shell);
		if (ended) {
			drop(st, i);
			changed = 1;
		} else
			i++;
	}
	return changed;
}

/* Values. */

static int
is_value_byte(unsigned char c)
{
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' ||
	    c == '.' || c == ',' || c == '+' || c == '/' || c == '=' || c == '-';
}

/* What an app name and each segment of an id are made of. */
static int
is_name_byte(unsigned char c)
{
	return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' ||
	    c == '.' || c == '+' || c == '-';
}

static struct slice
trim(const unsigned char *at, size_t len)
{
	while (len > 0 && at[0] == ' ') {
		at++;
		len--;
	}
	while (len > 0 && at[len - 1] == ' ')
		len--;
	return (struct slice){ at, len };
}

static int
equals(struct slice s, const char *word)
{
	size_t n = strlen(word);
	return s.at != NULL && s.len == n && memcmp(s.at, word, n) == 0;
}

static int
named(struct slice s, const char *const *names, int count)
{
	for (int i = 1; i < count; i++)
		if (equals(s, names[i]))
			return i;
	return 0;
}

static int
base64_digit(unsigned char c)
{
	if (c >= 'A' && c <= 'Z')
		return c - 'A';
	if (c >= 'a' && c <= 'z')
		return c - 'a' + 26;
	if (c >= '0' && c <= '9')
		return c - '0' + 52;
	if (c == '+')
		return 62;
	if (c == '/')
		return 63;
	return -1;
}

/*
 * Decodes base64, padding optional, into at most `cap` bytes of UTF-8 text with no control characters
 * (U+0000-001F, U+007F, U+0080-009F). Returns its length, or -1 when it is not that.
 */
static long
decode_text(struct slice s, unsigned char *out, size_t cap)
{
	size_t n = s.len, pad = 0;
	while (pad < 2 && n > 0 && s.at[n - 1] == '=') {
		n--;
		pad++;
	}
	if (n % 4 == 1 || (pad > 0 && (n + pad) % 4 != 0))
		return -1;
	if (n / 4 * 3 + (n % 4 ? n % 4 - 1 : 0) > cap)
		return -1;
	size_t len = 0;
	unsigned int bits = 0, held = 0;
	for (size_t i = 0; i < n; i++) {
		int digit = base64_digit(s.at[i]);
		if (digit < 0)
			return -1;
		bits = (bits << 6 | (unsigned int)digit) & 0xffffff;
		held += 6;
		if (held >= 8) {
			held -= 8;
			out[len++] = (unsigned char)(bits >> held);
		}
	}
	for (size_t i = 0; i < len;) {
		unsigned char c = out[i];
		size_t width;
		unsigned long point;
		if (c < 0x80) {
			width = 1;
			point = c;
		} else if (c >= 0xc2 && c <= 0xdf) {
			width = 2;
			point = c & 0x1f;
		} else if (c >= 0xe0 && c <= 0xef) {
			width = 3;
			point = c & 0x0f;
		} else if (c >= 0xf0 && c <= 0xf4) {
			width = 4;
			point = c & 0x07;
		} else
			return -1;
		if (i + width > len)
			return -1;
		for (size_t k = 1; k < width; k++) {
			if ((out[i + k] & 0xc0) != 0x80)
				return -1;
			point = point << 6 | (out[i + k] & 0x3f);
		}
		if ((width == 3 && point < 0x800) || (width == 4 && (point < 0x10000 || point > 0x10ffff)) ||
		    (point >= 0xd800 && point <= 0xdfff))
			return -1;
		if (point < 0x20 || (point >= 0x7f && point <= 0x9f))
			return -1;
		i += width;
	}
	return (long)len;
}

/* An id's limits: 128 bytes, 8 segments, 32 bytes a segment. */
static int
id_within_limits(struct slice s)
{
	if (s.len > ID_MAX)
		return 0;
	size_t segments = 1, segment = 0;
	for (size_t i = 0; i < s.len; i++) {
		if (s.at[i] == '/') {
			if (++segments > SEGMENTS_MAX)
				return 0;
			segment = 0;
		} else if (++segment > SEGMENT_MAX)
			return 0;
	}
	return 1;
}

/* An id is segments of [A-Za-z0-9_.+-], none empty, joined by "/". */
static int
id_valid(struct slice s)
{
	size_t segment = 0;
	for (size_t i = 0; i < s.len; i++) {
		if (s.at[i] == '/') {
			if (segment == 0)
				return 0;
			segment = 0;
		} else if (is_name_byte(s.at[i]))
			segment++;
		else
			return 0;
	}
	return segment > 0;
}

static int
app_valid(struct slice s)
{
	if (s.len == 0 || s.len > APP_MAX)
		return 0;
	for (size_t i = 0; i < s.len; i++)
		if (!is_name_byte(s.at[i]))
			return 0;
	return 1;
}

/* 0-100 in decimal, or -1. */
static int
progress_value(struct slice s)
{
	if (s.at == NULL || s.len == 0 || s.len > 3)
		return -1;
	int value = 0;
	for (size_t i = 0; i < s.len; i++) {
		if (s.at[i] < '0' || s.at[i] > '9')
			return -1;
		value = value * 10 + (s.at[i] - '0');
	}
	return value <= 100 ? value : -1;
}

/* Reports. */

/* What a report says, once every pair in it has passed. */
struct report {
	struct slice state, id, kind, progress, app;
	size_t title_len, msg_len;
	unsigned char title[TITLE_MAX];
	unsigned char msg[MSG_MAX];
};

/*
 * Takes one pair into the report: the last value of a key wins. A pair whose value has a byte the
 * protocol does not allow is skipped; so is a key it does not know, which takes in every key that is
 * not [a-z]+. Returns 0 when the pair breaks a limit or its text does not decode, which discards the
 * report.
 */
static int
take(struct report *r, struct slice key, struct slice value)
{
	if (key.len > KEY_MAX)
		return 0;
	if ((equals(key, "msg") && value.len > MSG_ENCODED_MAX) ||
	    (equals(key, "title") && value.len > TITLE_ENCODED_MAX) || (equals(key, "app") && value.len > APP_MAX) ||
	    (equals(key, "id") && !id_within_limits(value)))
		return 0;
	for (size_t i = 0; i < value.len; i++)
		if (!is_value_byte(value.at[i]))
			return 1;
	if (equals(key, "state"))
		r->state = value;
	else if (equals(key, "id"))
		r->id = value;
	else if (equals(key, "kind"))
		r->kind = value;
	else if (equals(key, "progress"))
		r->progress = value;
	else if (equals(key, "app"))
		r->app = value;
	else if (equals(key, "title") || equals(key, "msg")) {
		int title = equals(key, "title");
		long len = decode_text(value, title ? r->title : r->msg, title ? TITLE_MAX : MSG_MAX);
		if (len < 0)
			return 0;
		if (title)
			r->title_len = (size_t)len;
		else
			r->msg_len = (size_t)len;
	}
	return 1;
}

static uint64_t
next_stamp(struct status *st, uint64_t now)
{
	st->last_stamp = now > st->last_stamp ? now : st->last_stamp + 1;
	return st->last_stamp;
}

/* Makes room for one more record, removing the one updated least recently at the cap. */
static struct record *
new_record(struct status *st)
{
	if (st->count == RECORDS_MAX) {
		size_t oldest = 0;
		for (size_t i = 1; i < st->count; i++)
			if (st->records[i].stamp < st->records[oldest].stamp)
				oldest = i;
		drop(st, oldest);
	}
	if (st->count == st->capacity) {
		size_t capacity = st->capacity ? st->capacity * 2 : 2;
		if (capacity > RECORDS_MAX)
			capacity = RECORDS_MAX;
		struct record *records = realloc(st->records, capacity * sizeof *records);
		if (records == NULL)
			return NULL;
		st->records = records;
		st->capacity = capacity;
	}
	struct record *r = &st->records[st->count++];
	memset(r, 0, sizeof *r);
	return r;
}

/* One report's pairs, ESC ] 7501; and the terminator taken off. Returns whether it applied. */
static int
report(struct status *st, const unsigned char *body, size_t len, struct feed *f)
{
	struct report r;
	memset(&r, 0, offsetof(struct report, title));
	size_t start = 0;
	for (;;) {
		const unsigned char *colon = memchr(body + start, ':', len - start);
		size_t end = colon != NULL ? (size_t)(colon - body) : len;
		const unsigned char *equal = memchr(body + start, '=', end - start);
		if (equal != NULL) {
			size_t at = (size_t)(equal - body);
			struct slice key = trim(body + start, at - start);
			if (key.len > 0 && !take(&r, key, trim(equal + 1, end - at - 1)))
				return 0;
		}
		if (colon == NULL)
			break;
		start = end + 1;
	}

	/* OSC 7501 ; ?, the feature query, has no state, so it goes like any report without one. */
	enum state state = (enum state)named(r.state, state_names, CLEAR + 1);
	if (state == NONE || (r.id.at != NULL && !id_valid(r.id)))
		return 0;
	st->reported = 1;
	if (state == CLEAR) {
		for (size_t i = 0; i < st->count;) {
			if (r.id.at == NULL || within(&st->records[i], r.id.at, r.id.len))
				drop(st, i);
			else
				i++;
		}
		return 1;
	}

	const char *id = r.id.at != NULL ? (const char *)r.id.at : "";
	size_t id_len = r.id.at != NULL ? r.id.len : 0;
	struct record *rec = find(st, id, id_len);
	if (rec != NULL) {
		free(rec->text);
		rec->text = NULL;
	} else {
		rec = new_record(st);
		if (rec == NULL)
			return 1;
		memcpy(rec->id, id, id_len);
		rec->id_len = (unsigned char)id_len;
	}
	rec->state = (unsigned char)state;
	rec->kind = state == BLOCKED ? (unsigned char)named(r.kind, kind_names, AUTH + 1) : NO_KIND;
	rec->progress = (signed char)(state == WORKING || state == BLOCKED ? progress_value(r.progress) : -1);
	rec->app_len = 0;
	if (app_valid(r.app)) {
		memcpy(rec->app, r.app.at, r.app.len);
		rec->app_len = (unsigned char)r.app.len;
	}
	rec->title_len = 0;
	rec->msg_len = 0;
	if (r.title_len + r.msg_len > 0 && (rec->text = malloc(r.title_len + r.msg_len)) != NULL) {
		memcpy(rec->text, r.title, r.title_len);
		memcpy(rec->text + r.title_len, r.msg, r.msg_len);
		rec->title_len = (unsigned char)r.title_len;
		rec->msg_len = (unsigned short)r.msg_len;
	}
	rec->owner = front(f);
	rec->stamp = next_stamp(st, f->now);
	return 1;
}

/* Scanning. */

static int scan(struct status *, struct scanner *, const unsigned char *, size_t, struct feed *);

static void
osc_byte(struct scanner *sc, unsigned char c)
{
	unsigned int at = sc->len;
	if (sc->len <= SEQUENCE_MAX)
		sc->len++;
	switch (sc->osc) {
	case OSC_UNSURE:
		if (c != (unsigned char)report_prefix[at])
			sc->match &= ~1u;
		if (c != (unsigned char)prompt_prefix[at])
			sc->match &= ~2u;
		if (sc->match == 0)
			sc->osc = OSC_OTHER;
		else if (at == PREFIX_LEN - 1) {
			if (sc->match & 1) {
				if (sc->body == NULL)
					sc->body = malloc(BODY_MAX);
				sc->osc = sc->body != NULL ? OSC_REPORT : OSC_OTHER;
			} else
				sc->osc = OSC_PROMPT;
		}
		break;
	case OSC_REPORT:
		if (at - PREFIX_LEN < BODY_MAX)
			sc->body[at - PREFIX_LEN] = c;
		break;
	case OSC_PROMPT:
		/* 133;A ends there or goes on with options; 133;AB is something else. */
		sc->osc = c == ';' ? OSC_PROMPT_OPTIONS : OSC_OTHER;
		break;
	}
}

static int
osc_end(struct status *st, struct scanner *sc, unsigned int terminator, struct feed *f)
{
	switch (sc->osc) {
	case OSC_REPORT:
		if (2 + sc->len + terminator > SEQUENCE_MAX)
			return 0;
		return report(st, sc->body, sc->len - PREFIX_LEN, f);
	case OSC_PROMPT:
	case OSC_PROMPT_OPTIONS: {
		/* Only the shell's prompt counts: a program in front may mark zones in its own screen, as omp
		 * marks each message he sends it. */
		long now = front(f);
		return now <= 0 || now == f->terminal->shell ? prompt(st) : 0;
	}
	}
	return 0;
}

/* Bytes a passthrough carries, unescaped, for the terminal outside tmux. */
static int
pass(struct status *st, struct scanner *sc, const unsigned char *bytes, size_t len, struct feed *f)
{
	if (len == 0 || sc->depth >= NESTING_MAX)
		return 0;
	if (sc->inner == NULL) {
		if ((sc->inner = calloc(1, sizeof *sc->inner)) == NULL)
			return 0;
		sc->inner->depth = sc->depth + 1;
	}
	return scan(st, sc->inner, bytes, len, f);
}

/* tmux writes each passthrough out on its own, its own output in between: nothing carries over. */
static void
end_pass(struct scanner *sc)
{
	for (struct scanner *inner = sc->inner; inner != NULL; inner = inner->inner)
		inner->state = GROUND;
}

static int
scan(struct status *st, struct scanner *sc, const unsigned char *bytes, size_t len, struct feed *f)
{
	int changed = 0;
	size_t i = 0;
	while (i < len) {
		unsigned char c = bytes[i];
		const unsigned char *esc;
		switch (sc->state) {
		case GROUND:
		case DCS:
			if ((esc = memchr(bytes + i, ESC, len - i)) == NULL)
				return changed;
			i = (size_t)(esc - bytes) + 1;
			sc->state = sc->state == GROUND ? ESCAPE : DCS_ESCAPE;
			break;
		case ESCAPE:
			i++;
			if (c == ']') {
				sc->state = OSC;
				sc->osc = OSC_UNSURE;
				sc->match = 3;
				sc->len = 0;
			} else if (c == 'P') {
				sc->state = DCS_HEAD;
				sc->len = 0;
			} else if (c == 'c') {
				sc->state = GROUND;
				changed |= reset(st);
			} else if (c != ESC)
				sc->state = GROUND;
			break;
		case OSC:
			i++;
			if (c == BEL) {
				sc->state = GROUND;
				changed |= osc_end(st, sc, 1, f);
			} else if (c == ESC)
				sc->state = OSC_ESCAPE;
			else if (c == CAN || c == SUB)
				sc->state = GROUND;
			else if (c >= 0x20)
				osc_byte(sc, c);
			break;
		case OSC_ESCAPE:
			if (c == '\\') {
				i++;
				sc->state = GROUND;
				changed |= osc_end(st, sc, 2, f);
			} else
				sc->state = ESCAPE; /* not a terminator: the OSC is dropped and c read again */
			break;
		case DCS_HEAD:
			i++;
			if (c == ESC)
				sc->state = DCS_ESCAPE;
			else if (c == (unsigned char)passthrough_prefix[sc->len]) {
				if (++sc->len == sizeof passthrough_prefix - 1)
					sc->state = PASS;
			} else
				sc->state = DCS;
			break;
		case DCS_ESCAPE:
			/* Only ESC \ ends a DCS; ESC and any other byte is that byte. */
			i++;
			sc->state = c == '\\' ? GROUND : DCS;
			break;
		case PASS: {
			esc = memchr(bytes + i, ESC, len - i);
			size_t end = esc != NULL ? (size_t)(esc - bytes) : len;
			changed |= pass(st, sc, bytes + i, end - i, f);
			i = end;
			if (esc != NULL) {
				i++;
				sc->state = PASS_ESCAPE;
			}
			break;
		}
		case PASS_ESCAPE:
			i++;
			if (c == '\\') {
				sc->state = GROUND;
				end_pass(sc);
			} else {
				sc->state = PASS;
				changed |= pass(st, sc, &c, 1, f);
			}
			break;
		}
	}
	return changed;
}

int
status_feed(struct status *st, const unsigned char *bytes, size_t length, uint64_t now,
    const struct status_terminal *terminal)
{
	struct feed f = { now, terminal, -1, 0 };
	int changed = scan(st, &st->scanner, bytes, length, &f);
	if (st->count > 0)
		changed |= settle(st, &f);
	return changed;
}

/* The summary. */

struct out {
	char *at;
	size_t left; /* bytes left, the NUL included */
	int overflow;
};

static void
put(struct out *o, const void *bytes, size_t len)
{
	if (o->overflow || len >= o->left) {
		o->overflow = 1;
		return;
	}
	memcpy(o->at, bytes, len);
	o->at += len;
	o->left -= len;
	*o->at = '\0';
}

static void
put_text(struct out *o, const char *text)
{
	put(o, text, strlen(text));
}

static void
put_number(struct out *o, uint64_t n)
{
	char digits[20];
	size_t i = sizeof digits;
	do
		digits[--i] = (char)('0' + n % 10);
	while ((n /= 10) > 0);
	put(o, digits + i, sizeof digits - i);
}

static void
put_base64(struct out *o, const unsigned char *bytes, size_t len)
{
	static const char digits[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
	for (size_t i = 0; i < len; i += 3) {
		unsigned long group = (unsigned long)bytes[i] << 16;
		if (i + 1 < len)
			group |= (unsigned long)bytes[i + 1] << 8;
		if (i + 2 < len)
			group |= bytes[i + 2];
		char quad[4] = { digits[group >> 18 & 63], digits[group >> 12 & 63],
			i + 1 < len ? digits[group >> 6 & 63] : '=', i + 2 < len ? digits[group & 63] : '=' };
		put(o, quad, 4);
	}
}

/* The record itself when it names an app, else its nearest ancestor that does, else NULL. */
static const struct record *
app_source(const struct status *st, const struct record *r)
{
	size_t len = r->id_len;
	const struct record *at = r;
	while (at == NULL || at->app_len == 0) {
		if (len == 0)
			return NULL;
		while (len > 0 && r->id[len - 1] != '/')
			len--;
		if (len > 0)
			len--;
		at = find(st, r->id, len);
	}
	return at;
}

static void
put_record(struct out *o, const struct status *st, const struct record *r, size_t msg_limit)
{
	put_text(o, "state=");
	put_text(o, state_names[r->state]);
	if (r->kind != NO_KIND) {
		put_text(o, ":kind=");
		put_text(o, kind_names[r->kind]);
	}
	if (r->progress >= 0) {
		put_text(o, ":progress=");
		put_number(o, (uint64_t)r->progress);
	}
	const struct record *app = app_source(st, r);
	if (app != NULL) {
		put_text(o, ":app=");
		put(o, app->app, app->app_len);
	}
	if (r->title_len > 0) {
		put_text(o, ":title=");
		put_base64(o, r->text, r->title_len);
	}
	if (r->msg_len > 0) {
		const unsigned char *msg = r->text + r->title_len;
		put_text(o, ":msg=");
		if (r->msg_len <= msg_limit)
			put_base64(o, msg, r->msg_len);
		else {
			unsigned char cut[SUMMARY_MSG_MAX];
			size_t len = msg_limit - 3;
			while (len > 0 && (msg[len] & 0xc0) == 0x80)
				len--;
			memcpy(cut, msg, len);
			memcpy(cut + len, "\xe2\x80\xa6", 3);
			put_base64(o, cut, len + 3);
		}
	}
}

void
status_summary(const struct status *st, char *summary)
{
	struct out o = { summary, STATUS_SUMMARY_MAX, 0 };
	*summary = '\0';
	if (!st->reported)
		return;
	const struct record *shown = NULL;
	for (size_t i = 0; i < st->count; i++) {
		const struct record *r = &st->records[i];
		if (shown == NULL || r->state > shown->state || (r->state == shown->state && r->stamp > shown->stamp))
			shown = r;
	}
	if (shown != NULL) {
		put_record(&o, st, shown, SUMMARY_MSG_MAX);
		put_text(&o, ":");
	}
	put_text(&o, "records=");
	put_number(&o, st->count);
	if (shown != NULL && lasting(shown)) {
		put_text(&o, ":seq=");
		put_number(&o, shown->stamp);
	}
}

void
status_snapshot(const struct status *st, char *snapshot)
{
	status_summary(st, snapshot);
	if (!st->reported || st->count == 0)
		return;
	char items[STATUS_ITEMS_MAX];
	items[0] = '\0';
	struct out records = { items, sizeof items, 0 };
	for (size_t i = 0; i < st->count && !records.overflow; i++) {
		const struct record *r = &st->records[i];
		if (i > 0)
			put_text(&records, "\n");
		put_text(&records, "id=");
		put(&records, r->id, r->id_len);
		put_text(&records, ":");
		put_record(&records, st, r, MSG_MAX);
		if (lasting(r)) {
			put_text(&records, ":seq=");
			put_number(&records, r->stamp);
		}
	}
	size_t length = strlen(snapshot);
	struct out o = { snapshot + length, STATUS_SNAPSHOT_MAX - length, 0 };
	put_text(&o, ":items=");
	if (records.overflow)
		put_text(&o, "unavailable");
	else
		put_base64(&o, (const unsigned char *)items, (size_t)(records.at - items));
}
