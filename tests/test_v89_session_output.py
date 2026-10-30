"""v8.9: one-tap Start/Stop and audio output selection.

The pure-C parts (request validation, output-route policy, channel-scoped stream control) are compiled and run on
the host. The CoreFoundation and Objective-C glue cannot run here, so it is checked statically for the ordering and
fail-closed properties the design depends on. Behaviour on the phone still needs a device test.
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


def shared_define(name):
    match = re.search(r'#define\s+%s\s+"([^"]+)"' % name, read("BTPSShared.h"))
    assert match, name
    return match.group(1)


class V89(unittest.TestCase):
    def compile_run(self, source, cpp=False, extra=()):
        compiler = shutil.which("c++" if cpp else "cc")
        self.assertIsNotNone(compiler)
        flags = ["-std=c++17" if cpp else "-std=gnu11", "-O2", "-Wall", "-Wextra", "-Werror",
                 "-I" + str(ROOT), "-I" + str(ROOT / "btpsaudiohelper"), *extra]
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
            ran = subprocess.run([str(exe)], text=True, capture_output=True, timeout=20, env=env)
            self.assertEqual(ran.returncode, 0, ran.stdout + ran.stderr)

    # ---------------------------------------------------------------- session request (daemon side, pure C)
    def test_session_request_validation(self):
        self.compile_run(r'''
#include <assert.h>
#include "BTPSV89Session.h"
int main(void) {
    assert(btps_v89_parse_action("start") == BTPS_V89_ACTION_START);
    assert(btps_v89_parse_action("stop") == BTPS_V89_ACTION_STOP);
    assert(btps_v89_parse_action("START") == BTPS_V89_ACTION_NONE);
    assert(btps_v89_parse_action("restart") == BTPS_V89_ACTION_NONE);
    assert(btps_v89_parse_action("") == BTPS_V89_ACTION_NONE);
    assert(btps_v89_parse_action(NULL) == BTPS_V89_ACTION_NONE);
    assert(btps_v89_nonce_valid("2F1E6A0C-9B1D-4C55-8A7E-0D3B5C6F7A81"));    /* NSUUID string from Settings */
    assert(btps_v89_nonce_valid("deadbeef"));
    assert(!btps_v89_nonce_valid("deadbee"));
    assert(!btps_v89_nonce_valid("0123456789abcdef0123456789abcdef012345678"));
    assert(!btps_v89_nonce_valid("2F1E6A0C 9B1D"));
    assert(!btps_v89_nonce_valid("nonce=1234;x"));
    assert(!btps_v89_nonce_valid(NULL));
    assert(btps_v89_request_fresh(1000.0, 1000.0));
    assert(btps_v89_request_fresh(1000.0, 1030.0));
    assert(!btps_v89_request_fresh(1000.0, 1030.5));
    assert(btps_v89_request_fresh(1004.0, 1000.0));
    assert(!btps_v89_request_fresh(1006.0, 1000.0));
    assert(!btps_v89_request_fresh(0.0, 10.0));
    assert(!btps_v89_request_fresh(-5.0, 10.0));
    return 0;
}
''')

    def test_session_entry_points_link_from_cpp(self):
        cc = shutil.which("cc")
        cxx = shutil.which("c++")
        self.assertTrue(cc and cxx)
        with tempfile.TemporaryDirectory() as td:
            td = pathlib.Path(td)
            (td / "provider.c").write_text('#include "BTPSV89Session.h"\n'
                                           'void BTPSV89SessionStart(void) {}\n'
                                           'void BTPSV89SessionReport(int a, int b) {(void)a;(void)b;}\n')
            (td / "consumer.cpp").write_text('#include "BTPSV89Session.h"\n'
                                             'int main() { BTPSV89SessionStart(); BTPSV89SessionReport(1, 0); return 0; }\n')
            subprocess.run([cc, "-std=c11", "-Wall", "-Werror", "-I", str(ROOT), "-c", str(td / "provider.c"),
                            "-o", str(td / "provider.o")], check=True)
            subprocess.run([cxx, "-std=c++17", "-Wall", "-Werror", "-I", str(ROOT), str(td / "consumer.cpp"),
                            str(td / "provider.o"), "-o", str(td / "link")], check=True)
            subprocess.run([str(td / "link")], check=True)

    def test_daemon_consumes_validates_and_verifies_before_restarting(self):
        code = read("BTPSV89Session.c")
        body = code.split("*/", 1)[1]          # the header comment may mention what NOT to do
        for forbidden in ("system(", "popen(", "posix_spawn", "execv", "execl", "fork(", "launchctl", "MSHookFunction"):
            self.assertNotIn(forbidden, body)
        self.assertIn("notify_register_dispatch(BTPS_NOTIFY_V89_SESSION", body)
        self.assertIn("DISPATCH_QUEUE_SERIAL", body)
        take = body.split("static int v89_take_record(", 1)[1].split("static int v89_read_bool(", 1)[0]
        self.assertLess(take.index("CFPreferencesSetAppValue(key, NULL, V89_DOMAIN)"), take.index("return ok ? 1 : -2"))
        self.assertIn("return -1;", take)
        handle = body.split("static void v89_handle_request(void)", 1)[1].split("void BTPSV89SessionStart(void)", 1)[0]
        consume = handle.index("v89_take_record(CFSTR(BTPS_KEY_V89_REQUEST)")
        refuse = handle.index("if (why) {")
        write = handle.index("if (!v89_write_switches(")
        kill = handle.index("kill(getpid(), SIGKILL)")
        self.assertLess(consume, refuse)
        self.assertLess(refuse, write)
        self.assertLess(write, kill)
        self.assertIn("btps_v89_request_fresh(when, v89_now())", handle)
        self.assertIn("btps_v89_nonce_valid(nonce)", handle)
        switches = body.split("static int v89_write_switches(", 1)[1].split("static void v89_handle_request(", 1)[0]
        for key in ("BTPS_KEY_V81_SEVEN_ONCE", "BTPS_KEY_V82_DECISIVE_ONCE", "BTPS_KEY_EXPERIMENTS", "BTPS_KEY_V89_PENDING"):
            self.assertIn("CFSTR(%s)" % key, switches)
        self.assertIn("v89_read_bool(CFSTR(BTPS_KEY_V81_SEVEN_ONCE), &seven) || seven != start", switches)
        self.assertIn("v89_read_bool(CFSTR(BTPS_KEY_V82_DECISIVE_ONCE), &decisive) || decisive != start", switches)
        report = body.split("void BTPSV89SessionReport(", 1)[1]
        self.assertIn("v89_take_record(CFSTR(BTPS_KEY_V89_PENDING)", report)
        self.assertIn("nonce=%s pid=%d result=%s", report)

    def test_restart_is_self_sigkill_like_killall(self):
        # bluetoothd runs as mobile, so system-domain launchctl is unavailable to it; signalling itself needs no
        # privilege and launchd relaunches it exactly as after `killall -9 bluetoothd`.
        self.assertIn("The daemon runs as user `mobile`", read("BTPSShared.h"))
        body = read("BTPSV89Session.c").split("*/", 1)[1]
        self.assertEqual(body.count("kill(getpid(), SIGKILL)"), 1)
        self.assertIn("#include <signal.h>", body)
        handle = body.split("static void v89_handle_request(void)", 1)[1].split("void BTPSV89SessionStart(void)", 1)[0]
        self.assertLess(handle.index("g_v89_restarting = 1;"), handle.index("kill(getpid(), SIGKILL)"))
        self.assertLess(handle.index("BTPSLogNow("), handle.index("kill(getpid(), SIGKILL)"))  # breadcrumb hits disk first

    def test_daemon_wiring_and_key_literals(self):
        tweak = read("Tweak.xm")
        self.assertIn('#include "BTPSV89Session.h"', tweak)
        ctor = tweak.split("%ctor {", 1)[1]
        self.assertIn("BTPSLogInit();\n    BTPSV89SessionStart();", ctor)
        self.assertLess(ctor.index("BTPSV89SessionStart();"), ctor.index("find_main_image(&index, &mh)"))
        final = ctor.rindex("BTPSV89SessionReport(g_v82_armed, btps_v89_receive_ready());")
        self.assertLess(ctor.index("btps_v83_install_native_registration((uintptr_t)mh, uuid_ok);"), final)
        self.assertLess(ctor.index("BTPSDaemonProbeStartV75();"), final)
        early = ctor.split("if (!find_main_image(&index, &mh)) {", 1)[1].split("return;", 1)[0]
        self.assertIn("BTPSV89SessionReport(0, 0);", early)
        self.assertIn("BTPSV89Session.c", read("Makefile").split("Speaka_FILES", 1)[1].split("\n", 1)[0])
        # Settings, the tweak and the helper must agree on the literal the existing one-shot code consumes.
        self.assertEqual(shared_define("BTPS_KEY_V82_DECISIVE_ONCE"), "SpeakaV82DecisiveOnce")
        self.assertIn('CFSTR("SpeakaV82DecisiveOnce")', tweak)
        self.assertIn("CFSTR(BTPS_KEY_V81_SEVEN_ONCE)", tweak)

    # ---------------------------------------------------------------- channel-scoped stream control (tweak)
    def test_stream_control_ignores_other_devices_once_pc_channel_is_known(self):
        tweak = read("Tweak.xm")
        note = tweak.split("static void btps_v88_note_signal(", 1)[1].split("/* v8.8.2: the verified native idle check", 1)[0]
        self.assertLess(note.index("if (sink_cid && cid!=sink_cid) return;"), note.index("btps_v88_signal("))
        rx = tweak.split("static uint64_t btps_v82_receive_signal(", 1)[1].split("static void btps_v82_install_rx", 1)[0]
        self.assertIn("(control[1]&63u)==3u && (control[2]>>2)==7u", rx)
        self.assertLess(rx.index("__atomic_store_n(&g_v89_sink_sig_cid,cid,__ATOMIC_RELEASE)"),
                        rx.index("btps_v88_note_signal(0,cid,control,(size_t)length)"))
        self.compile_run(r'''
#include <assert.h>
#include <stdint.h>
#include <string.h>
#include <pthread.h>
#include "BTPSV88Control.c"
static unsigned g_v88_ready=1,g_v82_sink_accepted=1;
static volatile uint64_t g_v89_sink_sig_cid=0;
static BTPSV88Control g_v88_control;
static pthread_mutex_t g_v88_control_lock=PTHREAD_MUTEX_INITIALIZER;
static int last_active=-9,changes=0;
static void BTPSV88SetActive(int active) {last_active=active;changes++;}
static void BTPSLogNow(const char *,...) {}
static void btps_v88_note_signal(''' + note + r'''
int main() {
    memset(&g_v88_control,0,sizeof g_v88_control);
    g_v88_control.local_seid=7;g_v88_control.remote_seid=52;
    /* PC on CID 0x108; earbuds on CID 0x140 whose endpoint happens to also be SEID 52. */
    const uint8_t start_pc[3]={0x30,0x07,0x1c},accept_start_pc[2]={0x32,0x07};
    btps_v88_note_signal(0,0x108,start_pc,3);assert(changes==0);
    btps_v88_note_signal(1,0x108,accept_start_pc,2);assert(changes==1 && last_active==1);
    /* Channel not yet known (old behaviour): an earbud SUSPEND with a colliding SEID would stop forwarding. */
    const uint8_t suspend_buds[3]={0x50,0x09,0xd0};
    btps_v88_note_signal(1,0x140,suspend_buds,3);assert(changes==2 && last_active==0);
    /* Channel known: earbud traffic is ignored; the PC still starts and stops the stream. */
    g_v89_sink_sig_cid=0x108;changes=0;last_active=-9;
    btps_v88_note_signal(1,0x140,suspend_buds,3);assert(changes==0);
    const uint8_t start_buds[3]={0x60,0x07,0xd0},accept_buds[2]={0x62,0x07};
    btps_v88_note_signal(1,0x140,start_buds,3);btps_v88_note_signal(0,0x140,accept_buds,2);assert(changes==0);
    const uint8_t start_pc2[3]={0x40,0x07,0x1c},accept_pc2[2]={0x42,0x07};
    btps_v88_note_signal(0,0x108,start_pc2,3);btps_v88_note_signal(1,0x108,accept_pc2,2);
    assert(changes==1 && last_active==1);
    const uint8_t suspend_pc[3]={0x70,0x09,0x1c};
    btps_v88_note_signal(0,0x108,suspend_pc,3);assert(changes==2 && last_active==0);
    g_v82_sink_accepted=0;changes=0;
    btps_v88_note_signal(0,0x108,suspend_pc,3);assert(changes==0);
    return 0;
}
''', cpp=True)

    # ---------------------------------------------------------------- output policy (helper, pure C)
    def test_output_route_policy(self):
        self.compile_run(r'''
#include <assert.h>
#include <stdio.h>
#include "BTPSV89Output.h"
int main(void) {
    const btps_v89_port speaker[]={{BTPS_V89_PORT_SPEAKER,"Speaker","Speaker"}};
    const btps_v89_port receiver[]={{BTPS_V89_PORT_RECEIVER,"Built-In Receiver","Receiver"}};
    const btps_v89_port airpods[]={{BTPS_V89_PORT_HEADPHONES,"AA:BB:CC:DD:EE:01-tacl","AirPods Pro"}};
    const btps_v89_port wired[]={{BTPS_V89_PORT_HEADPHONES,"Wired Headphones","Headphones"}};
    const btps_v89_port pc[]={{BTPS_V89_PORT_HEADPHONES,"11:22:33:44:55:66-tacl","LAPTOP-UGIVBIA5"}};
    const btps_v89_port airplay[]={{BTPS_V89_PORT_OTHER,"airplay-1","Living Room"}};
    const btps_v89_port mixed[]={{BTPS_V89_PORT_HEADPHONES,"h","Headphones"},{BTPS_V89_PORT_OTHER,"hdmi","HDMI"}};
    const btps_v89_port speaker_plus[]={{BTPS_V89_PORT_SPEAKER,"Speaker","Speaker"},{BTPS_V89_PORT_OTHER,"a","TV"}};
    const btps_v89_port unnamed[]={{BTPS_V89_PORT_HEADPHONES,"",""}};
    const btps_v89_never never_uid[]={{"11:22:33:44:55:66-TACL",""}};
    const btps_v89_never never_name[]={{"","laptop-ugivbia5"}};
    const btps_v89_never never_builtin[]={{"Speaker","Speaker"},{"Built-In Receiver","Receiver"}};
    const btps_v89_never blank[]={{"",""}},nulls[]={{NULL,NULL}};
    size_t bad=99;

    assert(btps_v89_mode_from_string("speaker")==BTPS_V89_MODE_SPEAKER);
    assert(btps_v89_mode_from_string("headphones")==BTPS_V89_MODE_HEADPHONES);
    assert(btps_v89_mode_from_string("any")==BTPS_V89_MODE_ANY);
    assert(btps_v89_mode_from_string(NULL)==BTPS_V89_MODE_SPEAKER);
    assert(btps_v89_mode_from_string("Headphones")==BTPS_V89_MODE_SPEAKER);
    assert(btps_v89_mode_from_string("bogus")==BTPS_V89_MODE_SPEAKER);
    for(int m=0;m<3;m++) assert(btps_v89_mode_from_string(btps_v89_mode_name(m))==m);

    /* speaker: exactly the built-in speaker, as in v8.8.1 */
    assert(btps_v89_route_check(BTPS_V89_MODE_SPEAKER,speaker,1,NULL,0,&bad)==BTPS_V89_ROUTE_OK);
    assert(btps_v89_route_check(BTPS_V89_MODE_SPEAKER,speaker,1,never_builtin,2,&bad)==BTPS_V89_ROUTE_OK);
    assert(btps_v89_route_check(BTPS_V89_MODE_SPEAKER,airpods,1,NULL,0,&bad)==BTPS_V89_ROUTE_NOT_SPEAKER);
    assert(btps_v89_route_check(BTPS_V89_MODE_SPEAKER,receiver,1,NULL,0,&bad)==BTPS_V89_ROUTE_NOT_SPEAKER);
    assert(btps_v89_route_check(BTPS_V89_MODE_SPEAKER,speaker_plus,2,NULL,0,&bad)==BTPS_V89_ROUTE_NOT_SPEAKER);
    assert(btps_v89_route_check(BTPS_V89_MODE_SPEAKER,speaker,0,NULL,0,&bad)==BTPS_V89_ROUTE_NO_OUTPUT);
    assert(btps_v89_route_check(BTPS_V89_MODE_SPEAKER,NULL,1,NULL,0,&bad)==BTPS_V89_ROUTE_NO_OUTPUT);
    assert(btps_v89_route_check(7,airpods,1,NULL,0,&bad)==BTPS_V89_ROUTE_NOT_SPEAKER); /* unknown mode */

    /* headphones: wired or Bluetooth only; waits on the speaker; refuses the never-listed PC */
    assert(btps_v89_route_check(BTPS_V89_MODE_HEADPHONES,airpods,1,never_uid,1,&bad)==BTPS_V89_ROUTE_OK);
    assert(btps_v89_route_check(BTPS_V89_MODE_HEADPHONES,wired,1,NULL,0,&bad)==BTPS_V89_ROUTE_OK);
    assert(btps_v89_route_check(BTPS_V89_MODE_HEADPHONES,speaker,1,NULL,0,&bad)==BTPS_V89_ROUTE_NOT_HEADPHONES);
    assert(btps_v89_route_check(BTPS_V89_MODE_HEADPHONES,receiver,1,NULL,0,&bad)==BTPS_V89_ROUTE_NOT_HEADPHONES);
    assert(btps_v89_route_check(BTPS_V89_MODE_HEADPHONES,airplay,1,NULL,0,&bad)==BTPS_V89_ROUTE_NOT_HEADPHONES);
    bad=99;assert(btps_v89_route_check(BTPS_V89_MODE_HEADPHONES,mixed,2,NULL,0,&bad)==BTPS_V89_ROUTE_NOT_HEADPHONES && bad==1);
    assert(btps_v89_route_check(BTPS_V89_MODE_HEADPHONES,pc,1,NULL,0,&bad)==BTPS_V89_ROUTE_OK); /* not marked yet */
    assert(btps_v89_route_check(BTPS_V89_MODE_HEADPHONES,pc,1,never_uid,1,&bad)==BTPS_V89_ROUTE_NEVER_LISTED);
    assert(btps_v89_route_check(BTPS_V89_MODE_HEADPHONES,pc,1,never_name,1,&bad)==BTPS_V89_ROUTE_NEVER_LISTED);

    /* any: everything except the never-play list; the iPhone's own outputs can never be excluded */
    assert(btps_v89_route_check(BTPS_V89_MODE_ANY,speaker,1,never_builtin,2,&bad)==BTPS_V89_ROUTE_OK);
    assert(btps_v89_route_check(BTPS_V89_MODE_ANY,receiver,1,never_builtin,2,&bad)==BTPS_V89_ROUTE_OK);
    assert(btps_v89_route_check(BTPS_V89_MODE_ANY,airplay,1,never_uid,1,&bad)==BTPS_V89_ROUTE_OK);
    assert(btps_v89_route_check(BTPS_V89_MODE_ANY,mixed,2,NULL,0,&bad)==BTPS_V89_ROUTE_OK);
    bad=99;assert(btps_v89_route_check(BTPS_V89_MODE_ANY,pc,1,never_name,1,&bad)==BTPS_V89_ROUTE_NEVER_LISTED && bad==0);
    assert(btps_v89_route_check(BTPS_V89_MODE_ANY,unnamed,1,blank,1,&bad)==BTPS_V89_ROUTE_OK);  /* blanks never match */
    assert(btps_v89_route_check(BTPS_V89_MODE_ANY,airpods,1,nulls,1,&bad)==BTPS_V89_ROUTE_OK);
    for(int r=0;r<=4;r++) assert(btps_v89_route_reason(r)[0]);
    puts("v8.9 output policy passed");
    return 0;
}
''')

    def test_helper_output_wiring(self):
        helper = read("btpsaudiohelper/BTPSV88Stream.m")
        external = helper.split("static int configure_external(", 1)[1].split("static int builtin_only(", 1)[0]
        self.assertIn("AVAudioSessionCategoryPlayback", external)
        self.assertNotIn("PlayAndRecord", external)
        self.assertLess(external.index("route_verdict(session,&device)"), external.index("setActive:YES"))
        self.assertIn("return -2;", external)
        kinds = helper.split("static btps_v89_kind port_kind(", 1)[1].split("static NSString *text_field(", 1)[0]
        for port in ("BuiltInSpeaker", "BuiltInReceiver", "Headphones", "USBAudio", "BluetoothA2DP",
                     "BluetoothLE", "BluetoothHFP"):
            self.assertIn("AVAudioSessionPort" + port, kinds)
        load = helper.split("static void load_output_settings(void)", 1)[1].split("static int route_verdict(", 1)[0]
        self.assertIn("CFSTR(BTPS_KEY_V89_OUTPUT_MODE)", load)
        self.assertIn("CFSTR(BTPS_KEY_V89_NEVER)", load)
        self.assertIn("notify_register_check(BTPS_NOTIFY_V89_OUTPUT,&g_output_notify)", helper)
        self.assertIn("notify_check(g_output_notify,&settings_changed)", helper)
        status = helper.split("static void publish_status(NSString *state,NSString *reason,BOOL force) {", 1)[1]
        status = status.split("static void log_route(", 1)[0]
        self.assertLess(status.index("dispatch_async(g_status_queue"), status.index("CFSTR(BTPS_KEY_V89_HELPER)"))
        health = helper.split("static void report_health(", 1)[1].split("static int read_exact(", 1)[0]
        # v8.9.4: an unacceptable route is reported as reason bit 0x20 (any reason means "not playing").
        self.assertIn("if(route_verdict([AVAudioSession sharedInstance],NULL)) why|=0x20u;", health)
        self.assertIn("why?-(int32_t)why:1", health)
        # The render callback and level meter that test_v881 compiles must not depend on the new code.
        render = helper.split("#define PCM_CAPACITY", 1)[1].split("static void stop_output", 1)[0]
        for term in ("route_verdict", "publish_status", "g_output_mode", "NSString"):
            self.assertNotIn(term, render)
        policy = read("btpsaudiohelper/BTPSV89Output.h")
        for mode in ("speaker", "headphones", "any"):
            self.assertIn('"%s"' % mode, policy)

    # ---------------------------------------------------------------- Settings page
    def test_settings_page_wiring(self):
        plist = plistlib.loads((ROOT / "speakaprefs/Resources/Root.plist").read_bytes())
        items = plist["items"]
        controller = read("speakaprefs/BTPSRootListController.m")
        # Every selector the plist names must exist, or tapping the row crashes Settings.
        for item in items:
            for field in ("get", "action"):
                if field in item:
                    selector = item[field]
                    self.assertRegex(controller, r"- \((?:id|void)\)%s\(id\)specifier" % re.escape(selector), selector)
        actions = {item.get("action") for item in items}
        self.assertTrue({"startSink:", "stopSink:", "chooseOutput:", "neverPlayCurrent:", "clearNeverPlay:"} <= actions)
        ids = {item.get("id") for item in items}
        self.assertTrue({"session", "playing", "never"} <= ids)
        self.assertIn('@[ @"session", @"playing", @"never" ]', controller)
        lists = [item for item in items if item.get("cell") == "PSLinkListCell"]
        self.assertEqual(len(lists), 1)
        mode = lists[0]
        self.assertEqual(mode["key"], shared_define("BTPS_KEY_V89_OUTPUT_MODE"))
        self.assertEqual(mode["defaults"], "com.apple.bluetooth")
        self.assertEqual(mode["default"], "speaker")
        self.assertEqual(mode["validValues"], ["speaker", "headphones", "any"])
        self.assertEqual(len(mode["validTitles"]), 3)
        self.assertEqual(mode["PostNotification"], shared_define("BTPS_NOTIFY_V89_OUTPUT"))
        self.assertEqual(mode["detail"], "PSListItemsController")
        # The manual switches stay available as an alternative.
        keys = {item.get("key") for item in items}
        self.assertTrue({"SpeakaV81SevenOnce", "SpeakaV82DecisiveOnce"} <= keys)
        # Settings only writes the request; the tweak arms the switches after validating it.
        send = controller.split("- (void)sendSession:(NSString *)action", 1)[1].split("- (void)schedulePoll", 1)[0]
        self.assertLess(send.index("BTPSWritePref(@BTPS_KEY_V89_REQUEST, request)"),
                        send.index("notify_post(BTPS_NOTIFY_V89_SESSION)"))
        for key in ("BTPS_KEY_V81_SEVEN_ONCE", "BTPS_KEY_V82_DECISIVE_ONCE", "SpeakaV81SevenOnce",
                    "SpeakaV82DecisiveOnce"):
            self.assertNotIn(key, controller)
        self.assertIn('[@"nonce=" stringByAppendingString:self.pendingNonce]', controller)
        never = controller.split("- (void)neverPlayCurrent:(id)specifier", 1)[1].split("- (void)clearNeverPlay:", 1)[0]
        self.assertLess(never.index("BTPSWritePref(@BTPS_KEY_V89_NEVER, list)"), never.index("notify_post(BTPS_NOTIFY_V89_OUTPUT)"))
        self.assertIn("AVKit", read("speakaprefs/Makefile"))
        self.assertIn("- (void)reloadSpecifierID:(NSString *)specifierID;", read("speakaprefs/BTPSRootListController.h"))

    def test_settings_gates_start_on_daemon_version_and_never_advises_toggling(self):
        controller = read("speakaprefs/BTPSRootListController.m")
        # Start/Stop is only offered to a bluetoothd that actually contains the listener.
        confirm = controller.split("- (void)confirmSession:(NSString *)action", 1)[1].split("- (void)sendSession:", 1)[0]
        self.assertLess(confirm.index("daemonHasSessionListener"), confirm.index("presentViewController:alert"))
        gate = controller.split("- (BOOL)daemonHasSessionListener", 1)[1].split("- (void)confirmSession:", 1)[0]
        self.assertIn('@"diag.v89.build"', gate)
        self.assertIn('status[@"diag.v89.build"]', controller.split("static NSString *BTPSSessionSummary", 1)[1])
        summary = controller.split("static NSString *BTPSSessionSummary", 1)[1].split("\n}\n", 1)[0]
        self.assertLess(summary.index('hasPrefix:@"LOST"'), summary.index('hasPrefix:@"ARMED"'))
        # Turning Bluetooth off and on does not restart bluetoothd and drops a live Sink: never recommend it.
        for advice in ("turn Bluetooth off and on", "Turn Bluetooth off and on", "toggle Bluetooth", "Airplane Mode off/on",
                       "auto-restart unavailable"):
            self.assertNotIn(advice, controller)
        footer = [i for i in plistlib.loads((ROOT / "speakaprefs/Resources/Root.plist").read_bytes())["items"]
                  if i.get("label") == "Bluetooth speaker"][0]["footerText"]
        self.assertIn("tap Start", footer)
        self.assertIn("off and on", footer)

    def test_sink_loss_after_bluetooth_toggle_is_reported(self):
        tweak = read("Tweak.xm")
        hook = tweak.split("static uint64_t btps_v83_hook_native_registration(", 1)[1] \
            .split("static void btps_v83_install_native_registration(", 1)[0]
        self.compile_run(r'''
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint64_t (*btps_v83_source_reg_fn_t)(uint64_t);
static btps_v83_source_reg_fn_t g_v83_source_reg_orig;
static int g_v82_armed = 1;
static volatile unsigned g_native_source_success = 6, g_v83_audio_extended = 0, g_v82_sink_accepted = 0;
static volatile unsigned g_v892_native_loops = 0;
static pthread_mutex_t g_v88_control_lock = PTHREAD_MUTEX_INITIALIZER;
static int post_source_calls = 0, set_active_calls = 0, last_active = -9;
static char last_sep[200];
static void BTPSLogNow(const char *, ...) {}
static void BTPSSetStatus(const char *key, const char *fmt, ...) {
    if (!strcmp(key, "diag.v82.sep")) snprintf(last_sep, sizeof last_sep, "%s", fmt);
}
static void BTPSV88SetActive(int active) { set_active_calls++; last_active = active; }
static void btps_v83_attempt_post_source(uint64_t) {   /* first power-up installs the Sink, later ones cannot */
    post_source_calls++;
    if (post_source_calls == 1) { g_v83_audio_extended = 1; g_v82_sink_accepted = 1; }
}
static uint64_t native_loop(uint64_t) { return 0; }
static uint64_t btps_v83_hook_native_registration(''' + hook + r'''
int main() {
    g_v83_source_reg_orig = native_loop;
    btps_v83_hook_native_registration(0x1000);                 /* bluetoothd starts: Sink installed */
    assert(post_source_calls == 1 && g_v82_sink_accepted == 1 && set_active_calls == 0 && !last_sep[0]);
    btps_v83_hook_native_registration(0x2000);                 /* Bluetooth off/on inside the same process */
    assert(g_v82_sink_accepted == 0 && set_active_calls == 1 && last_active == 0);
    assert(strncmp(last_sep, "LOST", 4) == 0 && strstr(last_sep, "tap Start"));
    /* Not armed: nothing is reported or changed. */
    g_v82_armed = 0; last_sep[0] = 0; set_active_calls = 0;
    btps_v83_hook_native_registration(0x3000);
    assert(set_active_calls == 0 && !last_sep[0]);
    return 0;
}
''', cpp=True)

    def test_postinst_restarts_bluetoothd_to_load_the_new_tweak(self):
        post = read("layout/DEBIAN/postinst")
        restart = [line for line in post.splitlines() if "killall -9 bluetoothd" in line]
        self.assertEqual(len(restart), 1)
        self.assertTrue(restart[0].rstrip().endswith("|| true"), restart[0])   # can never fail the install
        self.assertLess(post.index("launchctl bootstrap system"), post.index("killall -9 bluetoothd"))
        self.assertLess(post.index("killall -9 bluetoothd"), post.index("\nfi\nexit 0"))  # inside the configure branch
        subprocess.run(["sh", "-n", str(ROOT / "layout/DEBIAN/postinst")], check=True)


if __name__ == "__main__":
    unittest.main()
