"""Guard the v7.6 helper-only diagnostics; no daemon / Bluetooth modifications."""
from pathlib import Path
import unittest
P=Path(__file__).resolve().parents[1]
H=(P/'btpsaudiohelper/main.m').read_text()
class HelperPlaybackDiagnostics(unittest.TestCase):
 def test_audio_mode_explicit(self):
  self.assertIn('SBC_PLAY_DECODE_AND_OUTPUT', H)
  self.assertIn('SBC_VERIFY_ONLY_NO_SOUND', H)
  self.assertIn('play_sbc_mode=argc>=2 && strcmp(argv[1],"--sbc-play")==0', H)
 def test_ack_is_transport_only(self):
  self.assertIn('this ACK proves only transport/framing',H)
  self.assertIn('reply(fd,"SBC_VERIFIED")',H)
  self.assertIn('BTPS_V76_RESULT ipc=PASS rtp=PASS sbc_frames=PASS decode=FAIL',H)
 def test_route_diagnostics(self):
  self.assertIn('SBC_AUDIO_ROUTE port=',H)
  self.assertIn('session.currentRoute',H)
  self.assertIn('session.outputVolume',H)
 def test_saved_reference_unmodified(self):
  a=H.index('NSData *wav=wav_from_sbc_pcm(pcm,nsamples)')
  b=H.index('pcm[k]=(int16_t)lrint((double)pcm[k]*gain)')
  c=H.index('NSData *playbackWav=wav_from_sbc_pcm(pcm,nsamples)')
  self.assertLess(a,b)
  self.assertLess(b,c)
  self.assertIn('SBC_AUDIO_PREP original_peak=',H)
 def test_gain_limited(self):
  self.assertIn('fmin(4.0,14000.0/(double)peak)',H)
  self.assertIn('fidelity=FAIL audio_api=NOT_STARTED',H)
 def test_daemon_unchanged(self):
  self.assertIn('v7.7-sink-capacity-trial',(P/'Tweak.xm').read_text())
  self.assertIn('V75_SBC armed:',(P/'BTPSDaemonProbe.c').read_text())
if __name__=='__main__':unittest.main()
