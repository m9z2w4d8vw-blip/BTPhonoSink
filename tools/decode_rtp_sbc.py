#!/usr/bin/env python3
"""Offline-only A2DP RTP/SBC packet decoder. No Bluetooth/iPhone interaction.

Usage: python tools/decode_rtp_sbc.py captured-packet.bin decoded.wav
Requires a local C compiler (cc/clang/gcc). The input is *one complete* RTP(v2)
packet containing nonfragmented SBC frames, not an L2CAP/PCAP capture.

Research decoder: correct packet framing is tested, but bit-exact fidelity and
SBC CRC verification have not yet been established. Do not trust playback quality.
"""
import argparse
import ctypes as ct
import shutil
import subprocess
import sys
import tempfile
import wave
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
class View(ct.Structure):
    _fields_=[('sequence',ct.c_uint16),('timestamp',ct.c_uint32),('ssrc',ct.c_uint32),
              ('payload_type',ct.c_uint8),('marker',ct.c_uint8),('frame_count',ct.c_uint8),
              ('channels',ct.c_uint8),('sample_rate',ct.c_uint32),
              ('media_offset',ct.c_size_t),('media_length',ct.c_size_t),
              ('frame_offsets',ct.c_uint16*15),('frame_lengths',ct.c_uint16*15)]

def decode(data: bytes):
    cc=shutil.which('cc') or shutil.which('clang') or shutil.which('gcc')
    if not cc: raise RuntimeError('C compiler not installed; use GitHub Actions offline tests')
    with tempfile.TemporaryDirectory() as tmp:
        target=Path(tmp)/('media.dylib' if sys.platform=='darwin' else ('media.dll' if sys.platform=='win32' else 'media.so'))
        flags=['-dynamiclib'] if sys.platform=='darwin' else ['-shared']
        subprocess.run([cc,'-std=c11','-O2','-fPIC',*flags,'-o',str(target),
                        str(ROOT/'BTPSMedia.c'),str(ROOT/'sbc_decode.c'),'-lm'],
                       check=True)
        lib=ct.CDLL(str(target))
        lib.btps_media_decode_rtp_sbc.argtypes=[ct.c_void_p,ct.c_size_t,ct.c_void_p,ct.c_size_t,
                                                ct.POINTER(ct.c_size_t),ct.POINTER(View)]
        lib.btps_media_decode_rtp_sbc.restype=ct.c_int
        b=ct.create_string_buffer(data)
        # A2DP SBC frame count <=15; 16 blocks * 8 subbands * 2 PCM channels each.
        out=(ct.c_int16 * (15*16*8*2))()
        n=ct.c_size_t()
        view=View()
        rc=lib.btps_media_decode_rtp_sbc(b,len(data),out,len(out),ct.byref(n),ct.byref(view))
        if rc: raise ValueError(f'RTP/SBC decode rejected packet: error {rc}')
        samples=ct.string_at(ct.addressof(out),n.value*2)
        return samples,view

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('rtp_packet',type=Path)
    parser.add_argument('wav_file',type=Path)
    args=parser.parse_args()
    pcm,view=decode(args.rtp_packet.read_bytes())
    with wave.open(str(args.wav_file),'wb') as out:
        out.setnchannels(2)       # stereo interleaved; mono is duplicated
        out.setsampwidth(2)       # signed 16-bit
        out.setframerate(view.sample_rate)
        out.writeframes(pcm)
    print(f'Decoded sequence={view.sequence} frames={view.frame_count}, '
          f'sample_rate={view.sample_rate}, samples={len(pcm)//2}, WAV={args.wav_file}')

if __name__=='__main__': main()
