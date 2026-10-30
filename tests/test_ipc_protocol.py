"""Native executable tests of the exact protocol shared by Settings sender and CLI receiver."""
from pathlib import Path
import unittest
import ctypes
import subprocess
import tempfile
import shutil
import struct
import zlib
ROOT=Path(__file__).resolve().parents[1]

class IPCTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory()
        cc=shutil.which('clang') or shutil.which('cc')
        if not cc: raise unittest.SkipTest('C compiler is unavailable')
        so=Path(cls.tmp.name)/'libipc.so'
        subprocess.run([cc,'-std=c11','-Wall','-Wextra','-Werror','-fPIC','-shared','-I',str(ROOT),str(ROOT/'BTPSIPCProtocol.c'),'-o',str(so)],check=True,capture_output=True)
        cls.lib=ctypes.CDLL(str(so))
        cls.lib.btps_ipc_crc32.argtypes=[ctypes.c_void_p,ctypes.c_size_t]
        cls.lib.btps_ipc_crc32.restype=ctypes.c_uint32
        cls.lib.btps_ipc_encode.argtypes=[ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32]
        cls.lib.btps_ipc_validate.argtypes=[ctypes.c_void_p,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_size_t]
        cls.lib.btps_ipc_validate.restype=ctypes.c_int
        cls.lib.btps_ipc_encode_daemon_v74.argtypes=[ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32]
        cls.lib.btps_ipc_validate_daemon_v74.argtypes=[ctypes.c_void_p,ctypes.c_uint32,ctypes.c_void_p,ctypes.c_size_t]
        cls.lib.btps_ipc_validate_daemon_v74.restype=ctypes.c_int
    @classmethod
    def tearDownClass(cls):cls.tmp.cleanup()
    def build(self):
        pcm=bytes([0x55,0xCC])*35280
        raw=ctypes.create_string_buffer(pcm)
        crc=self.lib.btps_ipc_crc32(raw,len(pcm))
        header=ctypes.create_string_buffer(24)
        self.lib.btps_ipc_encode(header,123456,crc)
        return header,raw,crc
    def test_versioned_header_and_crc(self):
        header,raw,crc=self.build()
        self.assertEqual(header.raw[:4],b'BTPS')
        self.assertEqual(struct.unpack_from('<HHIIII',header.raw,4),(1,1,44100,35280,123456,crc))
        self.assertEqual(crc,zlib.crc32(raw.raw[:70560]))
        self.assertEqual(self.lib.btps_ipc_validate(header,123456,raw,70560),1)
    def test_bad_token(self):
        h,pcm,_=self.build()
        self.assertEqual(self.lib.btps_ipc_validate(h,234567,pcm,70560),0)
    def test_bad_length(self):
        h,pcm,_=self.build()
        self.assertEqual(self.lib.btps_ipc_validate(h,123456,pcm,70560-2),0)
    def test_crc_tampering(self):
        h,pcm,_=self.build()
        pcm[44]=b'X'[0]
        self.assertEqual(self.lib.btps_ipc_validate(h,123456,pcm,70560),0)
    def test_wrong_rate(self):
        h,pcm,_=self.build()
        h[8]=0;self.assertEqual(self.lib.btps_ipc_validate(h,123456,pcm,70560),0)
    def test_wrong_channels(self):
        h,pcm,_=self.build()
        h[6]=2;self.assertEqual(self.lib.btps_ipc_validate(h,123456,pcm,70560),0)
    def test_wrong_magic(self):
        h,pcm,_=self.build()
        h[0]=ord('Q');self.assertEqual(self.lib.btps_ipc_validate(h,123456,pcm,70560),0)
    def test_reject_null_payload(self):
        h,_,_=self.build()
        self.assertEqual(self.lib.btps_ipc_validate(h,123456,None,70560),0)
    def build_daemon_v74(self):
        pcm=bytes([0x14,0x9A])*35280
        raw=ctypes.create_string_buffer(pcm)
        crc=self.lib.btps_ipc_crc32(raw,70560)
        header=ctypes.create_string_buffer(28)
        self.lib.btps_ipc_encode_daemon_v74(header,654321,crc)
        return header,raw,crc
    def test_v74_magic_tag_and_crc(self):
        h,pcm,crc=self.build_daemon_v74()
        self.assertEqual(h.raw[:4],b'BTPS')
        self.assertEqual(struct.unpack_from('<HHIIII',h.raw,4),(2,1,44100,35280,654321,crc))
        self.assertEqual(h.raw[24:],b'BTD4')
        self.assertEqual(self.lib.btps_ipc_validate_daemon_v74(h,654321,pcm,70560),1)
        self.assertEqual(zlib.crc32(pcm.raw[:70560]),crc)
    def test_v74_rejects_wrong_token(self):
        h,pcm,_=self.build_daemon_v74()
        self.assertEqual(self.lib.btps_ipc_validate_daemon_v74(h,123456,pcm,70560),0)
    def test_v74_rejects_wrong_sender_tag(self):
        h,pcm,_=self.build_daemon_v74()
        h[24]=ord('X')
        self.assertEqual(self.lib.btps_ipc_validate_daemon_v74(h,654321,pcm,70560),0)
    def test_v74_rejects_wrong_version(self):
        h,pcm,_=self.build_daemon_v74()
        h[4]=1
        self.assertEqual(self.lib.btps_ipc_validate_daemon_v74(h,654321,pcm,70560),0)
    def test_v74_rejects_wrong_length(self):
        h,pcm,_=self.build_daemon_v74()
        self.assertEqual(self.lib.btps_ipc_validate_daemon_v74(h,654321,pcm,70558),0)
    def test_v74_rejects_crc_tampering(self):
        h,pcm,_=self.build_daemon_v74()
        pcm[1]=ord('Z')
        self.assertEqual(self.lib.btps_ipc_validate_daemon_v74(h,654321,pcm,70560),0)
    def test_v74_rejects_legacy_v1_payload(self):
        h,pcm,_=self.build()
        self.assertEqual(self.lib.btps_ipc_validate_daemon_v74(h,123456,pcm,70560),0)
    def test_v74_rejects_null_payload(self):
        h,_,_=self.build_daemon_v74()
        self.assertEqual(self.lib.btps_ipc_validate_daemon_v74(h,654321,None,70560),0)
    def test_source_wiring(self):
        ui=(ROOT/'btphonosinkprefs/BTPSLogViewController.m').read_text()
        daemon=(ROOT/'Tweak.xm').read_text()
        self.assertIn('Send PCM to Separate Helper',ui)
        self.assertIn('sendTestPCMWithToken',ui)
        self.assertNotIn('BTPSIPCSender',daemon)
        self.assertNotIn('BTPSIPCProtocol',daemon)
        make=(ROOT/'Makefile').read_text()
        self.assertIn('SUBPROJECTS += btpsaudiohelper',make)
        self.assertIn('BTPSAudioHelper', (ROOT/'btpsaudiohelper/Makefile').read_text())
        # Both subprojects compile the root copy through a one-line include, so the protocol cannot drift.
        for sub in ('btpsaudiohelper','btphonosinkprefs'):
            wrapper=(ROOT/sub/'BTPSIPCProtocol.c').read_text()
            self.assertEqual([l for l in wrapper.splitlines() if l.strip() and not l.lstrip().startswith('/*')],
                             ['#include "../BTPSIPCProtocol.c"'])
        self.assertIn('btps_ipc_',(ROOT/'BTPSIPCProtocol.c').read_text())
    def test_log_export_result(self):
        report=(ROOT/'btphonosinkprefs/BTPSLogReader.m').read_text()
        self.assertIn('V7.3 INTERPROCESS AUDIO TEST',report)
        self.assertIn('V7.4 BLUETOOTHD-TO-HELPER REQUEST',report)
        self.assertIn('BTPSIPCPlaybackLastResult',report)
if __name__=='__main__':unittest.main()
