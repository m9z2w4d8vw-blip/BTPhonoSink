"""v9.1: the helper keeps its output through stream changes, so it can no longer feed the 23:33 route loop.

The 23:33 export (wired earbuds plugged in, "iPhone speaker" mode) and its screen recording: Control Center switched
between "Headphones" and the PC every 0.71 s for minutes and nothing played. All 25 STARTs and 25 SUSPENDs in the loop
were sent by the phone itself (Apple's A2DP code treats the PC as an output); each one followed the helper activating
or deactivating its audio session, and the helper did that because every START/SUSPEND changed the stream generation.
No AudioQueue lived longer than 30 ms. The policy lives in btpsaudiohelper/BTPSV91Hold.h; the helper uses it.
"""
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]


def read(rel):
    return (ROOT / rel).read_text(encoding="utf-8")


def between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class V91OutputHold(unittest.TestCase):
    def compile_run(self, source, cpp=False):
        compiler = shutil.which("c++" if cpp else "cc")
        self.assertIsNotNone(compiler)
        flags = ["-std=c++17" if cpp else "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-I" + str(ROOT), "-I" + str(ROOT / "btpsaudiohelper")]
        env = dict(os.environ)
        if os.environ.get("BTPS_SANITIZE"):
            flags += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
            env.update(ASAN_OPTIONS="detect_leaks=0", UBSAN_OPTIONS="halt_on_error=1")
        with tempfile.TemporaryDirectory() as td:
            src = pathlib.Path(td) / ("t.cpp" if cpp else "t.c")
            exe = pathlib.Path(td) / "t"
            src.write_text(source)
            built = subprocess.run([compiler, *flags, str(src), "-o", str(exe), "-pthread"],
                                   text=True, capture_output=True, timeout=60)
            self.assertEqual(built.returncode, 0, built.stdout + built.stderr)
            ran = subprocess.run([str(exe)], text=True, capture_output=True, timeout=30, env=env)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)
            return ran.stdout

    def test_policy(self):
        out = self.compile_run(r'''
#include <assert.h>
#include <stdio.h>
#include "BTPSV91Hold.h"
int main(void) {
    btps_v91_hold h = {0};
    assert(btps_v91_may_start(&h, 0, 1) == BTPS_V91_START_OK);
    assert(btps_v91_may_start(&h, 0, 0) == BTPS_V91_START_SILENT);    /* exact digital silence never activates */
    btps_v91_started(&h, 1000);
    assert(btps_v91_may_start(&h, 1000, 1) == BTPS_V91_START_RUNNING);

    /* The 23:33 churn: the phone STARTs, ~80 ms of media, the phone SUSPENDs, ~650 ms later it STARTs again.
     * Every change keeps the running output, and the hold never expires while it goes on. */
    uint64_t t = 1000;
    for (int cycle = 0; cycle < 100; cycle++) {
        assert(btps_v91_generation_changed(&h) == 1);
        t += 80; btps_v91_media(&h, t);
        assert(btps_v91_generation_changed(&h) == 1);
        t += 650; assert(!btps_v91_expired(&h, t));
    }

    /* The PC suspends for good (23:33:44): one release, exactly at the hold time. */
    uint64_t last = t; btps_v91_media(&h, last);
    assert(!btps_v91_expired(&h, last + BTPS_V91_HOLD_MS - 1));
    assert(btps_v91_expired(&h, last + BTPS_V91_HOLD_MS));
    uint64_t r = last + BTPS_V91_HOLD_MS;
    btps_v91_released(&h, r, BTPS_V91_RELEASE_AUTOMATIC);
    assert(!btps_v91_expired(&h, r + 10 * BTPS_V91_HOLD_MS));       /* nothing running, nothing to expire */
    assert(btps_v91_generation_changed(&h) == 0);
    btps_v91_media(&h, r + 5); assert(h.media_ms == last);           /* media is ignored while idle */

    /* Letting go on its own arms the rearm wait; silence still never starts. */
    assert(btps_v91_may_start(&h, r, 1) == BTPS_V91_START_REARM);
    assert(btps_v91_may_start(&h, r + BTPS_V91_REARM_MS - 1, 1) == BTPS_V91_START_REARM);
    assert(btps_v91_may_start(&h, r + BTPS_V91_REARM_MS, 1) == BTPS_V91_START_OK);
    assert(btps_v91_may_start(&h, r + BTPS_V91_REARM_MS, 0) == BTPS_V91_START_SILENT);

    /* A user action or a real device change skips the wait; a requested release never arms it. */
    btps_v91_released(&h, 50000, BTPS_V91_RELEASE_AUTOMATIC);
    btps_v91_rearm_now(&h); assert(btps_v91_may_start(&h, 50000, 1) == BTPS_V91_START_OK);
    btps_v91_released(&h, 60000, BTPS_V91_RELEASE_REQUESTED);
    assert(btps_v91_may_start(&h, 60000, 1) == BTPS_V91_START_OK);

    /* However fast something asks (here: every start is refused 200 ms later), automatic activations stay at least
     * BTPS_V91_REARM_MS apart. v9.0 activated every ~0.7 s. */
    btps_v91_hold f = {0}; unsigned starts = 0; uint64_t prev = 0;
    for (uint64_t now = 0; now < 60000; now += 5) {
        if (btps_v91_may_start(&f, now, 1) != BTPS_V91_START_OK) continue;
        assert(!starts || now - prev >= BTPS_V91_REARM_MS);
        prev = now; starts++;
        btps_v91_started(&f, now);
        btps_v91_released(&f, now + 200, BTPS_V91_RELEASE_AUTOMATIC);
    }
    assert(starts >= 2 && starts <= 60000 / BTPS_V91_REARM_MS + 1);

    assert(btps_v91_route_is_device_change(1) && btps_v91_route_is_device_change(2));
    for (long reason = 3; reason <= 8; reason++) assert(!btps_v91_route_is_device_change(reason));
    for (long reason = -1; reason <= 9; reason++) assert(btps_v91_route_reason_name(reason)[0]);
    for (int code = 0; code <= 4; code++) assert(btps_v91_start_reason(code)[0]);
    /* Windows reopened the stream 6.1 s after the phone suspended it (21:35 log, TESTING-v8.9.4). */
    assert(BTPS_V91_HOLD_MS >= 6100u && BTPS_V91_REARM_MS >= 1000u);
    printf("v9.1 policy passed (%u rearmed starts in 60 s)\n", starts);
    return 0;
}
''')
        self.assertIn("passed", out)

    def test_loop_model_v90_versus_v91(self):
        """A model, not iOS: the log fits two mechanisms, and the 23:33 log cannot tell them apart.

        H1: the helper's AudioQueue starting makes iOS START the PC's stream; deactivating its session makes iOS SUSPEND it.
        H2: activating the helper's session re-routes iOS away from the PC (SUSPEND); deactivating it routes iOS back
            to the PC (START).
        Timing is from the 23:33 log: configuring and starting took ~450 ms (active after ~250 ms), stopping ~170 ms.
        Windows, once the phone suspends a stream it is still playing, closes it after 3.7 s and reopens it 2.3 s later
        (TESTING-v8.9.4). Under both, the v9.0 rule loops and v9.1 settles: at once (H1) or after Windows reopens (H2).
        """
        out = self.compile_run(r'''
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "BTPSV91Hold.h"
enum { H1 = 1, H2 = 2 };
enum { PC_STREAMING, PC_SUSPENDED, PC_CLOSED };
typedef struct {
    int model, v91, pc, session, queue, retry;
    uint64_t t, gen, hgen, pc_since, start_at, sus_at, busy_until, act_at, deact_at, queue_at;
    uint64_t ring[32]; unsigned head, n;
    btps_v91_hold hold;
    unsigned activations; uint64_t playing_ms;
} W;
static void set_active(W *w, int active) { w->gen = ((w->gen & ~1ull) + 2u) | (active ? 1u : 0u); }
static void push(W *w) {
    if (w->n == 32) { w->head = (w->head + 1) % 32; w->n--; }
    w->ring[(w->head + w->n) % 32] = w->gen; w->n++;
}
static int pop(W *w, uint64_t *g) {
    if (!w->n) return 0;
    *g = w->ring[w->head]; w->head = (w->head + 1) % 32; w->n--; return 1;
}
static void suspend_by_phone(W *w) {
    if (w->pc != PC_STREAMING) return;
    w->pc = PC_SUSPENDED; w->pc_since = w->t; set_active(w, 0); set_active(w, 0);   /* TX command + RX accept */
}
static void start(W *w) { w->busy_until = w->t + 450; w->act_at = w->t + 250; w->queue_at = w->t + 450; }
static void full_stop(W *w) { w->queue = 0; w->busy_until = w->t + 170; w->deact_at = w->t + 150; }
static void edges(W *w) {
    if (w->act_at && w->t >= w->act_at) {
        w->act_at = 0; w->session = 1; w->activations++;
        if (w->model == H2) w->sus_at = w->t + 50;
    }
    if (w->queue_at && w->t >= w->queue_at) {
        w->queue_at = 0; w->queue = 1;
        if (w->model == H1) w->start_at = w->t + 130;
    }
    if (w->deact_at && w->t >= w->deact_at) {
        w->deact_at = 0; w->session = 0;
        if (w->model == H2) w->start_at = w->t + 110; else w->sus_at = w->t + 40;
    }
}
static void phone(W *w) {
    if (w->sus_at && w->t >= w->sus_at) { w->sus_at = 0; suspend_by_phone(w); }
    if (w->start_at && w->t >= w->start_at) {
        w->start_at = 0;
        if (w->pc == PC_SUSPENDED) { w->pc = PC_STREAMING; w->pc_since = w->t; set_active(w, 1); }
    }
}
static void pc(W *w) {
    if (w->pc == PC_SUSPENDED && w->t - w->pc_since >= 3700) { w->pc = PC_CLOSED; w->pc_since = w->t; set_active(w, 0); }
    if (w->pc == PC_CLOSED && w->t - w->pc_since >= 2300) {
        set_active(w, 0);                                              /* SET_CONFIGURATION again */
        w->pc = PC_STREAMING; w->pc_since = w->t; set_active(w, 1);    /* the PC's own START */
    }
    if (w->pc == PC_STREAMING && w->t % 23 == 0) push(w);              /* one SBC packet every ~23 ms */
}
static void helper(W *w) {
    if (w->t < w->busy_until || w->t % 5) return;                      /* 5 ms loop; blocked inside a call */
    uint64_t g = w->gen;
    if (g != w->hgen) {
        if (w->v91) (void)btps_v91_generation_changed(&w->hold);       /* v9.1: keep */
        else if (w->queue || w->session) { w->hgen = g; w->retry = 0; full_stop(w); return; }  /* v9.0 */
        w->hgen = g; w->retry = 0;
    }
    if (w->v91 && btps_v91_expired(&w->hold, w->t)) {
        full_stop(w); btps_v91_released(&w->hold, w->t, BTPS_V91_RELEASE_AUTOMATIC); return;
    }
    if (w->retry) w->retry--;
    uint64_t pg;
    while (pop(w, &pg)) {
        if (!(w->hgen & 1u) || pg != w->hgen) continue;
        if (w->gen != w->hgen) break;
        if (!w->queue && !w->retry &&
            (!w->v91 || btps_v91_may_start(&w->hold, w->t, 1) == BTPS_V91_START_OK)) {
            start(w);
            if (w->v91) btps_v91_started(&w->hold, w->t + 450);
            return;
        }
        if (w->v91 && w->queue) btps_v91_media(&w->hold, w->t);
    }
}
static void run(W *w, int model, int v91) {
    memset(w, 0, sizeof *w); w->model = model; w->v91 = v91;
    w->pc = PC_STREAMING; set_active(w, 1);                            /* t=0: the PC starts playing */
    for (w->t = 0; w->t < 60000; w->t++) {
        if (w->t == 300) suspend_by_phone(w);   /* the seed: one phone SUSPEND while the helper is still starting */
        edges(w); phone(w); pc(w); helper(w);
        if (w->queue && w->pc == PC_STREAMING && (w->gen & 1u) && w->hgen == w->gen) w->playing_ms++;
    }
}
int main(void) {
    W w;
    for (int model = H1; model <= H2; model++) {
        run(&w, model, 0);
        unsigned old_activations = w.activations; uint64_t old_playing = w.playing_ms;
        run(&w, model, 1);
        printf("H%d: v9.0 %u activations, %llu ms played | v9.1 %u activation(s), %llu ms played (of 60000)\n",
               model, old_activations, (unsigned long long)old_playing, w.activations, (unsigned long long)w.playing_ms);
        assert(old_activations >= 40 && old_playing < 6000);
        assert(w.activations <= 2);
        assert(w.playing_ms >= (model == H1 ? 57000u : 51000u));
    }
    return 0;
}
''')
        print(out, end="")

    def test_helper_wiring(self):
        helper = read("btpsaudiohelper/BTPSV88Stream.m")
        self.assertIn('#include "BTPSV91Hold.h"', helper)
        loop = between(helper, "for(;;) {", "[[NSNotificationCenter defaultCenter] removeObserver:observer];")
        generation = between(loop, "if(current!=generation) {", "\n            }\n")
        self.assertIn("if(btps_v91_generation_changed(&hold)) keep_output(o,current);", generation)
        self.assertNotIn("stop_output(", generation)          # v9.0 stopped here, which re-routed iOS
        self.assertNotIn("stream_generation_changed", helper)
        self.assertIn("if(btps_v91_expired(&hold,now)) {", loop)
        self.assertNotIn("idle==400", helper)
        packets = loop.split("for(unsigned i=0;i<BTPS_V88_SLOTS && btps_v88_dequeue(s,&packet);i++) {", 1)[1]
        self.assertIn("int audible=level.nonzero!=nonzero_before;", packets)
        cold = packets.split("if(!o->queue && !retry) {", 1)[1]
        self.assertLess(cold.index("btps_v91_may_start(&hold,helper_ms(),audible)"), cold.index("start_output(o,rate,s)"))
        self.assertIn('stop_output(o,s,"sample_rate_changed",0);', packets)   # a new rate keeps the session
        # Every release in the loop tells the policy, so the rearm wait cannot be skipped by accident.
        releases = list(re.finditer(r"stop_output\(o,s,[^;]*,1\);", loop))
        self.assertGreaterEqual(len(releases), 7)
        for match in releases:
            self.assertIn("btps_v91_released(", loop[match.end():match.end() + 260], match.group(0))
        # Route changes: speaker mode re-applies its override; the helper's own echo does not reset the backoff.
        self.assertIn("g_output_mode==BTPS_V89_MODE_SPEAKER && !reassert_speaker(o,o->rate,s)", loop)
        self.assertIn("} else if(device || !own) {", loop)
        reassert = between(helper, "static int reassert_speaker(", "typedef struct { uint32_t samples,nonzero,peak; } PCMLevels;")
        self.assertLess(reassert.index('stop_output(o,s,"route_changed_reassert",0);'),
                        reassert.index("overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker"))
        self.assertNotIn("setActive:", reassert)
        stop = between(helper, "static void stop_output(", "static int speaker_selected(")
        self.assertLess(stop.index("if(!release) return;"), stop.index("setActive:NO"))
        start = between(helper, "static int start_output(", "static int reassert_speaker(")
        self.assertIn("int configured=reuse?0:configure_output(rate,s);", start)
        # Each configure_* records its activation right after setActive:YES succeeds.
        self.assertEqual(helper.count("ok=[session setActive:YES error:&error];if(ok) note_session(1,"), 3)
        self.assertIn("AVAudioSessionMediaServicesWereResetNotification", helper)
        self.assertIn("removeObserver:reset_observer]", helper)
        self.assertTrue((ROOT / "docs/history/TESTING-v9.1.md").is_file())

    def test_control_log_names_the_initiator(self):
        tweak = read("Tweak.xm")
        note = between(tweak, "static void btps_v88_note_signal(", "/* v8.8.2: the verified native idle check")
        self.compile_run(r'''
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <stdarg.h>
#include <stdio.h>
#include <pthread.h>
#include "BTPSV88Control.c"
static unsigned g_v88_ready=1,g_v82_sink_accepted=1;
static volatile uint64_t g_v89_sink_sig_cid=0x108;
static BTPSV88Control g_v88_control;
static pthread_mutex_t g_v88_control_lock=PTHREAD_MUTEX_INITIALIZER;
static char line[256];
static void BTPSV88SetActive(int) {}
static void BTPSLogNow(const char *fmt,...) {va_list ap;va_start(ap,fmt);vsnprintf(line,sizeof line,fmt,ap);va_end(ap);}
static void btps_v88_note_signal(''' + note + r'''
static void expect(unsigned direction,const uint8_t *p,size_t n,const char *tail) {
    line[0]=0;btps_v88_note_signal(direction,0x108,p,n);
    assert(strstr(line,tail));
}
int main() {
    memset(&g_v88_control,0,sizeof g_v88_control);
    g_v88_control.local_seid=7;g_v88_control.remote_seid=52;
    /* Exact PDUs from the 23:33 log: the phone suspends (TX 80 09 d0, accepted RX 82 09) and starts (TX 90 07 d0,
     * accepted RX 92 07); at 23:33:44 the PC suspends (RX 60 09 1c, accepted TX 62 09). */
    const uint8_t phone_suspend[3]={0x80,0x09,0xd0},phone_suspend_ok[2]={0x82,0x09};
    const uint8_t phone_start[3]={0x90,0x07,0xd0},phone_start_ok[2]={0x92,0x07};
    const uint8_t pc_suspend[3]={0x60,0x09,0x1c},pc_suspend_ok[2]={0x62,0x09};
    const uint8_t pc_start[3]={0x30,0x07,0x1c},pc_start_ok[2]={0x32,0x07};
    expect(1,phone_suspend,3,"active=0 by=phone");
    expect(0,phone_suspend_ok,2,"active=0 by=phone");
    line[0]=0;btps_v88_note_signal(1,0x108,phone_start,3);assert(!line[0]);   /* a START command alone changes nothing */
    expect(0,phone_start_ok,2,"msg=2 sig=7 active=1 by=phone");
    expect(0,pc_suspend,3,"active=0 by=pc");
    expect(1,pc_suspend_ok,2,"active=0 by=pc");
    line[0]=0;btps_v88_note_signal(0,0x108,pc_start,3);assert(!line[0]);
    expect(1,pc_start_ok,2,"msg=2 sig=7 active=1 by=pc");
    return 0;
}
''', cpp=True)


if __name__ == "__main__":
    unittest.main()
