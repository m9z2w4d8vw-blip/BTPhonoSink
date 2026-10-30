/* BTPSV89Session.h - v8.9 one-tap Start/Stop from Settings.
 *
 * Old flow: turn on two one-shot switches, then run `ssh ... "sudo killall -9 bluetoothd"`.
 * New flow: Settings writes a short request and posts a Darwin notification. The tweak, which is already running
 * inside bluetoothd, validates and consumes the request, sets or clears exactly the same two one-shot switches,
 * and then ends its own process with SIGKILL - the same thing `killall -9 bluetoothd` did. launchd relaunches
 * bluetoothd and the existing one-shot code consumes the switches exactly as before.
 * No root helper, shell, spawned process or new privilege is involved.
 *
 * The validation helpers below are pure C (no Apple frameworks) so the host tests can run them.
 */
#pragma once
#include <stddef.h>
#include <string.h>

#ifdef __cplusplus
extern "C" {
#endif

enum { BTPS_V89_ACTION_NONE = 0, BTPS_V89_ACTION_START = 1, BTPS_V89_ACTION_STOP = 2 };

static inline int btps_v89_parse_action(const char *action)
{
    if (!action) return BTPS_V89_ACTION_NONE;
    if (strcmp(action, "start") == 0) return BTPS_V89_ACTION_START;
    if (strcmp(action, "stop") == 0) return BTPS_V89_ACTION_STOP;
    return BTPS_V89_ACTION_NONE;
}

/* Settings sends an NSUUID string. Accept 8..40 characters of hex digits and hyphens only. */
static inline int btps_v89_nonce_valid(const char *nonce)
{
    if (!nonce) return 0;
    size_t n = strlen(nonce);
    if (n < 8 || n > 40) return 0;
    for (size_t i = 0; i < n; i++) {
        char c = nonce[i];
        int ok = (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == '-';
        if (!ok) return 0;
    }
    return 1;
}

/* A request is honoured only within 30 s of being written (5 s of clock tolerance into the future). */
static inline int btps_v89_request_fresh(double requested, double now)
{
    return requested > 0.0 && requested <= now + 5.0 && now - requested <= 30.0;
}

/* Registers the Settings listener. Call right after BTPSLogInit(), before any hook can be refused. */
void BTPSV89SessionStart(void);

/* Call at the end of the constructor: reports the outcome of a Settings-requested restart. */
void BTPSV89SessionReport(int trial_armed, int receive_ready);

#ifdef __cplusplus
}
#endif
