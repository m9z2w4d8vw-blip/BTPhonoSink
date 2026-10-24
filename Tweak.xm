/*
 * BTPhonoSink - OBSERVE-ONLY build.
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
 *   4. ONLY if the "Enable sink experiments" switch is on: whenever the daemon registers an AVDTP *source*
 *      endpoint, register a *sink* endpoint right after it, re-using the same capability list.
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
 */
#include <CoreFoundation/CoreFoundation.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <substrate.h>

#include "BTPSBuild.h"
#include "BTPSLog.h"
#include "BTPSShared.h"

#define BTPS_BUILD_TAG "observe-only v3"

/* AVDTP constants, used only by the experiment */
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

static void note_return(int idx, uint64_t r)
{
    if (g_calls[idx] <= 25u)
        BTPSLog("%s returned %#llx", BTPS_TARGETS[idx].name, (unsigned long long)r);
}

/* ------------------------------------------------------------------------------------------ pass-through hooks */

#define BTPS_OBSERVER(FN, IDX)                                                                            \
    static uint64_t FN(uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,                                \
                       uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7)                                \
    {                                                                                                     \
        note_call(IDX, a0, a1, a2, a3, a4, a5);                                                           \
        uint64_t r = g_orig[IDX] ? g_orig[IDX](a0, a1, a2, a3, a4, a5, a6, a7) : 0;                       \
        note_return(IDX, r);                                                                              \
        return r;                                                                                         \
    }

BTPS_OBSERVER(hook_advertise,     BTPS_H_ADVERTISE)       /* logs "Advertising A2DP Source"                        */
BTPS_OBSERVER(hook_setconfigind,  BTPS_H_SETCONFIGIND)    /* a remote device configured one of our endpoints       */
BTPS_OBSERVER(hook_accept_sbc,    BTPS_H_ACCEPT_SBC)      /* ... and chose SBC settings                            */
BTPS_OBSERVER(hook_publish,       BTPS_H_PUBLISH)         /* an audio device was published to the audio system     */

/* AVDTP_RegisterMultipoint(a0=mediaType, a1=endpointType, a2=caps [pointer], a3=numCaps, a4=count); a5 is a
 * pointer the daemon's own log line does not print - not yet known what it's for. See the v3 note above for how
 * this mapping was confirmed (it differs from the print order in that log line). */
static uint64_t hook_register(uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                              uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7)
{
    note_call(BTPS_H_REGISTER, a0, a1, a2, a3, a4, a5);
    unsigned n = g_calls[BTPS_H_REGISTER];

    /* Learn how Apple lays out the capability list: dump the memory `caps` (a2) points at (first few calls only).
     * Also watch a5: if the real call changes what it points to, that's a strong sign it's an out-parameter. */
    uint64_t a5_before = 0;
    int a5_readable = (n <= 6u) && btps_peek(a5, &a5_before, sizeof a5_before);
    if (n <= 6u) {
        uint8_t buf[96];
        if (btps_peek(a2, buf, sizeof buf)) BTPSLogHexdump("caps", buf, sizeof buf);
        else BTPSLog("caps value %#llx is not a readable pointer (it may be a handle or bitmask)", (unsigned long long)a2);
        if (a5_readable) BTPSLog("arg5 %#llx currently holds %#llx (unknown purpose, watching for a change)",
                                  (unsigned long long)a5, (unsigned long long)a5_before);
    }

    uint64_t r = g_orig[BTPS_H_REGISTER] ? g_orig[BTPS_H_REGISTER](a0, a1, a2, a3, a4, a5, a6, a7) : 0;
    note_return(BTPS_H_REGISTER, r);

    if (a5_readable) {
        uint64_t a5_after = 0;
        if (btps_peek(a5, &a5_after, sizeof a5_after) && a5_after != a5_before)
            BTPSLog("arg5 %#llx changed %#llx -> %#llx across the real call (looks like an out-param)",
                    (unsigned long long)a5, (unsigned long long)a5_before, (unsigned long long)a5_after);
    }

    /* EXPERIMENT (off unless switched on in Settings): mirror each audio SOURCE endpoint as a SINK endpoint with the
     * same capability list. Re-using Apple's own list avoids guessing the structure layout. */
    if (BTPSExperimentsEnabled() && g_orig[BTPS_H_REGISTER] &&
        (uint32_t)a0 == BTPS_AVDTP_MEDIA_AUDIO && (uint32_t)a1 == BTPS_AVDTP_TSEP_SRC && (uint32_t)r == 0u) {
        BTPSLogNow("EXPERIMENT: registering a SINK endpoint next to this SOURCE one (same caps %#llx)", (unsigned long long)a2);
        uint64_t r2 = g_orig[BTPS_H_REGISTER](a0, BTPS_AVDTP_TSEP_SNK, a2, a3, a4, a5, a6, a7);
        BTPSLogNow("EXPERIMENT: sink registration returned %#llx", (unsigned long long)r2);
        BTPSSetStatus("experiment.sink_register", "returned %#llx", (unsigned long long)r2);
    }
    return r;
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
    BTPSSetStatus("experiments", "%s", BTPSExperimentsEnabled() ? "ON" : "off (observe-only)");

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
}
