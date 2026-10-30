/* BTPSLog.c - see BTPSLog.h.  Plain C on purpose: no Objective-C, no blocks. */
#include "BTPSLog.h"

#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <notify.h>
#include <os/log.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "BTPSCore.h"
#include "BTPSShared.h"

#define STATUS_MAX 72

typedef struct { char key[40]; char val[160]; } kv_t;

static pthread_mutex_t   g_lock = PTHREAD_MUTEX_INITIALIZER;
static btps_ring_t       g_ring;                       /* guarded by g_lock */
static kv_t              g_status[STATUS_MAX];         /* guarded by g_lock */
static int               g_status_n;
static char              g_file_result[2][96];         /* last write result per file channel, guarded by g_lock */
static unsigned          g_loaded, g_uuid_ok, g_hooks_ok, g_hooks_bad;
static uint32_t          g_last_event;
static int               g_inited;
static time_t            g_session_started;
static volatile int      g_dirty;
static volatile int      g_flush_pending;
static volatile int      g_experiments;
static dispatch_queue_t  g_queue;
static int               g_notify_token = -1;
static uint32_t          g_notify_register_status = 0xFFFFFFFFu;

static const char *const kFiles[2] = { BTPS_LOG_FILE_TMP, BTPS_LOG_FILE_ALT };

/* ------------------------------------------------------------------------------------------------ file channel */

static void file_append(int idx, const char *line)
{
    char result[96];
    if (idx == 0) (void)mkdir(BTPS_LOG_DIR_TMP, 0777);            /* result ignored: open() below reports the truth */
    int fd = open(kFiles[idx], O_WRONLY | O_CREAT | O_APPEND, 0666);
    if (fd < 0) {
        snprintf(result, sizeof result, "open failed: errno %d (%s)", errno, strerror(errno));
    } else {
        struct stat st;
        if (fstat(fd, &st) == 0 && st.st_size > 512 * 1024) (void)ftruncate(fd, 0);   /* keep it bounded */
        char buf[BTPS_LINE_MAX + 2];
        int n = snprintf(buf, sizeof buf, "%s\n", line);
        if (n > 0 && write(fd, buf, (size_t)n) == n) snprintf(result, sizeof result, "ok");
        else snprintf(result, sizeof result, "write failed: errno %d (%s)", errno, strerror(errno));
        close(fd);
    }
    pthread_mutex_lock(&g_lock);
    snprintf(g_file_result[idx], sizeof g_file_result[idx], "%s", result);
    pthread_mutex_unlock(&g_lock);
}

static void files_append_all(const char *line)
{
    file_append(0, line);
    file_append(1, line);
}

static void async_write_line(void *ctx)
{
    files_append_all((const char *)ctx);
    free(ctx);
}

/* --------------------------------------------------------------------------------------- preferences channel */

static Boolean prefs_flush(void)
{
    CFStringRef domain = CFSTR(BTPS_PREFS_DOMAIN);
    CFMutableArrayRef lines = CFArrayCreateMutable(kCFAllocatorDefault, 0, &kCFTypeArrayCallBacks);
    CFMutableDictionaryRef status = CFDictionaryCreateMutable(kCFAllocatorDefault, 0, &kCFTypeDictionaryKeyCallBacks,
                                                              &kCFTypeDictionaryValueCallBacks);
    if (!lines || !status) { if (lines) CFRelease(lines); if (status) CFRelease(status); return false; }

    pthread_mutex_lock(&g_lock);
    for (unsigned i = 0; i < btps_ring_count(&g_ring); i++) {
        CFStringRef s = CFStringCreateWithCString(kCFAllocatorDefault, btps_ring_at(&g_ring, i), kCFStringEncodingUTF8);
        if (s) { CFArrayAppendValue(lines, s); CFRelease(s); }
    }
    for (int j = 0; j < g_status_n; j++) {
        CFStringRef k = CFStringCreateWithCString(kCFAllocatorDefault, g_status[j].key, kCFStringEncodingUTF8);
        CFStringRef v = CFStringCreateWithCString(kCFAllocatorDefault, g_status[j].val, kCFStringEncodingUTF8);
        if (k && v) CFDictionarySetValue(status, k, v);
        if (k) CFRelease(k);
        if (v) CFRelease(v);
    }
    pthread_mutex_unlock(&g_lock);

    CFPreferencesSetValue(CFSTR(BTPS_KEY_LOG), lines, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSetValue(CFSTR(BTPS_KEY_STATUS), status, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    Boolean ok = CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFRelease(lines);
    CFRelease(status);
    return ok;
}

static int read_experiments_flag(void)
{
    int on = 0;
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR(BTPS_KEY_EXPERIMENTS), CFSTR(BTPS_PREFS_DOMAIN));
    if (v) {
        if (CFGetTypeID(v) == CFBooleanGetTypeID()) {
            on = CFBooleanGetValue((CFBooleanRef)v) ? 1 : 0;
        } else if (CFGetTypeID(v) == CFNumberGetTypeID()) {
            int x = 0;
            CFNumberGetValue((CFNumberRef)v, kCFNumberIntType, &x);
            on = x != 0;
        }
        CFRelease(v);
    }
    return on;
}

/* ------------------------------------------------------------------------------------ notification channel */

static void publish_state(void)
{
    if (g_notify_register_status != 0) return;                     /* NOTIFY_STATUS_OK is 0 */
    pthread_mutex_lock(&g_lock);
    uint64_t s = btps_state_pack(g_loaded, g_uuid_ok, (unsigned)g_experiments, g_hooks_ok, g_hooks_bad, g_last_event);
    pthread_mutex_unlock(&g_lock);
    (void)notify_set_state(g_notify_token, s);
    (void)notify_post(BTPS_NOTIFY_STATE);
}

/* ------------------------------------------------------------------------------------------------- status */

void BTPSSetStatus(const char *key, const char *fmt, ...)
{
    char val[160];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(val, sizeof val, fmt, ap);
    va_end(ap);

    pthread_mutex_lock(&g_lock);
    int slot = -1;
    for (int i = 0; i < g_status_n; i++) if (!strcmp(g_status[i].key, key)) { slot = i; break; }
    if (slot < 0 && g_status_n < STATUS_MAX) slot = g_status_n++;
    if (slot >= 0) {
        snprintf(g_status[slot].key, sizeof g_status[slot].key, "%s", key);
        snprintf(g_status[slot].val, sizeof g_status[slot].val, "%s", val);
    }
    g_dirty = 1;
    pthread_mutex_unlock(&g_lock);
}

void BTPSSetSummary(unsigned loaded, unsigned uuid_ok, unsigned hooks_ok, unsigned hooks_bad)
{
    pthread_mutex_lock(&g_lock);
    g_loaded = loaded; g_uuid_ok = uuid_ok; g_hooks_ok = hooks_ok; g_hooks_bad = hooks_bad;
    pthread_mutex_unlock(&g_lock);
    publish_state();
}

int BTPSExperimentsEnabled(void) { return g_experiments; }

/* ----------------------------------------------------------------------------------------------- logging */

static void flush_cb(void *ctx)
{
    (void)ctx;
    g_flush_pending = 0;
    if (g_dirty) { g_dirty = 0; (void)prefs_flush(); }
}

static void log_common(int sync, const char *fmt, va_list ap)
{
    char msg[265], ts[16], line[BTPS_LINE_MAX];
    vsnprintf(msg, sizeof msg, fmt, ap);
    btps_fmt_time(ts, sizeof ts);
    snprintf(line, sizeof line, "%s %s", ts, msg);

    pthread_mutex_lock(&g_lock);
    btps_ring_push(&g_ring, line);
    g_last_event = (uint32_t)time(NULL);
    g_dirty = 1;
    int inited = g_inited;
    pthread_mutex_unlock(&g_lock);

    os_log(OS_LOG_DEFAULT, "[Speaka] %{public}s", line);

    if (sync || !inited) {
        files_append_all(line);
    } else {
        char *copy = strdup(line);
        if (copy) dispatch_async_f(g_queue, copy, async_write_line);
        if (!__sync_lock_test_and_set(&g_flush_pending, 1)) {  /* coalesce across daemon threads */
            dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 1LL * NSEC_PER_SEC), g_queue, NULL, flush_cb);
        }
    }
}

void BTPSLog(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    log_common(0, fmt, ap);
    va_end(ap);
}

void BTPSLogNow(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    log_common(1, fmt, ap);
    va_end(ap);
}

void BTPSLogHexdump(const char *label, const void *p, size_t n)
{
    const unsigned char *b = (const unsigned char *)p;
    for (size_t off = 0; off < n; off += 16) {
        char hex[64];
        size_t chunk = (n - off) < 16 ? (n - off) : 16;
        btps_hex(b + off, chunk, hex, sizeof hex);
        BTPSLog("%s +%04zx: %s", label, off, hex);
    }
}

/* ------------------------------------------------------------------------------------------------ self-test */

static void probe_audio_services(void)
{
    static const char *const names[] = {
        "com.apple.audio.AudioSession", "com.apple.audio.AURemoteIOServer",
        "com.apple.audio.AudioQueueServer", "com.apple.audio.AudioComponentRegistrar",
    };
    typedef kern_return_t (*lookup_fn)(mach_port_t, const char *, mach_port_t *);
    lookup_fn look = (lookup_fn)dlsym(RTLD_DEFAULT, "bootstrap_look_up");
    mach_port_t bp = MACH_PORT_NULL;
    kern_return_t kr0 = task_get_special_port(mach_task_self(), TASK_BOOTSTRAP_PORT, &bp);
    if (!look || kr0 != KERN_SUCCESS) {
        BTPSSetStatus("probe.audio", "skipped (no bootstrap_look_up)");
        return;
    }
    for (unsigned i = 0; i < sizeof names / sizeof names[0]; i++) {
        mach_port_t port = MACH_PORT_NULL;
        kern_return_t kr = look(bp, names[i], &port);
        const char *what = kr == 0 ? "reachable" : kr == 1100 ? "BLOCKED by sandbox" : kr == 1102 ? "service unknown" : "error";
        char key[48];
        snprintf(key, sizeof key, "probe.%s", names[i] + strlen("com.apple.audio."));
        BTPSSetStatus(key, "%s (kr=%d)", what, (int)kr);
        if (kr == 0 && port != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), port);
    }
}

static void self_test(void *ctx)
{
    (void)ctx;
    BTPSLog("self-test: checking which log channels this daemon is allowed to use");

    /* file channels: each already has a result from the lines written so far */
    pthread_mutex_lock(&g_lock);
    char r0[96], r1[96];
    snprintf(r0, sizeof r0, "%s", g_file_result[0][0] ? g_file_result[0] : "not tried");
    snprintf(r1, sizeof r1, "%s", g_file_result[1][0] ? g_file_result[1] : "not tried");
    pthread_mutex_unlock(&g_lock);
    BTPSSetStatus("channel.file.tmp", "%s", r0);
    BTPSSetStatus("channel.file.logs", "%s", r1);

    /* preferences channel: write, then read the key back */
    Boolean synced = prefs_flush();
    CFPropertyListRef back = CFPreferencesCopyValue(CFSTR(BTPS_KEY_LOG), CFSTR(BTPS_PREFS_DOMAIN),
                                                    kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    long n = (back && CFGetTypeID(back) == CFArrayGetTypeID()) ? (long)CFArrayGetCount((CFArrayRef)back) : -1;
    if (back) CFRelease(back);
    BTPSSetStatus("channel.prefs", "%s (synchronize=%d, read back %ld lines)", n > 0 ? "ok" : "NOT readable", (int)synced, n);

    /* notification channel */
    uint64_t probe = 0xB7B7B7B7ull, got = 0;
    uint32_t st_set = 0xFFFFFFFFu, st_get = 0xFFFFFFFFu;
    if (g_notify_register_status == 0) {
        st_set = notify_set_state(g_notify_token, probe);
        st_get = notify_get_state(g_notify_token, &got);
    }
    BTPSSetStatus("channel.notify", "%s (register=%u set=%u get=%u)",
                  (st_set == 0 && st_get == 0 && got == probe) ? "ok" : "NOT working",
                  (unsigned)g_notify_register_status, (unsigned)st_set, (unsigned)st_get);

    /* can this process reach the audio servers at all? (needed if audio is ever to be played from in here) */
    probe_audio_services();

    BTPSLog("self-test done (see the status block for each channel)");
    publish_state();
    g_dirty = 1;
}

/* A callback-free period must not look like a dead daemon. A lightweight
 * heartbeat every 60s marks the active session without touching Bluetooth. */
static void heartbeat_cb(void *ctx)
{
    (void)ctx;
    unsigned long long seq;
    pthread_mutex_lock(&g_lock);
    seq = btps_ring_seq(&g_ring);
    pthread_mutex_unlock(&g_lock);
    time_t now = time(NULL);
    unsigned long uptime_s = now >= g_session_started ?
        (unsigned long)(now - g_session_started) : 0ul;
    BTPSSetStatus("diag.heartbeat", "pid=%d uptime_s=%lu log_seq=%llu",
                  (int)getpid(), uptime_s, seq);
    BTPSLog("HEARTBEAT bluetoothd pid=%d uptime_s=%lu log_seq=%llu (passive)",
            (int)getpid(), uptime_s, seq);
    publish_state();
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 60LL * NSEC_PER_SEC), g_queue, NULL, heartbeat_cb);
}

static void poll_cb(void *ctx)
{
    (void)ctx;
    g_experiments = read_experiments_flag();
    publish_state();
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 10LL * NSEC_PER_SEC), g_queue, NULL, poll_cb);
}

void BTPSLogInit(void)
{
    pthread_mutex_lock(&g_lock);
    if (g_inited) { pthread_mutex_unlock(&g_lock); return; }
    btps_ring_init(&g_ring);
    g_session_started = time(NULL);
    g_inited = 1;
    pthread_mutex_unlock(&g_lock);

    g_queue = dispatch_queue_create("com.parv.speaka.log", DISPATCH_QUEUE_SERIAL);
    g_experiments = read_experiments_flag();
    g_notify_register_status = notify_register_check(BTPS_NOTIFY_STATE, &g_notify_token);

    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 2LL * NSEC_PER_SEC), g_queue, NULL, self_test);
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 10LL * NSEC_PER_SEC), g_queue, NULL, poll_cb);
    dispatch_after_f(dispatch_time(DISPATCH_TIME_NOW, 60LL * NSEC_PER_SEC), g_queue, NULL, heartbeat_cb);
}
