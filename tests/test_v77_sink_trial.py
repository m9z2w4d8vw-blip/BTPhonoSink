"""V7.7 opt-in Sink experiment: native C capability ownership and source safety."""
from pathlib import Path
import ctypes
import subprocess
import tempfile
import unittest
import plistlib

ROOT=Path(__file__).resolve().parents[1]
class SinkCaps(ctypes.Structure):
    _fields_=[('caps_words',ctypes.c_uint64*6),('codec_bytes',ctypes.c_uint8*4),('assigned_seid',ctypes.c_uint8)]

class V77Safety(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp=tempfile.TemporaryDirectory()
        lib=Path(cls.tmp.name)/'caps.so'
        subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-shared','-fPIC',
                        '-o',str(lib),str(ROOT/'BTPSV77Sink.c')],check=True)
        cls.func=ctypes.CDLL(str(lib)).btps_v77_prepare_sink_caps
        cls.func.argtypes=[ctypes.POINTER(SinkCaps),ctypes.POINTER(ctypes.c_uint8),ctypes.POINTER(ctypes.c_uint8)]
        cls.func.restype=ctypes.c_int
    @classmethod
    def tearDownClass(cls): cls.tmp.cleanup()
    def test_native_sbc_capability_is_copied_to_owned_memory(self):
        src=(ctypes.c_uint8*48)()
        src[0]=1;src[16]=7;src[18]=0;src[19]=4;src[32]=8
        codec=(ctypes.c_uint8*4)(0x3f,0x15,0x02,0x35)
        result=SinkCaps()
        self.assertEqual(self.func(ctypes.byref(result),src,codec),0)
        ptr=int.from_bytes(ctypes.string_at(ctypes.addressof(result.caps_words)+24,8),'little')
        self.assertEqual(ptr,ctypes.addressof(result.codec_bytes))
        self.assertNotEqual(ptr,ctypes.addressof(codec))
        self.assertEqual(bytes(result.codec_bytes),bytes(codec))
        src[18]=2;codec[0]=0
        self.assertEqual(bytes(result.codec_bytes),bytes((0x3f,0x15,0x02,0x35)))
        self.assertEqual(bytes(ctypes.string_at(ctypes.addressof(result.caps_words),48))[18],0)
        self.assertEqual(result.assigned_seid,0)
    def test_reject_non_sbc_or_malformed_caps(self):
        src=(ctypes.c_uint8*48)();src[0]=1;src[16]=7;src[18]=2;src[19]=4;src[32]=8
        codec=(ctypes.c_uint8*4)(0x3f,0x15,0x02,0x35)
        result=SinkCaps()
        self.assertNotEqual(self.func(ctypes.byref(result),src,codec),0)
    def test_v77_trial_retired_from_settings(self):
        pl=plistlib.loads((ROOT/'speakaprefs/Resources/Root.plist').read_bytes())
        self.assertFalse(any(x.get('key')=='SpeakaV77SinkTrial' for x in pl['items']))
    def test_v77_mutation_disabled_after_error_0x68(self):
        src=(ROOT/'Tweak.xm').read_text()
        self.assertNotIn('btps_v77_attempt_after_sources(',src)
        self.assertNotIn('btps_v77_attempt_after_sources();',src)
        self.assertIn('btps_v78_snapshot_capacity();',src)
    def test_v78_capacity_logger_is_in_build(self):
        self.assertIn('BTPSV78Capacity.c',(ROOT/'Makefile').read_text())
        self.assertIn('diag.v78_table',(ROOT/'Tweak.xm').read_text())

if __name__=='__main__':unittest.main()
