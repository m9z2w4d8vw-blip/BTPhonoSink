/*
 * BTPhonoSink - v6 detailed passive diagnostics (observe only).
 *
 * Goal of the project: make the iPhone show up as a Bluetooth speaker (A2DP sink). Nobody knows yet whether the
 * daemon's stack can be taught that, so this build only WATCHES. Everything it sees is written to the debug log
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
 *      This hook never adds, deletes or modifies an SDP record and does not allocate an AVDTP SEP.
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
#include <string.h>
#include <unistd.h>
#include <substrate.h>

#include "BTPSBuild.h"
#include "BTPSLog.h"
#include "BTPSShared.h"
#include "BTPSDaemonProbe.h"

#define BTPS_BUILD_TAG "v7.4-daemon-to-helper-probe"

/* AVDTP constants, used for native Source registration diagnostics */
#define BTPS_AVDTP_TSEP_SRC 0u
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
typedef uint64_t (*btps_sdp_fn_t)(uint64_t, uint64_t);
static btps_sdp_fn_t g_sdp_orig = NULL;
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
    if (!btps_sdp_probe_requested()) {
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
    BTPSLogNow("SDP_PROBE installing OPTIONAL observer at image+0x1e8e78 (pass-through only)");
    MSHookFunction((void *)entry, (void *)hook_sdp_add_record, &orig);
    if (!orig) {
        BTPSSetStatus("diag.sdp_probe", "FAILED to install; restart with toggle OFF");
        BTPSLogNow("SDP_PROBE FAILED: no trampoline from hook engine");
        return;
    }
    g_sdp_orig = (btps_sdp_fn_t)orig;
    BTPSSetStatus("diag.sdp_probe", "installed (optional 6th hook, non-mutating)");
    BTPSLogNow("SDP_PROBE optional observer installed; SDP records/SEPs will NOT be added");
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
    BTPSSetStatus("experiment.sink_register", "disabled - no additional registrations permitted");
    BTPSSetStatus("diag.sdp_sink_0x110b", "no local Sink SDP publishing implemented; verify externally");
    BTPSSetStatus("diag.audio_receive", "NOT hooked - media transport/decoder wiring absent");
    BTPSSetStatus("diag.stage", "observe native registration, advertising, configuration, SDP (optional) and publish callbacks");
    BTPSSetStatus("diag.session_id", "%ld-%d", (long)time(NULL), (int)getpid());
    BTPSLogNow("SESSION start pid=%d role=observe-only; no SDP/endpoint modifications", (int)getpid());

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

    install_hooks((uintptr_t)mh, uuid_ok);
    install_optional_sdp_probe((uintptr_t)mh, uuid_ok);
    /* Explicit user request only; no sockets or audio on Bluetooth callback threads. */
    if (uuid_ok && g_orig[BTPS_H_REGISTER] && g_orig[BTPS_H_ADVERTISE])
        BTPSDaemonProbeStart();
    else
        BTPSSetStatus("diag.v74_ipc", "DISABLED: exact daemon UUID and baseline hooks required");
}
