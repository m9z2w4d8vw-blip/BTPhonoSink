/* BTPSV89Session.c - v8.9.1 one-tap Start/Stop, handled inside bluetoothd.
 *
 * The notification handler runs on its own serial dispatch queue, never on a Bluetooth hook or receive thread.
 * A request is consumed (deleted) before it is acted on, so it is honoured at most once. Switches are written
 * and read back before the restart; if anything cannot be verified, Bluetooth is NOT restarted.
 *
 * Restart: v8.9.0 did kill(getpid(),SIGKILL) from inside bluetoothd. On the device launchd did not always
 * relaunch bluetoothd after that, so Bluetooth could stay down (a daemon killing ITSELF is not the same as an
 * external killall, which is what actually relaunches it). v8.9.1 instead posix_spawns
 *   launchctl kickstart -k system/com.apple.bluetoothd
 * which atomically kills AND relaunches the service in one launchd operation, so bluetoothd can never be left
 * down. The spawn happens while bluetoothd is still alive and running as root, so launchctl inherits the
 * privilege it needs; bluetoothd then exits when launchctl terminates it, already committed to the restart.
 * Nothing is done as the mobile-owned helper, which lacks the privilege to restart a root service.
 */
#include "BTPSV89Session.h"
#include "BTPSLog.h"
#include "BTPSShared.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <notify.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

extern char **environ;

/* Launchd service target for bluetoothd. On a rootless jailbreak bluetoothd is still an Apple system daemon,
 * so it lives in the system domain under its real Apple label (NOT the /var/jb prefix, which is only for the
 * tweak's own jailbroken services). */
#define BTPS_V89_BLUETOOTHD_TARGET "system/com.apple.bluetoothd"

/* launchctl is part of the base system. Rootless relocates most binaries under /var/jb, but launchctl is one of
 * the few that must exist at the real /bin for launchd itself; try the rootless path first anyway, then /bin. */
static const char *const kV89LaunchctlPaths[] = {
    "/var/jb/bin/launchctl",
    "/var/jb/usr/bin/launchctl",
    "/bin/launchctl",
    "/usr/bin/launchctl",
};

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

/* Spawn `launchctl kickstart -k <target>`. Returns 0 if launchctl was spawned and exited 0 (launchd has
 * committed to killing and relaunching the service), nonzero otherwise. This runs inside bluetoothd (root), so
 * the child inherits the privilege; bluetoothd itself is torn down by launchd as part of the kickstart.
 * Never kills this process directly: a failed spawn must leave Bluetooth running. */
static int v89_spawn_kickstart(const char *launchctl, const char *target)
{
    char *const argv[] = { (char *)launchctl, (char *)"kickstart", (char *)"-k", (char *)target, NULL };
    pid_t pid = 0;
    int rc = posix_spawn(&pid, launchctl, NULL, NULL, argv, environ);
    if (rc != 0) return rc;                 /* launchctl not spawnable at this path */
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) { }
    /* If launchd tears us down before waitpid returns, we simply never get here - that is fine, the restart is
     * already in flight. A returned status of 0 means kickstart was accepted. */
    return (WIFEXITED(status) && WEXITSTATUS(status) == 0) ? 0 : -1;
}

static void v89_restart_bluetoothd(void)
{
    for (size_t i = 0; i < sizeof kV89LaunchctlPaths / sizeof kV89LaunchctlPaths[0]; i++) {
        struct stat st;
        if (stat(kV89LaunchctlPaths[i], &st) != 0) continue;     /* path not present on this install */
        BTPSLogNow("V89_SESSION kickstart via %s %s", kV89LaunchctlPaths[i], BTPS_V89_BLUETOOTHD_TARGET);
        if (v89_spawn_kickstart(kV89LaunchctlPaths[i], BTPS_V89_BLUETOOTHD_TARGET) == 0) return;
        BTPSLogNow("V89_SESSION kickstart via %s did not report success; trying the next path", kV89LaunchctlPaths[i]);
    }
    /* No launchctl worked. Bluetooth is still up and the switches are armed: the user can restart Bluetooth
     * themselves (toggle Bluetooth, or the SSH command) and the armed trial will run on the next launch. */
    BTPSSetStatus(BTPS_STATUS_V89_SESSION,
                  "ARMED but auto-restart unavailable: toggle Bluetooth off/on (or restart bluetoothd) to apply");
    BTPSLogNow("V89_SESSION could not spawn launchctl; switches remain armed, Bluetooth left running");
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
    BTPSLogNow("V89_SESSION %s nonce=%s: one-shot switches %s; restarting bluetoothd via launchctl kickstart -k",
               action, nonce, start ? "ARMED" : "cleared");
    v89_restart_bluetoothd();
    /* kickstart -k returns BEFORE launchd tears this process down, so we normally reach here. Do NOT fall back to
     * killing ourselves: that is the v8.9.0 bug that left Bluetooth down. Leave the request consumed (so it is not
     * retried) and let the pending launchd restart proceed. If the spawn failed, Bluetooth is untouched and the
     * reported status tells Settings to use the manual switches. */
    g_v89_restarting = 0;
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
