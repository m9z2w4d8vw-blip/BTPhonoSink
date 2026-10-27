/*
 * BTPSShared.h - constants shared by the tweak (runs inside the Bluetooth daemon) and the Settings pane.
 *
 * The daemon runs as user `mobile` (its launchd plist says so), the same user as the Settings app, so a preference
 * value the daemon writes with kCFPreferencesCurrentUser is one Settings can read back.
 *
 * Log channels (the sandbox profile of the daemon is not readable, so we try several and report which work):
 *   1. preferences  - the daemon's OWN domain, "com.apple.bluetooth" (its sandbox is built around its own domains)
 *   2. file in /tmp/FTABHarvest/ - the one directory its entitlements explicitly allow it to write
 *   3. file in /var/mobile/Library/Logs/ - probably denied, but cheap to try
 *   4. a Darwin notification "state" word - a few bits of status, no file or preference access needed
 */
#pragma once
#include <stdint.h>

#define BTPS_PREFS_DOMAIN     "com.apple.bluetooth"
#define BTPS_KEY_LOG          "BTPhonoSinkLog"           /* array of strings: the newest log lines            */
#define BTPS_KEY_STATUS       "BTPhonoSinkStatus"        /* dictionary string -> string: self-test + hook state */
#define BTPS_KEY_V77_SINK_TRIAL "BTPhonoSinkV77SinkTrial" /* OFF by default; one attempt after native Sources */
#define BTPS_KEY_SDP_PROBE    "BTPhonoSinkSDPProbe"   /* OFF by default; optional read-only hook */
#define BTPS_KEY_V80_CFG_OBSERVER "BTPhonoSinkV80ConfigLookupObserver" /* OFF: pass-through getter timing observer */
#define BTPS_KEY_EXPERIMENTS  "BTPhonoSinkExperiments"   /* boolean, flipped by the switch in the Settings pane */

#define BTPS_LOG_DIR_TMP      "/tmp/FTABHarvest"
#define BTPS_LOG_FILE_TMP     "/tmp/FTABHarvest/BTPhonoSink.log"
#define BTPS_LOG_FILE_ALT     "/var/mobile/Library/Logs/BTPhonoSink.log"

#define BTPS_NOTIFY_STATE     "com.parv.btphonosink.state"
#define BTPS_NOTIFY_DAEMON_PROBE "com.parv.btphonosink.v74.ipc.request"
#define BTPS_KEY_DAEMON_PROBE "BTPhonoSinkV74IPCRequest"
#define BTPS_NOTIFY_V75_SBC "com.parv.btphonosink.v75.sbc.request"
#define BTPS_KEY_V75_SBC "BTPhonoSinkV75SBCRequest"

/* ---- the 64-bit notification state word ---------------------------------------------------------------------
 * bit 0  tweak loaded in the daemon      bit 1  UUID matched the analysed build     bit 2  experiments enabled
 * bits 8-15  hooks installed             bits 16-23  hooks skipped/failed           bits 32-63  last event (unix secs) */
static inline uint64_t btps_state_pack(unsigned loaded, unsigned uuid_ok, unsigned experiments,
                                       unsigned hooks_ok, unsigned hooks_bad, uint32_t last_event)
{
    return (uint64_t)(loaded & 1u) | ((uint64_t)(uuid_ok & 1u) << 1) | ((uint64_t)(experiments & 1u) << 2) |
           ((uint64_t)(hooks_ok & 0xFFu) << 8) | ((uint64_t)(hooks_bad & 0xFFu) << 16) | ((uint64_t)last_event << 32);
}
static inline void btps_state_unpack(uint64_t s, unsigned *loaded, unsigned *uuid_ok, unsigned *experiments,
                                     unsigned *hooks_ok, unsigned *hooks_bad, uint32_t *last_event)
{
    if (loaded)      *loaded      = (unsigned)(s & 1u);
    if (uuid_ok)     *uuid_ok     = (unsigned)((s >> 1) & 1u);
    if (experiments) *experiments = (unsigned)((s >> 2) & 1u);
    if (hooks_ok)    *hooks_ok    = (unsigned)((s >> 8) & 0xFFu);
    if (hooks_bad)   *hooks_bad   = (unsigned)((s >> 16) & 0xFFu);
    if (last_event)  *last_event  = (uint32_t)(s >> 32);
}
