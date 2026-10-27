"""Static regression assertions for the production daemon hook source."""
from pathlib import Path
import unittest

ROOT=Path(__file__).resolve().parents[1]
SOURCE=(ROOT/'Tweak.xm').read_text(encoding='utf-8')

class SourceSafetyTests(unittest.TestCase):
    def test_v7_tag(self):
        self.assertIn('#define BTPS_BUILD_TAG "v7.7-sink-capacity-trial"', SOURCE)
    def test_original_registration_called_once(self):
        hook=SOURCE.split('static uint64_t hook_register(',1)[1].split('/* ------------------------------------------------------------------------------------------------ v7 SDP observer',1)[0]
        # One pass-through Source registration and one guarded, separate trial.
        self.assertEqual(hook.count('g_orig[BTPS_H_REGISTER]('),1)
        self.assertIn('sizeof seid_before',hook)
        self.assertIn('btps_v77_attempt_after_sources();',hook)
        self.assertIn('if (sources == 6u)',hook)
        self.assertIn('g_v77_caps.assigned_seid',SOURCE)
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
