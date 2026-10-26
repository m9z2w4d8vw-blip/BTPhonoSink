"""Exercise the same plain-C PCM tone generator linked into bluetoothd."""
import ctypes, math, subprocess, shutil, tempfile, unittest
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
class ToneTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cc=shutil.which('clang') or shutil.which('cc')
  if not cc: raise unittest.SkipTest('C compiler not installed')
  cls.temp=tempfile.TemporaryDirectory()
  so=Path(cls.temp.name)/'libtone.so'
  subprocess.run([cc,'-std=c11','-Wall','-Wextra','-Werror','-shared','-fPIC','-I',str(ROOT),
                  str(ROOT/'BTPSV74Tone.c'),'-lm','-o',str(so)],capture_output=True,check=True)
  cls.lib=ctypes.CDLL(str(so))
  cls.lib.btps_v74_make_tone.argtypes=[ctypes.c_void_p,ctypes.c_size_t]
  cls.lib.btps_v74_make_tone.restype=ctypes.c_int
 @classmethod
 def tearDownClass(cls):cls.temp.cleanup()
 def test_reject_null_and_short_buffers(self):
  self.assertEqual(self.lib.btps_v74_make_tone(None,70560),0)
  data=(ctypes.c_uint8*70560)()
  self.assertEqual(self.lib.btps_v74_make_tone(data,70559),0)
 def test_generate_distinct_880hz_pcm(self):
  data=(ctypes.c_uint8*70560)()
  self.assertEqual(self.lib.btps_v74_make_tone(data,70560),1)
  samples=[int.from_bytes(bytes(data[i:i+2]),'little',signed=True) for i in range(0,70560,2)]
  self.assertEqual(len(samples),35280)
  self.assertEqual(samples[0],0)
  self.assertEqual(samples[-1],0)
  self.assertLessEqual(max(abs(v) for v in samples),12000)
  self.assertGreater(max(abs(v) for v in samples),11000)
  # 880 cycles/s for 0.8 seconds -> 704 periods (allow end-fade rounding).
  positive_crossings=sum(a<=0<b for a,b in zip(samples[:-1],samples[1:]))
  self.assertTrue(700<=positive_crossings<=705,positive_crossings)
  # v7.3 was 660 Hz -> ~528 rising transitions; this signal differs decisively.
  self.assertGreater(positive_crossings,600)
if __name__=='__main__':unittest.main()
