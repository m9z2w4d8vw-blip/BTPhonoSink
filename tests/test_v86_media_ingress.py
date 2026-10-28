"""v8.6 static source invariants, NOT live Bluetooth evidence."""
import unittest
from pathlib import Path
S=(Path(__file__).resolve().parents[1]/'Tweak.xm').read_text()
class V86MediaTest(unittest.TestCase):
    def test_build(self):
        self.assertIn('v8.6-live-media-cid-counter',S)
    def test_exact_verified_offsets(self):
        self.assertIn('0x000d8cf8ul',S)
        self.assertIn('0x000d917cul',S)
        self.assertIn('0x00385dfcul',S)
        self.assertIn('0xd503237fu, 0xd10203ffu, 0xa90367fau, 0xa9045ff8u',S)
        self.assertIn('0xb00044e8u, 0xf9445908u, 0xb4000248u, 0x39418509u',S)
    def test_only_observe_media_callback(self):
        block=S.split('/* v8.6 media handler:',1)[1].split('/* v8.3 one-shot:',1)[0]
        self.assertIn('MSHookFunction((void *)(base + BTPS_V86_MEDIA_HANDLER)',block)
        self.assertNotIn('MSHookFunction((void *)(base + BTPS_V86_MEDIA_STUB)',block)
        self.assertIn('btps_v86_receive_media',block)
        self.assertIn('g_v86_media_orig(cid, packet, length, a3, a4, a5, a6, a7)',block)
        self.assertNotIn('BTPSDaemonProbeSend',block)
        self.assertNotIn('BTPSAudioHelper',block)
    def test_count_derived_from_verified_media_path(self):
        block=S.split('static uint64_t btps_v86_receive_media(',1)[1].split('static void btps_v86_install_media(',1)[0]
        self.assertIn('btps_peek(entry + 0x80u, channel_fields',block)
        self.assertIn('channel_fields[4]',block)
        self.assertIn('channel_fields[6]',block)
        self.assertIn('channel_fields[8]',block)
        self.assertIn('payload_offset = 12u + (uint64_t)(first & 0x0fu)',block)
        self.assertIn('MEDIA_BYTES_RECEIVED=',block)
        self.assertIn('cid != g_v86_sink_sig_cid',block)
        self.assertIn('g_v86_sink_stream_started',block)
    def test_no_unobserved_sink_trial(self):
        block=S.split('static void btps_v83_attempt_post_source(',1)[1].split('static uint64_t btps_v83_hook_native_registration(',1)[0]
        self.assertIn('!g_v86_media_hook_ok',block)
        install=S.split('    install_hooks((uintptr_t)mh, uuid_ok);',1)[1]
        self.assertLess(install.index('btps_v86_install_media('),install.index('btps_v83_install_native_registration('))
    def test_v85_sbc_and_sdp_unchanged(self):
        self.assertIn('0x31u, 0x15u, 0x02u, 0xfau',S)
        self.assertIn('V83 SDP add ret=',S)
        self.assertIn('V83 SEP RESULT',S)
if __name__ == '__main__': unittest.main()
