"""Guard the new user-facing actions and the zero-mutation SDP observer."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
class V72Tests(unittest.TestCase):
 def test_iOS_audio_probe_is_settings_only(self):
  make=(ROOT/'btphonosinkprefs/Makefile').read_text()
  self.assertIn('BTPSAudioProbe.m',make)
  self.assertIn('AVFoundation',make)
  self.assertNotIn('BTPSAudioProbe.m',(ROOT/'Makefile').read_text())
  src=(ROOT/'btphonosinkprefs/BTPSAudioProbe.m').read_text()
  for text in ('BTPSMakeTone','AVAudioPlayer','setActive:YES','audioPlayerDidFinishPlaying','44100','440.0'):
   self.assertIn(text,src)
 def test_existing_daemon_hook_did_not_add_registration_or_media_hook(self):
  tweak=(ROOT/'Tweak.xm').read_text()
  self.assertIn('v7.9-readonly-allocator-audit',tweak)
  self.assertNotIn('hook_media_recv(',tweak)
  self.assertNotIn('btphonosink_on_rtp_packet(',tweak)
  self.assertIn('static uint16_t btps_sdp_class_hint(',tweak)
  self.assertIn('diag.sdp_source_seen',tweak)
  self.assertIn('diag.sdp_sink_candidate_seen',tweak)
 def test_checklist_reports_manual_requirements(self):
  ui=(ROOT/'btphonosinkprefs/BTPSLogViewController.m').read_text()
  self.assertIn('showChecklist',ui)
  self.assertIn('stored=off',ui)
  self.assertIn('Verify Test Checklist',ui)
  self.assertIn('MANUAL: Confirm headphones',ui)
  self.assertIn('Test iOS Audio Output (440 Hz)',ui)
 def test_audio_test_is_exported(self):
  src=(ROOT/'btphonosinkprefs/BTPSLogReader.m').read_text()
  self.assertIn('SETTINGS PROCESS AUDIO SELF-TEST',src)
  self.assertIn('BTPSAudioTestLastResult',src)
if __name__=='__main__':unittest.main()
