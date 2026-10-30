"""v8.9.3 diagnostics: a log export must cover the whole session and say where the audio went.

The 21:06 export covered only the last 7.5 s of a 3-minute session because 94% of its 480 lines were
per-packet success lines, and it could not show which output device the helper used.
"""
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


class V893Diagnostics(unittest.TestCase):
    def compile_run(self, source):
        compiler = shutil.which("cc")
        self.assertIsNotNone(compiler)
        flags = ["-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror", "-I" + str(ROOT)]
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

    def test_daemon_summarizes_packets_and_keeps_errors_visible(self):
        # Compiles the real daemon source with a fake event queue and a capturing logger.
        self.compile_run(r'''
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>
#include "BTPSV88Daemon.c"

static char lines[64][400];
static int nlines;
void BTPSLogNow(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    if (nlines < 64) vsnprintf(lines[nlines++], sizeof lines[0], fmt, ap);
    va_end(ap);
}
int BTPSDaemonConnectLoopback(uint16_t port) { (void)port; return -1; }
void btps_v88_init(BTPSV88Shared *s, uint32_t pid, uint64_t token) { (void)s; (void)pid; (void)token; }
int btps_v88_enqueue(BTPSV88Shared *s, const BTPSV88Packet *p) { (void)s; (void)p; return 0; }
void btps_v88_event(BTPSV88Shared *s, int h, BTPSV88Event e) { (void)s; (void)h; (void)e; }

static BTPSV88Shared shared;
static BTPSV88Event fwd[200], dec[200];
static unsigned nfwd, ndec, ifwd, idec;
int btps_v88_pop(BTPSV88Queue *q, void *slots, size_t stride, unsigned n, void *v, size_t bytes) {
    (void)slots; (void)stride; (void)n;
    if (q == &shared.forward_log && ifwd < nfwd) { memcpy(v, &fwd[ifwd++], bytes); return 1; }
    if (q == &shared.decode_log && idec < ndec) { memcpy(v, &dec[idec++], bytes); return 1; }
    return 0;
}
static int count(const char *needle) {
    int c = 0;
    for (int i = 0; i < nlines; i++) if (strstr(lines[i], needle)) c++;
    return c;
}
static const char *find(const char *needle) {
    for (int i = 0; i < nlines; i++) if (strstr(lines[i], needle)) return lines[i];
    return "";
}

int main(void) {
    BTPSV882Health health = {0};
    for (int i = 0; i < 100; i++) fwd[nfwd++] = (BTPSV88Event){BTPS_V88_FORWARD, 953, 1, 0};
    for (int i = 0; i < 5; i++)   fwd[nfwd++] = (BTPSV88Event){BTPS_V88_FORWARD, 953, 1, -1};   /* after SUSPEND */
    for (int i = 0; i < 12; i++)  fwd[nfwd++] = (BTPSV88Event){BTPS_V88_FORWARD, 4000, 1, -5};  /* abnormal */
    for (int i = 0; i < 100; i++) dec[ndec++] = (BTPSV88Event){BTPS_V88_DECODE, 953, 8, 0};
    dec[ndec++] = (BTPSV88Event){BTPS_V88_DECODE, 500, 0, 1};       /* fragment pending: normal */
    dec[ndec++] = (BTPSV88Event){BTPS_V88_DECODE, 953, 0, -3};      /* malformed: abnormal */
    dec[ndec++] = (BTPSV88Event){BTPS_V881_PCM, 9730, 92416, 92266};
    dec[ndec++] = (BTPSV88Event){BTPS_V881_RENDER, 8320, 48512, 111};

    v893_flush_tally(1000, 0);                  /* opens the window */
    drain_logs(&shared, &health, 1000);
    v893_flush_tally(1500, 0);
    assert(count("V893_RX") == 0);              /* still inside the window */
    v893_flush_tally(3000, 0);
    assert(count("V893_RX") == 1);
    assert(count("result=0") == 0);             /* no per-packet success lines */
    assert(count("V88_FORWARD") + count("V88_DECODE") == 8);   /* abnormal ones, capped per window */
    assert(strstr(find("V893_RX"), "forwarded=117 ok=100 inactive=5 other=12"));
    assert(strstr(find("V893_RX"), "decoded=102 ok=100 partial=1 bad=1 frames=800"));
    assert(strstr(find("V893_RX"), "held_back=5"));             /* 13 abnormal, 8 shown */
    assert(count("V881_PCM samples=92416 nonzero=92266 peak=9730 | RENDER callbacks=111 pcm_frames=48512 "
                 "silence_frames=8320") == 1);

    nlines = 0;
    v893_flush_tally(6000, 0);
    assert(nlines == 0);                        /* an empty window writes nothing */
    fwd[nfwd++] = (BTPSV88Event){BTPS_V88_FORWARD, 953, 1, 0};
    drain_logs(&shared, &health, 6100);
    v893_flush_tally(6200, 1);                  /* forced, e.g. right before a stream state change */
    assert(count("V893_RX") == 1 && strstr(find("V893_RX"), "forwarded=1 ok=1 "));
    return 0;
}
''')

    def test_worker_summarizes_before_logging_stream_changes(self):
        worker = read("BTPSV88Daemon.c").split("static void *worker(void *arg) {", 1)[1].split("int BTPSV88Prepare(void)", 1)[0]
        flush = worker.index("v893_flush_tally(now,generation!=last_generation);")
        self.assertLess(worker.index("drain_logs(s,&health,now);"), flush)
        self.assertLess(flush, worker.index('"V88_STREAM active=%u generation=%llu"'))
        drain = read("BTPSV88Daemon.c").split("static void drain_logs(", 1)[1].split("static int attach_helper(", 1)[0]
        self.assertNotIn('"V88_FORWARD bytes=%u handle=%u result=%d",e.bytes,e.frames,e.result);\n    }', drain)
        self.assertIn("if(v893_detail_allowed()) BTPSLogNow(\"V88_FORWARD", drain)
        self.assertIn("if(v893_detail_allowed()) BTPSLogNow(\"V88_DECODE", drain)

    def test_settings_export_includes_helper_status_and_log(self):
        launchd = plistlib.loads((ROOT / "layout/Library/LaunchDaemons/com.parv.btphonosink.audio.plist").read_bytes())
        path = re.search(r'#define BTPS_HELPER_LOG_FILE\s+"([^"]+)"', read("BTPSShared.h")).group(1)
        self.assertEqual(path, launchd["StandardOutPath"])
        reader = read("btphonosinkprefs/BTPSLogReader.m")
        full = reader.split("- (NSString *)fullText", 1)[1]
        self.assertLess(full.index("[self appendHelperSection:out];"), full.index("== WHAT THIS SCREEN COULD READ =="))
        section = reader.split("- (void)appendHelperSection:(NSMutableString *)out", 1)[1].split("- (NSString *)fullText", 1)[0]
        for needle in ("CFSTR(BTPS_KEY_V89_HELPER)", "CFSTR(BTPS_KEY_V89_OUTPUT_MODE)", "CFSTR(BTPS_KEY_V89_NEVER)",
                       "ReadFileTail(@BTPS_HELPER_LOG_FILE", '@"V881_PCM"', 'h[@"volume"]'):
            self.assertIn(needle, section)
        tail = reader.split("static NSArray<NSString *> *ReadFileTail(", 1)[1].split("static NSString *HelperText(", 1)[0]
        self.assertIn("fseeko(f, start, SEEK_SET)", tail)          # reads the end, never the whole growing file
        self.assertIn("removeObjectAtIndex:0", tail)               # drops the partial first line

    def test_helper_lines_are_timestamped(self):
        helper = read("btpsaudiohelper/BTPSV88Stream.m")
        self.assertNotIn("fprintf(stdout,", helper)
        self.assertNotIn("fprintf(stderr,", helper)
        self.assertLess(helper.index("static void hlog(FILE *stream,const char *fmt,...) {"), helper.index("#define PCM_CAPACITY"))
        self.assertIn("__attribute__((format(printf,2,3)))", helper)
        self.assertIn("localtime_r(&secs,&tm)", helper)
        self.assertGreaterEqual(helper.count("hlog(stdout,") + helper.count("hlog(stderr,"), 13)
        self.assertIn('@"volume":@(session.outputVolume)', helper)

    def test_playing_on_shows_device_type_and_zero_volume(self):
        controller = read("btphonosinkprefs/BTPSRootListController.m")
        label = controller.split("static NSString *BTPSTypeLabel(", 1)[1].split("static NSString *BTPSOutputName(", 1)[0]
        self.assertIn("AVAudioSessionPortBluetoothA2DP", label)
        self.assertIn('return @"Bluetooth";', label)
        playing = controller.split("- (id)playingValue:(id)specifier", 1)[1].split("- (NSArray<NSDictionary *> *)neverList", 1)[0]
        self.assertIn('helper[@"volume"]', playing)
        self.assertIn('@" - volume 0%"', playing)


if __name__ == "__main__":
    unittest.main()
