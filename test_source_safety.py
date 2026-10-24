"""Regression assertions on the actual source shipped in this repository."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
SOURCE=(ROOT/'Tweak.xm').read_text(encoding='utf-8')

class SourceSafetyTests(unittest.TestCase):
    def test_v5_tag(self):
        self.assertIn('#define BTPS_BUILD_TAG "v5-safe-observe"', SOURCE)
    def test_original_registration_called_once(self):
        hook=SOURCE.split('static uint64_t hook_register(',1)[1].split('/* ------------------------------------------------------------------------------------------------ installing */',1)[0]
        self.assertEqual(hook.count('g_orig[BTPS_H_REGISTER]('),1)
        self.assertNotIn('BTPS_AVDTP_TSEP_SNK',hook)
        self.assertIn('sizeof seid_before',hook)
    def test_codec_uses_observed_byte_four(self):
        self.assertIn('uint8_t codec = buf[s + 4]', SOURCE)
    def test_no_unverified_sdp_api_calls(self):
        self.assertNotIn('OI_SDPDB_AddServiceRecord(',SOURCE)
        self.assertIn('v5.sdp_sink_0x110b',SOURCE)

if __name__=='__main__': unittest.main()
