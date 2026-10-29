"""Exercise freshness and connection scoping; verify exact native code gates."""
import hashlib
import os
import pathlib
import re
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


class V882IdleGuard(unittest.TestCase):
    def compile_run(self, source, cpp=False):
        compiler = shutil.which("c++" if cpp else "cc")
        self.assertIsNotNone(compiler)
        flags = ["-std=c++17" if cpp else "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-I" + str(ROOT)]
        env = dict(os.environ)
        if os.environ.get("BTPS_SANITIZE"):
            flags += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
            env.update(ASAN_OPTIONS="detect_leaks=0", UBSAN_OPTIONS="halt_on_error=1")
        with tempfile.TemporaryDirectory() as td:
            src = pathlib.Path(td) / ("guard.cpp" if cpp else "health.c")
            exe = pathlib.Path(td) / "test"
            src.write_text(source)
            built = subprocess.run([compiler, *flags, str(src), "-o", str(exe)], text=True, capture_output=True, timeout=30)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            ran = subprocess.run([str(exe)], text=True, capture_output=True, timeout=10, env=env)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)

    def test_health_requires_current_media_heartbeat_and_rendering(self):
        self.compile_run(r'''
#include <assert.h>
#include "BTPSV882Health.h"
int main(void) {
    BTPSV882Health h;
    btps_v882_health_reset(&h,3,100,1000);
    assert(!btps_v882_health_ready(&h,1,100));
    btps_v882_health_sample(&h,101,1001,200);
    btps_v882_health_render(&h,3,5,1,200);
    assert(btps_v882_health_ready(&h,1,200));
    assert(!btps_v882_health_ready(&h,0,200));
    assert(!btps_v882_health_ready(&h,1,199));
    /* Repeated reports with a stalled callback are not playback progress. */
    btps_v882_health_sample(&h,102,1002,1701);
    btps_v882_health_render(&h,3,5,1,1701);
    assert(!btps_v882_health_ready(&h,1,1701));
    btps_v882_health_render(&h,3,6,1,1701);
    assert(btps_v882_health_ready(&h,1,1701));
    /* Stale heartbeat, then stale incoming media, both release the guard. */
    btps_v882_health_sample(&h,103,1002,2702);
    btps_v882_health_render(&h,3,7,1,2702);
    assert(!btps_v882_health_ready(&h,1,2702));
    btps_v882_health_sample(&h,103,1003,4203);
    btps_v882_health_render(&h,3,8,1,4203);
    assert(!btps_v882_health_ready(&h,1,4203));
    btps_v882_health_sample(&h,104,1004,4204);
    assert(btps_v882_health_ready(&h,1,4204));
    btps_v882_health_render(&h,3,8,0,4205);
    assert(!btps_v882_health_ready(&h,1,4205));
    /* STOP/new START must discard the old generation's health. */
    btps_v882_health_reset(&h,4,104,1004);
    btps_v882_health_render(&h,3,9,1,4206);
    assert(!btps_v882_health_ready(&h,1,4206));
    btps_v882_health_reset(&h,5,104,1004);
    btps_v882_health_sample(&h,105,1005,4300);
    btps_v882_health_render(&h,3,10,1,4300);
    assert(!btps_v882_health_ready(&h,1,4300));
    btps_v882_health_render(&h,5,UINT32_MAX,1,4300);
    assert(btps_v882_health_ready(&h,1,4300));
    btps_v882_health_render(&h,5,0,1,4400); /* enqueue counter wrap */
    assert(btps_v882_health_ready(&h,1,4400));
    return 0;
}
''')

    def test_actual_idle_wrapper_only_keeps_the_configured_healthy_sink(self):
        source = (ROOT / "Tweak.xm").read_text()
        wrapper = source.split("typedef void (*btps_v882_idle_fn)", 1)[1].split("static void btps_v882_install_idle_guard", 1)[0]
        self.compile_run(r'''
#include <stdint.h>
#include <assert.h>
static unsigned g_v88_ready=1,g_v82_armed=1,g_v82_sink_accepted=1,g_v88_sink_handle=1;
static uint64_t g_v882_sink_owner=0x1234;
static int healthy=1,health_checks=0,native_calls=0;
static uint64_t last_owner,last_key;
static int BTPSV882SinkHealthy(void) {health_checks++;return healthy;}
static void BTPSLogNow(const char *,...) {}
static void BTPSSetStatus(const char *,const char *,...) {}
static void native_idle(uint64_t owner,uint64_t key) {native_calls++;last_owner=owner;last_key=key;}
''' + "typedef void (*btps_v882_idle_fn)" + wrapper + r'''
int main() {
    g_v882_idle_orig=native_idle;
    btps_v882_idle_check(0x1234,1);assert(native_calls==0 && health_checks==1);
    btps_v882_idle_check(0x1234,2);assert(native_calls==1 && last_key==2 && health_checks==1);
    btps_v882_idle_check(0x5678,1);assert(native_calls==2 && last_owner==0x5678 && health_checks==1);
    healthy=0;btps_v882_idle_check(0x1234,1);assert(native_calls==3 && health_checks==2);
    healthy=1;g_v82_armed=0;btps_v882_idle_check(0x1234,1);assert(native_calls==4 && health_checks==2);
    g_v82_armed=1;g_v82_sink_accepted=0;btps_v882_idle_check(0x1234,1);assert(native_calls==5);
    g_v82_sink_accepted=1;g_v88_ready=0;btps_v882_idle_check(0x1234,1);assert(native_calls==6);
    g_v88_ready=1;g_v88_sink_handle=0;btps_v882_idle_check(0x1234,0);assert(native_calls==7);
    return 0;
}
''', cpp=True)

    def test_exact_binary_gates(self):
        path = os.environ.get("BTPS_BLUETOOTHD")
        if not path:
            self.skipTest("Set BTPS_BLUETOOTHD to the verified iOS 17.0 device binary")
        data = pathlib.Path(path).read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), "e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6")
        source = (ROOT / "Tweak.xm").read_text()
        block = source.split("BTPS_V882_IDLE_GATES[] = {", 1)[1].split("};", 1)[0]
        gates = re.findall(r"\{(0x[0-9a-f]+)u,\{([^}]+)\}\}", block)
        self.assertEqual(len(gates), 7)
        for offset, words in gates:
            expected = tuple(int(w.rstrip("u"), 16) for w in words.split(","))
            self.assertEqual(struct.unpack_from("<4I", data, int(offset, 16)), expected, offset)
        # Verify this is a full function, not the adjacent 8-byte predicate.
        self.assertIn("BTPS_V882_IDLE_CHECK 0x00376034ul", source)

    def test_daemon_lease_expires_and_stop_invalidates_it(self):
        # Include the complete daemon source to compile the production lease API
        # and STOP logic. Its worker is never launched in this test.
        self.compile_run(r'''
#include <assert.h>
#include "BTPSV88Daemon.c"
int BTPSDaemonConnectLoopback(uint16_t port) {(void)port;return -1;}
void BTPSLogNow(const char *fmt,...) {(void)fmt;}
void btps_v88_init(BTPSV88Shared *s,uint32_t pid,uint64_t token) {(void)s;(void)pid;(void)token;}
int btps_v88_enqueue(BTPSV88Shared *s,const BTPSV88Packet *p) {(void)s;(void)p;return 0;}
int btps_v88_pop(BTPSV88Queue *q,void *slots,size_t stride,unsigned n,void *v,size_t bytes) {
    (void)q;(void)slots;(void)stride;(void)n;(void)v;(void)bytes;return 0;
}
void btps_v88_event(BTPSV88Shared *s,int h,BTPSV88Event e) {(void)s;(void)h;(void)e;}
int main(void) {
    BTPSV88Shared shared={0};g_shared=&shared;
    shared.generation=3;g_health_generation=3;g_health_deadline_ms=monotonic_ms()+10000;
    assert(BTPSV882SinkHealthy());
    g_health_deadline_ms=monotonic_ms()-1;assert(!BTPSV882SinkHealthy());
    g_health_deadline_ms=monotonic_ms()+10000;
    BTPSV88SetActive(0);assert(!(shared.generation&1) && !g_health_deadline_ms);
    assert(!BTPSV882SinkHealthy());
    /* Even a late publication from the worker's previous iteration is invalid. */
    g_health_deadline_ms=monotonic_ms()+10000;assert(!BTPSV882SinkHealthy());
    BTPSV88SetActive(1);assert(!BTPSV882SinkHealthy());
    g_health_deadline_ms=monotonic_ms()+10000;assert(!BTPSV882SinkHealthy());
    g_health_generation=shared.generation;assert(BTPSV882SinkHealthy());
    g_shared=NULL;assert(!BTPSV882SinkHealthy());
    return 0;
}
''')

    def test_native_signaling_and_media_are_not_suppressed(self):
        source = (ROOT / "Tweak.xm").read_text()
        tx = source.split("static uint64_t btps_v82_transmit_signal(", 1)[1].split("static void btps_v82_install_tx", 1)[0]
        self.assertNotIn("BTPSV882SinkHealthy", tx)
        self.assertIn("g_v82_tx_orig(cid, packet, length", tx)
        helper = (ROOT / "btpsaudiohelper/BTPSV88Stream.m").read_text()
        self.assertIn("report_health(o,s,generation)", helper)
        self.assertIn("kAudioQueueProperty_IsRunning", helper.split("static void report_health(", 1)[1])
        daemon = (ROOT / "BTPSV88Daemon.c").read_text()
        forward = daemon.split("void BTPSV88Forward(", 1)[1].split("static void drain_logs", 1)[0]
        for term in ("clock_gettime", "monotonic_ms", "BTPSV882SinkHealthy", "pthread_", "BTPSLog"):
            self.assertNotIn(term, forward)


if __name__ == "__main__":
    unittest.main()
