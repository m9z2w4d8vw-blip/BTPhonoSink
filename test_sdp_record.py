import sys
from pathlib import Path
import unittest

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/"tools"))
from sdp_record import a2dp_sink_record,decode_attributes,decode_element,seq,u16

class SDPTests(unittest.TestCase):
    def test_valid_structure(self):
        raw=a2dp_sink_record()
        fields=decode_attributes(raw)
        self.assertEqual(set(fields),{1,4,9,0x100,0x311})
        self.assertEqual(fields[1],(6,[(3,b"\x11\x0b")]))
        self.assertEqual(fields[0x311],(1,b"\x00\x02"))
    def test_l2cap_avdtp(self):
        fields=decode_attributes(a2dp_sink_record())
        self.assertEqual(fields[4],(6,[
            (6,[(3,b"\x01\x00"),(1,b"\x00\x19")]),
            (6,[(3,b"\x00\x19"),(1,b"\x01\x03")])]))
    def test_profile(self):
        fields=decode_attributes(a2dp_sink_record())
        self.assertEqual(fields[9],(6,[(6,[(3,b"\x11\x0d"),(1,b"\x01\x02")])]))
    def test_name(self):
        fields=decode_attributes(a2dp_sink_record("iPhone audio"))
        self.assertEqual(fields[0x100],(4,b"iPhone audio"))
    def test_truncation(self):
        raw=a2dp_sink_record()
        with self.assertRaises(ValueError): decode_attributes(raw[:-1])
    def test_long_name(self):
        with self.assertRaises(ValueError): a2dp_sink_record("a"*256)
    def test_one_or_two_byte_sequence_length(self):
        blob=seq(*[u16(i) for i in range(100)])
        elem,end=decode_element(blob)
        self.assertEqual(end,len(blob))
        self.assertEqual(len(elem[1]),100)

if __name__=="__main__":
    unittest.main()
