#!/usr/bin/env python3
"""Read-only evidence collector for the precise 2026 Speaka daemon.
Does not invoke or patch private symbols.
"""
import argparse, hashlib,struct,subprocess,shutil
from pathlib import Path
SHA256="e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6"
UUID="5491BA47B5AE3D449536B30161DF1E90"
HOOKS={
 "AVDTP_RegisterMultipoint":(0x0CECF0,"d503237fd102c3ffa9056ffca90667fa"),
 "advertise_A2DP_source":(0x44DF14,"d503237fa9ba6ffca90167faa9025ff8"),
 "SetConfigInd_handler":(0x37AE68,"d503237fd10303ffa9066ffca90767fa"),
 "SetConfig_accept_SBC":(0x3B03B4,"d503237fd102c3ff6d0423e9a9056ffc"),
 "publish_audio_device":(0x376E4C,"d503237fd104c3ffa90d6ffca90e67fa")
}
def analyze(path, disasm=False):
    blob=Path(path).read_bytes()
    digest=hashlib.sha256(blob).hexdigest()
    print("Length:",len(blob),"SHA256:",digest)
    if digest!=SHA256:
        raise ValueError("Unexpected bluetoothd SHA-256; refusing conclusions for this build")
    if blob[:4]!=b"\xcf\xfa\xed\xfe":
        raise ValueError("Not a little-endian 64-bit Mach-O")
    print("File identity: MATCH")
    print("Expected UUID:",UUID)
    for name,(offset,sig) in HOOKS.items():
        actual="".join(blob[offset+i:offset+i+4][::-1].hex() for i in range(0,16,4))
        print(f"  {name}: image+0x{offset:06x}  {'MATCH' if actual==sig else 'MISMATCH'}")
        if actual!=sig: raise ValueError("Instruction fingerprint mismatch")
    for msg in [
        b"Advertising A2DP Source",
        b"AudioSinkSdp",
        b"OI_SDPDB_AddServiceRecord failed",
    ]:
        ofs=blob.find(msg)
        print(f"  {msg.decode()}: file+0x{ofs:x}" if ofs>=0 else f"  {msg.decode()}: NOT FOUND")
    print("\nStatic callsite landmarks (image-relative):")
    print("  0x0CEEC4: AVDTP endpoint state read")
    print("  0x0CEE08: endpoint slot-count field loaded [state+0x60]")
    print("  0x0CEE34: 0x28-byte endpoint stride")
    print("  0x0CEEE8: SEID stored through x5 by an 8-bit store")
    print("  0x0AB990: caller of candidate SDP database AddServiceRecord")
    print("  0x44E170: A2DP Source 0x110A written to advertising data")
    if disasm:
        objdump=shutil.which("llvm-objdump")
        if not objdump:
            print("llvm-objdump unavailable; inspect with Xcode tools or llvm locally.")
        else:
            for start,stop in ((0xCEDEC,0xCEF24),(0xAB970,0xAB9E0),(0x44E15C,0x44E180)):
                print(f"\n--- image+0x{start:x}...0x{stop:x} ---")
                subprocess.run([objdump,"--disassemble",f"--start-address=0x{0x100000000+start:x}",
                  f"--stop-address=0x{0x100000000+stop:x}",str(path)],check=True)
def main():
    p=argparse.ArgumentParser()
    p.add_argument("bluetoothd")
    p.add_argument("--disasm",action="store_true")
    args=p.parse_args()
    analyze(args.bluetoothd,args.disasm)
if __name__=="__main__":main()
