"""Static regression assertions for the production daemon hook source."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
SOURCE=(ROOT/'Tweak.xm').read_text(encoding='utf-8')

class SourceSafetyTests(unittest.TestCase):
    def test_v6_tag(self):
        self.assertIn('#define BTPS_BUILD_TAG "v6-detailed-observe"', SOURCE)
    def test_original_registration_called_once(self):
        hook=SOURCE.split('static uint64_t hook_register(',1)[1].split('/* ------------------------------------------------------------------------------------------------ installing */',1)[0]
        self.assertEqual(hook.count('g_orig[BTPS_H_REGISTER]('),1)
        self.assertNotIn('BTPS_AVDTP_TSEP_SNK',hook)
        self.assertIn('sizeof seid_before',hook)
    def test_codec_uses_observed_byte_two(self):
        self.assertIn('uint8_t codec_type;', (ROOT/'BTPSDiagnostics.h').read_text())
        self.assertIn('out->codec_type = buffer[off + 2]', (ROOT/'BTPSDiagnostics.c').read_text())
    def test_no_unverified_sdp_api_calls(self):
        self.assertNotIn('OI_SDPDB_AddServiceRecord(',SOURCE)
        self.assertIn('diag.sdp_sink_0x110b',SOURCE)
    def test_heartbeat_passive_and_scheduled(self):
        log=(ROOT/'BTPSLog.c').read_text()
        self.assertIn('HEARTBEAT bluetoothd',log)
        self.assertIn('60LL * NSEC_PER_SEC',log)
        self.assertIn('static void heartbeat_cb',log)
    def test_makefile_includes_diagnostics(self):
        self.assertIn('BTPSDiagnostics.c',(ROOT/'Makefile').read_text())

if __name__=='__main__': unittest.main()
