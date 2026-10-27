"""Source invariants only. NOT live Bluetooth verification."""
import unittest
from pathlib import Path
S=(Path(__file__).resolve().parents[1]/'Tweak.xm').read_text()
class TestV83PostSource(unittest.TestCase):
    def test_only_after_original_native_loop(self):
        block=S.split('static uint64_t btps_v83_hook_native_registration(',1)[1].split('static void btps_v83_install_native_registration(',1)[0]
        self.assertLess(block.index('g_v83_source_reg_orig(audio_context)'),block.index('btps_v83_attempt_post_source(audio_context)'))
    def test_registration_not_reentrant_inside_sixth_source(self):
        block=S.split('if (sources == 6u)',1)[1].split('if (BTPSExperimentsEnabled()',1)[0]
        self.assertNotIn('btps_v83_attempt_post_source(',block)
        self.assertIn('btps_v79_snapshot_geometry();',block)
    def test_exact_hook_image(self):
        self.assertIn('0x003b4128ul',S)
        for x in ['0xd503237fu','0xd10103ffu','0xa90157f6u','0xa9024ff4u']:
            self.assertIn(x,S)
    def test_memory_and_gate(self):
        self.assertIn('calloc(7u, 32u)',S)
        self.assertIn('calloc(3u, 16u)',S)
        self.assertIn('memcpy((void *)(uintptr_t)(audio_context + 0x78u)',S)
        self.assertIn('audio_context + 0x68u',S)
        self.assertIn('audio_context + 0x6cu',S)
        self.assertIn('g_v83_leaked_original_table',S)
        self.assertIn('g_v82_signal_hook_ok',S)
        self.assertIn('g_v82_tx_hook_ok',S)
        self.assertIn('g_v82_sdp_hook_ok',S)
    def test_no_trick_acceptance(self):
        self.assertNotIn('SetConfig_accept_SBC returned 0',S)
        self.assertIn('V83 SEP RESULT',S)
        self.assertIn('V83 SDP add',S)
if __name__=='__main__': unittest.main()
