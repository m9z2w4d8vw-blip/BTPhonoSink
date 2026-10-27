"""Build regression only. NOT evidence of live Bluetooth or SDP discoverability."""
import ctypes
import hashlib
import pathlib
import shutil
import struct
import subprocess
import tempfile
import unittest

ROOT=pathlib.Path(__file__).resolve().parent.parent
EXPECTED={
    0xCECF0:(0xd503237f,0xd102c3ff,0xa9056ffc,0xa90667fa),
    0x1F5F20:(0xd503237f,0xa9be4ff4,0xa9017bfd,0x910043fd),
    0x1E8E78:(0xd503237f,0xa9bd57f6,0xa9014ff4,0xa9027bfD),
    0xD3B08:(0xd503237f,0xd10203ff,0xa90557f6,0xa9064ff4),
}
class Elem(ctypes.Structure):
    _fields_=[('type',ctypes.c_uint8),('reserved',ctypes.c_uint8),('length',ctypes.c_uint16),
              ('padding',ctypes.c_uint32),('value',ctypes.c_uint64)]
class Attr(ctypes.Structure):
    _fields_=[('id',ctypes.c_uint16),('padding',ctypes.c_uint8*6),('element',Elem)]
class Descriptor(ctypes.Structure):
    _fields_=[('a',ctypes.POINTER(Attr)),('count_a',ctypes.c_uint16),('reserved_a',ctypes.c_uint8*6),
              ('b',ctypes.POINTER(Attr)),('count_b',ctypes.c_uint16),('reserved_b',ctypes.c_uint8*6)]
class SDPTests(unittest.TestCase):
    def test_abi_layout_and_nested_values(self):
        self.assertEqual((ctypes.sizeof(Elem),ctypes.sizeof(Attr),ctypes.sizeof(Descriptor)),(16,24,32))
        cc=shutil.which('clang') or shutil.which('cc')
        if not cc: self.skipTest('no native compiler')
        with tempfile.TemporaryDirectory() as td:
            so=pathlib.Path(td)/'sdp.so'
            subprocess.run([cc,'-shared','-fPIC','-o',str(so),str(ROOT/'BTPSV82SDP.c')],check=True,
                            stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            lib=ctypes.CDLL(str(so));lib.BTPSV82SinkSDPDescriptor.restype=ctypes.POINTER(Descriptor)
            desc=lib.BTPSV82SinkSDPDescriptor().contents
            self.assertEqual((desc.count_a,desc.count_b),(4,1))
            attrs=[desc.a[i] for i in range(4)]
            self.assertEqual([a.id for a in attrs],[1,4,9,0x311])
            def nested(elem):
                self.assertEqual(elem.type,6)
                return ctypes.cast(elem.value,ctypes.POINTER(Elem))
            self.assertEqual(nested(attrs[0].element)[0].value,0x110b)
            protos=nested(attrs[1].element)
            self.assertEqual(tuple(nested(protos[0])[i].value for i in range(2)),(0x100,0x19))
            self.assertEqual(tuple(nested(protos[1])[i].value for i in range(2)),(0x19,0x103))
            profile=nested(attrs[2].element)
            self.assertEqual(tuple(nested(profile[0])[i].value for i in range(2)),(0x110d,0x103))
            self.assertEqual((attrs[3].element.type,attrs[3].element.length,attrs[3].element.value),(1,2,1))
            name=desc.b[0]
            self.assertEqual(name.id,0x100)
            self.assertEqual(ctypes.string_at(name.element.value,name.element.length),b'Audio Sink')
    def test_binary_signatures_if_uploaded_present(self):
        b=pathlib.Path('/mnt/data/files/bluetoothd')
        if not b.exists(): self.skipTest('device binary is not committed to GitHub; verify locally')
        data=b.read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(),
            'e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6')
        for off,words in EXPECTED.items(): self.assertEqual(struct.unpack_from('<4I',data,off),words)
    def test_trial_requires_both_arms_and_verified_hooks(self):
        s=(ROOT/'Tweak.xm').read_text()
        self.assertIn('decisive_requested && g_v81_seven_armed && !BTPSExperimentsEnabled()',s)
        self.assertIn('!g_v82_signal_hook_ok || !g_v82_sdp_hook_ok',s)
        self.assertIn('g_native_source_success != 6',s)
        self.assertIn('BTPSV82SinkSDPDescriptor()',s)
        self.assertIn('BTPS_V82_RX_DISPATCH 0x000d3b08ul',s)
        self.assertNotIn('MEDIA_BYTES_RECEIVED=PASS',s)
if __name__=='__main__': unittest.main()
