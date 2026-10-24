/*
 * BTPSLog.h - debug log for code running INSIDE the Bluetooth daemon.
 *
 * Everything goes to the system log (os_log) and to a bounded in-memory ring. From there it is copied to every
 * channel in BTPSShared.h, and a startup self-test records which channels the daemon's sandbox actually allows.
 * The Settings pane (BTPhonoSinkPrefs) reads the same channels back.
 */
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Call once, as early as possible (the tweak's constructor). Safe to call twice. */
void BTPSLogInit(void);

/* Normal log line: ring + os_log immediately, files/preferences shortly after, off the calling thread. */
void BTPSLog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

/* Breadcrumb: same, but the file channels are written synchronously before returning. Use it right before anything
 * that might crash, so the last line before a crash survives. */
void BTPSLogNow(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

/* Hex dump as log lines, 16 bytes per line. */
void BTPSLogHexdump(const char *label, const void *p, size_t n);

/* Key/value shown at the top of the pane (replaces an existing key). */
void BTPSSetStatus(const char *key, const char *fmt, ...) __attribute__((format(printf, 2, 3)));

/* How the hook installation went; published in the notification state word. */
void BTPSSetSummary(unsigned loaded, unsigned uuid_ok, unsigned hooks_ok, unsigned hooks_bad);

/* Value of the "experiments" switch in the pane (re-read every few seconds). */
int  BTPSExperimentsEnabled(void);

#ifdef __cplusplus
}
#endif
