"""Native C checks of the v7.5 compressed (non-PCM) daemon-to-helper boundary."""
import ctypes as C
from pathlib import Path
import subprocess, shutil, tempfile, unittest, sys
ROOT=Path(__file__).resolve().parents[1]

class SBCStreamTests(unittest.TestCase):
 @classmethod
 def setUpClass(cls):
  cc=shutil.which('clang') or shutil.which('cc')
  if not cc:raise unittest.SkipTest('C compiler missing')
  cls.tmp=tempfile.TemporaryDirectory()
  out=Path(cls.tmp.name)/('libtest.dylib' if sys.platform=='darwin' else 'libtest.so')
  subprocess.run([cc,'-std=c11','-O2','-fPIC','-dynamiclib' if sys.platform=='darwin' else '-shared','-I'+str(ROOT),
                  '-o',str(out),str(ROOT/'BTPSV75RTP.c'),str(ROOT/'BTPSMedia.c'),str(ROOT/'sbc_decode.c'),
                  str(ROOT/'BTPSIPCProtocol.c'),'-lm'],check=True)
  cls.lib=C.CDLL(str(out))
  cls.decode=cls.lib.btps_v75_extract_sbc
  cls.decode.argtypes=[C.c_void_p,C.c_size_t,C.c_void_p,C.c_size_t,C.POINTER(C.c_size_t),C.POINTER(C.c_uint),C.POINTER(C.c_uint)]
  cls.decode.restype=C.c_int
  cls.enc=cls.lib.btps_ipc_encode_sbc_v75
  cls.enc.argtypes=[C.c_void_p,C.c_uint32,C.c_uint32]
  cls.check=cls.lib.btps_ipc_validate_sbc_v75
  cls.check.argtypes=[C.c_void_p,C.c_uint32,C.c_void_p,C.c_size_t]
  cls.check.restype=C.c_int
  cls.crc=cls.lib.btps_ipc_crc32;cls.crc.argtypes=[C.c_void_p,C.c_size_t];cls.crc.restype=C.c_uint32
  cls.fixture=(ROOT/'tests/fixtures/BTPS_SBC_440Hz_reference.rtpbin').read_bytes()
 @classmethod
 def tearDownClass(cls):cls.tmp.cleanup()
 def invoke(self,data,capacity=16000):
  inp=C.create_string_buffer(data);out=C.create_string_buffer(capacity);n=C.c_size_t();p=C.c_uint();f=C.c_uint()
  err=self.decode(inp,len(data),out,capacity,C.byref(n),C.byref(p),C.byref(f))
  return err,out.raw[:n.value],p.value,f.value
 def test_reference_extracts_258_frames_exact(self):
  e,out,p,f=self.invoke(self.fixture)
  self.assertEqual((e,len(out),p,f),(0,12126,258,258))
  self.assertEqual(out[0],0x9c)
  # independent byte extraction from fixture, no use of parser
  b=self.fixture;off=0;expected=bytearray()
  while off<len(b):
   length=int.from_bytes(b[off:off+2],'big');expected.extend(b[off+2+13:off+2+length]);off+=2+length
  self.assertEqual(out,expected)
 def test_truncated_and_corrupt_packets_rejected(self):
  for blob in (self.fixture[:-1],self.fixture[:120],b'',b'\x00\x01\x00'):
   self.assertNotEqual(self.invoke(blob)[0],0)
  m=bytearray(self.fixture);m[2+2]=0xff # sequence gap in packet 1
  self.assertNotEqual(self.invoke(bytes(m))[0],0)
  m=bytearray(self.fixture);m[2+13]=0 # breaks SBC syncword
  self.assertNotEqual(self.invoke(bytes(m))[0],0)
 def test_bad_timestamps_and_capacity_rejected(self):
  m=bytearray(self.fixture);at=2+60+2+4 # second packet timestamp starts at RTP byte offset 4
  m[at+3]^=1
  self.assertNotEqual(self.invoke(bytes(m))[0],0)
  self.assertNotEqual(self.invoke(self.fixture,1000)[0],0)
 def test_compiled_fixture_matches_exact_binary(self):
  cc=shutil.which('cc') or shutil.which('clang')
  with tempfile.TemporaryDirectory() as td:
   lib=Path(td)/('fixture.dylib' if sys.platform=='darwin' else 'fixture.so')
   subprocess.run([cc,'-std=c11','-O2','-fPIC','-dynamiclib' if sys.platform=='darwin' else '-shared',
                   '-o',str(lib),str(ROOT/'BTPSV75Fixture.c')],check=True)
   compiled=C.CDLL(str(lib))
   arr=(C.c_uint8*len(self.fixture)).in_dll(compiled,'btps_v75_reference_rtp')
   count=C.c_size_t.in_dll(compiled,'btps_v75_reference_size').value
   self.assertEqual(count,len(self.fixture))
   self.assertEqual(bytes(arr),self.fixture)

 def test_v75_protocol_typed_version_and_crc(self):
  wire=C.create_string_buffer(self.fixture)
  h=(C.c_uint8*32)();token=555111
  self.enc(h,token,self.crc(wire,len(self.fixture)))
  self.assertEqual(self.check(h,token,wire,len(self.fixture)),1)
  self.assertEqual(self.check(h,token+1,wire,len(self.fixture)),0)
  self.assertEqual(self.check(h,token,wire,len(self.fixture)-1),0)
  h[4]=2
  self.assertEqual(self.check(h,token,wire,len(self.fixture)),0)
 def test_safety_workflow(self):
  daemon=(ROOT/'Tweak.xm').read_text()
  self.assertIn('"v7.6-sbc-playback"',daemon)
  self.assertIn('BTPSDaemonProbeStartV75();',daemon)
  self.assertIn('if (uuid_ok && g_orig[BTPS_H_REGISTER] && g_orig[BTPS_H_ADVERTISE]) {',daemon)
  worker=(ROOT/'BTPSDaemonProbe.c').read_text()
  for token in ('notify_register_dispatch(BTPS_NOTIFY_V75_SBC','INADDR_LOOPBACK','btps_v75_reference_rtp','g_v75_last_uuid','g_v75_last_time','diag.v75_sbc'):
   self.assertIn(token,worker)
  self.assertNotIn('AVDTP_RegisterMultipoint(',worker)
  self.assertNotIn('MSHookFunction',worker)
  helper=(ROOT/'btpsaudiohelper/main.m').read_text()
  for token in ('--sbc','SBC_RECEIVED','BTPS_V75_RESULT','V75_SBC','SBC_VERIFIED','btps_v75_extract_sbc'):
   self.assertIn(token,helper)
  self.assertIn('Save Log to iCloud Drive', (ROOT/'btphonosinkprefs/BTPSLogViewController.m').read_text())
  self.assertNotIn('BTPS_AVDTP_TSEP_SNK',daemon)
  for file in ('BTPSIPCProtocol.c','BTPSV75RTP.c','BTPSMedia.c','sbc_decode.c'):
   self.assertEqual((ROOT/file).read_bytes(),(ROOT/'btpsaudiohelper'/file).read_bytes())

if __name__=='__main__':unittest.main()
