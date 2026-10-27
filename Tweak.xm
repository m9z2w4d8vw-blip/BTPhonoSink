/*
 * BTPhonoSink - v8.2 one-shot native A2DP Sink signaling experiment (OFF by default).
 *
 * Goal of the project: make the iPhone show up as a Bluetooth speaker (A2DP sink). Nobody knows yet whether the
 * daemon's stack can be taught that, so the default build only WATCHES; an explicitly armed ONE-SHOT
 * initializer count override changes only the returned config shadow. Everything is written to the debug log
 * that Settings > BTPhonoSink displays.
 *
 * What it does:
 *   1. Finds the daemon's own image (the one MH_EXECUTE image; NOT "image 0", which is not reliable when libraries
 *      are injected), logs the loaded images, and compares its UUID with the analysed build.
 *   2. The real guard is the CODE: before hooking, the first four instruction words of every target are compared
 *      with BTPSBuild.h (read with a fault-safe reader). If the UUID differs but the code at all five targets
 *      matches, it is the same code (a patched copy) and hooking proceeds; any other mismatch hooks nothing.
 *      A mismatch is a log line, never a crash.
 *   3. Hooks five functions with a generic pass-through that forwards all eight argument registers untouched and
 *      logs the first calls. It cannot change behaviour, whatever the real signatures turn out to be.
 *   4. Preserves ALL native Source registrations. The v4 endpoint-mirroring experiment is disabled
 *      regardless of the stored switch value: six native endpoints were seen and the table filled up.
 *      The sixth argument is a pointer to a ONE-BYTE assigned SEID; do not reuse a Source output pointer
 *      for an injected Sink (and do not read 8 bytes from the output pointer).
 *
 * Why the old version could not work: every offset in the first analysis pointed one instruction past the
 * function's `pacibsp`. On arm64e that makes the hook's return address double-signed, so the first call crashes.
 * The table in BTPSBuild.h was regenerated from the binary and each entry checked against its own log message.
 *
 * v3 fix: AVDTP_RegisterMultipoint's own debug line - "AVDTP_RegisterMultipoint(mediaType=%d,count=%d,
 * endpointType=%d,caps=0x%x,numCaps=%d)" - prints its five arguments in a different order than the registers
 * that hold them. Tracing the real prologue shows the true mapping is a0=mediaType, a1=endpointType,
 * a2=caps (the pointer), a3=numCaps, a4=count. v2 assumed the print order was the register order and read
 * a3 as caps and a2 as endpointType; that's why the log said "caps value 0x3 is not a readable pointer"
 * (0x3 is numCaps, not caps) and why the experiment's Source/Sink check and substitution were on the wrong
 * register entirely.
 *
 * v4: with a2 fixed, the first real capability-list bytes came back. The list is a run of fixed 16-byte
 * records, one per AVDTP service category (byte 0 of each 16 bytes = the category: 1 Media Transport, 7 Media
 * Codec, 8 Delay Reporting), and numCaps (a3) is exactly how many 16-byte records there are - 3 on every call
 * seen so far, so 48 bytes total. The Media Codec record's own fields (media type, codec type, codec-specific
 * length) matched three different codecs across the six calls: SBC, MPEG-2/4 AAC, and a vendor-specific one.
 * v3 dumped a fixed 96 bytes, twice the real size, so anything past the real list was just whatever the heap
 * happened to hold next - harmless, but call #6's tail happened to land on a reused chunk still holding an
 * earlier log line, which looked alarming without this context. v4 dumps exactly numCaps*16 bytes and decodes
 * each record's category inline.
 *
 * v5: correctly observe 1-byte SEID output; do not mirror Sink endpoints or overwrite Source SEIDs.
 * v6: decode the observed codec at byte +2, trace return values and timings and include
 *      a session-specific export. SDP 0x110B and media receive remain NOT implemented.
 * v7: optional, OFF-BY-DEFAULT pass-through instrumentation for existing SDP record additions.
 * v7.8: disables additional Sink registration even if the old v7.7 preference is ON.
 *       Once six native Sources register, safely snapshots the AVDTP slot table
 *       and independently counts vacant entries. No table mutation or new SDP.
 */
#include <CoreFoundation/CoreFoundation.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <time.h>
#include "BTPSDiagnostics.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <substrate.h>

#include "BTPSBuild.h"
#include "BTPSLog.h"
#include "BTPSShared.h"
#include "BTPSDaemonProbe.h"
#include "BTPSV78Capacity.h"
#include "BTPSV79Geometry.h"
#include "BTPSV81Config.h"
#include "BTPSV77Sink.h"
#include "BTPSV82SDP.h"

#define BTPS_BUILD_TAG "v8.3-post-source-audio-context"

/* AVDTP constants, used for native Source registration diagnostics */
#define BTPS_AVDTP_TSEP_SRC 0u
#define BTPS_AVDTP_TSEP_SNK 1u
#define BTPS_AVDTP_MEDIA_AUDIO 0u

/* ------------------------------------------------------------------------------------------------ helpers */

/* All eight integer argument registers, returning x0. Anything the real function takes in x0..x7 is passed through
 * unchanged; floating-point and stack arguments are untouched because this wrapper never writes them. */
typedef uint64_t (*btps_fn_t)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t);

static volatile unsigned g_calls[BTPS_N_HOOKS];
static btps_fn_t         g_orig[BTPS_N_HOOKS];

/* Read memory without being able to crash: returns 0 if the address is not readable. */
static int btps_peek(uint64_t addr, void *out, size_t n)
{
    if (addr < 0x1000ull || addr > 0x0000FFFFFFFFFFFFull) return 0;
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr, (vm_size_t)n, (vm_address_t)out, &got);
    return kr == KERN_SUCCESS && got == (vm_size_t)n;
}

static int image_uuid(const struct mach_header_64 *mh, uint8_t out[16])
{
    if (!mh || mh->magic != MH_MAGIC_64 || mh->ncmds > 4096u) return 0;
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmdsize < sizeof(struct load_command)) return 0;       /* corrupt header: stop */
        if (lc->cmd == LC_UUID) {
            memcpy(out, ((const struct uuid_command *)lc)->uuid, 16);
            return 1;
        }
        p += lc->cmdsize;
    }
    return 0;
}

/* The daemon is the one image of type MH_EXECUTE. Its index is not guaranteed to be 0 when libraries are injected. */
static int find_main_image(uint32_t *index_out, const struct mach_header_64 **mh_out)
{
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (mh && mh->magic == MH_MAGIC_64 && mh->filetype == MH_EXECUTE) {
            *index_out = i;
            *mh_out = mh;
            return 1;
        }
    }
    return 0;
}

static void uuid_string(const uint8_t u[16], char *out, size_t cap)
{
    snprintf(out, cap, "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
             u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
}

static const char *tail_of(const char *s, size_t keep)
{
    if (!s) return "?";
    size_t n = strlen(s);
    return n > keep ? s + (n - keep) : s;
}

/* Log the first loaded images (index, address, type, UUID, path) so it is never a guess which one is which. */
static void log_images(void)
{
    uint32_t n = _dyld_image_count();
    BTPSLogNow("loaded images: %u (listing the first %u)", n, n < 8u ? n : 8u);
    for (uint32_t i = 0; i < n && i < 8u; i++) {
        const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(i);
        uint8_t u[16];
        char us[40] = "-";
        if (image_uuid(mh, u)) uuid_string(u, us, sizeof us);
        BTPSLog("image[%u] %p type=%u uuid=%s %s", i, (const void *)mh, mh ? (unsigned)mh->filetype : 0u, us,
                tail_of(_dyld_get_image_name(i), 70));
    }
}

static void note_call(int idx, uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3, uint64_t a4, uint64_t a5)
{
    unsigned n = __sync_add_and_fetch(&g_calls[idx], 1u);
    if (n <= 25u || (n % 200u) == 0u) {
        BTPSLog("%s call #%u  x0..x5 = %#llx %#llx %#llx %#llx %#llx %#llx", BTPS_TARGETS[idx].name, n,
                (unsigned long long)a0, (unsigned long long)a1, (unsigned long long)a2,
                (unsigned long long)a3, (unsigned long long)a4, (unsigned long long)a5);
        char key[48];
        snprintf(key, sizeof key, "seen.%s", BTPS_TARGETS[idx].name);
        BTPSSetStatus(key, "%u call(s)", n);
        BTPSSetStatus("last_event", "%s #%u", BTPS_TARGETS[idx].name, n);
    }
}

/* Decode the copied 16-byte records from this particular firmware. Do not treat
 * these byte positions as an ABI or use them to construct new endpoints. */
static void btps_log_caps(const uint8_t *buf, size_t len)
{
    btps_caps_info_t c;
    if (!btps_decode_caps(buf, len, &c)) {
        BTPSLog("CAPS invalid or truncated, len=%zu; no decoding attempted", len);
        return;
    }
    BTPSLog("CAPS records=%u transport=%u codec=%u delay=%u other=%u fingerprint=%08x",
            c.total_records, c.transport_records, c.codec_records, c.delay_records,
            c.unknown_records, c.fingerprint);
    if (c.codec_present) {
        BTPSLog("CAPS codec=%s (code=0x%02x at record+2) media=%u specific_len=%u",
                btps_codec_name(c.codec_type), (unsigned)c.codec_type,
                (unsigned)c.media_type, (unsigned)c.codec_data_len);
        BTPSSetStatus("diag.last_caps", "%s code=%02x len=%u hash=%08x",
                      btps_codec_name(c.codec_type), (unsigned)c.codec_type,
                      (unsigned)c.codec_data_len, c.fingerprint);
    } else {
        BTPSLog("CAPS no codec record found");
    }
    BTPSLogHexdump("caps", buf, len);
}

static uint64_t btps_elapsed_us(uint64_t start, uint64_t end)
{
    if (end < start) return 0;
    mach_timebase_info_data_t tb = {0, 0};
    (void)mach_timebase_info(&tb);
    if (!tb.denom) return 0;
    return ((end - start) * (uint64_t)tb.numer / (uint64_t)tb.denom) / 1000u;
}

static void note_return(int idx, uint64_t r)
{
    if (g_calls[idx] <= 25u)
        BTPSLog("%s returned %#llx", BTPS_TARGETS[idx].name, (unsigned long long)r);
}

/* ------------------------------------------------------------------------------------------ pass-through hooks */

/* The four non-registration hooks remain pass-through. First 25 invocations include
 * timing and return codes; later calls are sampled to avoid stressing bluetoothd.
 * Return values are raw because these private ABIs are not yet characterized. */
#define BTPS_OBSERVER(FN, IDX)                                                                            \
    static uint64_t FN(uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,                                \
                       uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7)                                \
    {                                                                                                     \
        note_call(IDX, a0, a1, a2, a3, a4, a5);                                                           \
        unsigned n = g_calls[IDX];                                                                         \
        uint64_t started = (n <= 25u) ? mach_absolute_time() : 0u;                                       \
        uint64_t r = g_orig[IDX] ? g_orig[IDX](a0, a1, a2, a3, a4, a5, a6, a7) : 0;                       \
        note_return(IDX, r);                                                                              \
        if (started) {                                                                                   \
            uint64_t us = btps_elapsed_us(started, mach_absolute_time());                                 \
            BTPSLog("TRACE %s #%u return=%#llx duration_us=%llu (private ABI; raw return)",              \
                    BTPS_TARGETS[IDX].name, n, (unsigned long long)r, (unsigned long long)us);            \
            char key[40];                                                                                 \
            snprintf(key, sizeof key, "diag.ret.%s", BTPS_TARGETS[IDX].name);                          \
            BTPSSetStatus(key, "call=%u ret=%#llx duration_us=%llu", n,                                 \
                          (unsigned long long)r, (unsigned long long)us);                                 \
        }                                                                                                 \
        return r;                                                                                         \
    }

BTPS_OBSERVER(hook_advertise,     BTPS_H_ADVERTISE)
BTPS_OBSERVER(hook_setconfigind,  BTPS_H_SETCONFIGIND)
BTPS_OBSERVER(hook_accept_sbc,    BTPS_H_ACCEPT_SBC)
BTPS_OBSERVER(hook_publish,       BTPS_H_PUBLISH)

/* AVDTP_RegisterMultipoint: a0=media type, a1=TSEP, a2=caps pointer,
 * a3=number of 16-byte capability records, a4=count, a5=SEID output BYTE.
 *
 * The arm64e daemon stores the assigned SEID with `strb w8, [x19]` at
 * image+0x0ceee8. Do NOT treat a5 as a uint64_t output. An injected Sink
 * must never reuse Apple's Source SEID pointer.
 *
 * v5 safety: observe without extra registrations. Six native Source records
 * were previously observed, exhausting the six-entry endpoint table.
 * Adding even one Sink requires verifying a safe capacity expansion or
 * an explicit trade-off that removes one Source endpoint.
 */
static volatile unsigned g_native_source_success = 0;
/* Trial requires BOTH separate one-shot preferences. Never retry automatically. */
static int g_v82_armed = 0;
static volatile unsigned g_v82_sink_attempted = 0;
static BTPSV77SinkCaps g_v82_caps;
static volatile unsigned g_v82_caps_ready = 0;
static volatile unsigned g_v82_sink_accepted = 0;
static volatile uint32_t g_v82_sdp_handle = 0;
static volatile unsigned g_v82_sdp_registered = 0;
static btps_fn_t g_v82_sig_orig = NULL;
static volatile unsigned g_v82_sig_calls = 0;
static volatile unsigned g_v82_signal_hook_ok = 0;
static volatile unsigned g_v82_sdp_hook_ok = 0;
static btps_fn_t g_v82_tx_orig = NULL;
static volatile unsigned g_v82_tx_calls = 0;
static volatile unsigned g_v82_tx_hook_ok = 0;

/* Existing SDP insertion routine, shared with the v8.3 post-registration path. */
typedef uint64_t (*btps_sdp_fn_t)(uint64_t, uint64_t);
static btps_sdp_fn_t g_sdp_orig = NULL;

/* v8.3: the higher-level audio table is separate from the AVDTP SEP table.
 * One-shot hook is installed at the exact verified registration-loop entry.
 * It calls the native loop first, THEN expands the audio table to seven.
 */
#define BTPS_V83_SOURCE_REG_ENTRY 0x003b4128ul
static const uint32_t BTPS_V83_SOURCE_REG_SIG[4] = {
    0xd503237fu, 0xd10103ffu, 0xa90157f6u, 0xa9024ff4u
};
typedef uint64_t (*btps_v83_source_reg_fn_t)(uint64_t);
static btps_v83_source_reg_fn_t g_v83_source_reg_orig = NULL;
static volatile unsigned g_v83_source_reg_hook_ok = 0;
static volatile unsigned g_v83_audio_extended = 0;
static void *g_v83_leaked_original_table = NULL; /* intentionally retained; see TESTING-v8.3 */


/* Optional one-shot Sink SEP capacity experiment. Unlike v4, this does not
 * consume slots before Apple's six native Sources. Disabled by default;
 * the OFF legacy flag is a hard prerequisite. This never publishes SDP. */


/* ONLY address- and signature-validated reads; NEVER written or hooked. */
static uintptr_t g_v78_base = 0;
static int g_v78_exact_uuid = 0;
static volatile unsigned g_v78_snapshots = 0;

static int btps_v78_signature_matches(void)
{
    /* Each exact instruction is drawn from the user's verified bluetoothd binary.
       The table layout is invalid for any different firmware build. */
    struct sig_at { uintptr_t offset; uint32_t word; } s[] = {
        {0x0cede4u, 0xf9445b28u}, /* ldr x8, [x25,#0x8b0]: AVDTP global */
        {0x0cede8u, 0x3941911au}, /* ldrb w26,[x8,#0x64]: SEID cursor */
        {0x0cee08u, 0x3941810au}, /* ldrb w10,[x8,#0x60]: slot capacity */
        {0x0cee14u, 0x52800d00u}, /* mov w0,#0x68 on exhausted search */
        {0x0cee54u, 0x385fb36eu}, /* ldurb w14,[x27,#-5]: slot marker */
        {0x0cee60u, 0x9100a37bu}, /* add x27,x27,#0x28: slot stride */
    };
    if (!g_v78_exact_uuid || !g_v78_base) return 0;
    for (size_t i = 0; i < sizeof s / sizeof s[0]; ++i) {
        uint32_t word = 0;
        if (!btps_peek((uint64_t)(g_v78_base + s[i].offset), &word, sizeof word) ||
            word != s[i].word) return 0;
    }
    return 1;
}

static void btps_v78_snapshot_capacity(void)
{
    /* Called once, only after Apple's six Source registrations returned zero.
       No private stack calls, writes, sockets, locks or allocations. */
    if (!__sync_bool_compare_and_swap(&g_v78_snapshots, 0u, 1u)) return;
    if (!btps_v78_signature_matches()) {
        BTPSSetStatus("diag.v78_table", "UNAVAILABLE: UUID or signature mismatch");
        BTPSLogNow("V78_TABLE SKIPPED: exact binary UUID/signatures are required");
        return;
    }
    uint64_t state = 0, slot_ptr = 0;
    uint8_t count = 0, next = 0;
    /* ADRP x25,#0x976000; LDR x8,[x25,#0x8b0] (not an exported API). */
    if (!btps_peek((uint64_t)(g_v78_base + 0x9768b0u), &state, sizeof state) ||
        !btps_peek(state + 0x0u, &slot_ptr, sizeof slot_ptr) ||
        !btps_peek(state + 0x60u, &count, sizeof count) ||
        !btps_peek(state + 0x64u, &next, sizeof next) ||
        !count || count > BTPS_V78_MAX_SLOTS) {
        BTPSSetStatus("diag.v78_table", "UNREADABLE: table metadata missing or unsafe");
        BTPSLogNow("V78_TABLE UNREADABLE: capacity metadata was not readable");
        return;
    }
    uint8_t slots[BTPS_V78_MAX_SLOTS * BTPS_V78_SLOT_BYTES];
    const size_t len = (size_t)count * BTPS_V78_SLOT_BYTES;
    BTPSV78Capacity capacity;
    if (!btps_peek(slot_ptr, slots, len) ||
        btps_v78_analyze(slots, len, count, &capacity) != 0) {
        BTPSSetStatus("diag.v78_table", "UNREADABLE: slot bytes inaccessible");
        BTPSLogNow("V78_TABLE UNREADABLE: slot bytes inaccessible");
        return;
    }
    BTPSSetStatus("diag.v78_table", "READ-ONLY slots=%u occupied=%u free=%u nextSEID=%u duplicates=%u",
                  capacity.total, capacity.occupied, capacity.vacant,
                  (unsigned)next, capacity.duplicate_seids);
    BTPSSetStatus("diag.capacity", "verified endpoint table: slots=%u occupied=%u free=%u (read-only)",
                  capacity.total, capacity.occupied, capacity.vacant);
    BTPSLogNow("V78_TABLE RESULT slots=%u occupied=%u free=%u nextSEID=%u duplicates=%u; no endpoint inserted",
               capacity.total, capacity.occupied, capacity.vacant,
               (unsigned)next, capacity.duplicate_seids);
    for (unsigned i = 0; i < capacity.total; i++)
        BTPSLog("V78_TABLE slot[%u] SEID=%u", i, (unsigned)capacity.seids[i]);
}




/* v7.9: Exact-image static instructions identify the constructor which
 * obtains AVDTP configuration block #3, then allocates three independent
 * arrays of config byte [0]*40, [1]*144, and [2]*64 bytes. We ONLY read
 * the registered configuration pointer and the already-live context.
 * There are NO allocator hooks, calls into private init, or changes to counts.
 */
static int g_v80_enabled_for_v79_audit(void);
static volatile unsigned g_v79_snapshots = 0;
/* Captured before the optional getter hook changes its prologue. */
static int g_v81_verified_initial_signature = 0;
static int btps_v79_signatures_match(void)
{
    if (!g_v78_exact_uuid || !g_v78_base) return 0;
    struct sig_at { uintptr_t offset; uint32_t word; } s[] = {
        {0x0ce3f8u, 0x52800060u}, /* mov w0,#3: AVDTP configuration slot */
        {0x0ce3fcu, 0x94049ec9u}, /* bl config getter */
        {0x0ce408u, 0x52800d00u}, /* mov w0,#0x68: context allocation */
        {0x0ce41cu, 0x394002e8u}, /* ldrb w8,[x23]: endpoint count */
        {0x0ce424u, 0xd37df100u}, /* lsl x0,x8,#3 (after x8=5*count) */
        {0x0ce428u, 0x97ff6f1du}, /* bl allocator: endpoint bytes */
        {0x0ce434u, 0xf9000018u}, /* str x24,[x0]: endpoint pointer */
        {0x0ce470u, 0xd37ced00u}, /* lsl x0,x8,#4: secondary bytes */
        {0x0ce4d4u, 0xd37ae500u}, /* lsl x0,x8,#6: tertiary bytes */
        {0x0ce4f4u, 0x39018008u}, /* strb w8,[x0,#0x60]: live slot count */
        {0x1f5f20u, 0xd503237fu}, /* PAC-protected configuration lookup */
        {0x1f5f48u, 0xf8735a80u}, /* ldr x0,[x20,w19,uxtw #3] */
    };
    for (size_t i = 0; i < sizeof s / sizeof s[0]; ++i) {
        uint32_t word = 0;
        /* ElleKit/Substrate rewrites the getter prologue. Verify its ORIGINAL
         * four words before installing the hook; do not re-read a patched
         * instruction and mistake it for a different iOS build. All other
         * initializer/lookup instructions are still checked live. */
        if (s[i].offset == 0x1f5f20u && g_v80_enabled_for_v79_audit()) {
            if (!g_v81_verified_initial_signature) return 0;
            continue;
        }
        if (!btps_peek((uint64_t)(g_v78_base + s[i].offset), &word, sizeof word) ||
            word != s[i].word) return 0;
    }
    return 1;
}
static void btps_v79_snapshot_geometry(void)
{
    if (!__sync_bool_compare_and_swap(&g_v79_snapshots, 0u, 1u)) return;
    if (!btps_v79_signatures_match()) {
        BTPSSetStatus("diag.v79_allocator", "UNAVAILABLE: exact UUID or instruction signatures differ");
        BTPSLogNow("V79_ALLOC SKIPPED: cannot verify exact initializer and lookup instructions");
        return;
    }
    /* The config getter uses pointer table image+0x984a48 and index 3.
       We READ pointer table entry image+0x984a60, never call the getter. */
    uint64_t config_ptr = 0, context_ptr = 0;
    uint8_t config[3] = {0}, live[3] = {0};
    uint64_t tables[3] = {0};
    if (!btps_peek((uint64_t)(g_v78_base + 0x984a60u), &config_ptr, sizeof config_ptr) ||
        !config_ptr || !btps_peek(config_ptr, config, sizeof config) ||
        !btps_peek((uint64_t)(g_v78_base + 0x9768b0u), &context_ptr, sizeof context_ptr) ||
        !context_ptr || !btps_peek(context_ptr, tables, sizeof tables) ||
        !btps_peek(context_ptr + 0x60u, live, sizeof live)) {
        BTPSSetStatus("diag.v79_allocator", "UNREADABLE: config pointer or live allocation metadata");
        BTPSLogNow("V79_ALLOC UNREADABLE: config pointer or live allocation metadata");
        return;
    }
    unsigned present = 0;
    for (unsigned i = 0; i < 3; i++) if (tables[i]) present |= (1u << i);
    BTPSV79Geometry result;
    int rc = btps_v79_analyze(config, live, present, &result);
    if (rc != 0) {
        BTPSSetStatus("diag.v79_allocator", "INVALID: config/context counts are out of bounds (code=%d)", rc);
        BTPSLogNow("V79_ALLOC INVALID: bounded geometry rejected rc=%d", rc);
        return;
    }
    BTPSSetStatus("diag.v79_allocator",
        "READ-ONLY config=(%u,%u,%u) live=(%u,%u,%u) request_bytes=(%u,%u,%u) match=%s missing_mask=%u",
        result.configured[0], result.configured[1], result.configured[2],
        result.observed[0], result.observed[1], result.observed[2],
        result.bytes[0], result.bytes[1], result.bytes[2],
        result.config_matches_context ? "yes" : "NO", result.missing_table_mask);
    BTPSLogNow("V79_ALLOC RESULT config=(%u,%u,%u) live=(%u,%u,%u) request_bytes=(%u,%u,%u) match=%s missing_mask=%u; READ ONLY",
        result.configured[0], result.configured[1], result.configured[2],
        result.observed[0], result.observed[1], result.observed[2],
        result.bytes[0], result.bytes[1], result.bytes[2],
        result.config_matches_context ? "yes" : "NO", result.missing_table_mask);
    BTPSLogNow("V79_ALLOC NOTE: constructor uses config[0]*40, config[1]*144, config[2]*64; byte counts are allocation REQUESTS, not measured heap extents");
}

/* v8.0/v8.1: Optional config getter observer or one-shot shadow override.
 * AVDTP init calls this exact function (image+0x1f5f20) with index 3 to
 * obtain the three count bytes BEFORE allocating the three AVDTP arrays.
 * In ordinary observation mode no count or pointer changes. In explicitly
 * armed one-shot mode, the first validated index-3 call returns a static
 * 32-byte copy with only the first count byte changed from 6 to 7. */
#define BTPS_V80_GET_CONFIG_ENTRY 0x001f5f20u
static const uint32_t BTPS_V80_GET_CONFIG_SIG[4] = {
    0xd503237fu, 0xa9be4ff4u, 0xa9017bfdu, 0x910043fdu
};
static btps_fn_t g_v80_get_config_orig = NULL;
static volatile unsigned g_v80_get_calls = 0;
static volatile unsigned g_v80_index3_calls = 0;
static int g_v80_enabled = 0;
static int g_v81_seven_armed = 0;
static volatile unsigned g_v81_seven_applied = 0;
static volatile unsigned g_v81_shadow_returned = 0;
/* Original object at exact-image __TEXT,__const +0x774010 has a bounded
 * 32-byte configuration record. This shadow has static process lifetime. */
static uint8_t g_v81_shadow[BTPS_V81_CONFIG_COPY_BYTES] __attribute__((aligned(16)));
static int g_v80_enabled_for_v79_audit(void) { return g_v80_enabled; }

/* Consumed before installing ANY private hook. Missing seven-slot arm fails closed. */
static int btps_v82_consume_trial_arm(void)
{
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR("BTPhonoSinkV82DecisiveOnce"),
                                                   CFSTR(BTPS_PREFS_DOMAIN));
    int requested = v && CFGetTypeID(v) == CFBooleanGetTypeID() &&
                    CFBooleanGetValue((CFBooleanRef)v);
    if (v) CFRelease(v);
    if (!requested) return 0;
    CFPreferencesSetAppValue(CFSTR("BTPhonoSinkV82DecisiveOnce"), kCFBooleanFalse,
                             CFSTR(BTPS_PREFS_DOMAIN));
    Boolean saved = CFPreferencesAppSynchronize(CFSTR(BTPS_PREFS_DOMAIN));
    v = CFPreferencesCopyAppValue(CFSTR("BTPhonoSinkV82DecisiveOnce"), CFSTR(BTPS_PREFS_DOMAIN));
    int clear = v && CFGetTypeID(v) == CFBooleanGetTypeID() && !CFBooleanGetValue((CFBooleanRef)v);
    if (v) CFRelease(v);
    BTPSSetStatus("diag.v82.arm", saved && clear ? "one-shot CONSUMED" : "REFUSED: cannot verify disarm");
    return saved && clear;
}


/* A request is CONSUMED before the hook can run. Do not retry automatically
 * on daemon relaunch; fail closed if the preference cannot be cleared. */
static int btps_v81_consume_one_shot(void)
{
    CFPropertyListRef initial = CFPreferencesCopyAppValue(CFSTR(BTPS_KEY_V81_SEVEN_ONCE),
                                                          CFSTR(BTPS_PREFS_DOMAIN));
    int requested = initial && CFGetTypeID(initial) == CFBooleanGetTypeID() &&
                    CFBooleanGetValue((CFBooleanRef)initial);
    if (initial) CFRelease(initial);
    if (!requested) return 0;
    CFPreferencesSetAppValue(CFSTR(BTPS_KEY_V81_SEVEN_ONCE), kCFBooleanFalse,
                             CFSTR(BTPS_PREFS_DOMAIN));
    Boolean synced = CFPreferencesAppSynchronize(CFSTR(BTPS_PREFS_DOMAIN));
    CFPropertyListRef check = CFPreferencesCopyAppValue(CFSTR(BTPS_KEY_V81_SEVEN_ONCE),
                                                        CFSTR(BTPS_PREFS_DOMAIN));
    int disarmed = check && CFGetTypeID(check) == CFBooleanGetTypeID() &&
                   !CFBooleanGetValue((CFBooleanRef)check);
    if (check) CFRelease(check);
    if (!synced || !disarmed) {
        BTPSSetStatus("diag.v81_seven_slots", "REFUSED: cannot persist one-shot disarm");
        BTPSLogNow("V81_CFG REFUSED: did not verify persistent one-shot disarm");
        return 0;
    }
    BTPSLogNow("V81_CFG ARM CONSUMED: preference set OFF before any count changes");
    BTPSSetStatus("diag.v81_seven_slots", "ARMED for next matching index-3 lookup (one shot)");
    return 1;
}

/* This function is the ONLY path returning a changed config pointer.
 * Refuse whenever the exact original source/data state is not expected. */
static uint64_t btps_v81_try_seven(uint64_t original, unsigned hit)
{
    if (!g_v81_seven_armed || hit != 1u ||
        !__sync_bool_compare_and_swap(&g_v81_seven_applied, 0u, 1u)) return original;
    uint8_t source[BTPS_V81_CONFIG_COPY_BYTES] = {0};
    uint64_t table_original = 0;
    int good = g_v81_verified_initial_signature && g_v78_exact_uuid &&
        btps_peek((uint64_t)(g_v78_base + 0x984a60u), &table_original, sizeof table_original) &&
        table_original == original &&
        btps_peek(original, source, sizeof source) &&
        btps_v81_prepare_shadow(source, sizeof source, g_v81_shadow, 1) == 0;
    if (!good) {
        BTPSSetStatus("diag.v81_seven_slots", "REFUSED: config pointer/signature/count not exact");
        BTPSLogNow("V81_CFG REFUSED index=3: preflight mismatch; ORIGINAL pointer returned");
        return original;
    }
    g_v81_shadow_returned = 1u;
    BTPSSetStatus("diag.v81_seven_slots", "OVERRIDE APPLIED once: config shadow=(7,3,3); verify live slots");
    BTPSLogNow("V81_CFG SHADOW index=3 original=(6,3,3) returned=(7,3,3) pointer=STATIC; awaiting live audit");
    return (uint64_t)(uintptr_t)g_v81_shadow;
}

static uint64_t btps_v80_hook_get_config(uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                                         uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7)
{
    /* Always call the original first; pass it through unless v8.1 was explicitly armed. */
    uint64_t value = g_v80_get_config_orig ?
        g_v80_get_config_orig(a0,a1,a2,a3,a4,a5,a6,a7) : 0;
    __sync_add_and_fetch(&g_v80_get_calls, 1u);
    if ((uint32_t)a0 != 3u) return value;
    unsigned hit = __sync_add_and_fetch(&g_v80_index3_calls, 1u);
    if (hit > 4u) return value;
    uint8_t cfg[3] = {0};
    uint64_t in_table = 0;
    int read_ok = value && btps_peek(value, cfg, sizeof cfg);
    int table_ok = btps_peek((uint64_t)(g_v78_base + 0x984a60u), &in_table, sizeof in_table);
    BTPSLogNow("V80_CFG_GET index=3 call=%u result=%#llx readable=%s bytes=(%u,%u,%u) matches_table=%s; original getter result (trial may subsequently return a shadow)",
               hit, (unsigned long long)value, read_ok ? "yes" : "no",
               (unsigned)cfg[0], (unsigned)cfg[1], (unsigned)cfg[2],
               (table_ok && value == in_table) ? "yes" : "no");
    BTPSSetStatus("diag.v80_config_lookup",
                  "OBSERVED index=3 calls=%u bytes=(%u,%u,%u) getter_matches_table=%s; original read-only",
                  hit,(unsigned)cfg[0],(unsigned)cfg[1],(unsigned)cfg[2],
                  (table_ok && value == in_table) ? "yes" : "no");
    if (g_v81_seven_armed) return btps_v81_try_seven(value, hit);
    return value;
}

static int btps_v80_requested(void)
{
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR(BTPS_KEY_V80_CFG_OBSERVER),
                                                   CFSTR(BTPS_PREFS_DOMAIN));
    int enabled = v && CFGetTypeID(v) == CFBooleanGetTypeID() &&
                  CFBooleanGetValue((CFBooleanRef)v);
    if (v) CFRelease(v);
    return enabled;
}

static void btps_v80_install_config_observer(uintptr_t base, int uuid_ok)
{
    /* Disarm the one-shot setting even if later gates refuse installation. */
    g_v81_seven_armed = btps_v81_consume_one_shot();
    int decisive_requested = btps_v82_consume_trial_arm();
    g_v82_armed = decisive_requested && g_v81_seven_armed && !BTPSExperimentsEnabled();
    BTPSSetStatus("diag.v82.trial", g_v82_armed ?
        "ARMED: one-shot seven slots + one Sink SEP + local SDP candidate + signaling RX" :
        (decisive_requested ? "REFUSED: seven-slot arm absent or legacy ON" : "OFF (default)"));
    if (decisive_requested && !g_v82_armed) BTPSLogNow("V82 REFUSED: both independent one-shot arms required; legacy OFF");
    if (!btps_v80_requested() && !g_v81_seven_armed) {
        BTPSSetStatus("diag.v80_config_lookup", "OFF (default), no extra hook");
        BTPSLogNow("V80_CFG_GET observer OFF; no config getter hook installed");
        return;
    }
    if (!uuid_ok || !g_orig[BTPS_H_REGISTER] || !g_orig[BTPS_H_ADVERTISE]) {
        BTPSSetStatus("diag.v80_config_lookup", "REFUSED: exact UUID and baseline hooks required");
        return;
    }
    /* Must be checked BEFORE MSHookFunction rewrites the getter prologue. */
    g_v81_verified_initial_signature = btps_v79_signatures_match();
    if (!g_v81_verified_initial_signature) {
        BTPSSetStatus("diag.v80_config_lookup", "REFUSED: initializer/getter static signature mismatch");
        BTPSSetStatus("diag.v81_seven_slots", "REFUSED: initializer/getter static signature mismatch");
        BTPSLogNow("V81_CFG REFUSED: binary preflight signature mismatch");
        return;
    }
    uint32_t observed[4] = {0};
    uintptr_t target = base + BTPS_V80_GET_CONFIG_ENTRY;
    if (!btps_peek(target, observed, sizeof observed) ||
        memcmp(observed, BTPS_V80_GET_CONFIG_SIG, sizeof observed) != 0) {
        BTPSSetStatus("diag.v80_config_lookup", "REFUSED: config getter signature mismatch");
        BTPSLogNow("V80_CFG_GET refused: getter instruction signature mismatch");
        return;
    }
    void *trampoline = NULL;
    MSHookFunction((void *)target, (void *)btps_v80_hook_get_config, &trampoline);
    if (!trampoline) {
        BTPSSetStatus("diag.v80_config_lookup", "FAILED: no trampoline, switch OFF");
        BTPSLogNow("V80_CFG_GET FAILED: hook engine returned no trampoline");
        return;
    }
    g_v80_get_config_orig = (btps_fn_t)trampoline;
    g_v80_enabled = 1;
    BTPSSetStatus("diag.v80_config_lookup", "ARMED: pass-through getter observer, awaiting index=3");
    BTPSLogNow("V80_CFG_GET installed at image+0x1f5f20; one-shot seven=%s; otherwise original return unchanged", g_v81_seven_armed ? "ARMED" : "OFF");
}

/* Verified exact-image AVDTP RX signaling dispatcher; CID, packet ptr, length.
 * These logs are inbound SIGNALING, not RTP media or TX response receipts. */
#define BTPS_V82_RX_DISPATCH 0x000d3b08ul
static const uint32_t BTPS_V82_RX_SIG[4] = {0xd503237fu,0xd10203ffu,0xa90557f6u,0xa9064ff4u};
static uint64_t btps_v82_receive_signal(uint64_t cid, uint64_t ptr, uint64_t length,
                                       uint64_t a3,uint64_t a4,uint64_t a5,uint64_t a6,uint64_t a7)
{
    uint32_t n = __sync_add_and_fetch(&g_v82_sig_calls, 1);
    if (length >= 2u && length <= 1024u) {
        uint8_t h[2];
        if (btps_peek(ptr, h, 2)) {
            unsigned tx=(h[0]>>4)&15u, packet=(h[0]>>2)&3u, msg=h[0]&3u;
            unsigned id=h[1]&63u;
            if (n < 2000u) {
                BTPSLogNow("V82 RX_SIGNAL #%u CID=%#llx tx=%u pkt=%u msg=%u sig=%u len=%llu",
                    n,(unsigned long long)cid,tx,packet,msg,id,(unsigned long long)length);
                uint8_t bytes[32];
                for (uint64_t off=0; off<length; off+=sizeof bytes) {
                    size_t take = (size_t)(length-off < sizeof bytes ? length-off : sizeof bytes);
                    if (!btps_peek(ptr+off,bytes,take)) {
                        BTPSLogNow("V82 RX_SIGNAL #%u read-failed at +%llu",n,(unsigned long long)off);break;
                    }
                    char hex[sizeof bytes*3+1]; size_t p=0;
                    for (size_t i=0;i<take;i++) p+=(size_t)snprintf(hex+p,sizeof hex-p,"%02x%s",bytes[i],i+1==take?"":" ");
                    BTPSLog("V82 RX_RAW #%u +%llu %s", n,(unsigned long long)off,hex);
                }
            }
        }
    } else if (n < 2000u) BTPSLogNow("V82 RX_SIGNAL #%u unexpected length=%llu",n,(unsigned long long)length);
    return g_v82_sig_orig ? g_v82_sig_orig(cid,ptr,length,a3,a4,a5,a6,a7) : 0;
}
static void btps_v82_install_rx(uintptr_t base,int uuid_ok)
{
    if (!g_v82_armed || !uuid_ok) return;
    uintptr_t target=base+BTPS_V82_RX_DISPATCH; uint32_t words[4]={0};
    if (!btps_peek(target,words,sizeof words) || memcmp(words,BTPS_V82_RX_SIG,sizeof words)!=0) {
        BTPSSetStatus("diag.v82.rx","REFUSED: exact dispatcher signature mismatch");return;
    }
    void *trampoline=NULL;
    MSHookFunction((void*)target,(void*)btps_v82_receive_signal,&trampoline);
    if (!trampoline) { BTPSSetStatus("diag.v82.rx","FAILED: no trampoline");return; }
    g_v82_sig_orig=(btps_fn_t)trampoline;
    g_v82_signal_hook_ok=1;
    BTPSSetStatus("diag.v82.rx","installed, incoming AVDTP SIGNALING only; no TX/media hook");
    BTPSLogNow("V82 RX dispatcher hooked at image+0xD3B08; incoming signaling only");
}

/* AVDTP SIGNALING TX, never media: verified image+0xDA414.
 * Caller +0xDA36C constructs an AVDTP response PDU and tail-branches here;
 * arguments x0=CID, x1=encoded AVDTP PDU pointer, x2=byte length.
 * The underlying routine queues the packet for L2CAP transmission; returning
 * zero is NOT evidence of over-the-air delivery or remote acceptance.
 * Experimental hook is strictly pass-through, bounded and one-shot-gated. */
#define BTPS_V82_TX_QUEUE 0x000da414ul
static const uint32_t BTPS_V82_TX_SIG[4] = {0xd503237fu, 0xd10103ffu, 0xa90157f6u, 0xa9024ff4u};
static uint64_t btps_v82_transmit_signal(uint64_t cid, uint64_t packet, uint64_t length,
                                         uint64_t a3, uint64_t a4, uint64_t a5,
                                         uint64_t a6, uint64_t a7)
{
    unsigned n = __sync_add_and_fetch(&g_v82_tx_calls, 1u);
    int sampled = n <= 128u;
    unsigned tx = 0, ptype = 0, mtype = 0, sig = 0;
    uint8_t bytes[96];
    size_t take = 0;
    if (sampled && length >= 2u && length <= 1024u) {
        take = (size_t)(length < sizeof bytes ? length : sizeof bytes);
        if (btps_peek(packet, bytes, take)) {
            tx = (unsigned)((bytes[0] >> 4) & 15u);
            ptype = (unsigned)((bytes[0] >> 2) & 3u);
            mtype = (unsigned)(bytes[0] & 3u);
            sig = (unsigned)(bytes[1] & 63u);
            BTPSLogNow("V82 TX_SIGNAL #%u CID=%#llx tx=%u pkt=%u msg=%u sig=%u len=%llu",
                       n, (unsigned long long)cid, tx, ptype, mtype, sig,
                       (unsigned long long)length);
            if (mtype == 3u && take >= 3u)
                BTPSLogNow("V82 TX_REJECT #%u sig=%u last_error_byte=0x%02x (inspect complete raw PDU)",
                           n, sig, (unsigned)bytes[take-1u]);
            for (size_t off = 0; off < take; off += 32u) {
                size_t count = take-off < 32u ? take-off : 32u;
                char hex[32u*3u+1u]; size_t p = 0;
                for (size_t i = 0; i < count; ++i)
                    p += (size_t)snprintf(hex+p, sizeof hex-p, "%02x%s", bytes[off+i],
                                          i+1u == count ? "" : " ");
                BTPSLogNow("V82 TX_RAW #%u +%u %s", n, (unsigned)off, hex);
            }
            if ((uint64_t)take < length)
                BTPSLogNow("V82 TX_RAW #%u truncated at %u of %llu bytes", n,
                           (unsigned)take, (unsigned long long)length);
        } else BTPSLogNow("V82 TX_SIGNAL #%u unreadable packet pointer=%#llx",
                          n, (unsigned long long)packet);
    } else if (sampled) {
        BTPSLogNow("V82 TX_SIGNAL #%u length outside safe capture range: %llu",
                   n, (unsigned long long)length);
    }
    uint64_t ret = g_v82_tx_orig
      ? g_v82_tx_orig(cid, packet, length, a3, a4, a5, a6, a7) : 0xFFFFFFFFu;
    if (sampled) {
        BTPSLogNow("V82 TX_QUEUE_RESULT #%u ret=%#llx (not proof of air delivery)",
                   n, (unsigned long long)ret);
        BTPSSetStatus("diag.v82.tx", "TX capture active: %u queued attempts, last CID=%#llx signal=%u msg=%u ret=%#llx",
                      n, (unsigned long long)cid, sig, mtype, (unsigned long long)ret);
    }
    return ret;
}
static void btps_v82_install_tx(uintptr_t base, int uuid_ok)
{
    if (!g_v82_armed || !uuid_ok) return;
    uintptr_t target = base + BTPS_V82_TX_QUEUE;
    uint32_t words[4] = {0};
    if (!btps_peek(target, words, sizeof words) ||
        memcmp(words, BTPS_V82_TX_SIG, sizeof words) != 0) {
        BTPSSetStatus("diag.v82.tx", "REFUSED: exact AVDTP TX queue signature mismatch");
        BTPSLogNow("V82 TX refused: image+0xDA414 signature mismatch");
        return;
    }
    void *trampoline = NULL;
    MSHookFunction((void *)target, (void *)btps_v82_transmit_signal, &trampoline);
    if (!trampoline) {
        BTPSSetStatus("diag.v82.tx", "FAILED: no TX trampoline");
        return;
    }
    g_v82_tx_orig = (btps_fn_t)trampoline;
    g_v82_tx_hook_ok = 1u;
    BTPSSetStatus("diag.v82.tx", "installed at image+0xDA414; TX AVDTP PDU + queue result, no radio delivery claim");
    BTPSLogNow("V82 TX hook installed at image+0xDA414 (encoded AVDTP signaling queue; pass-through)");
}

/* v8.3 one-shot: swap higher-level audio context AFTER the native Source
 * registration function returns. The original source-capability allocations
 * remain owned by the native daemon and are referenced by the new table.
 * Only the obsolete 192-byte parent table is deliberately leaked. */
static void btps_v83_attempt_post_source(uint64_t audio_context)
{
    if (!g_v82_armed || !g_v81_shadow_returned || !g_v82_caps_ready ||
        !g_v83_source_reg_hook_ok || !g_orig[BTPS_H_REGISTER] ||
        !g_v82_signal_hook_ok || !g_v82_sdp_hook_ok || !g_v82_tx_hook_ok ||
        !g_sdp_orig || g_native_source_success != 6 ||
        !__sync_bool_compare_and_swap(&g_v82_sink_attempted, 0, 1)) return;
    uint64_t avdtp_context = 0;
    uint8_t avdtp_slots = 0;
    if (!btps_peek((uint64_t)(g_v78_base + 0x9768b0u), &avdtp_context, sizeof avdtp_context) ||
        !avdtp_context || !btps_peek(avdtp_context + 0x60u, &avdtp_slots, 1) ||
        avdtp_slots != 7u) {
        BTPSLogNow("V83 REFUSED: low-level AVDTP allocation is not 7 slots"); return;
    }
    if (!audio_context) {
        BTPSLogNow("V83 REFUSED: audio context pointer is null"); return;
    }
    struct {
        uint32_t used;
        uint32_t second;
        uint64_t table;
    } meta = {};
    if (!btps_peek(audio_context + 0x68u, &meta, sizeof meta) ||
        meta.used != 6u || meta.second != 6u || !meta.table) {
        BTPSLogNow("V83 REFUSED: audio table metadata expected (6,6,nonzero) observed (%u,%u,%#llx)",
            meta.used, meta.second, (unsigned long long)meta.table); return;
    }
    /* malloc_type_calloc(6,32,...) constructs the original table; the
       allocator guarantees zero-initialized entries. calloc/free use the
       same libSystem allocator family. The daemon's destructor calls free. */
    uint8_t *new_table = (uint8_t *)calloc(7u, 32u);
    uint8_t *new_caps = (uint8_t *)calloc(3u, 16u);
    if (!new_table || !new_caps) {
        BTPSLogNow("V83 REFUSED: calloc failed"); free(new_caps); free(new_table); return;
    }
    uint8_t *e7 = new_table + 6u * 32u;
    uint64_t source_caps = 0;
    uint64_t cap_context = 0;
    uint32_t source_seid = 0;
    if (!btps_peek(meta.table, new_table, 6u * 32u)) goto reject_before_swap;
    memcpy(&source_seid, new_table + 4u, sizeof source_seid);
    memcpy(&source_caps, new_table + 0x10u, sizeof source_caps);
    if (source_seid != 1u || !source_caps || !btps_peek(source_caps, new_caps, 3u * 16u))
        goto reject_before_swap;
    /* Verify the known native Source codec-capability pointer refers to
       the same audio context supplied to +0x3B4128. Distinguish these
       audio-context capability records from AVDTP codec-byte records. */
    memcpy(&cap_context, new_caps + 0x18u, sizeof cap_context);
    if (new_caps[0] != 1u || new_caps[16] != 7u || new_caps[18] != 0u ||
        new_caps[19] != 4u || new_caps[32] != 8u ||
        cap_context != audio_context) goto reject_before_swap;
    {
        uint32_t seid = 7u, ncap = 3u;
        uint64_t pcap = (uint64_t)(uintptr_t)new_caps;
        memcpy(e7 + 0x04u, &seid, sizeof seid);
        memcpy(e7 + 0x10u, &pcap, sizeof pcap);
        e7[0x18u] = 1u; /* exact native initializer +0x3B3AA8 */
        memcpy(e7 + 0x1cu, &ncap, sizeof ncap);
    }
    /* The live pointer and both count fields must be changed together,
       after native Source registration completed, never before its loop. */
    memcpy((void *)(uintptr_t)(audio_context + 0x78u), &new_table, sizeof new_table);
    {
        uint32_t seven = 7u;
        memcpy((void *)(uintptr_t)(audio_context + 0x68u), &seven, sizeof seven);
        memcpy((void *)(uintptr_t)(audio_context + 0x6cu), &seven, sizeof seven);
    }
    g_v83_leaked_original_table = (void *)(uintptr_t)meta.table;
    g_v83_audio_extended = 1u;
    BTPSSetStatus("diag.v83.audio_table", "REPLACED post native Source: entries=7, native=6, new_SEID=7; original parent block intentionally retained");
    BTPSLogNow("V83 AUDIO_TABLE SWAPPED after native registration: count 6->7, old=%#llx retained, new=%p entry7_caps=%p",
        (unsigned long long)meta.table, new_table, new_caps);
    /* Use the SEID storage of the new high-level entry itself, exactly as
       Apple's registration loop passes entry+4 as output. */
    {
        uint64_t ret = g_orig[BTPS_H_REGISTER](0, 1,
            (uint64_t)(uintptr_t)&g_v82_caps.caps_words[0], 3, 1,
            (uint64_t)(uintptr_t)(e7 + 4u), 0, 0);
        uint32_t assigned_seid = 0;
        memcpy(&assigned_seid, e7 + 4u, sizeof assigned_seid);
        g_v82_caps.assigned_seid = (uint8_t)assigned_seid;
        BTPSLogNow("V83 SEP RESULT ret=%#llx seid=%u type=SNK(1) audio_table=7; PEER validation required",
            (unsigned long long)ret, assigned_seid);
        if (ret != 0) {
            /* The native routine did not register an endpoint. Restore the
               previous pointer/counts and release only our two new blocks.
               Original six children remain owned by Apple's original table. */
            uint32_t six=6u;
            void *old=(void *)(uintptr_t)meta.table;
            memcpy((void *)(uintptr_t)(audio_context + 0x78u), &old, sizeof old);
            memcpy((void *)(uintptr_t)(audio_context + 0x68u), &six, sizeof six);
            memcpy((void *)(uintptr_t)(audio_context + 0x6cu), &six, sizeof six);
            g_v83_audio_extended=0u;
            g_v83_leaked_original_table=NULL;
            free(new_caps);
            free(new_table);
            BTPSSetStatus("diag.v83.audio_table", "ROLLED BACK: Sink registration returned %#llx; 6 entries restored", (unsigned long long)ret);
            return;
        }
        if (assigned_seid != 7u) {
            BTPSSetStatus("diag.v83.audio_table", "UNSAFE TRIAL: assigned unexpected Sink SEID=%u; restart daemon, do not retry", assigned_seid);
            return; /* successful SEP registration may retain entry pointers */
        }
        g_v82_sink_accepted = 1u;
        BTPSSetStatus("diag.v82.sep", "LOCAL register=0 SEID=%u role=SNK with high-level audio entry; remote validation required", assigned_seid);
    }
    /* Source SDP was published inside the native loop before our post-hook.
       Add the new Sink SDP here explicitly rather than relying on the old
       Source-SDP hook timing. Uses the existing permanent SDP descriptor. */
    if (__sync_bool_compare_and_swap(&g_v82_sdp_registered, 0u, 1u)) {
        g_v82_sdp_handle = 0;
        uint64_t ret = g_sdp_orig((uint64_t)(uintptr_t)BTPSV82SinkSDPDescriptor(),
                                   (uint64_t)(uintptr_t)&g_v82_sdp_handle);
        BTPSLogNow("V83 SDP add ret=%#llx handle=%#x class=0x110B; PEER SDP REQUIRED",
            (unsigned long long)ret, (unsigned)g_v82_sdp_handle);
        BTPSSetStatus("diag.sdp_sink_0x110b", "LOCAL add result=%#llx; peer SDP required", (unsigned long long)ret);
        BTPSSetStatus("diag.v82.sdp", "LOCAL add=%#llx handle=%#x; remote SDP 0x110B must be queried",
            (unsigned long long)ret, (unsigned)g_v82_sdp_handle);
        if (ret != 0) BTPSSetStatus("diag.v83.audio_table", "SDP publish failed; restart daemon to recover");
    }
    return;
reject_before_swap:
    BTPSLogNow("V83 REFUSED: native Source table/caps/SEID/context layout did not match expected image");
    BTPSSetStatus("diag.v83.audio_table", "REFUSED: Source table or capability validation failed");
    free(new_caps);
    free(new_table);
}

/* Function identity and exact four-word signature established from uploaded
 * bluetoothd: +0x3B4128. It takes audio context as x0, returns w0 status.
 * This observer calls the original once, and only then runs the experiment. */
static uint64_t btps_v83_hook_native_registration(uint64_t audio_context)
{
    uint64_t ret = g_v83_source_reg_orig ? g_v83_source_reg_orig(audio_context) : 1u;
    if (g_v82_armed) {
        BTPSLogNow("V83 NATIVE_SOURCE_LOOP RETURN ret=%#llx observed_sources=%u; post-return boundary",
                   (unsigned long long)ret, (unsigned)g_native_source_success);
        if (ret == 0) btps_v83_attempt_post_source(audio_context);
        else BTPSSetStatus("diag.v83.audio_table", "REFUSED: native Source loop returned error %#llx", (unsigned long long)ret);
    }
    return ret;
}

static void btps_v83_install_native_registration(uintptr_t base,int uuid_ok)
{
    if (!g_v82_armed || !uuid_ok) return;
    if (!g_orig[BTPS_H_REGISTER] || !g_v82_signal_hook_ok ||
        !g_v82_tx_hook_ok || !g_v82_sdp_hook_ok || !g_v80_enabled) {
        BTPSSetStatus("diag.v83.audio_table", "REFUSED: required RX/TX/SDP/config hooks missing");return;
    }
    uintptr_t target=base+BTPS_V83_SOURCE_REG_ENTRY;
    uint32_t words[4]={0};
    if (!btps_peek(target,words,sizeof words) ||
        memcmp(words,BTPS_V83_SOURCE_REG_SIG,sizeof words)!=0) {
        BTPSSetStatus("diag.v83.audio_table", "REFUSED: registration-loop instruction signature mismatch");return;
    }
    void *trampoline=NULL;
    MSHookFunction((void*)target,(void*)btps_v83_hook_native_registration,&trampoline);
    if (!trampoline) {
        BTPSSetStatus("diag.v83.audio_table", "FAILED: registration-loop hook returned no trampoline");return;
    }
    g_v83_source_reg_orig=(btps_v83_source_reg_fn_t)trampoline;
    g_v83_source_reg_hook_ok=1u;
    BTPSLogNow("V83 native Source loop hooked at image+0x3B4128; post-original one-shot table expansion only");
    BTPSSetStatus("diag.v83.audio_table", "ARMED: post-Source-loop table expansion; no changes until original returns");
}

static uint64_t hook_register(uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                              uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7)
{
    note_call(BTPS_H_REGISTER, a0, a1, a2, a3, a4, a5);
    const unsigned n = g_calls[BTPS_H_REGISTER];

    /* Read only the one SEID output byte, not eight bytes from the caller. */
    uint8_t seid_before = 0, seid_after = 0;
    const int seid_readable = (n <= 16u) &&
         btps_peek(a5, &seid_before, sizeof seid_before);

    if (n <= 12u) {
        const unsigned ncap = (unsigned)a3;
        if (ncap >= 1u && ncap <= 6u) {
            const size_t len = (size_t)ncap * 16u;
            uint8_t caps[96];
            if (btps_peek(a2, caps, len))
                btps_log_caps(caps, len);
            else
                BTPSLog("v5: capability pointer %#llx was unreadable",
                        (unsigned long long)a2);
        } else {
            BTPSLog("v5: refusing to interpret unexpected numCaps=%u", ncap);
        }
    }

    /* Capture one validated native SBC capability set into stable tweak-owned
       memory. Read-only observation of Source data; no source modification. */
    /* No capability mirroring: the v7.7 trial is retired. */

    /* Copy only the SBC Source capability bytes; never mutate Apple's memory.
       This is deliberately NOT an audio Sink success claim. */
    if (g_v82_armed && !g_v82_caps_ready && (uint32_t)a0 == 0 &&
        (uint32_t)a1 == 0 && (uint32_t)a3 == 3) {
        uint8_t raw[48], codec[4]; uint64_t ptr = 0;
        if (btps_peek(a2, raw, sizeof raw) && raw[16] == 7 &&
            raw[18] == 0 && raw[19] == 4) {
            memcpy(&ptr, raw + 24, sizeof ptr);
            if (btps_peek(ptr, codec, sizeof codec) &&
                btps_v77_prepare_sink_caps(&g_v82_caps, raw, codec) == 0) {
                g_v82_caps_ready = 1;
                BTPSLogNow("V82 SEP caps: stable private copy of 3 native SBC capabilities ready");
            }
        }
    }

    /* Always forward all arguments untouched. */
    const uint64_t started = mach_absolute_time();
    const uint64_t result = g_orig[BTPS_H_REGISTER]
        ? g_orig[BTPS_H_REGISTER](a0, a1, a2, a3, a4, a5, a6, a7) : 0;
    const uint64_t elapsed_us = btps_elapsed_us(started, mach_absolute_time());
    note_return(BTPS_H_REGISTER, result);
    if (n <= 25u || result != 0u) {
        BTPSLog("TRACE AVDTP registration #%u role=%s type=%llu count=%llu numCaps=%llu ret=%#llx (%s) duration_us=%llu",
                n, btps_endpoint_name((uint32_t)a0, (uint32_t)a1),
                (unsigned long long)a0, (unsigned long long)a4, (unsigned long long)a3,
                (unsigned long long)result, btps_registration_result(result),
                (unsigned long long)elapsed_us);
        BTPSSetStatus("diag.register_last", "#%u %s ret=%#llx us=%llu", n,
                      btps_endpoint_name((uint32_t)a0, (uint32_t)a1),
                      (unsigned long long)result, (unsigned long long)elapsed_us);
    }

    if (seid_readable && btps_peek(a5, &seid_after, sizeof seid_after)) {
        BTPSLog("TRACE registration #%u SEID OUT BYTE before=%u after=%u (only one byte read)",
                n, (unsigned)seid_before, (unsigned)seid_after);
    }

    if ((uint32_t)a0 == BTPS_AVDTP_MEDIA_AUDIO && (uint32_t)a1 == 1u) {
        /* Merely report any native Sink calls; NEVER inject or modify them. */
        BTPSLogNow("TRACE observed native Audio Sink registration #%u ret=%#llx", n,
                   (unsigned long long)result);
        BTPSSetStatus("diag.sink_native_observed", "yes - call #%u", n);
    }

    if ((uint32_t)a0 == BTPS_AVDTP_MEDIA_AUDIO &&
        (uint32_t)a1 == BTPS_AVDTP_TSEP_SRC) {
        if ((uint32_t)result == 0u) {
            const unsigned sources = __sync_add_and_fetch(&g_native_source_success, 1u);
            BTPSSetStatus("diag.native_source_ok", "%u", sources);
            if (seid_readable)
                BTPSLog("TRACE native A2DP Source #%u accepted (SEID=%u)",
                        sources, (unsigned)seid_after);
            else
                BTPSLog("TRACE native A2DP Source #%u accepted; SEID output unreadable", sources);
            if (sources == 6u) {
                BTPSLogNow("MILESTONE all six observed native Source endpoints registered; no Sink inserted");
                BTPSSetStatus("diag.capacity", "six native Source registrations; free space unverified");
                btps_v78_snapshot_capacity();
                btps_v79_snapshot_geometry();
                /* Independently verify that the ORIGINAL constructor allocated
                 * seven entries. This is read-only and adds NO Sink endpoint. */
                if (g_v81_shadow_returned) {
                    uint64_t context = 0;
                    uint8_t live_count = 0;
                    int readable = btps_peek((uint64_t)(g_v78_base + 0x9768b0u), &context, sizeof context) &&
                                   btps_peek(context + 0x60u, &live_count, sizeof live_count);
                    BTPSSetStatus("diag.v81_seven_slots",
                                  "ONE SHOT result: live_slots=%s%u expected=7 native_sources=6; v8.2 may separately attempt Sink",
                                  readable ? "" : "unreadable/", (unsigned)live_count);
                    BTPSLogNow("V81_LIVE RESULT readable=%s live_slots=%u expected=7 sources=6; v8.2 gate follows",
                               readable ? "yes" : "no", (unsigned)live_count);
                }
                /* v8.3: never insert Sink inside the native Source loop.
                   The optional post-return hook runs after all native Source setup. */
                /* Did the optional getter probe reach the index-3 lookup before registration? */
                if (g_v80_enabled && g_v80_index3_calls == 0u) {
                    BTPSSetStatus("diag.v80_config_lookup",
                                  "NO_INDEX3_CALL_OBSERVED before six Sources; cannot infer hook timing");
                    BTPSLogNow("V80_CFG_GET no index=3 call observed before native Sources registered");
                }

            }
        } else {
            BTPSLogNow("FAIL native Source registration #%u status %#llx (%s)",
                       n, (unsigned long long)result, btps_registration_result(result));
            BTPSSetStatus("diag.native_source_error", "call #%u status %#llx", n,
                          (unsigned long long)result);
        }
    }

    if (BTPSExperimentsEnabled() && n == 1u) {
        BTPSLogNow("WARN legacy experiment preference ON, but Sink injection is fully DISABLED");
        BTPSSetStatus("experiment.sink_register",
                      "v6 safety gate: disabled (no private SDP invocation)");
    }
    return result;
}
/* --------------------------------------------------------------------------------------- v7 SDP observer
 * Entry verified in this exact 10,196,720-byte bluetoothd image at image+0x1e8e78.
 * The function has 20 direct call sites. Disassembly establishes that x0 is a two-list
 * descriptor (pointer,count at +0/+8 and pointer,count at +0x10/+0x18), and x1 is a
 * nullable 32-bit record-handle out pointer. This is NOT a public, stable ABI.
 *
 * Important: this hook is opt-in and does no mutation. In case a private ABI assumption
 * is wrong, the five normal diagnostic hooks still operate with this observer OFF.
 */
#define BTPS_SDP_RECORD_ADD_ENTRY 0x001e8e78ul
static const uint32_t BTPS_SDP_RECORD_ADD_SIG[4] = {
    0xd503237fu, 0xa9bd57f6u, 0xa9014ff4u, 0xa9027bfdu
};
static volatile unsigned g_sdp_calls = 0;
static volatile unsigned g_sdp_source_seen = 0;
static volatile unsigned g_sdp_sink_seen = 0;

static int btps_sdp_probe_requested(void)
{
    /* Read the exact current-user domain used by the Preferences pane. */
    CFPropertyListRef v = CFPreferencesCopyAppValue(CFSTR(BTPS_KEY_SDP_PROBE), CFSTR(BTPS_PREFS_DOMAIN));
    int on = v && CFGetTypeID(v) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)v);
    if (v) CFRelease(v);
    return on;
}

static uint16_t btps_load_u16(const uint8_t *b)
{
    uint16_t v = 0;
    memcpy(&v, b, sizeof v);
    return v;
}

static uint64_t btps_load_u64(const uint8_t *b)
{
    uint64_t v = 0;
    memcpy(&v, b, sizeof v);
    return v;
}

static void btps_log_sdp_attributes(unsigned n, const char *which, uint64_t address, unsigned count)
{
    /* Inspect at most eight 24-byte entries in a compact, bounded summary.
     * This avoids overflowing the 300-line Settings ring during SDP startup. */
    if (count == 0u) {
        BTPSLog("SDP_PROBE #%u %s attrs=none", n, which);
        return;
    }
    if (!address || count > 128u) {
        BTPSLog("SDP_PROBE #%u %s attrs=unreadable-or-implausible count=%u", n, which, count);
        return;
    }
    unsigned limit = count < 8u ? count : 8u;
    char info[150] = "";
    size_t used = 0;
    for (unsigned i = 0; i < limit; i++) {
        uint8_t attr[24];
        if (i > (UINT64_MAX - address) / 24u || !btps_peek(address + (uint64_t)i * 24u, attr, sizeof attr)) {
            (void)snprintf(info + used, sizeof info - used, " [#%u unreadable]", i);
            break;
        }
        /* Inspected function reads a 16-bit attribute ID at element +0 and a
         * one-byte element type at +8. Do not assume more about the private format. */
        unsigned attribute_id = (unsigned)btps_load_u16(attr);
        unsigned element_type = (unsigned)attr[8];
        int added = snprintf(info + used, sizeof info - used, " %04x:t%02x", attribute_id, element_type);
        if (added < 0) break;
        if ((size_t)added >= sizeof info - used) { used = sizeof info - 1u; break; }
        used += (size_t)added;
        if (attribute_id == 1u && element_type == 6u) {
            /* Matched the precise sequence in the record-add function:
             * list[i].value (+16), then candidate 16-bit class at value+8.
             * Observing 0x110A here is suggestive, not independent remote proof. */
            uint64_t element_data = btps_load_u64(attr + 16);
            uint16_t candidate_class = 0;
            if (element_data <= UINT64_MAX - 8u &&
                btps_peek(element_data + 8u, &candidate_class, sizeof candidate_class))
                BTPSLog("SDP_PROBE #%u %s candidate_class16=0x%04x (private ABI)",
                        n, which, (unsigned)candidate_class);
        }
    }
    BTPSLog("SDP_PROBE #%u %s attr_ids(type) count=%u first%u:%s%s", n, which, count, limit,
            info, count > limit ? " ..." : "");
}

/* Minimal, bounded extraction of the same class candidate we already log.
 * It is a private in-memory hint, NOT proof of remote SDP discoverability. */
static uint16_t btps_sdp_class_hint(uint64_t descriptor)
{
    uint8_t lists[32];
    if (!btps_peek(descriptor, lists, sizeof lists)) return 0;
    uint64_t list = btps_load_u64(lists);
    uint16_t count = btps_load_u16(lists + 8);
    if (!list || count > 128u) return 0;
    unsigned n = count < 32u ? count : 32u;
    for (unsigned i = 0; i < n; ++i) {
        if ((uint64_t)i > (UINT64_MAX - list) / 24u) return 0;
        uint8_t attr[24];
        if (!btps_peek(list + (uint64_t)i * 24u, attr, sizeof attr)) return 0;
        if (btps_load_u16(attr) == 1u && attr[8] == 6u) {
            uint64_t ptr = btps_load_u64(attr + 16);
            uint16_t service = 0;
            if (ptr <= UINT64_MAX - 8u && btps_peek(ptr + 8u, &service, sizeof service))
                return service;
        }
    }
    return 0;
}

static uint64_t hook_sdp_add_record(uint64_t descriptor, uint64_t handle_out)
{
    unsigned n = __sync_add_and_fetch(&g_sdp_calls, 1u);
    const uint16_t service_hint = btps_sdp_class_hint(descriptor);
    uint32_t handle_before = 0, handle_after = 0;
    const int handle_readable = handle_out && btps_peek(handle_out, &handle_before, sizeof handle_before);
    const int sample = n <= 24u || (n % 100u) == 0u;
    if (sample) {
        uint8_t header[32];
        if (btps_peek(descriptor, header, sizeof header)) {
            uint64_t first_ptr = btps_load_u64(header);
            uint16_t first_count = btps_load_u16(header + 8);
            uint64_t second_ptr = btps_load_u64(header + 16);
            uint16_t second_count = btps_load_u16(header + 24);
            BTPSLog("SDP_PROBE #%u enter listA.count=%u listB.count=%u handle_out=%s",
                    n, (unsigned)first_count, (unsigned)second_count,
                    handle_readable ? "readable" : "unavailable");
            btps_log_sdp_attributes(n, "listA", first_ptr, first_count);
            btps_log_sdp_attributes(n, "listB", second_ptr, second_count);
        } else {
            BTPSLog("SDP_PROBE #%u descriptor unreadable; forwarding untouched", n);
        }
    }
    /* The single and only invocation of the original routine. */
    uint64_t ret = g_sdp_orig ? g_sdp_orig(descriptor, handle_out) : 0xFFFFFFFFull;
    if (ret == 0 && service_hint == 0x110au) {
        unsigned seen = __sync_add_and_fetch(&g_sdp_source_seen, 1u);
        BTPSSetStatus("diag.sdp_source_seen", "yes - local Source record-add succeeded (%u)", seen);
    } else if (ret == 0 && service_hint == 0x110bu) {
        unsigned seen = __sync_add_and_fetch(&g_sdp_sink_seen, 1u);
        BTPSSetStatus("diag.sdp_sink_candidate_seen", "local 0x110B record-add observed (%u); remote unverified", seen);
        BTPSLogNow("SDP_PROBE NOTE: local 0x110B class candidate added; Windows SDP visibility NOT verified");
    }
    if (ret == 0 && service_hint == 0x110a && g_v82_armed &&
        g_v82_sink_accepted && g_v83_audio_extended &&
        !g_v82_sdp_registered && g_sdp_orig) {
        if (__sync_bool_compare_and_swap(&g_v82_sdp_registered, 0u, 1u)) {
            const void *candidate = BTPSV82SinkSDPDescriptor();
            g_v82_sdp_handle = 0;
            uint64_t add = g_sdp_orig((uint64_t)(uintptr_t)candidate,
                                      (uint64_t)(uintptr_t)&g_v82_sdp_handle);
            BTPSSetStatus("diag.sdp_sink_0x110b", "LOCAL add result=%#llx; remote 0x110B NOT VERIFIED", (unsigned long long)add);
            BTPSSetStatus("diag.v82.sdp", "LOCAL add=%#llx handle=%#x; remote SDP 0x110B NOT VERIFIED",
                          (unsigned long long)add, (unsigned)g_v82_sdp_handle);
            BTPSLogNow("V82 SDP add ret=%#llx handle=%#x class=0x110B; PEER SDP REQUIRED",
                       (unsigned long long)add, (unsigned)g_v82_sdp_handle);
        }
    }
    if (sample) {
        int after_readable = handle_out && btps_peek(handle_out, &handle_after, sizeof handle_after);
        BTPSLog("SDP_PROBE #%u exit ret=%#llx out_handle=%s before=0x%08x after=0x%08x",
                n, (unsigned long long)ret, after_readable ? "readable" : "unavailable",
                (unsigned)handle_before, (unsigned)handle_after);
        BTPSSetStatus("diag.sdp_probe_calls", "%u call(s), last return %#llx", n,
                      (unsigned long long)ret);
    }
    return ret;
}

static void install_optional_sdp_probe(uintptr_t base, int uuid_ok)
{
    if (!btps_sdp_probe_requested() && !g_v82_armed) {
        BTPSSetStatus("diag.sdp_probe", "OFF (default); no SDP hook installed");
        BTPSLogNow("SDP_PROBE disabled by default; enable separately in Settings, then restart bluetoothd once");
        return;
    }
    if (!uuid_ok) {
        BTPSSetStatus("diag.sdp_probe", "REFUSED: exact bluetoothd UUID mismatch");
        return;
    }
    const uintptr_t entry = base + BTPS_SDP_RECORD_ADD_ENTRY;
    uint32_t current[4] = {0};
    if (!btps_peek(entry, current, sizeof current) ||
        memcmp(current, BTPS_SDP_RECORD_ADD_SIG, sizeof current) != 0) {
        BTPSSetStatus("diag.sdp_probe", "REFUSED: SDP record-add code signature mismatch");
        BTPSLogNow("SDP_PROBE REFUSED: unexpected code at image+0x1e8e78");
        return;
    }
    if (!g_orig[BTPS_H_REGISTER] || !g_orig[BTPS_H_ADVERTISE]) {
        BTPSSetStatus("diag.sdp_probe", "REFUSED: baseline hooks not both installed");
        return;
    }
    void *orig = NULL;
    BTPSLogNow("SDP_PROBE installing at image+0x1e8e78 (PASS-THROUGH unless v8.2 one-shot Sink registration succeeds)");
    MSHookFunction((void *)entry, (void *)hook_sdp_add_record, &orig);
    if (!orig) {
        BTPSSetStatus("diag.sdp_probe", "FAILED to install; restart with toggle OFF");
        BTPSLogNow("SDP_PROBE FAILED: no trampoline from hook engine");
        return;
    }
    g_sdp_orig = (btps_sdp_fn_t)orig;
    g_v82_sdp_hook_ok = 1;
    BTPSSetStatus("diag.sdp_probe", "installed; one-shot v8.2 may add separate Sink record");
    BTPSLogNow("SDP_PROBE installed; only v8.2 armed trial after accepted Sink SEP may add 0x110B");
}

/* ------------------------------------------------------------------------------------------------ installing */

static void install_hooks(uintptr_t base, int uuid_ok)
{
    void *hook_fn[BTPS_N_HOOKS];
    hook_fn[BTPS_H_REGISTER]     = (void *)hook_register;
    hook_fn[BTPS_H_ADVERTISE]    = (void *)hook_advertise;
    hook_fn[BTPS_H_SETCONFIGIND] = (void *)hook_setconfigind;
    hook_fn[BTPS_H_ACCEPT_SBC]   = (void *)hook_accept_sbc;
    hook_fn[BTPS_H_PUBLISH]      = (void *)hook_publish;

    /* 1. read the first four instruction words of every target with the fault-safe reader and compare */
    int match[BTPS_N_HOOKS];
    unsigned nmatch = 0;
    for (int i = 0; i < BTPS_N_HOOKS; i++) {
        const btps_target_t *t = &BTPS_TARGETS[i];
        uint32_t w[4] = {0, 0, 0, 0};
        int readable = btps_peek((uint64_t)(base + t->entry), w, sizeof w);
        match[i] = readable && memcmp(w, t->sig, sizeof w) == 0;
        nmatch += (unsigned)match[i];
        if (!match[i]) {
            if (readable)
                BTPSLogNow("%s: code at image+%#lx is %08x %08x %08x %08x, expected %08x %08x %08x %08x", t->name,
                           (unsigned long)t->entry, w[0], w[1], w[2], w[3], t->sig[0], t->sig[1], t->sig[2], t->sig[3]);
            else
                BTPSLogNow("%s: image+%#lx is not readable", t->name, (unsigned long)t->entry);
        }
    }

    /* 2. decide: the UUID is a hint, the code is the proof */
    int all_match  = (nmatch == (unsigned)BTPS_N_HOOKS);
    int recognised = uuid_ok || all_match;
    if (uuid_ok) {
        BTPSSetStatus("image.match", "yes - UUID matches the analysed build");
    } else if (all_match) {
        BTPSSetStatus("image.match", "yes - code matches although the UUID differs");
        BTPSLogNow("UUID differs from the analysed build, but the code at all %d targets matches: hooking", BTPS_N_HOOKS);
    } else {
        BTPSSetStatus("image.match", "NO - unknown build, hooks disabled");
        BTPSLogNow("unknown daemon build: UUID differs and only %u of %d targets match: no hooks will be installed",
                   nmatch, BTPS_N_HOOKS);
    }

    /* 3. hook */
    unsigned ok = 0, bad = 0;
    for (int i = 0; i < BTPS_N_HOOKS; i++) {
        const btps_target_t *t = &BTPS_TARGETS[i];
        char key[56];
        snprintf(key, sizeof key, "hook.%s", t->name);

        if (!recognised) {
            BTPSSetStatus(key, "NOT hooked: unknown daemon build");
            bad++;
            continue;
        }
        if (!match[i]) {
            BTPSSetStatus(key, "skipped: code differs");
            bad++;
            continue;
        }

        const uint32_t *code = (const uint32_t *)(base + t->entry);
        BTPSLogNow("hooking %s at image+%#lx (%p)", t->name, (unsigned long)t->entry, (const void *)code);
        void *orig = NULL;
        MSHookFunction((void *)code, hook_fn[i], &orig);
        if (!orig) {
            BTPSLogNow("%s: hook engine returned no trampoline -> treating as failed", t->name);
            BTPSSetStatus(key, "FAILED: no trampoline from the hook engine");
            bad++;
            continue;
        }
        g_orig[i] = (btps_fn_t)orig;
        BTPSLogNow("%s hooked, original continues at %p", t->name, orig);
        BTPSSetStatus(key, "installed");
        ok++;
    }
    BTPSSetSummary(1u, (unsigned)recognised, ok, bad);
    BTPSLogNow("hooks: %u installed, %u not installed", ok, bad);
}

%ctor {
    const char *prog = getprogname();
    if (!prog || strcmp(prog, "bluetoothd") != 0) return;      /* the filter plist should guarantee this; be paranoid */

    BTPSLogInit();
    BTPSLogNow("BTPhonoSink %s loaded into %s pid %d (built %s %s)", BTPS_BUILD_TAG, prog, (int)getpid(), __DATE__, __TIME__);
    BTPSSetStatus("build", "%s, %s %s", BTPS_BUILD_TAG, __DATE__, __TIME__);
    BTPSSetStatus("pid", "%d", (int)getpid());
    BTPSSetStatus("experiments", "off (v7 forced-passive, stored=%s)", BTPSExperimentsEnabled() ? "ON" : "off");
    BTPSSetStatus("experiment.sink_register", "v8.2: OFF by default; separate one-shot Sink trial only with seven-slot arm");
    BTPSSetStatus("diag.sdp_sink_0x110b", "not verified; optional trial may add local 0x110B candidate");
    BTPSSetStatus("diag.audio_receive", "NOT hooked - media transport/decoder wiring absent");
    BTPSSetStatus("diag.v77_sink_trial", "DISABLED permanently in v7.8 after return 0x68");
    BTPSSetStatus("diag.v78_table", "PENDING: read-only table scan after six normal Sources");
    BTPSSetStatus("diag.v79_allocator", "PENDING: allocation geometry after six normal Sources");
    BTPSSetStatus("diag.v80_config_lookup", "PENDING: optional observer not installed yet");
    BTPSSetStatus("diag.v81_seven_slots", "OFF (default); no count overrides unless explicitly armed");
    BTPSSetStatus("diag.stage", "opt-in live A2DP sink signaling trial; PASS requires remote Sink media bytes");
    BTPSSetStatus("diag.v82.trial", "OFF pending one-shot arm");
    BTPSSetStatus("diag.v83.audio_table", "OFF: no extra audio-context table by default");
    BTPSSetStatus("diag.v82.sep", "NOT attempted");
    BTPSSetStatus("diag.v82.sdp", "NOT published");
    BTPSSetStatus("diag.v82.rx", "NOT hooked");
    BTPSSetStatus("diag.v82.media", "UNOBSERVED: media callback not hooked; no PASS possible in this build");
    BTPSSetStatus("diag.v82.tx", "OFF: experimental TX hook not armed");
    BTPSSetStatus("diag.session_id", "%ld-%d", (long)time(NULL), (int)getpid());
    BTPSLogNow("SESSION start pid=%d optional one-shot 7-slot initializer config, OFF by default; no Sink registration", (int)getpid());

    char exe[512];
    uint32_t exe_size = sizeof exe;
    if (_NSGetExecutablePath(exe, &exe_size) != 0) snprintf(exe, sizeof exe, "?");
    BTPSLogNow("executable path: %s", tail_of(exe, 120));
    BTPSSetStatus("image.exec_path", "%s", tail_of(exe, 150));

    log_images();

    uint32_t index = 0;
    const struct mach_header_64 *mh = NULL;
    if (!find_main_image(&index, &mh)) {
        BTPSLogNow("no MH_EXECUTE image found: no hooks will be installed");
        BTPSSetStatus("image.match", "NO - main executable not found, hooks disabled");
        BTPSSetSummary(1u, 0u, 0u, (unsigned)BTPS_N_HOOKS);
        return;
    }

    uint8_t uuid[16] = {0};
    char have_s[40] = "?";
    int have = image_uuid(mh, uuid);
    if (have) uuid_string(uuid, have_s, sizeof have_s);
    int uuid_ok = have && memcmp(uuid, BTPS_EXPECTED_UUID, 16) == 0;

    BTPSLogNow("main executable is image[%u] at %p, UUID %s (analysed build: %s)", index, (const void *)mh, have_s, BTPS_BUILD_UUID);
    BTPSSetStatus("image.index", "%u", index);
    BTPSSetStatus("image.uuid", "%s", have_s);
    BTPSSetStatus("image.expected", "%s", BTPS_BUILD_UUID);

    /* v7.7's one-shot registration was refused with 0x68; intentionally never retry it.
       Even a persisted ON preference cannot start another Sink call. */
    BTPSSetStatus("diag.v77_sink_trial", "DISABLED: do not retry return 0x68");
    g_v78_exact_uuid = uuid_ok;
    g_v78_base = (uintptr_t)mh;
    install_hooks((uintptr_t)mh, uuid_ok);
    btps_v80_install_config_observer((uintptr_t)mh, uuid_ok);
    btps_v82_install_rx((uintptr_t)mh, uuid_ok);
    btps_v82_install_tx((uintptr_t)mh, uuid_ok);
    install_optional_sdp_probe((uintptr_t)mh, uuid_ok);
    btps_v83_install_native_registration((uintptr_t)mh, uuid_ok);
    /* Explicit user request only; no sockets or audio on Bluetooth callback threads. */
    if (uuid_ok && g_orig[BTPS_H_REGISTER] && g_orig[BTPS_H_ADVERTISE]) {
        BTPSDaemonProbeStart();
        BTPSDaemonProbeStartV75();
    } else {
        BTPSSetStatus("diag.v74_ipc", "DISABLED: exact daemon UUID and baseline hooks required");
        BTPSSetStatus("diag.v75_sbc", "DISABLED: exact daemon UUID and baseline hooks required");
    }
}
