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
#define BTPS_KEY_V81_SEVEN_ONCE "BTPhonoSinkV81SevenOnce" /* OFF by default, consumed before use */
#define BTPS_KEY_V80_CFG_OBSERVER "BTPhonoSinkV80ConfigLookupObserver" /* OFF: pass-through getter timing observer */
#define BTPS_KEY_EXPERIMENTS  "BTPhonoSinkExperiments"   /* boolean, flipped by the switch in the Settings pane */

#define BTPS_LOG_DIR_TMP      "/tmp/FTABHarvest"
#define BTPS_LOG_FILE_TMP     "/tmp/FTABHarvest/BTPhonoSink.log"
#define BTPS_LOG_FILE_ALT     "/var/mobile/Library/Logs/BTPhonoSink.log"
#define BTPS_HELPER_LOG_FILE  "/tmp/FTABHarvest/BTPSAudioHelper-v88.log"  /* launchd StandardOutPath of the helper */

#define BTPS_NOTIFY_STATE     "com.parv.btphonosink.state"
#define BTPS_NOTIFY_DAEMON_PROBE "com.parv.btphonosink.v74.ipc.request"
#define BTPS_KEY_DAEMON_PROBE "BTPhonoSinkV74IPCRequest"
#define BTPS_NOTIFY_V75_SBC "com.parv.btphonosink.v75.sbc.request"
#define BTPS_KEY_V75_SBC "BTPhonoSinkV75SBCRequest"

/* ---- v8.9: one-tap Start/Stop and audio output selection ---------------------------------------------------
 * Start/Stop: Settings writes BTPS_KEY_V89_REQUEST and posts BTPS_NOTIFY_V89_SESSION. The tweak inside bluetoothd
 * consumes the request, sets or clears the two existing one-shot switches and restarts its own process. The
 * relaunched daemon reports the result under BTPS_STATUS_V89_SESSION, matched to the request by its nonce.
 * Output: Settings stores the mode and a "never play to" list; BTPSAudioHelper reads them, re-reads them when
 * BTPS_NOTIFY_V89_OUTPUT is posted, and publishes what is playing where under BTPS_KEY_V89_HELPER. */
#define BTPS_KEY_V82_DECISIVE_ONCE "BTPhonoSinkV82DecisiveOnce"  /* same literal Tweak.xm consumes at launch */
#define BTPS_NOTIFY_V89_SESSION    "com.parv.btphonosink.v89.session"
#define BTPS_KEY_V89_REQUEST       "BTPhonoSinkV89SessionRequest" /* {action,nonce,time}; consumed by the tweak */
#define BTPS_KEY_V89_PENDING       "BTPhonoSinkV89SessionPending" /* carried across the restart; consumed */
#define BTPS_STATUS_V89_SESSION    "diag.v89.session"
#define BTPS_NOTIFY_V89_OUTPUT     "com.parv.btphonosink.v89.output"
#define BTPS_KEY_V89_OUTPUT_MODE   "BTPhonoSinkV89OutputMode"     /* "speaker" (default) | "headphones" | "any" */
#define BTPS_KEY_V89_NEVER         "BTPhonoSinkV89NeverOutputs"   /* array of {uid,name}: never play there */
#define BTPS_KEY_V89_HELPER        "BTPhonoSinkV89HelperStatus"   /* written by BTPSAudioHelper for Settings */

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
