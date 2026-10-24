/* BTPSCore.h - pure C helpers for the debug log (no Apple APIs, so they can be unit-tested anywhere). */
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BTPS_RING_LINES 480     /* lines kept                                            */
#define BTPS_LINE_MAX   300     /* bytes per line including the terminating NUL          */

typedef struct {
    char               line[BTPS_RING_LINES][BTPS_LINE_MAX];
    unsigned           head;    /* index of the OLDEST line                              */
    unsigned           count;   /* number of valid lines                                 */
    unsigned long long seq;     /* total lines ever pushed                               */
} btps_ring_t;

void               btps_ring_init(btps_ring_t *r);
void               btps_ring_push(btps_ring_t *r, const char *text);   /* newlines -> spaces, truncated to fit */
unsigned           btps_ring_count(const btps_ring_t *r);
const char        *btps_ring_at(const btps_ring_t *r, unsigned i);     /* 0 = oldest; NULL if out of range     */
unsigned long long btps_ring_seq(const btps_ring_t *r);
size_t             btps_ring_join(const btps_ring_t *r, char *out, size_t cap);   /* newline-joined, always NUL-terminated */

/* "HH:MM:SS.mmm" in local time. `out` must hold at least 16 bytes. */
void               btps_fmt_time(char *out, size_t cap);

/* "de ad be ef ..." for up to n bytes; returns the number of bytes rendered. */
size_t             btps_hex(const void *p, size_t n, char *out, size_t cap);

#ifdef __cplusplus
}
#endif
