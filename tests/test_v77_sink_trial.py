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
    def test_switch_off_by_default_and_distinct_from_legacy(self):
        pl=plistlib.loads((ROOT/'btphonosinkprefs/Resources/Root.plist').read_bytes())
        opts=[x for x in pl['items'] if x.get('key')=='BTPhonoSinkV77SinkTrial']
        self.assertEqual(len(opts),1);self.assertIs(opts[0]['default'],False)
        self.assertNotEqual(opts[0]['key'],'BTPhonoSinkExperiments')
    def test_register_once_only_after_native_sources_and_with_separate_byte(self):
        src=(ROOT/'Tweak.xm').read_text()
        self.assertIn('if (sources == 6u)',src)
        self.assertIn('btps_v77_attempt_after_sources();',src)
        self.assertIn('__sync_bool_compare_and_swap(&g_v77_attempted, 0u, 1u)',src)
        self.assertIn('g_native_source_success != 6u',src)
        self.assertIn('&g_v77_caps.assigned_seid',src)
        self.assertIn('g_v77_caps.caps_words',src)
        self.assertIn('BTPS_AVDTP_TSEP_SNK',src)
        self.assertIn('if (g_v77_requested && uuid_ok && !legacy_on)',src)
        self.assertNotIn('OI_SDPDB_AddServiceRecord(',src)
    def test_build_and_logger_have_trial(self):
        self.assertIn('BTPSV77Sink.c',(ROOT/'Makefile').read_text())
        self.assertIn('diag.v77_sink_trial',(ROOT/'btphonosinkprefs/BTPSLogReader.m').read_text())
        self.assertIn('v7.7-sink-capacity-trial',(ROOT/'Tweak.xm').read_text())

if __name__=='__main__':unittest.main()
