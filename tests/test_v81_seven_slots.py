"""Native validation and guardrails for v8.1 one-shot allocation-only trial."""
from pathlib import Path
import ctypes
import plistlib
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SRC = (ROOT/'Tweak.xm').read_text()

class TrialTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        lib = Path(cls.tmp.name)/'v81config.so'
        subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-shared','-fPIC',
                        str(ROOT/'BTPSV81Config.c'),'-o',str(lib)],check=True)
        cls.fn = ctypes.CDLL(str(lib)).btps_v81_prepare_shadow
        cls.fn.argtypes=[ctypes.POINTER(ctypes.c_uint8),ctypes.c_size_t,
                         ctypes.POINTER(ctypes.c_uint8),ctypes.c_int]
        cls.fn.restype=ctypes.c_int
    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()
    def call(self,header=(6,3,3),arm=1,length=32):
        buf=(ctypes.c_uint8*32)(*(list(header)+list(range(3,32))))
        out=(ctypes.c_uint8*32)()
        n=self.fn(buf,length,out,arm)
        return n, bytes(buf), bytes(out)
    def test_seven_only_changes_first_byte(self):
        rc,original,altered=self.call()
        self.assertEqual(rc,0)
        self.assertEqual(altered[:3],b'\x07\x03\x03')
        self.assertEqual(altered[3:],original[3:])
        self.assertEqual(original[:3],b'\x06\x03\x03')
    def test_six_clone_is_identical(self):
        rc,original,altered=self.call(arm=0)
        self.assertEqual(rc,0)
        self.assertEqual(altered,original)
    def test_reject_unexpected_config(self):
        for hdr in ((7,3,3),(6,4,3),(6,3,4),(0,3,3)):
            self.assertNotEqual(self.call(header=hdr)[0],0)
    def test_reject_invalid_size_or_mode(self):
        for mode,length in ((2,32),(-1,32),(1,3),(1,31)):
            self.assertNotEqual(self.call(arm=mode,length=length)[0],0)
    def test_default_off_and_registration_requires_separate_one_shot_arm(self):
        plist=plistlib.loads((ROOT/'btphonosinkprefs/Resources/Root.plist').read_bytes())
        switches=[x for x in plist['items'] if x.get('key')=='BTPhonoSinkV81SevenOnce']
        self.assertEqual(len(switches),1)
        self.assertIs(switches[0]['default'],False)
        self.assertEqual(switches[0]['defaults'],'com.apple.bluetooth')
        self.assertIn('decisive_requested && g_v81_seven_armed && !BTPSExperimentsEnabled()',SRC)
        self.assertIn('!g_v82_signal_hook_ok || !g_v82_sdp_hook_ok',SRC)
        self.assertIn('g_native_source_success != 6',SRC)
        self.assertNotIn('btps_v77_attempt_after_sources(',SRC)
        self.assertIn('g_orig[BTPS_H_REGISTER]',SRC)
    def test_one_shot_cleared_before_hook(self):
        disarm=SRC.index('btps_v81_consume_one_shot();')
        install=SRC.index('MSHookFunction((void *)target, (void *)btps_v80_hook_get_config')
        self.assertLess(disarm,install)
        block=SRC.split('static int btps_v81_consume_one_shot(void)',1)[1].split('static uint64_t btps_v81_try_seven(',1)[0]
        self.assertIn('CFPreferencesSetAppValue(',block)
        self.assertIn('kCFBooleanFalse',block)
        self.assertIn('CFPreferencesAppSynchronize(',block)
        self.assertIn('!synced || !disarmed',block)
    def test_signature_precheck_and_avoid_hook_collision(self):
        self.assertIn('g_v81_verified_initial_signature = btps_v79_signatures_match()',SRC)
        self.assertIn('if (s[i].offset == 0x1f5f20u && g_v80_enabled_for_v79_audit())',SRC)
        self.assertIn('if (!g_v81_verified_initial_signature) return 0;',SRC)
        self.assertIn('g_v81_verified_initial_signature && g_v78_exact_uuid',SRC)
        self.assertIn('table_original == original',SRC)
    def test_separate_static_shadow_not_live_mutation(self):
        self.assertIn('static uint8_t g_v81_shadow[BTPS_V81_CONFIG_COPY_BYTES]',SRC)
        self.assertIn('btps_v81_prepare_shadow(source, sizeof source, g_v81_shadow, 1)',SRC)
        self.assertIn('__sync_bool_compare_and_swap(&g_v81_seven_applied, 0u, 1u)',SRC)
        self.assertNotIn('vm_write(',SRC)
        self.assertNotIn('vm_protect(',SRC)
        self.assertIn('BTPSV81Config.c', (ROOT/'Makefile').read_text())
        self.assertIn('V81_LIVE RESULT',SRC)
        self.assertIn('g_v81_shadow_returned',SRC)
    def test_documents_disclose_no_sink_and_rollback(self):
        docs=(ROOT/'docs/history/TESTING-v8.1.md').read_text()
        for term in ('OFF','Legacy Sink','one-shot','v8.0','no Sink', 'slots=7'):
            self.assertIn(term,docs)
if __name__=='__main__': unittest.main()
