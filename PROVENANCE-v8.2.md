# v8.2 offsets: derivation from the *exact uploaded* bluetoothd

SHA256 `e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6`

LC_UUID `5491BA47-B5AE-3D44-9536-B30161DF1E90`

All addresses below refer to image base 0x100000000; offsets are arithmetic differences.

| Target | Entry RVA | Verified entry words | Proven role |
|---|---:|---|---|
| AVDTP_RegisterMultipoint | CE CF0 | d503237f d102c3ff a9056ffc a90667fa | Existing Apple Source registrar; six native Source calls demonstrated |
| AVDTP config getter | 1F5F20 | d503237f a9be4ff4 a9017bfd 910043fd | Existing v8.1 single-restart seven-slot allocation shadow |
| OI_SDPDB_AddServiceRecord candidate | 1E8E78 | d503237f a9bd57f6 a9014ff4 a9027bfd | Existing SDP record-add hook; retains attribute pointer arrays |
| AVDTP signaling RX dispatcher | D3B08 | d503237f d10203ff a90557f6 a9064ff4 | Caller passes CID, packet pointer, length; dispatches signaling IDs 1..13 |

## Relevant instructions from the uploaded image

```
1000ceed0: sturb w23, [x27, #-0x3]  ; endpoint type from x1
1000ceee8: strb w8, [x19]           ; one-byte assigned SEID output x5

1001e8ea4: ldr x8, [x21]
1001e8ea8: str x8, [x0, #0x10]      ; retained first attr array
1001e8eac: ldrh w8, [x21, #0x8]   ; count
1001e8eb4: ldr x8, [x21, #0x10]
1001e8eb8: str x8, [x0, #0x20]     ; retained second attr array
1001e8ebc: ldrh w8, [x21, #0x18]  ; count

1000d3b38: cbz w2, 0x1000d3f14
1000d3b3c: mov x19, x0
1000d3b40: str x1, [sp, #0x20]
1000d3b44: strh w2, [sp, #0x28]
1000d3c64: sub w16, w9, #0x1
1000d3c68: cmp w16, #0xc
1000d3c8c: br x16
```

Source SDP descriptor: caller `0x1000CB0B0` to `0x1001E8E78`.
Static Source attributes image+`0x91ABD0`, protocol sequence +`0x91AC30`, A2DP profile sequence +`0x91AC50`; primitives +`0x773678...`. Source IDs `0x0001`, `0x0004`, `0x0009`, `0x0311`, service-name `0x0100`. The Sink candidate uses Source-derived private element layout (24-byte attrs/16-byte elements) with `0x110B`, PSM `0x0019`, profile `0x110D`, feature value `0x0001`, name `Audio Sink`.

## Binary validation (not an on-device test)

```
python3 - <<'PY'
from pathlib import Path
import hashlib,struct
b=Path('bluetoothd').read_bytes()
assert hashlib.sha256(b).hexdigest()=='e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6'
for off in [0xCECF0,0x1F5F20,0x1E8E78,0xD3B08]:
 print(hex(off),[hex(x) for x in struct.unpack_from('<4I',b,off)])
PY
```

No TX signaling-response hook, internal SEP state-transition hook, or authenticated incoming RTP media hook is claimed. Those are pending further binary validation. This v8.2 trial cannot independently prove **PASS** or **KILL-NATIVE-SINK-ACP**; peer-side SDP and response checks are mandatory to establish signaling outcomes.
