"""Verify the receive decoder is integrated but not accidentally active in bluetoothd."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class IntegrationTests(unittest.TestCase):
    def test_build_includes_media_c(self):
        self.assertIn('BTPSMedia.c',(ROOT/'Makefile').read_text())
    def test_playback_adapter_calls_media_decoder(self):
        src=(ROOT/'SBCSink.mm').read_text()
        self.assertIn('int speaka_on_rtp_packet(', src)
        self.assertIn('btps_media_decode_rtp_sbc(packet, packet_len',src)
        self.assertIn('ring_write(g_decode_scratch',src)
        self.assertIn('BTPS_MEDIA_BACKPRESSURE',src)
        self.assertIn('All or nothing: never enqueue only part of an SBC packet',src)
    def test_live_media_receiver_remains_one_shot(self):
        tweak=(ROOT/'Tweak.xm').read_text()
        self.assertNotIn('hook_media_recv(',tweak)
        self.assertNotIn('speaka_on_rtp_packet(',tweak)
        self.assertIn('v8.8 OFF until both one-shot switches are armed',tweak)
    def test_sbc_header_includes_crc_byte(self):
        src=(ROOT/'sbc_decode.c').read_text()
        self.assertIn('int header_bytes = 4;',src)
        self.assertIn('bs_read(&bs, 32);',src)
if __name__=='__main__':unittest.main()
