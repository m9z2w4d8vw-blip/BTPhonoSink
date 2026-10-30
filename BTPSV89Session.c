/* BTPSV89Session.c - v8.9.2 one-tap Start/Stop, handled inside bluetoothd.
 *
 * The notification handler runs on its own serial dispatch queue, never on a Bluetooth hook or receive thread.
 * A request is consumed (deleted) before it is acted on, so it is honoured at most once. Switches are written
 * and read back before the restart; if anything cannot be verified, Bluetooth is NOT restarted.
 *
 * The restart is SIGKILL to this very process. launchd only sees "bluetoothd exited on signal 9", exactly as
 * after `killall -9 bluetoothd`, which reliably relaunches it on the tested phone. bluetoothd runs as mobile
 * (which is why Settings can read the preferences it writes), so system-domain `launchctl kickstart` is not
 * available to it; v8.9.1 tried that and is reverted. Killing yourself needs no privilege and no sandbox rule.
 *
 * History: v8.9.0's "Still waiting" reports were NOT this restart failing. The running bluetoothd still had the
 * pre-v8.9 tweak loaded (installing a package does not restart daemons), so nothing was listening. The package
 * postinst now restarts bluetoothd so a freshly installed tweak is always the one running.
 */
#include "BTPSV89Session.h"
#include "BTPSLog.h"
#include "BTPSShared.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <notify.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

#define V89_DOMAIN CFSTR(BTPS_PREFS_DOMAIN)

static dispatch_queue_t g_v89_queue;
static int g_v89_token = -1;
static int g_v89_restarting;               /* only touched on g_v89_queue */

static double v89_now(void)
{
    return (double)time(NULL);
}

static int v89_copy_string(CFDictionaryRef d, CFStringRef key, char *out, size_t cap)
{
    CFTypeRef v = CFDictionaryGetValue(d, key);
    return v && CFGetTypeID(v) == CFStringGetTypeID() &&
           CFStringGetCString((CFStringRef)v, out, (CFIndex)cap, kCFStringEncodingUTF8);
}

static int v89_copy_double(CFDictionaryRef d, CFStringRef key, double *out)
{
    CFTypeRef v = CFDictionaryGetValue(d, key);
    return v && CFGetTypeID(v) == CFNumberGetTypeID() &&
           CFNumberGetValue((CFNumberRef)v, kCFNumberDoubleType, out);
}

/* Reads {action, nonce, time} under `key` and deletes it.
 * 0 = absent, 1 = read, -1 = could not be deleted (never act on it), -2 = malformed. */
static int v89_take_record(CFStringRef key, char action[16], char nonce[48], double *when)
{
    (void)CFPreferencesAppSynchronize(V89_DOMAIN);
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, V89_DOMAIN);
    if (!v) return 0;
    int ok = CFGetTypeID(v) == CFDictionaryGetTypeID() &&
             v89_copy_string((CFDictionaryRef)v, CFSTR("action"), action, 16) &&
             v89_copy_string((CFDictionaryRef)v, CFSTR("nonce"), nonce, 48) &&
             v89_copy_double((CFDictionaryRef)v, CFSTR("time"), when);
    CFRelease(v);
    CFPreferencesSetAppValue(key, NULL, V89_DOMAIN);
    if (!CFPreferencesAppSynchronize(V89_DOMAIN)) return -1;
    return ok ? 1 : -2;
}

static int v89_read_bool(CFStringRef key, int *out)
{
    CFPropertyListRef v = CFPreferencesCopyAppValue(key, V89_DOMAIN);
    int ok = v && CFGetTypeID(v) == CFBooleanGetTypeID();
    if (ok) *out = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
    if (v) CFRelease(v);
    return ok;
}

/* Sets (start) or clears (stop) exactly the two existing one-shot switches, plus a marker that lets the
 * relaunched daemon report back to Settings. Returns 1 only if everything reads back as written. */
static int v89_write_switches(int start, const char *nonce, double when)
{
    CFBooleanRef arm = start ? kCFBooleanTrue : kCFBooleanFalse;
    CFPreferencesSetAppValue(CFSTR(BTPS_KEY_V81_SEVEN_ONCE), arm, V89_DOMAIN);
    CFPreferencesSetAppValue(CFSTR(BTPS_KEY_V82_DECISIVE_ONCE), arm, V89_DOMAIN);
    /* The v8.2 gate refuses while the retired legacy flag is ON, so Start turns it off. */
    if (start) CFPreferencesSetAppValue(CFSTR(BTPS_KEY_EXPERIMENTS), kCFBooleanFalse, V89_DOMAIN);

    CFStringRef action = start ? CFSTR("start") : CFSTR("stop");
    CFStringRef nonce_s = CFStringCreateWithCString(kCFAllocatorDefault, nonce, kCFStringEncodingUTF8);
    CFNumberRef when_n = CFNumberCreate(kCFAllocatorDefault, kCFNumberDoubleType, &when);
    int marker_ok = 0;
    if (nonce_s && when_n) {
        const void *keys[3] = { CFSTR("action"), CFSTR("nonce"), CFSTR("time") };
        const void *values[3] = { action, nonce_s, when_n };
        CFDictionaryRef marker = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 3,
                                                    &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
        if (marker) {
            CFPreferencesSetAppValue(CFSTR(BTPS_KEY_V89_PENDING), marker, V89_DOMAIN);
            CFRelease(marker);
            marker_ok = 1;
        }
    }
    if (nonce_s) CFRelease(nonce_s);
    if (when_n) CFRelease(when_n);
    if (!marker_ok || !CFPreferencesAppSynchronize(V89_DOMAIN)) return 0;

    int seven = -1, decisive = -1, legacy = 1;
    if (!v89_read_bool(CFSTR(BTPS_KEY_V81_SEVEN_ONCE), &seven) || seven != start) return 0;
    if (!v89_read_bool(CFSTR(BTPS_KEY_V82_DECISIVE_ONCE), &decisive) || decisive != start) return 0;
    if (start && (!v89_read_bool(CFSTR(BTPS_KEY_EXPERIMENTS), &legacy) || legacy)) return 0;
    return 1;
}

static void v89_handle_request(void)
{
    if (g_v89_restarting) return;
    char action[16] = {0}, nonce[48] = {0};
    double when = 0.0;
    int got = v89_take_record(CFSTR(BTPS_KEY_V89_REQUEST), action, nonce, &when);
    if (got == 0) {
        BTPSLog("V89_SESSION notification without a request; ignored");
        return;
    }
    int act = got == 1 ? btps_v89_parse_action(action) : BTPS_V89_ACTION_NONE;
    const char *why = got == -1 ? "request could not be consumed" :
                      got == -2 ? "malformed request" :
                      act == BTPS_V89_ACTION_NONE ? "unknown action" :
                      !btps_v89_nonce_valid(nonce) ? "bad nonce" :
                      !btps_v89_request_fresh(when, v89_now()) ? "stale request" : NULL;
    if (why) {
        BTPSSetStatus(BTPS_STATUS_V89_SESSION, "REFUSED nonce=%s reason=%s; Bluetooth not restarted",
                      btps_v89_nonce_valid(nonce) ? nonce : "-", why);
        BTPSLog("V89_SESSION REFUSED: %s; Bluetooth not restarted", why);
        return;
    }
    int start = act == BTPS_V89_ACTION_START;
    if (!v89_write_switches(start, nonce, v89_now())) {
        BTPSSetStatus(BTPS_STATUS_V89_SESSION,
                      "REFUSED nonce=%s reason=switches could not be saved; Bluetooth not restarted", nonce);
        BTPSLog("V89_SESSION REFUSED: one-shot switches could not be saved and verified");
        return;
    }
    g_v89_restarting = 1;
    BTPSLogNow("V89_SESSION %s nonce=%s: one-shot switches %s; restarting bluetoothd (SIGKILL, same as killall -9)",
               action, nonce, start ? "ARMED" : "cleared");
    (void)kill(getpid(), SIGKILL);
    _exit(1); /* only reached if SIGKILL was somehow refused; launchd restarts bluetoothd either way */
}

void BTPSV89SessionStart(void)
{
    if (g_v89_queue) return;
    g_v89_queue = dispatch_queue_create("com.parv.btphonosink.v89.session", DISPATCH_QUEUE_SERIAL);
    if (!g_v89_queue) {
        BTPSSetStatus(BTPS_STATUS_V89_SESSION, "UNAVAILABLE: no worker queue; use the manual switches");
        return;
    }
    uint32_t r = notify_register_dispatch(BTPS_NOTIFY_V89_SESSION, &g_v89_token, g_v89_queue, ^(int token) {
        (void)token;
        v89_handle_request();
    });
    if (r == NOTIFY_STATUS_OK) {
        BTPSLog("V89_SESSION Settings Start/Stop listener ready");
    } else {
        BTPSSetStatus(BTPS_STATUS_V89_SESSION, "UNAVAILABLE: notify_register_dispatch=%u; use the manual switches",
                      (unsigned)r);
        BTPSLogNow("V89_SESSION listener unavailable: notify_register_dispatch=%u", (unsigned)r);
    }
}

void BTPSV89SessionReport(int trial_armed, int receive_ready)
{
    char action[16] = {0}, nonce[48] = {0};
    double when = 0.0;
    int got = v89_take_record(CFSTR(BTPS_KEY_V89_PENDING), action, nonce, &when);
    if (got == 0) {
        BTPSSetStatus(BTPS_STATUS_V89_SESSION, "idle: this Bluetooth launch was not requested from Settings");
        return;
    }
    int act = got == 1 ? btps_v89_parse_action(action) : BTPS_V89_ACTION_NONE;
    double now = v89_now();
    if (act == BTPS_V89_ACTION_NONE || !btps_v89_nonce_valid(nonce) || when > now + 5.0 || now - when > 180.0) {
        BTPSSetStatus(BTPS_STATUS_V89_SESSION, "idle: ignored an old or malformed restart marker");
        BTPSLog("V89_SESSION ignored an old or malformed restart marker");
        return;
    }
    const char *result = act == BTPS_V89_ACTION_START
        ? (trial_armed ? (receive_ready ? "ARMED" : "ARMED_INCOMPLETE") : "REFUSED")
        : (trial_armed ? "STILL_ARMED" : "OFF");
    BTPSSetStatus(BTPS_STATUS_V89_SESSION, "%s nonce=%s pid=%d result=%s", action, nonce, (int)getpid(), result);
    BTPSLog("V89_SESSION relaunched for %s nonce=%s pid=%d result=%s", action, nonce, (int)getpid(), result);
}
