from pathlib import Path
import sys
import unittest
ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'tools'))
from triage_log import assess,summary

class TriageTests(unittest.TestCase):
    def test_success_counts_and_seid(self):
        data='''build: v6-detailed-observe\nhook.AVDTP_RegisterMultipoint: installed
== LOG (from preferences, oldest first) ==
TRACE native A2DP Source #1 accepted (SEID=1)
TRACE native A2DP Source #2 accepted (SEID=2)
publish_audio_device call #1
'''
        a=assess(data)
        self.assertEqual(a['source_success_seen'],2)
        self.assertEqual(a['source_seids'],[1,2])
        self.assertTrue(a['seen_publish_audio'])
        self.assertFalse(a['sdp_110b_published_by_project'])
    def test_failed_registration(self):
        a=assess('FAIL native Source registration #4 status 0x68')
        self.assertEqual(a['native_source_failures'],1)
        self.assertIn('ATTENTION',summary(a))
    def test_empty_log_does_not_claim_success(self):
        a=assess('build: v6-detailed-observe')
        self.assertEqual(a['installed_hooks'],0)
        self.assertEqual(a['source_success_seen'],0)
        self.assertFalse(a['receive_path_implemented'])

if __name__ == '__main__': unittest.main()
