"""v8.9.4: headphones mode is wired/USB only, and the helper can see route changes and interruptions.

The 21:39 log showed every headphones-mode start playing to `BluetoothA2DPOutput LAPTOP-UGIVBIA5`: iOS lists the
sending PC as an A2DP output and, because it connected last, routes the Playback category to it. Leaving that route
made the phone send SUSPEND, after which the PC closed the stream. No route change or interruption was ever handled
in any session, although earbuds were replugged during playback.
"""
import os
import pathlib
import re
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
HELPER = ROOT / "btpsaudiohelper/BTPSV88Stream.m"


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class V894WiredOutput(unittest.TestCase):
    def compile_run(self, source):
        compiler = shutil.which("cc")
        self.assertIsNotNone(compiler)
        flags = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-I" + str(ROOT),
                 "-I" + str(ROOT / "btpsaudiohelper")]
        env = dict(os.environ)
        if os.environ.get("BTPS_SANITIZE"):
            flags += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
            env.update(ASAN_OPTIONS="detect_leaks=0", UBSAN_OPTIONS="halt_on_error=1")
        with tempfile.TemporaryDirectory() as td:
            src = pathlib.Path(td) / "t.c"
            exe = pathlib.Path(td) / "t"
            src.write_text(source)
            built = subprocess.run([compiler, *flags, str(src), "-o", str(exe), "-pthread"],
                                   text=True, capture_output=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            ran = subprocess.run([str(exe)], text=True, capture_output=True, timeout=20, env=env)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)

    def test_policy_wired_mode_never_accepts_bluetooth(self):
        self.compile_run(r'''
#include <assert.h>
#include <string.h>
#include "BTPSV89Output.h"
static int check(int mode, btps_v89_kind kind, const char *name, const btps_v89_never *never, size_t n) {
    btps_v89_port port = {kind, "AA:BB:CC:DD:EE:FF-tacl", name};
    size_t bad = 99;
    return btps_v89_route_check(mode, &port, 1, never, n, &bad);
}
int main(void) {
    const btps_v89_never pc = {"", "laptop-ugivbia5"};          /* matched case-insensitively by name */
    /* Wired / USB only: the PC (or any Bluetooth device) is refused even when nothing is never-listed. */
    assert(check(BTPS_V89_MODE_HEADPHONES, BTPS_V89_PORT_HEADPHONES, "Headphones", NULL, 0) == BTPS_V89_ROUTE_OK);
    assert(check(BTPS_V89_MODE_HEADPHONES, BTPS_V89_PORT_BLUETOOTH, "LAPTOP-UGIVBIA5", NULL, 0) == BTPS_V89_ROUTE_NOT_HEADPHONES);
    assert(check(BTPS_V89_MODE_HEADPHONES, BTPS_V89_PORT_BLUETOOTH, "AirPods", NULL, 0) == BTPS_V89_ROUTE_NOT_HEADPHONES);
    assert(check(BTPS_V89_MODE_HEADPHONES, BTPS_V89_PORT_RECEIVER, "Receiver", NULL, 0) == BTPS_V89_ROUTE_NOT_HEADPHONES);
    assert(check(BTPS_V89_MODE_HEADPHONES, BTPS_V89_PORT_SPEAKER, "Speaker", NULL, 0) == BTPS_V89_ROUTE_NOT_HEADPHONES);
    /* Any device still allows Bluetooth earbuds, and the never-play list still blocks the PC. */
    assert(check(BTPS_V89_MODE_ANY, BTPS_V89_PORT_BLUETOOTH, "AirPods", &pc, 1) == BTPS_V89_ROUTE_OK);
    assert(check(BTPS_V89_MODE_ANY, BTPS_V89_PORT_BLUETOOTH, "LAPTOP-UGIVBIA5", &pc, 1) == BTPS_V89_ROUTE_NEVER_LISTED);
    /* Speaker mode is unchanged. */
    assert(check(BTPS_V89_MODE_SPEAKER, BTPS_V89_PORT_SPEAKER, "Speaker", NULL, 0) == BTPS_V89_ROUTE_OK);
    assert(check(BTPS_V89_MODE_SPEAKER, BTPS_V89_PORT_BLUETOOTH, "LAPTOP-UGIVBIA5", NULL, 0) == BTPS_V89_ROUTE_NOT_SPEAKER);
    assert(strstr(btps_v89_route_reason(BTPS_V89_ROUTE_NOT_HEADPHONES), "wired"));
    /* The stored value is unchanged, so an existing "headphones" choice becomes wired mode. */
    assert(btps_v89_mode_from_string("headphones") == BTPS_V89_MODE_HEADPHONES);
    return 0;
}
''')

    def test_helper_classifies_bluetooth_separately(self):
        kinds = between(read("btpsaudiohelper/BTPSV88Stream.m"), "static btps_v89_kind port_kind(", "static NSString *text_field(")
        wired = kinds.split("return BTPS_V89_PORT_HEADPHONES;", 1)[0]
        self.assertIn("AVAudioSessionPortHeadphones", wired)
        self.assertIn("AVAudioSessionPortUSBAudio", wired)
        self.assertNotIn("Bluetooth", wired.split("AVAudioSessionPortBuiltInReceiver", 1)[1])
        bluetooth = kinds.split("return BTPS_V89_PORT_HEADPHONES;", 1)[1].split("return BTPS_V89_PORT_BLUETOOTH;", 1)[0]
        for port in ("BluetoothA2DP", "BluetoothLE", "BluetoothHFP"):
            self.assertIn("AVAudioSessionPort" + port, bluetooth)

    def test_wired_mode_cannot_reach_bluetooth_and_beats_a_later_pc(self):
        helper = read("btpsaudiohelper/BTPSV88Stream.m")
        wired = between(helper, "static int configure_wired(", "static int configure_output(")
        category = wired.index("setCategory:AVAudioSessionCategoryPlayAndRecord mode:AVAudioSessionModeDefault options:0")
        override = wired.index("overrideOutputAudioPort:AVAudioSessionPortOverrideNone")
        precheck = wired.index("if(verdict && builtin_only(session))")
        activate = wired.index("setActive:YES")
        verify = wired.index("for(unsigned i=0;i<20 && route_verdict(session,NULL);i++)")
        self.assertLess(category, override)
        self.assertLess(override, precheck)
        self.assertLess(precheck, activate)
        self.assertLess(activate, verify)
        self.assertNotIn("DefaultToSpeaker", wired)            # never falls back to the loudspeaker
        self.assertIn("AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation", wired.split("note_refusal(session,\"configured\"", 1)[0])
        only = between(helper, "static int builtin_only(", "static int configure_wired(")
        self.assertIn("if(!outputs.count) return 0;", only)  # an empty candidate is not conclusive
        self.assertIn("kind!=BTPS_V89_PORT_SPEAKER && kind!=BTPS_V89_PORT_RECEIVER", only)
        dispatch = between(helper, "static int configure_output(", "static int start_output(")
        self.assertLess(dispatch.index("if(g_output_mode==BTPS_V89_MODE_HEADPHONES) return configure_wired(rate,s);"),
                        dispatch.index("configure_external(rate,s)"))
        external = between(helper, "static int configure_external(", "static int builtin_only(")
        self.assertIn("AVAudioSessionCategoryPlayback", external)  # "any device" keeps following iOS

    def test_route_changes_and_interruptions_can_be_delivered(self):
        helper = read("btpsaudiohelper/BTPSV88Stream.m")
        loop = between(helper, "__block int interruption=0,route_changed=0;",
                       "[[NSNotificationCenter defaultCenter] removeObserver:observer];")
        drain = loop.index("CFRunLoopRunInMode(kCFRunLoopDefaultMode,0,true)")
        self.assertLess(drain, loop.index("usleep(5000);"))
        self.assertGreater(drain, loop.index("for(;;) {"))
        registration = helper.split("__block int interruption=0,route_changed=0;", 1)[1].split("for(;;) {", 1)[0]
        self.assertEqual(registration.count("queue:nil"), 2)  # handlers run on the posting thread, whichever it is
        self.assertNotIn("dispatch_get_main_queue", helper)   # nothing else is waiting to run on the main thread

    def test_an_interruption_cannot_mute_the_helper_for_good(self):
        helper = read("btpsaudiohelper/BTPSV88Stream.m")
        loop = helper.split("for(;;) {", 1)[1].split("[[NSNotificationCenter defaultCenter] removeObserver:observer];", 1)[0]
        generation = loop.split("if(current!=generation) {", 1)[1].split("\n            }\n", 1)[0]
        self.assertIn('if(interrupted) {hlog(stdout,"V894_INTERRUPTION_CLEARED by=new_stream\\n");interrupted=NO;}', generation)
        settings = loop.split("if(g_output_notify>=0 && notify_check(", 1)[1].split("\n            }\n", 1)[0]
        self.assertIn('interrupted=NO;', settings)
        self.assertIn("|| interrupted) continue;", loop)            # interruptions are still respected meanwhile
        self.assertIn('"V882_INTERRUPTION type=%s reason=%ld\\n"', loop)

    def test_health_reasons_reach_the_daemon_log(self):
        health = between(read("btpsaudiohelper/BTPSV88Stream.m"), "static void report_health(", "static int read_exact(")
        for bit, cause in (("0x1u", "generation&1u"), ("0x4u", "!running"), ("0x8u", "&o->stopping"),
                           ("0x10u", "&o->error"), ("0x20u", "route_verdict(")):
            line = next(l for l in health.splitlines() if "why|=" + bit in l)
            self.assertIn(cause, line)
        # Compiled: a negative result is "not playing" with reasons, 1 is playing.
        self.compile_run(r'''
#include <assert.h>
#include <stdarg.h>
#include "BTPSV88Daemon.c"
void BTPSLogNow(const char *fmt, ...) { (void)fmt; }
int BTPSDaemonConnectLoopback(uint16_t port) { (void)port; return -1; }
void btps_v88_init(BTPSV88Shared *s, uint32_t pid, uint64_t token) { (void)s; (void)pid; (void)token; }
int btps_v88_enqueue(BTPSV88Shared *s, const BTPSV88Packet *p) { (void)s; (void)p; return 0; }
void btps_v88_event(BTPSV88Shared *s, int h, BTPSV88Event e) { (void)s; (void)h; (void)e; }
static BTPSV88Shared shared;
static BTPSV88Event queued[4]; static unsigned nq, iq;
int btps_v88_pop(BTPSV88Queue *q, void *slots, size_t stride, unsigned n, void *v, size_t bytes) {
    (void)slots; (void)stride; (void)n;
    if (q == &shared.decode_log && iq < nq) { memcpy(v, &queued[iq++], bytes); return 1; }
    return 0;
}
int main(void) {
    BTPSV882Health health = {0};
    health.generation = 7;                                       /* an active stream generation */
    queued[nq++] = (BTPSV88Event){BTPS_V882_HEALTH, 7, 100, -0x20};
    drain_logs(&shared, &health, 1000);
    assert(health.playing == 0 && g_v894_health_why == 0x20u);
    queued[nq++] = (BTPSV88Event){BTPS_V882_HEALTH, 7, 101, 1};
    drain_logs(&shared, &health, 1100);
    assert(health.playing == 1 && g_v894_health_why == 0u);
    return 0;
}
''')
        daemon = read("BTPSV88Daemon.c")
        self.assertIn("why=0x%x", daemon)

    def test_settings_and_version(self):
        plist = plistlib.loads((ROOT / "speakaprefs/Resources/Root.plist").read_bytes())
        item = next(i for i in plist["items"] if i.get("key") == "SpeakaV89OutputMode")
        self.assertEqual(item["validValues"], ["speaker", "headphones", "any"])
        self.assertEqual(item["validTitles"][1], "Wired headphones or earbuds")
        self.assertEqual(item["shortTitles"][1], "Wired headphones")
        # v8.9.4 or any later build (v9.0 renamed everything to Speaka).
        for pattern, text in ((r'#define BTPS_V89_BUILD_TAG "v(\d+)\.(\d+)\.(\d+)-one-tap-output-select"', read("Tweak.xm")),
                              (r"V889_HELPER build=v(\d+)\.(\d+)\.(\d+)-output-select", read("btpsaudiohelper/BTPSV88Stream.m"))):
            version = re.search(pattern, text)
            self.assertIsNotNone(version, pattern)
            self.assertGreaterEqual(tuple(map(int, version.groups())), (8, 9, 4))


if __name__ == "__main__":
    unittest.main()
