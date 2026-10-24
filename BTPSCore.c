/* BTPSCore.c - see BTPSCore.h */
#include "BTPSCore.h"

#include <stdio.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

void btps_ring_init(btps_ring_t *r)
{
    memset(r, 0, sizeof *r);
}

void btps_ring_push(btps_ring_t *r, const char *text)
{
    unsigned slot;
    if (r->count < BTPS_RING_LINES) {
        slot = (r->head + r->count) % BTPS_RING_LINES;
        r->count++;
    } else {                                   /* full: overwrite the oldest line */
        slot = r->head;
        r->head = (r->head + 1) % BTPS_RING_LINES;
    }
    char *dst = r->line[slot];
    size_t i = 0;
    for (; text && text[i] && i < BTPS_LINE_MAX - 1; i++) {
        char c = text[i];
        dst[i] = (c == '\n' || c == '\r') ? ' ' : c;
    }
    dst[i] = '\0';
    r->seq++;
}

unsigned btps_ring_count(const btps_ring_t *r) { return r->count; }

const char *btps_ring_at(const btps_ring_t *r, unsigned i)
{
    if (i >= r->count) return NULL;
    return r->line[(r->head + i) % BTPS_RING_LINES];
}

unsigned long long btps_ring_seq(const btps_ring_t *r) { return r->seq; }

size_t btps_ring_join(const btps_ring_t *r, char *out, size_t cap)
{
    size_t used = 0;
    if (cap == 0) return 0;
    for (unsigned i = 0; i < r->count; i++) {
        const char *s = btps_ring_at(r, i);
        size_t n = strlen(s);
        if (used + n + 1 >= cap) break;        /* keep room for the NUL */
        memcpy(out + used, s, n);
        used += n;
        out[used++] = '\n';
    }
    out[used] = '\0';
    return used;
}

void btps_fmt_time(char *out, size_t cap)
{
    struct timeval tv;
    struct tm tmv;
    gettimeofday(&tv, NULL);
    time_t secs = tv.tv_sec;
    localtime_r(&secs, &tmv);
    snprintf(out, cap, "%02d:%02d:%02d.%03d", tmv.tm_hour, tmv.tm_min, tmv.tm_sec, (int)(tv.tv_usec / 1000));
}

size_t btps_hex(const void *p, size_t n, char *out, size_t cap)
{
    const unsigned char *b = (const unsigned char *)p;
    size_t done = 0, used = 0;
    if (cap == 0) return 0;
    for (; done < n; done++) {
        if (used + 3 >= cap) break;
        used += (size_t)snprintf(out + used, cap - used, done ? " %02x" : "%02x", b[done]);
    }
    out[used < cap ? used : cap - 1] = '\0';
    return done;
}
