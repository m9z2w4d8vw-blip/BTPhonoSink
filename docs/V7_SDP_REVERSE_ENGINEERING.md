# v7 SDP record-add instrumenting: static verification (local binary)

## Inputs and provenance

Analyzed `bluetoothd` from the user device: 10,196,720 bytes, SHA256 `e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6`, UUID `5491BA47-B5AE-3D44-9536-B30161DF1E90`. These findings apply **only** to this binary.

## New direct-call evidence

Disassembly contains **20 direct calls** to unslid `0x1001E8E78` (image+`0x1E8E78`):

```
0x0093a88, 0x00a58fc, 0x00ab4b8, 0x00ab998, 0x00cb0b0,
0x00e1d14, 0x00e8044, 0x00ee324, 0x00f4a64, 0x00fd3f0,
0x00fee28, 0x0100cb0, 0x0216f70, 0x02175bc, 0x03ccf10,
0x0479998, 0x058f904, 0x058f944, 0x068575c, 0x068579c
```

The `0x00AB998` caller branches to a `...SDPDB_AddServiceRecord failed` logger on nonzero return. The call is plausibly the SDP database service record-add routine, but **no external source validates its ABI for other builds**.

## Input descriptor inference from actual instructions

Entry `0x1E8E78` has words `D503237F A9BD57F6 A9014FF4 A9027BFD`. It reads x0 as a descriptor, x1 as an optional 32-bit record-handle output pointer.

* The callee copies x0+0x00 pointer and x0+0x08 count (16-bit) into its internal 0x50-byte node.
* It likewise copies x0+0x10 pointer and x0+0x18 count into the node.
* It examines the first descriptor array with a 0x18-byte **stride** (24 bytes, not 32). For each entry it reads attr ID at offset +0 (u16), type at +8 (u8), and for ServiceClassIDList attr ID 0x0001 with type 0x06 it reads pointer +16 followed by u16 at that pointer+8. The u16 is a provisional class-ID candidate, not a full SDP attribute parser.
* If a record handle output pointer is non-null, it stores a u32. It returns zero on its success branch; other codes are not documented.
* The callee appears to keep attribute array pointers in the database node. Therefore any *future* synthetic registration must provide persistent memory and understand ownership. v7 does not allocate or add a record.

## v7 safe diagnostic design

1. Exactly five v6 hooks remain in the original table. The optional sixth hook is excluded from the five-hook summary and OFF by default.
2. The optional hook requires BOTH the known image UUID and all four exact prologue words. No fallbacks based on partial matches.
3. Input inspection uses the existing failure-safe `mach_vm_read` helper, strict pointer bounds, a cap of eight attributes per descriptor list, and reduced logging after the first 24 calls.
4. Original function is called **once and exactly once** with the two original pointers untouched. v7 never calls AVDTP registration, SDP registration, audio service creation, or media decode paths.
5. If an unknown build is encountered, the optional probe is refused. If runtime behavior worsens, disable the separate Settings toggle and restart `bluetoothd` once; restore v6 if required.

**Expected v7 result:** determine which kinds of SDP service records Apple publishes normally and the format of the existing Source record metadata, before considering a live Sink registration. Windows-to-iPhone Bluetooth audio remains not implemented.
