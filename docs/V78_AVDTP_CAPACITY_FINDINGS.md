# AVDTP_RegisterMultipoint: origin of raw error 0x68

**Evidence:** `bluetoothd` executable copied from this iPhone, SHA-256 `e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6`, UUID `5491BA47-B5AE-3D44-9536-B30161DF1E90`; exact `arm64e` instructions disassembled with LLVM `llvm-objdump -d --start-address=0x1000cecf0 --stop-address=0x1000cef28 bluetoothd`.

`AVDTP_RegisterMultipoint` begins at image offset `0xCECF0` and receives endpoint media type `x0`, role `x1`, capability pointer `x2`, count `w3`, endpoint count `w4`, one-byte SEID output `x5`. Other callers' arguments are not exhaustively characterized.

The relevant instructions are:

| image offset | ARM64e instruction | Interpretation |
|---|---|---|
| `0xCEDE0` | `adrp x25, 0x100976000` | address private global page (hex offset is `0xCEDE0`) |
| `0xCEDE4` | `ldr x8, [x25, #0x8b0]` | load context pointer from image+`0x9768b0` |
| `0xCEDE8` | `ldrb w26, [x8, #0x64]` | next SEID candidate cursor |
| `0xCEE04` | `ldr x12, [x8]` | pointer to endpoint table |
| `0xCEE08` | `ldrb w10, [x8, #0x60]` | current slot-entry count |
| `0xCEE14` | `mov w0, #0x68` | preset fallback return code |
| `0xCEE24` | `ldrb w15, [x14]` | existing SEID at entry+`0x19` |
| `0xCEE34` | `add x14, x14, #0x28` | loop stride is 40 bytes |
| `0xCEE54` | `ldurb w14, [x27, #-5]` | occupied indicator (same entry+`0x19`) |
| `0xCEE60` | `add x27, x27, #0x28` | step to next endpoint |
| `0xCEE68` | `b.lo 0x1000cee54` | keep scanning while within entry count |
| `0xCEE78` | `cmp w9, #0xfe` | bound attempts over candidate SEIDs |
| `0xCEE80` | `b.lo 0x1000cee18` | retry candidate / scan |
| `0xCEE84` | `b 0x1000ceeec` | exit with default `0x68` when no slot selected |
| `0xCEE9C` | ... | successful free-slot path |
| `0xCEEB4` | `mov w0, #0` | success return |
| `0xCEEB8` | `sturb w26, [x27, #-5]` | set endpoint SEID in formerly free slot |
| `0xCEEE8` | `strb w8, [x19]` | copy 1-byte assigned SEID to caller |

**Inference (strong, not yet runtime-confirmed):** `0x68` occurs after the endpoint-registration search fails to identify a usable free slot; with six successful Apple Source entries it is strongly consistent with an occupied fixed-size table. An alternative is that the SEID search fails for another reason. `0x68` is *not* proof that a specific Apple public API reports “capacity exhausted.”

The v7.8 test snapshots image+`0x9768b0` and **only reads** the context's endpoint count and an owned local copy of up to 32 entries. It uses the byte at `entry+0x19` as the occupancy marker. `slots=6 occupied=6 free=0` would confirm this table was full at the time of the snapshot.

## Alternative approaches (not yet implemented)

- Reuse one of the existing Source slots for a Sink: dangerous unless Apple's Source initialization and outgoing audio expectations can tolerate losing that slot. A role change alone is insufficient and could break headphones.
- Expand the table: current allocation ownership, memory layout, absolute pointer references and other loops must be traced before any allocation/count modification. Merely setting count to 7 would cause an out-of-bounds write.
- Use an independently managed AVDTP/L2CAP profile stack: would need access to the already owned Bluetooth controller/transport, incoming signaling and media channels, without competing with `bluetoothd`. Feasibility unproven.

**Avoid repeating the v7.7 opt-in registration**: it already returned 0x68; v7.8 removes the switch and compiles out its side effect. Do not enable Legacy Sink or SDP advertisement.
