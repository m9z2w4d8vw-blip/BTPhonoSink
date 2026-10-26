"""Known limitation: SBC sample count tests are NOT PCM fidelity tests.

This test intentionally documents the known quality defect. Once fixed, an
unexpected success will fail CI, prompting removal of @expectedFailure.
"""
from pathlib import Path
import ctypes as c
import shutil
import subprocess
import tempfile
import unittest

ROOT=Path(__file__).resolve().parents[1]

class DecoderFidelityTests(unittest.TestCase):
 @unittest.expectedFailure
 def test_real_440hz_sbc_audio_must_not_clip(self):
  compiler=shutil.which('cc') or shutil.which('clang')
  if not compiler:self.skipTest('no compiler')
  with tempfile.TemporaryDirectory() as d:
   lib=Path(d)/'decode.so'
   import sys
   if sys.platform=='darwin':
    lib=Path(d)/'decode.dylib';link='-dynamiclib'
   else:link='-shared'
   subprocess.run([compiler,'-std=c11','-O2','-fPIC',link,'-o',str(lib),
     str(ROOT/'BTPSMedia.c'),str(ROOT/'sbc_decode.c'),'-lm'],check=True)
   f=c.CDLL(str(lib));f.btps_media_decode_rtp_sbc.argtypes=[c.c_void_p,c.c_size_t,c.c_void_p,c.c_size_t,c.POINTER(c.c_size_t),c.c_void_p];f.btps_media_decode_rtp_sbc.restype=c.c_int
   file=(ROOT/'tests/fixtures/BTPS_SBC_440Hz_reference.rtpbin').read_bytes()
   samples=[];offset=0
   while offset<len(file):
    count=int.from_bytes(file[offset:offset+2],'big');offset+=2
    packet=file[offset:offset+count];offset+=count
    a=c.create_string_buffer(packet);pcm=(c.c_int16*4096)();n=c.c_size_t()
    self.assertEqual(f.btps_media_decode_rtp_sbc(a,len(packet),pcm,4096,c.byref(n),None),0)
    samples.extend(pcm[:n.value])
   self.assertGreater(len(samples),40000)
   clipped=sum(abs(x)>=32000 for x in samples)/len(samples)
   # Present decoder clips >99% of real test vectors, a serious fidelity bug.
   self.assertLess(clipped,0.05,'SBC decoder is heavily clipped: %.1f%%' % (100*clipped))
if __name__=='__main__':unittest.main()
