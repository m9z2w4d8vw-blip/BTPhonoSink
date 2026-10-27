"""v8.0 static safety gates and binary-signature provenance."""
from pathlib import Path
import plistlib
import unittest
import re

ROOT=Path(__file__).resolve().parents[1]
SRC=(ROOT/'Tweak.xm').read_text()

class V80ConfigGetterObserver(unittest.TestCase):
    def test_exact_binary_function_entry(self):
        self.assertIn('0x001f5f20u', SRC)
        self.assertIn('0xd503237fu, 0xa9be4ff4u, 0xa9017bfdu, 0x910043fdu',SRC)
        self.assertIn('BTPS_V80_GET_CONFIG_SIG',SRC)
        self.assertIn('memcmp(observed, BTPS_V80_GET_CONFIG_SIG, sizeof observed)', SRC)
        self.assertIn('!uuid_ok',SRC)
    def test_opt_in_default_off(self):
        prefs=plistlib.loads((ROOT/'btphonosinkprefs/Resources/Root.plist').read_bytes())
        spec=[e for e in prefs['items'] if e.get('key')=='BTPhonoSinkV80ConfigLookupObserver']
        self.assertEqual(len(spec),1)
        self.assertIs(spec[0]['default'],False)
        self.assertEqual(spec[0]['defaults'],'com.apple.bluetooth')
        self.assertIn('BTPS_KEY_V80_CFG_OBSERVER', (ROOT/'BTPSShared.h').read_text())
        self.assertIn('if (!btps_v80_requested())',SRC)
    def test_observer_does_not_change_input_output_or_register_sink(self):
        block=SRC.split('static uint64_t btps_v80_hook_get_config(',1)[1].split('static int btps_v80_requested(void)',1)[0]
        self.assertIn('g_v80_get_config_orig(a0,a1,a2,a3,a4,a5,a6,a7)',block)
        self.assertIn('return value;',block)
        self.assertNotRegex(block,r'\b(memcpy|memmove|memset|malloc|free|realloc|vm_write|vm_protect|AVDTP_RegisterMultipoint)\s*\(')
        self.assertNotIn('g_orig[BTPS_H_REGISTER](',block)
        self.assertNotIn('MSHookFunction',block)
    def test_installation_order_and_baseline_unchanged(self):
        ctor=SRC.split('%ctor {',1)[1]
        self.assertLess(ctor.index('install_hooks((uintptr_t)mh, uuid_ok)'),
                        ctor.index('btps_v80_install_config_observer((uintptr_t)mh, uuid_ok)'))
        self.assertEqual(SRC.count('hook_fn[BTPS_H_REGISTER]'),1)
        self.assertIn('ALL Sink registration experiments disabled',SRC)
        self.assertIn('btps_v79_snapshot_geometry();',SRC)
        self.assertIn('if (g_v80_enabled && g_v80_index3_calls == 0u)',SRC)
    def test_docs_disclose_limitations(self):
        d=(ROOT/'TESTING-v8.0.md').read_text()
        self.assertIn('No memory changes',d)
        self.assertIn('NO_INDEX3_CALL_OBSERVED',d)
        self.assertIn('Legacy Sink',d)

if __name__=='__main__':unittest.main()
