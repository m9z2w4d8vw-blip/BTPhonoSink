#!/usr/bin/env python3
"""Construct a standards-shaped A2DP Audio Sink SDP *attribute list*.

This is offline SDP Data Element encoding. It is NOT an Apple OI_SDPDB
in-memory service-record ABI and must not be passed to private functions
without reverse engineering the exact API, layout and ownership rules.
"""
import argparse
import struct

def u16(n):
    if not 0 <= n <= 0xffff: raise ValueError("uint16 out of range")
    return b"\x09" + struct.pack(">H", n)

def uuid16(n):
    if not 0 <= n <= 0xffff: raise ValueError("uuid16 out of range")
    return b"\x19" + struct.pack(">H", n)

def seq(*elements):
    body = b"".join(elements)
    if len(body) < 256: return b"\x35" + bytes([len(body)]) + body
    if len(body) < 65536: return b"\x36" + struct.pack(">H", len(body)) + body
    raise ValueError("sequence too long")

def text(value):
    data = value.encode("utf-8")
    if len(data) > 255: raise ValueError("name too long")
    return b"\x25" + bytes([len(data)]) + data

def attr(aid, value):
    return u16(aid) + value

def a2dp_sink_record(name="Speaka", feature_bits=0x0002):
    # UUID: Sink=0x110B; A2DP profile=0x110D; L2CAP=0x0100;
    # AVDTP protocol=0x0019 / PSM=0x0019.
    return seq(
        attr(0x0001, seq(uuid16(0x110B))),
        attr(0x0004, seq(
            seq(uuid16(0x0100), u16(0x0019)),
            seq(uuid16(0x0019), u16(0x0103)))),
        attr(0x0009, seq(seq(uuid16(0x110D), u16(0x0102)))),
        attr(0x0100, text(name)),
        attr(0x0311, u16(feature_bits)),
    )

def decode_element(raw, offset=0):
    if offset >= len(raw): raise ValueError("truncated descriptor")
    desc=raw[offset]; tag=desc>>3; size_code=desc&7
    sizes=(1,2,4,8,16)
    if size_code < 5:
        size=sizes[size_code]; pos=offset+1
    elif size_code == 5:
        if offset+2>len(raw): raise ValueError("short length8")
        size=raw[offset+1]; pos=offset+2
    elif size_code == 6:
        if offset+3>len(raw): raise ValueError("short length16")
        size=int.from_bytes(raw[offset+1:offset+3],"big");pos=offset+3
    else:
        if offset+5>len(raw): raise ValueError("short length32")
        size=int.from_bytes(raw[offset+1:offset+5],"big");pos=offset+5
    end=pos+size
    if end>len(raw): raise ValueError("truncated element")
    blob=raw[pos:end]
    if tag==6:
        kids=[]; k=0
        while k<len(blob):
            item,k=decode_element(blob,k)
            kids.append(item)
        return (tag,kids),end
    return (tag,blob),end

def decode_attributes(raw):
    record,end=decode_element(raw)
    if end!=len(raw) or record[0]!=6: raise ValueError("not one SDP sequence")
    fields=record[1]
    if len(fields)%2: raise ValueError("unpaired attribute")
    decoded={}
    for i in range(0,len(fields),2):
        aid,val=fields[i],fields[i+1]
        if aid[0]!=1 or len(aid[1])!=2: raise ValueError("invalid attribute ID")
        key=int.from_bytes(aid[1],"big")
        if key in decoded: raise ValueError("duplicate attribute")
        decoded[key]=val
    return decoded

def main():
    ap=argparse.ArgumentParser()
    ap.add_argument("--name",default="Speaka")
    ap.add_argument("--output",help="write encoded binary to this local path")
    args=ap.parse_args()
    blob=a2dp_sink_record(args.name)
    decoded=decode_attributes(blob)
    print("SDP A2DP Sink attribute list:",blob.hex(" "))
    print("Attributes:",", ".join(f"0x{v:04x}" for v in decoded))
    print("Bytes:",len(blob))
    print("WARNING: this is a wire-format example, not an Apple private SDPDB ABI.")
    if args.output:
        from pathlib import Path
        Path(args.output).write_bytes(blob)
        print("Saved:",args.output)

if __name__=="__main__":
    main()
