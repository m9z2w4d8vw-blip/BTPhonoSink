"""Read-only native slot decoder, source gating and binary-provenance checks."""
from pathlib import Path
import unittest
import tempfile
import subprocess
import ctypes
import plistlib
import hashlib

ROOT = Path(__file__).resolve().parents[1]

class CStats(ctypes.Structure):
    _fields_ = [('total',ctypes.c_uint), ('occupied',ctypes.c_uint),
                ('vacant',ctypes.c_uint), ('duplicate_seids',ctypes.c_uint),
                ('seids',ctypes.c_uint8*32)]

class TestV78(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.t = tempfile.TemporaryDirectory()
        target = Path(cls.t.name)/'capacity.so'
        subprocess.run(['cc','-std=c11','-Wall','-Wextra','-Werror','-shared','-fPIC',
                        str(ROOT/'BTPSV78Capacity.c'),'-o',str(target)],check=True)
        cls.analyze = ctypes.CDLL(str(target)).btps_v78_analyze
        cls.analyze.argtypes = [ctypes.POINTER(ctypes.c_uint8),ctypes.c_size_t,ctypes.c_uint,ctypes.POINTER(CStats)]
        cls.analyze.restype=ctypes.c_int
    @classmethod
    def tearDownClass(cls): cls.t.cleanup()
    def make(self, values):
        raw=(ctypes.c_uint8*(40*len(values)))()
        for i,v in enumerate(values):raw[i*40+25]=v
        return raw
    def test_full_six_slots(self):
        mem=self.make([1,2,3,4,5,6]);out=CStats()
        self.assertEqual(self.analyze(mem,len(mem),6,ctypes.byref(out)),0)
        self.assertEqual((out.total,out.occupied,out.vacant,out.duplicate_seids),(6,6,0,0))
        self.assertEqual(list(out.seids)[:6],[1,2,3,4,5,6])
    def test_mixed_slots_and_duplicate(self):
        mem=self.make([1,0,1,7]);o=CStats()
        self.assertEqual(self.analyze(mem,len(mem),4,ctypes.byref(o)),0)
        self.assertEqual((o.occupied,o.vacant,o.duplicate_seids),(3,1,1))
    def test_reject_bad_buffer(self):
        mem=self.make([1,2]);o=CStats()
        self.assertNotEqual(self.analyze(mem,len(mem)-1,2,ctypes.byref(o)),0)
        self.assertNotEqual(self.analyze(mem,len(mem),33,ctypes.byref(o)),0)
        self.assertNotEqual(self.analyze(mem,len(mem),0,ctypes.byref(o)),0)
    def test_source_safety(self):
        src=(ROOT/'Tweak.xm').read_text()
        self.assertRegex(src, r'#define BTPS_BUILD_TAG "v[0-9]+\.[0-9]+[^"]*"')
        self.assertIn('btps_v78_snapshot_capacity();',src)
        self.assertIn('if (sources == 6u)',src)
        self.assertIn('g_v78_exact_uuid = uuid_ok;',src)
        self.assertIn('V78_TABLE RESULT',src)
        self.assertNotIn('btps_v77_attempt_after_sources(',src)
        self.assertNotIn('btps_v77_attempt_after_sources();',src)
        self.assertIn('BTPSV78Capacity.c',(ROOT/'Makefile').read_text())
        self.assertIn('#define BTPS_AVDTP_TSEP_SNK 1u',src)
        self.assertIn('decisive_requested && g_v81_seven_armed && !BTPSExperimentsEnabled()',src)
        self.assertIn('g_native_source_success != 6',src)
    def test_settings_no_trial_toggle(self):
        d=plistlib.loads((ROOT/'speakaprefs/Resources/Root.plist').read_bytes())
        self.assertNotIn('SpeakaV77SinkTrial',[x.get('key') for x in d['items']])
    def test_pinned_disassembly_layout(self):
        docs=(ROOT/'docs/research/V78_AVDTP_CAPACITY_FINDINGS.md').read_text()
        for x in ['0xCEE14','0xCEE54','0xCEEE8','0x9768b0']:
            self.assertIn(x,docs)

if __name__=='__main__':unittest.main()
