"""Host-executed tests of the actual RTP + SBC C depacketizer (not mock checks)."""
import ctypes as ct
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MAX_FRAMES = 15

class MediaView(ct.Structure):
    _fields_ = [('sequence',ct.c_uint16),('timestamp',ct.c_uint32),('ssrc',ct.c_uint32),
                ('payload_type',ct.c_uint8),('marker',ct.c_uint8),('frame_count',ct.c_uint8),
                ('channels',ct.c_uint8),('sample_rate',ct.c_uint32),
                ('media_offset',ct.c_size_t),('media_length',ct.c_size_t),
                ('frame_offsets',ct.c_uint16*MAX_FRAMES),('frame_lengths',ct.c_uint16*MAX_FRAMES)]

def frame(b1=0xB9, bitpool=35):
    # 44.1 kHz stereo, 16 blocks, 8 subbands, 35-bitpool -> 82 bytes
    stereo = ((b1 >> 2) & 3) == 2
    assert stereo and (b1 & 1) == 1 and ((b1 >> 4) & 3) == 3
    n = 4 + 8 + (16 * bitpool + 7)//8
    return bytes([0x9C,b1,bitpool,0]) + bytes(n-4)

def packet(payload, flags=0x80, second=0x60, cc_data=b'', ext=b'', padding=b''):
    header = bytes([flags, second,0x12,0x34,0,0,0,42, 0xde,0xad,0xbe,0xef])
    return header + cc_data + ext + payload + padding

class MediaPacketTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cc = shutil.which('cc') or shutil.which('clang') or shutil.which('gcc')
        if not cc: raise unittest.SkipTest('C compiler unavailable')
        cls.temp = tempfile.TemporaryDirectory()
        ext = '.dylib' if sys.platform == 'darwin' else '.so'
        libpath = str(Path(cls.temp.name)/('btps_media'+ext))
        mode = '-dynamiclib' if sys.platform == 'darwin' else '-shared'
        subprocess.run([cc,'-std=c11','-O2','-Wall','-Wextra','-Werror','-fPIC',mode,
                        '-o',libpath,str(ROOT/'BTPSMedia.c'),str(ROOT/'sbc_decode.c'),'-lm'],
                       check=True, capture_output=True, text=True)
        cls.lib = ct.CDLL(libpath)
        cls.lib.btps_media_parse_rtp.argtypes = [ct.c_void_p,ct.c_size_t,ct.POINTER(MediaView)]
        cls.lib.btps_media_parse_rtp.restype = ct.c_int
        cls.lib.btps_media_decode_rtp_sbc.argtypes = [ct.c_void_p,ct.c_size_t,ct.c_void_p,ct.c_size_t,
                                                      ct.POINTER(ct.c_size_t),ct.POINTER(MediaView)]
        cls.lib.btps_media_decode_rtp_sbc.restype = ct.c_int
    @classmethod
    def tearDownClass(cls): cls.temp.cleanup()
    def parse(self,data):
        data_buf = ct.create_string_buffer(data)
        info = MediaView()
        rc = self.lib.btps_media_parse_rtp(data_buf,len(data),ct.byref(info))
        return rc,info
    def test_one_frame(self):
        f = frame()
        rc,v = self.parse(packet(b'\x01'+f))
        self.assertEqual(rc,0)
        self.assertEqual((v.sequence,v.timestamp,v.ssrc),(0x1234,42,0xdeadbeef))
        self.assertEqual((v.payload_type,v.marker),(96,0))
        self.assertEqual((v.frame_count,v.sample_rate,v.channels),(1,44100,2))
        self.assertEqual((v.frame_lengths[0],v.media_length,v.media_offset),(82,82,13))
    def test_joint_stereo_frame_length(self):
        # Joint stereo has exactly one subband-wide join bitmap, not one per block.
        # 16 blocks, 8 subbands, bitpool 35: 4+8+ceil((8+16*35)/8)=83 bytes.
        b1=0xBD  # 44.1 kHz, 16 blocks, joint, loudness, 8 subbands
        f=bytes([0x9c,b1,35,0])+bytes(83-4)
        rc,v=self.parse(packet(b'\x01'+f))
        self.assertEqual(rc,0)
        self.assertEqual(v.frame_lengths[0],83)
    def test_dual_channel_frame_length(self):
        # Dual channel: 16 blocks, 8 subbands, 35 bitpool, two independent channels.
        b1=0xB5  # 44.1 kHz, 16 blocks, dual, loudness, 8 subbands
        n=4+8+((16*2*35+7)//8)
        f=bytes([0x9c,b1,35,0])+bytes(n-4)
        rc,v=self.parse(packet(b'\x01'+f))
        self.assertEqual(rc,0)
        self.assertEqual(v.frame_lengths[0],n)
    def test_two_frames(self):
        f=frame(); rc,v=self.parse(packet(b'\x02'+f+f))
        self.assertEqual(rc,0)
        self.assertEqual((v.frame_offsets[0],v.frame_offsets[1]),(0,82))
        self.assertEqual(v.frame_lengths[1],82)
    def test_csrc_extension_padding(self):
        f=frame()
        ext=b'\xbe\xde\x00\x01'+b'ABCD'
        rc,v=self.parse(packet(b'\x01'+f,flags=0xB1,second=0xE0,
                               cc_data=b'\0\0\0\1',ext=ext,padding=b'\0\0\0\4'))
        self.assertEqual(rc,0)
        self.assertEqual((v.media_offset,v.media_length,v.marker),(25,82,1))
    def test_reject_unsupported_fragment(self):
        self.assertEqual(self.parse(packet(b'\x81'+frame()))[0],-3)
    def test_reject_mismatched_frame_count(self):
        self.assertEqual(self.parse(packet(b'\x02'+frame()))[0],-2)
    def test_reject_extra_sbc_data(self):
        self.assertEqual(self.parse(packet(b'\x01'+frame()+b'123'))[0],-4)
    def test_reject_invalid_rtp_and_padding(self):
        self.assertEqual(self.parse(packet(b'\x01'+frame(), flags=0x40))[0],-1)
        self.assertEqual(self.parse(packet(b'\x01'+frame(), flags=0xA0,padding=b'\x00'))[0],-1)
    def test_reject_truncated_extension_and_csrc(self):
        self.assertEqual(self.parse(packet(b'',flags=0x81))[0],-2)
        self.assertEqual(self.parse(packet(b'\x01'+frame(),flags=0x90,ext=b'\xbe\xde\xff\xff'))[0],-2)
    def test_reject_wrong_sbc_codec_and_bitpool(self):
        self.assertEqual(self.parse(packet(b'\x01'+bytes([0x9c,0xb9,0,0])+bytes(90)))[0],-4)
        self.assertEqual(self.parse(packet(b'\x01'+b'\xff'+frame()[1:]))[0],-4)
    def test_pcm_capacity_preflight(self):
        p=packet(b'\x01'+frame()); buf=ct.create_string_buffer(p)
        output=(ct.c_int16*1)(); num=ct.c_size_t()
        rc=self.lib.btps_media_decode_rtp_sbc(buf,len(p),output,1,ct.byref(num),None)
        self.assertEqual(rc,-5)
        self.assertEqual(num.value,0)
    def test_synthetic_frame_decodes_and_yields_expected_pcm_samples(self):
        # This verifies plumbing and memory bounds, not bit-exact audio quality.
        p=packet(b'\x01'+frame()); buf=ct.create_string_buffer(p)
        output=(ct.c_int16*512)(); n=ct.c_size_t()
        rc=self.lib.btps_media_decode_rtp_sbc(buf,len(p),output,512,ct.byref(n),None)
        self.assertEqual(rc,0)
        self.assertEqual(n.value,256)

if __name__=='__main__': unittest.main()
