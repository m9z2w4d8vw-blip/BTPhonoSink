"""Portable C capability reader tests, compiled with the host C compiler."""
from ctypes import CDLL, Structure, POINTER, c_ubyte, c_uint, c_size_t, c_int, byref
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class Caps(Structure):
    _fields_ = [
        ("total_records", c_uint), ("transport_records", c_uint),
        ("codec_records", c_uint), ("delay_records", c_uint),
        ("unknown_records", c_uint), ("codec_present", c_uint),
        ("media_type", c_ubyte), ("codec_type", c_ubyte),
        ("codec_data_len", c_ubyte), ("fingerprint", c_uint)
    ]

@unittest.skipUnless(shutil.which('clang') or shutil.which('cc'), 'requires a C compiler')
class DecodingTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory()
        dylib = Path(cls.tmp.name) / ('libdiag.dylib' if os.uname().sysname == 'Darwin' else 'libdiag.so')
        subprocess.run([shutil.which('clang') or shutil.which('cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                        '-shared', '-fPIC', '-I', str(ROOT), str(ROOT / 'BTPSDiagnostics.c'),
                        '-o', str(dylib)], check=True)
        cls.lib = CDLL(str(dylib))
        cls.lib.btps_decode_caps.argtypes = [POINTER(c_ubyte), c_size_t, POINTER(Caps)]
        cls.lib.btps_decode_caps.restype = c_int

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def read(self, code, size):
        payload = bytearray(48)
        payload[0] = 1
        payload[16:21] = bytes([7, 0, code, size, 0])
        payload[32] = 8
        buf = (c_ubyte * 48).from_buffer_copy(payload)
        result = Caps()
        self.assertEqual(self.lib.btps_decode_caps(buf, 48, byref(result)), 1)
        self.assertEqual(result.transport_records, 1)
        self.assertEqual(result.codec_records, 1)
        self.assertEqual(result.delay_records, 1)
        self.assertEqual(result.total_records, 3)
        self.assertEqual(result.codec_data_len, size)
        self.assertNotEqual(result.fingerprint, 0)
        return result

    def test_sbc(self): self.assertEqual(self.read(0x00, 4).codec_type, 0x00)
    def test_aac(self): self.assertEqual(self.read(0x02, 6).codec_type, 0x02)
    def test_vendor(self): self.assertEqual(self.read(0xff, 14).codec_type, 0xff)

    def test_malformed_length(self):
        b = (c_ubyte * 2)(1, 7)
        result = Caps()
        self.assertEqual(self.lib.btps_decode_caps(b, 2, byref(result)), 0)
        self.assertEqual(result.total_records, 0)

    def test_null_argument(self):
        out = Caps()
        self.assertEqual(self.lib.btps_decode_caps(None, 48, byref(out)), 0)

    def test_same_caps_have_same_fingerprint(self):
        self.assertEqual(self.read(0x02, 6).fingerprint, self.read(0x02, 6).fingerprint)

if __name__ == '__main__': unittest.main()
