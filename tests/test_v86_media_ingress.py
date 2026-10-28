"""v8.7 static invariants only: NOT evidence of on-device media reception."""
import unittest
from pathlib import Path
S=(Path(__file__).resolve().parents[1]/'Tweak.xm').read_text()
class V87MediaTest(unittest.TestCase):
    def test_build(self):
        self.assertIn('v8.7-raw-media-entry-counter', S)
    def test_exact_verified_media_offset(self):
        self.assertIn('#define BTPS_V87_MEDIA_HANDLER 0x000d8cf8ul', S)
        self.assertIn('0xd503237fu, 0xd10203ffu, 0xa90367fau, 0xa9045ff8u', S)
    def test_no_structure_or_packet_read_in_hook(self):
        block=S.split('static uint64_t btps_v87_receive_media(',1)[1].split('static void btps_v87_install_media(',1)[0]
        self.assertIn('__sync_add_and_fetch(&g_v87_media_calls, 1u)', block)
        self.assertIn('g_v87_media_recent[(calls - 1u) & 7u]', block)
        self.assertIn('__atomic_store_n(&record->cid, raw_cid', block)
        self.assertIn('__atomic_store_n(&record->bytes, raw_bytes', block)
        self.assertIn('V87_MEDIA_ENTER', block)
        self.assertIn('V87_MEDIA_RX', block)
        self.assertIn('g_v87_media_orig(cid, packet, length, a3, a4, a5, a6, a7)',block)
        for forbidden in ['btps_peek(', 'g_v86_cid_lookup(', 'entry +', 'packet +', 'memcpy(', 'MSHookFunction(', 'g_v86_sink_media_cid']:
            self.assertNotIn(forbidden, block)
    def test_no_helpers_or_patch_to_stub(self):
        block=S.split('/* v8.7: exact verified native L2CAP',1)[1].split('/* v8.3 one-shot:',1)[0]
        self.assertIn('MSHookFunction((void *)(base + BTPS_V87_MEDIA_HANDLER)',block)
        self.assertNotIn('BTPS_V86_CID_LOOKUP', block)
        self.assertNotIn('BTPS_V86_MEDIA_STUB', block)
        self.assertNotIn('BTPSAudioHelper',block)
    def test_sink_requires_observer(self):
        block=S.split('static void btps_v83_attempt_post_source(',1)[1].split('static uint64_t btps_v83_hook_native_registration(',1)[0]
        self.assertIn('!g_v87_media_hook_ok',block)
    def test_v85_sink_design_retained(self):
        for invariant in ['0x31u, 0x15u, 0x02u, 0xfau','V83 AUDIO_TABLE SWAPPED',
                          'V83 SEP RESULT', 'V83 SDP add ret=', 'V86 SINK_START_ACCEPT_QUEUED']:
            self.assertIn(invariant, S)
if __name__=='__main__': unittest.main()
