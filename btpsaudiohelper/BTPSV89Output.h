/* BTPSV89Output.h - v8.9 audio output policy for BTPSAudioHelper.
 *
 * Pure C with no Apple frameworks, so the host tests can run it. BTPSV88Stream.m classifies every
 * AVAudioSession output port into a btps_v89_kind using the real AVAudioSessionPort constants and then asks
 * this policy whether playback may start, or continue, on the current route.
 *
 *   speaker     exactly the iPhone's built-in speaker (the v8.8.1 behaviour, and the default)
 *   headphones  only wired, USB or Bluetooth headphones; waits if none is the current output
 *   any         whatever iOS is using (Control Center / route picker), except devices on the never-play list
 *
 * The never-play list exists because the PC that sends the audio is itself connected over Bluetooth, so iOS can
 * list it as an output. Playing there is silent, so the user marks it once and the helper refuses it.
 */
#pragma once
#include <stddef.h>
#include <string.h>
#include <strings.h>

enum { BTPS_V89_MODE_SPEAKER = 0, BTPS_V89_MODE_HEADPHONES = 1, BTPS_V89_MODE_ANY = 2 };

typedef enum {
    BTPS_V89_PORT_OTHER = 0,      /* AirPlay, CarPlay, HDMI, line out, anything unknown */
    BTPS_V89_PORT_SPEAKER = 1,    /* built-in speaker */
    BTPS_V89_PORT_RECEIVER = 2,   /* built-in earpiece */
    BTPS_V89_PORT_HEADPHONES = 3, /* wired, USB, Bluetooth A2DP / LE / HFP */
} btps_v89_kind;

typedef struct { btps_v89_kind kind; const char *uid; const char *name; } btps_v89_port;
typedef struct { const char *uid; const char *name; } btps_v89_never;

enum {
    BTPS_V89_ROUTE_OK = 0,
    BTPS_V89_ROUTE_NO_OUTPUT = 1,
    BTPS_V89_ROUTE_NOT_SPEAKER = 2,
    BTPS_V89_ROUTE_NOT_HEADPHONES = 3,
    BTPS_V89_ROUTE_NEVER_LISTED = 4,
};

#define BTPS_V89_MAX_PORTS 8u
#define BTPS_V89_MAX_NEVER 16u

/* Unknown or missing values fall back to the speaker, the tested default. */
static inline int btps_v89_mode_from_string(const char *s)
{
    if (s && strcmp(s, "headphones") == 0) return BTPS_V89_MODE_HEADPHONES;
    if (s && strcmp(s, "any") == 0) return BTPS_V89_MODE_ANY;
    return BTPS_V89_MODE_SPEAKER;
}

static inline const char *btps_v89_mode_name(int mode)
{
    return mode == BTPS_V89_MODE_HEADPHONES ? "headphones" : mode == BTPS_V89_MODE_ANY ? "any" : "speaker";
}

static inline int btps_v89_same(const char *a, const char *b)
{
    return a && b && a[0] && b[0] && strcasecmp(a, b) == 0;
}

/* The iPhone's own speaker and earpiece can never be excluded. */
static inline int btps_v89_never_listed(const btps_v89_port *port, const btps_v89_never *never, size_t count)
{
    if (port->kind == BTPS_V89_PORT_SPEAKER || port->kind == BTPS_V89_PORT_RECEIVER) return 0;
    for (size_t i = 0; i < count; i++)
        if (btps_v89_same(port->uid, never[i].uid) || btps_v89_same(port->name, never[i].name)) return 1;
    return 0;
}

/* Returns BTPS_V89_ROUTE_OK when playback may use this route; otherwise the reason. *offending receives the
 * index of the port that caused a refusal (0 when the reason is not tied to one port). */
static inline int btps_v89_route_check(int mode, const btps_v89_port *ports, size_t count,
                                       const btps_v89_never *never, size_t never_count, size_t *offending)
{
    if (offending) *offending = 0;
    if (!ports || count == 0) return BTPS_V89_ROUTE_NO_OUTPUT;
    if (mode == BTPS_V89_MODE_HEADPHONES || mode == BTPS_V89_MODE_ANY) {
        for (size_t i = 0; i < count; i++) {
            if (btps_v89_never_listed(&ports[i], never, never_count)) {
                if (offending) *offending = i;
                return BTPS_V89_ROUTE_NEVER_LISTED;
            }
            if (mode == BTPS_V89_MODE_HEADPHONES && ports[i].kind != BTPS_V89_PORT_HEADPHONES) {
                if (offending) *offending = i;
                return BTPS_V89_ROUTE_NOT_HEADPHONES;
            }
        }
        return BTPS_V89_ROUTE_OK;
    }
    return count == 1 && ports[0].kind == BTPS_V89_PORT_SPEAKER ? BTPS_V89_ROUTE_OK : BTPS_V89_ROUTE_NOT_SPEAKER;
}

static inline const char *btps_v89_route_reason(int code)
{
    switch (code) {
    case BTPS_V89_ROUTE_OK: return "ok";
    case BTPS_V89_ROUTE_NO_OUTPUT: return "no output";
    case BTPS_V89_ROUTE_NOT_SPEAKER: return "speaker not selected";
    case BTPS_V89_ROUTE_NOT_HEADPHONES: return "no headphones connected";
    case BTPS_V89_ROUTE_NEVER_LISTED: return "on the never-play list";
    default: return "unknown";
    }
}
