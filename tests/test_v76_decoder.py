"""Compile the production decoder adapter against pinned upstream Google libsbc and
validate against the actual SBC/WAV exported from the jailbroken iPhone.
When the upstream source is missing locally, run tools/fetch_google_sbc.sh first.
CI does so as a separate explicit step (not silently skipped)."""
from pathlib import Path
import array,ctypes,math,platform,shutil,subprocess,tempfile,unittest,wave
P=Path(__file__).resolve().parents[1]
SRC=P/'btpsaudiohelper'
class V76Decoder(unittest.TestCase):
 def test_source_and_helper_wiring(self):
  h=(SRC/'main.m').read_text();m=(SRC/'Makefile').read_text()
  for term in ['--sbc-play','btps_v76_decode_sbc','SBC_DECODE_PASS','SBC_AUDIO_%s','SBC_FIDELITY_FAIL']:
   self.assertIn(term,h)
  for term in ['BTPSV76Decode.c','vendor_sbc/sbc.c','vendor_sbc/bits.c']:
   self.assertIn(term,m)
  # Research parser is still needed for RTP frame-boundary checks, but not PCM decoding.
  self.assertIn('sbc_decode.c',m)
  self.assertIn('btps_v76_decode_sbc',h)
 def test_no_new_daemon_sink_modifications(self):
  d=(P/'BTPSDaemonProbe.c').read_text()
  self.assertIn('BTPSDaemonProbeStartV75',d)
  self.assertNotIn('AVDTP_RegisterMultipoint(',d)
 def test_audio_fidelity_against_exported_ffmpeg_wav(self):
  # This is mandatory on CI; fail if the vendored source has not been downloaded.
  files=[SRC/'vendor_sbc'/i for i in ('sbc.c','bits.c','sbc.h','bits.h','LICENSE')]
  if any(not f.exists() for f in files):
   if __import__('os').environ.get('CI'):self.fail('Missing pinned Google libsbc source: run tools/fetch_google_sbc.sh')
   self.skipTest('Pinned upstream not downloaded locally; GitHub Actions fetches it')
  cc=shutil.which('cc') or shutil.which('clang')
  if not cc:self.skipTest('C compiler unavailable')
  with tempfile.TemporaryDirectory() as td:
   lib=Path(td)/('decode.dylib' if platform.system()=='Darwin' else 'decode.so')
   args=[cc,'-std=gnu11','-O2','-fPIC','-dynamiclib' if platform.system()=='Darwin' else '-shared','-I'+str(SRC/'vendor_sbc'),'-o',str(lib),str(SRC/'BTPSV76Decode.c'),str(SRC/'vendor_sbc/sbc.c'),str(SRC/'vendor_sbc/bits.c')]
   subprocess.run(args,check=True,capture_output=True,text=True)
   dll=ctypes.CDLL(str(lib));fn=dll.btps_v76_decode_sbc
   fn.argtypes=[ctypes.c_void_p,ctypes.c_size_t,ctypes.c_void_p,ctypes.c_size_t,ctypes.POINTER(ctypes.c_size_t),ctypes.POINTER(ctypes.c_size_t),ctypes.POINTER(ctypes.c_uint),ctypes.POINTER(ctypes.c_uint)]
   fn.restype=ctypes.c_int
   sbc=(P/'tests/fixtures/v75_actual_captured_258_frames.sbc').read_bytes();raw=ctypes.create_string_buffer(sbc)
   pcm=(ctypes.c_int16*(33024*2))();frames=ctypes.c_size_t();samples=ctypes.c_size_t();rate=ctypes.c_uint();channels=ctypes.c_uint()
   self.assertEqual(fn(raw,len(sbc),pcm,len(pcm),ctypes.byref(frames),ctypes.byref(samples),ctypes.byref(rate),ctypes.byref(channels)),0)
   self.assertEqual((frames.value,samples.value,rate.value,channels.value),(258,33024,44100,2))
   with wave.open(str(P/'tests/fixtures/v75_actual_ffmpeg_reference.wav')) as wav:
    self.assertEqual((wav.getnchannels(),wav.getframerate(),wav.getnframes()),(2,44100,33024))
    ref=array.array('h');ref.frombytes(wav.readframes(wav.getnframes()))
   if __import__('sys').byteorder!='little':ref.byteswap()
   ref_rms=math.sqrt(sum(y*y for y in ref)/len(ref))/32768
   x=list(pcm);rms=math.sqrt(sum(y*y for y in x)/len(x))/32768
   clipped=sum(abs(y)>=32000 for y in x)/len(x)
   self.assertLess(clipped,0.01,'Decoded output clipped, fail rather than play broken audio')
   self.assertGreater(rms,ref_rms*.65)
   self.assertLess(rms,ref_rms*1.6)
   # Correlate each channel with FFmpeg reference after ignoring startup transient.
   for ch in (0,1):
    a=x[4096*2+ch::2];b=ref[4096*2+ch::2]
    dot=sum(float(u)*v for u,v in zip(a,b));sa=sum(float(u)*u for u in a);sb=sum(float(v)*v for v in b)
    corr=dot/(math.sqrt(sa*sb)+1e-30)
    self.assertGreater(abs(corr),0.80,'Decoded waveform does not resemble reference channel %d: corr %g'%(ch,corr))
if __name__=='__main__':unittest.main()
