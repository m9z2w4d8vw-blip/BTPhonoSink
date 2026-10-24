/*
 * BTPhonoSink - OBSERVE-ONLY build.
 *
 * Goal of the project: make the iPhone show up as a Bluetooth speaker (A2DP sink). Nobody knows yet whether the
 * daemon's stack can be taught that, so this build only WATCHES. Everything it sees is written to the debug log
 * that Settings > BTPhonoSink displays.
 *
 * What it does:
 *   1. Refuses to touch anything unless this is the exact bluetoothd build that was analysed (image UUID).
 *   2. For every target function, checks the first four instruction words before hooking (BTPSBuild.h).
 *      A mismatch is a log line, never a crash.
 *   3. Hooks five functions with a generic pass-through that forwards all eight argument registers untouched and
 *      logs the first calls. It cannot change behaviour, whatever the real signatures turn out to be.
 *   4. ONLY if the "Enable sink experiments" switch is on: whenever the daemon registers an AVDTP *source*
 *      endpoint, register a *sink* endpoint right after it, re-using the same capability list.
 *
 * Why the old version could not work: every offset in the first analysis pointed one instruction past the
 * function's `pacibsp`. On arm64e that makes the hook's return address double-signed, so the first call crashes.
 * The table in BTPSBuild.h was regenerated from the binary and each entry checked against its own log message.
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

#define BTPS_BUILD_TAG "observe-only v1"

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

static int main_image(uint8_t uuid_out[16], uintptr_t *base_out)
{
    const struct mach_header_64 *mh = (const struct mach_header_64 *)_dyld_get_image_header(0);
    if (!mh || mh->magic != MH_MAGIC_64) return 0;
    *base_out = (uintptr_t)mh;
    const uint8_t *p = (const uint8_t *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_UUID) {
            memcpy(uuid_out, ((const struct uuid_command *)lc)->uuid, 16);
            return 1;
        }
        p += lc->cmdsize;
    }
    return 0;
}

static void uuid_string(const uint8_t u[16], char *out, size_t cap)
{
    snprintf(out, cap, "%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
             u[0], u[1], u[2], u[3], u[4], u[5], u[6], u[7], u[8], u[9], u[10], u[11], u[12], u[13], u[14], u[15]);
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

/* The registration function logs: AVDTP_RegisterMultipoint(mediaType, count, endpointType, caps, numCaps) */
static uint64_t hook_register(uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3,
                              uint64_t a4, uint64_t a5, uint64_t a6, uint64_t a7)
{
    note_call(BTPS_H_REGISTER, a0, a1, a2, a3, a4, a5);
    unsigned n = g_calls[BTPS_H_REGISTER];

    /* Learn how Apple lays out the capability list: dump the memory `caps` points at (first few calls only). */
    if (n <= 6u) {
        uint8_t buf[96];
        if (btps_peek(a3, buf, sizeof buf)) BTPSLogHexdump("caps", buf, sizeof buf);
        else BTPSLog("caps value %#llx is not a readable pointer (it may be a handle or bitmask)", (unsigned long long)a3);
    }

    uint64_t r = g_orig[BTPS_H_REGISTER] ? g_orig[BTPS_H_REGISTER](a0, a1, a2, a3, a4, a5, a6, a7) : 0;
    note_return(BTPS_H_REGISTER, r);

    /* EXPERIMENT (off unless switched on in Settings): mirror each audio SOURCE endpoint as a SINK endpoint with the
     * same capability list. Re-using Apple's own list avoids guessing the structure layout. */
    if (BTPSExperimentsEnabled() && g_orig[BTPS_H_REGISTER] &&
        (uint32_t)a0 == BTPS_AVDTP_MEDIA_AUDIO && (uint32_t)a2 == BTPS_AVDTP_TSEP_SRC && (uint32_t)r == 0u) {
        BTPSLogNow("EXPERIMENT: registering a SINK endpoint next to this SOURCE one (same caps %#llx)", (unsigned long long)a3);
        uint64_t r2 = g_orig[BTPS_H_REGISTER](a0, a1, BTPS_AVDTP_TSEP_SNK, a3, a4, a5, a6, a7);
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

    unsigned ok = 0, bad = 0;
    for (int i = 0; i < BTPS_N_HOOKS; i++) {
        const btps_target_t *t = &BTPS_TARGETS[i];
        char key[56];
        snprintf(key, sizeof key, "hook.%s", t->name);

        if (!uuid_ok) {
            BTPSSetStatus(key, "NOT hooked: unknown bluetoothd build");
            bad++;
            continue;
        }
        const uint32_t *code = (const uint32_t *)(base + t->entry);
        if (memcmp(code, t->sig, sizeof t->sig) != 0) {
            BTPSLogNow("%s: first instructions differ from the analysed build -> NOT hooking (%08x %08x %08x %08x)",
                       t->name, code[0], code[1], code[2], code[3]);
            BTPSSetStatus(key, "skipped: code differs (%08x %08x)", code[0], code[1]);
            bad++;
            continue;
        }

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
    BTPSSetSummary(1u, (unsigned)uuid_ok, ok, bad);
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

    uint8_t uuid[16] = {0};
    uintptr_t base = 0;
    int have = main_image(uuid, &base);
    char have_s[40] = "?";
    if (have) uuid_string(uuid, have_s, sizeof have_s);
    int uuid_ok = have && memcmp(uuid, BTPS_EXPECTED_UUID, 16) == 0;

    BTPSLogNow("image base %p, UUID %s", (void *)base, have_s);
    BTPSSetStatus("image.uuid", "%s", have_s);
    BTPSSetStatus("image.expected", "%s", BTPS_BUILD_UUID);
    BTPSSetStatus("image.match", "%s", uuid_ok ? "yes - offsets apply" : "NO - hooks disabled");
    if (!uuid_ok) BTPSLogNow("UUID differs from the analysed build %s: no hooks will be installed", BTPS_BUILD_UUID);

    install_hooks(base, uuid_ok);
}
