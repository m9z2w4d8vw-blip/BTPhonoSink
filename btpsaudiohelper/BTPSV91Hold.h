/* BTPSV91Hold.h - v9.1: when BTPSAudioHelper may start its output, and when it lets go of it.
 *
 * Pure C with no Apple frameworks, so the host tests can run it (the same pattern as BTPSV89Output.h).
 *
 * Why: the 23:33 export and its screen recording. With wired earbuds plugged in and "iPhone speaker" selected,
 * Control Center switched between "Headphones" and LAPTOP-UGIVBIA5 every 0.71 s for minutes and nothing played.
 * It was a feedback loop between the helper and iOS:
 *
 *   1. iOS lists the sending PC as a Bluetooth output, and Apple's own A2DP code in bluetoothd starts and suspends the
 *      PC's stream as if the iPhone were sending to it. All 25 STARTs and 25 SUSPENDs in the loop came from the
 *      phone (the PC only accepted them), each one right after the helper activated or deactivated its audio session.
 *   2. The tweak reports each START/SUSPEND as a new stream generation (+3 per cycle: 652, 655, 658, ...).
 *   3. The helper treated every generation change as a new stream: it stopped its AudioQueue, deactivated its session,
 *      and reactivated it about 0.4 s later for the next packets. Each of those session changes re-routed iOS, which
 *      made bluetoothd send the next START or SUSPEND. No AudioQueue lived longer than 30 ms.
 *
 * The policy breaks the loop on the helper's side, whichever iOS mechanism is behind step 1:
 *   - A running output is KEPT through a stream gap: a SUSPEND, a close and reopen, a track change or a pause. Only
 *     stale PCM is dropped. The audio session therefore never changes because the stream did. The output is released
 *     only after BTPS_V91_HOLD_MS without media, which also covers Windows closing and reopening the stream after the
 *     phone suspends it (21:35 log in TESTING-v8.9.4: SUSPEND, CLOSE 3.7 s later, reopen 6.1 s later).
 *   - After the helper lets go on its own (hold expired, route refused, start or enqueue error), it does not activate
 *     again for BTPS_V91_REARM_MS, so it can never switch iOS's audio around faster than that, whatever the cause.
 *   - Starting from idle needs audible PCM. Exact digital silence (what the PC sends when the phone restarts a stream
 *     the PC had paused: 23:33:36 to 23:33:44, peak=0) never activates the session.
 * A user action (a new output setting) or a real device change (headphones plugged in or unplugged) skips the wait.
 */
#pragma once
#include <stdint.h>

#define BTPS_V91_HOLD_MS  8000u   /* keep a running output this long without media */
#define BTPS_V91_REARM_MS 3000u   /* minimum time between letting go on our own and the next activation */

typedef struct {
    uint64_t media_ms;   /* last decoded packet written to the running output */
    uint64_t rearm_ms;   /* automatic starts are refused before this time; 0 = no wait */
    unsigned running;    /* an AudioQueue is running on an active session */
} btps_v91_hold;

enum {
    BTPS_V91_START_OK = 0,
    BTPS_V91_START_RUNNING = 1,   /* already playing: just write the PCM */
    BTPS_V91_START_REARM = 2,     /* the helper let go less than BTPS_V91_REARM_MS ago */
    BTPS_V91_START_SILENT = 3,    /* nothing audible to play yet */
};

/* Why the helper releases its output. Only AUTOMATIC releases arm the rearm wait. */
enum { BTPS_V91_RELEASE_AUTOMATIC = 1, BTPS_V91_RELEASE_REQUESTED = 0 };

static inline void btps_v91_started(btps_v91_hold *h, uint64_t now)
{
    h->running = 1;
    h->media_ms = now;
    h->rearm_ms = 0;
}

/* A decoded packet of the current stream reached the running output (silence counts: the PC is still sending). */
static inline void btps_v91_media(btps_v91_hold *h, uint64_t now)
{
    if (h->running) h->media_ms = now;
}

/* A new stream generation while playing: keep the output. Returns 1 when the caller must keep the queue and session
 * and drop only the stale PCM; 0 when nothing is running. It never asks for a stop: that is the whole point. */
static inline int btps_v91_generation_changed(const btps_v91_hold *h)
{
    return h->running ? 1 : 0;
}

/* True once a running output has had no media for the hold time. */
static inline int btps_v91_expired(const btps_v91_hold *h, uint64_t now)
{
    return h->running && now >= h->media_ms && now - h->media_ms >= BTPS_V91_HOLD_MS;
}

static inline void btps_v91_released(btps_v91_hold *h, uint64_t now, int automatic)
{
    h->running = 0;
    h->rearm_ms = automatic ? now + BTPS_V91_REARM_MS : 0;
}

/* A user action or a real device change: the next start may happen at once. */
static inline void btps_v91_rearm_now(btps_v91_hold *h)
{
    h->rearm_ms = 0;
}

/* May the helper start its output for a decoded packet? audible = the packet decoded to at least one nonzero sample. */
static inline int btps_v91_may_start(const btps_v91_hold *h, uint64_t now, int audible)
{
    if (h->running) return BTPS_V91_START_RUNNING;
    if (h->rearm_ms && now < h->rearm_ms) return BTPS_V91_START_REARM;
    if (!audible) return BTPS_V91_START_SILENT;
    return BTPS_V91_START_OK;
}

static inline const char *btps_v91_start_reason(int code)
{
    switch (code) {
    case BTPS_V91_START_OK: return "ok";
    case BTPS_V91_START_RUNNING: return "running";
    case BTPS_V91_START_REARM: return "rearm_wait";
    case BTPS_V91_START_SILENT: return "silent_stream";
    default: return "unknown";
    }
}

/* AVAudioSessionRouteChangeReason values (public, stable since iOS 6). A route change the helper did not cause and
 * that is a real device arrival or removal lets the next start skip the rearm wait. */
enum { BTPS_V91_ROUTE_NEW_DEVICE = 1, BTPS_V91_ROUTE_OLD_DEVICE_GONE = 2 };

static inline int btps_v91_route_is_device_change(long reason)
{
    return reason == BTPS_V91_ROUTE_NEW_DEVICE || reason == BTPS_V91_ROUTE_OLD_DEVICE_GONE;
}

static inline const char *btps_v91_route_reason_name(long reason)
{
    switch (reason) {
    case 0: return "unknown";
    case 1: return "new_device";
    case 2: return "old_device_gone";
    case 3: return "category_change";
    case 4: return "override";
    case 6: return "wake_from_sleep";
    case 7: return "no_suitable_route";
    case 8: return "route_configuration_change";
    default: return "other";
    }
}
