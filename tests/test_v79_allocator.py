"""v7.9 allocation geometry: native C checks, binary provenance and safe gates."""
from pathlib import Path
import ctypes
import subprocess
import tempfile
import unittest
import re

ROOT = Path(__file__).resolve().parents[1]

class Geometry(ctypes.Structure):
    _fields_ = [
        ('configured', ctypes.c_uint8 * 3),
        ('observed', ctypes.c_uint8 * 3),
        ('bytes', ctypes.c_uint * 3),
        ('config_matches_context', ctypes.c_uint),
        ('missing_table_mask', ctypes.c_uint),
    ]

class TestV79(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        lib = Path(cls.temp.name) / 'libv79.so'
        subprocess.run(['cc', '-std=c11', '-Wall', '-Wextra', '-Werror', '-shared', '-fPIC',
                        str(ROOT / 'BTPSV79Geometry.c'), '-o', str(lib)], check=True)
        cls.func = ctypes.CDLL(str(lib)).btps_v79_analyze
        cls.func.argtypes = [ctypes.POINTER(ctypes.c_uint8), ctypes.POINTER(ctypes.c_uint8),
                             ctypes.c_uint, ctypes.POINTER(Geometry)]
        cls.func.restype = ctypes.c_int
    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()
    def check(self, expected, live, mask):
        x=(ctypes.c_uint8*3)(*expected)
        y=(ctypes.c_uint8*3)(*live)
        out=Geometry()
        return self.func(x,y,mask,ctypes.byref(out)),out
    def test_expected_six_slots(self):
        rc,g = self.check([6,8,12],[6,8,12],7)
        self.assertEqual(rc,0)
        self.assertEqual(list(g.bytes),[240,1152,768])
        self.assertEqual(g.config_matches_context,1)
        self.assertEqual(g.missing_table_mask,0)
    def test_mismatch_detected(self):
        rc,g=self.check([7,8,12],[6,8,12],7)
        self.assertEqual(rc,0)
        self.assertEqual(g.config_matches_context,0)
    def test_missing_pointer_is_reported(self):
        rc,g=self.check([6,8,12],[6,8,12],3)
        self.assertEqual(rc,0)
        self.assertEqual(g.missing_table_mask,4)
    def test_zero_secondary_arrays_are_permitted(self):
        rc,g=self.check([6,0,0],[6,0,0],1)
        self.assertEqual(rc,0)
        self.assertEqual(list(g.bytes),[240,0,0])
        self.assertEqual(g.missing_table_mask,0)
    def test_invalid_config_refused(self):
        self.assertNotEqual(self.check([65,1,1],[6,1,1],7)[0],0)
        self.assertNotEqual(self.check([6,1,1],[0,1,1],7)[0],0)
        self.assertNotEqual(self.check([6,1,1],[6,1,1],8)[0],0)
    def test_source_uses_only_memory_reads(self):
        source=(ROOT/'Tweak.xm').read_text()
        block=source.split('static void btps_v79_snapshot_geometry(void)',1)[1].split('/* v8.0/v8.1: Optional config getter observer',1)[0]
        self.assertIn('g_v78_exact_uuid',source)
        self.assertIn('btps_v79_signatures_match()',block)
        self.assertIn('btps_peek',block)
        self.assertIn('btps_v79_analyze(',block)
        self.assertNotIn('MSHookFunction',block)
        self.assertNotIn('malloc(',block)
        self.assertNotIn('memcpy(',block)
        self.assertNotIn('g_orig[',block)
        self.assertNotIn('btps_v77_attempt_after_sources(',source)
        self.assertIn('if (sources == 6u)',source)
        self.assertIn('btps_v79_snapshot_geometry();',source)
        self.assertIn('BTPSV79Geometry.c', (ROOT/'Makefile').read_text())
        self.assertIn('diag.v79_allocator',source)
    def test_provenance_instruction_table(self):
        # We do not ship the user's proprietary 10MB bluetoothd in GitHub.
        # Verifies source pins sites analyzed from the exact UUID only.
        source=(ROOT/'Tweak.xm').read_text()
        for offset in ['0x0ce3f8u', '0x0ce3fcu', '0x0ce41cu', '0x0ce424u',
                       '0x0ce470u', '0x0ce4d4u', '0x0ce4f4u', '0x1f5f48u',
                       '0x984a60u', '0x9768b0u']:
            self.assertIn(offset, source)
        self.assertIn('v8.1-one-shot-seven-slot', source)
    def test_documented_limitations(self):
        docs=(ROOT/'docs/V79_AVDTP_ALLOCATION_FINDINGS.md').read_text()
        for needle in ['0xCE428', '0xCE4F4', '0x984a60', 'NOT', 'no allocation']:
            self.assertIn(needle,docs)

if __name__=='__main__':unittest.main()
