# v8.3 audio-context expansion: exact-image binary provenance

All evidence is from the user-provided `/mnt/data/files/bluetoothd` (10,196,720 bytes), SHA-256 `e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6`, LC_UUID `5491BA47-B5AE-3D44-9536-B30161DF1E90`. Tool: LLVM 17 `llvm-objdump -d --start-address=X --stop-address=Y bluetoothd`. Image base is 0x100000000. This binary is not shipped in the repository.

## Audio-table constructor and zero initialization

```
1003b39d8: mov   x19, x0
1003b39e4: str   w8, [x0]             ; NOTE: context+0, NOT entry+0
1003b39ec: mov   w0, #0x6             ; six entries
1003b39f0: mov   w1, #0x20            ; 32 bytes each
1003b3a04: bl    0x10075bea0         ; auth stub for malloc_type_calloc
1003b3a08: str   x0, [x19, #0x78]   ; table pointer
1003b3a0c: str   wzr, [x0, #0xc]     ; first entry+0xc
1003b3a14: ldr   d0, [x8, #0x320]  ; static template starts SEID=1
1003b3a18: stur  d0, [x0, #0x4]    ; entry+4..+b
1003b3a20: str   w21, [x0, #0x1c]  ; numCaps=3
1003b3a3c: bl    0x10075bea0         ; calloc 3 x 16-byte capabilities
1003b3a44: str   x0, [x8, #0x10]   ; entry+0x10 capability pointer
1003b3a4c: strb  w20, [x0]          ; CAPABILITY+0, not entry+0
1003b3aa8: strb  w20, [x8, #0x18] ; entry+0x18=1
```

Stub `0x10075bea0` is an authenticated bind through address `0x1009154d0` with chained-fixup word `c00900000000029a` -> import ordinal 666 -> `_malloc_type_calloc` (libSystem). Therefore the six-entry array is zero-initialized. No separate nonzero store to **parent** entry+0 identified in the native constructor. Keep new entry+0 as zero. Flag entry+0x18 is written explicitly to 1. The precise semantic meaning of this flag remains unknown.

## Registration-loop return is the intended interception boundary

```
100372bd4: add  x19, x0, #0x118
100372bd8: mov  x0, x19
100372bdc: bl   0x1003b39b4   ; construct higher-level audio table
...
100372e48: mov  x0, x19
100372e4c: bl   0x1003b4128   ; register native Source SEPs and Source SDP
```

Prologue signature for +0x3B4128:

```
1003b4128: d503237f  pacibsp
1003b412c: d10103ff  sub sp, sp, #0x40
1003b4130: a90157f6  stp x22, x21, [sp, #0x10]
1003b4134: a9024ff4  stp x20, x19, [sp, #0x20]
```

The native Source loop reads the audio count and registers each with TSEP=0:

```
1003b4150: ldr w8, [x19, #0x68]
1003b4160: ldr x8, [x19, #0x78]
1003b4164: add x5, x8, x22
1003b4168: ldr x2, [x5], #-0xc ; capability pointer, SEID out pointer at +4
1003b416c: mov w0, #0
1003b4170: mov w1, #0             ; native SOURCE TSEP
1003b4174: mov w3, #3
1003b4178: mov w4, #1
1003b417c: bl 0x1000cecf0
```

The function then invokes `0x1000cb008` to add Apple's native Source SDP record before it returns. Thus the new high-level entry MUST be installed only after the original `+0x3B4128` returns; otherwise the unmodified loop might register an accidental seventh Source.

## Entry layout at 32-byte stride

| Offset | Meaning | Evidence |
|---|---|---|
| +0x00..03 | zero from calloc in native constructor; further semantics unresolved | calloc import as above; no parent entry+0 nonzero store in examined constructor |
| +0x04..07 | SEID preseeded then used for lookup | `0x1003b3a18` and `0x1003b4418: ldr w10,[x9,#4]` |
| +0x08..0B | zero from template in native initial entries | static template `01 00 00 00 00 00 00 00` at `0x100778320` |
| +0x0C..0F | state initialized to zero | `1003b3a0c: str wzr,[x0,#0xc]` |
| +0x10..17 | pointer to 3 x 16-byte capability records | `1003b3a44: str x0,[x8,#0x10]` |
| +0x18 | byte initialized to 1; purpose not proven | `1003b3aa8: strb w20,[x8,#0x18]` with `w20=1` |
| +0x19..1B | remains zero from calloc on first native entry | no independent semantics proven |
| +0x1C..1F | numCaps=3 | `1003b3a20: str w21,[x0,#0x1c]` |

Codec capability pointer at second 16-byte entry+8 is the **audio context** `x19`, not the four SBC configuration bytes used by the *different*, low-level AVDTP SEP representation:

```
1003b3a90: str x19, [x8, #0x18]   ; cap_array+0x18
```

v8.3 duplicates a validated native SBC capability array for the new higher-level entry and uses the previously owned low-level Sink SEP capability array for `AVDTP_RegisterMultipoint`.

## Count/pointer consumers and teardown

```
1003b4028: stp w21, w21, [x19,#0x68]   ; two count fields
1003b4408: ldr w8,[x20,#0x68]          ; lookup count
1003b4414: ldr x9,[x20,#0x78]          ; lookup array
1003b4418: ldr w10,[x9,#4]             ; matching SEID
1003b4424: add x9,x9,#0x20             ; stride
1003b4298: ldr w8,[x19,#0x68]          ; deregistration loop
1003b42a8: ldr x8,[x19,#0x78]
1003b42b0: bl 0x1000cef28              ; deregister SEID
1003b3970: ldr x8,[x19,#0x78]          ; cleanup traversal
1003b3974: ldr x0,[x8,x21]             ; per-entry capability pointer
1003b3978: bl 0x10075bc70             ; free
1003b3990: ldr x0,[x19,#0x78]          ; current parent table
1003b3994: bl 0x10075bc70             ; free
```

The destructor frees the **currently published** table and its per-entry capability arrays. On successful swap, v8.3 deliberately retains the old 192-byte *parent* block but does NOT duplicate or free its six children; the copied pointers in the new array remain their owners. This avoids immediate dangling aliases to old entries, but **does not prove safe concurrency/ownership for every possible cached pointer**.

## Experiment limitations

- Original low-level seven-slot init remains the v8.1 one-shot feature. v8.3 adds a second high-level seven-entry table only with BOTH v8.2 one-shot arms enabled.
- This is not a verified safe API; `+0x18` flag semantics, possible pointer caching, synchronization, other users of +0x6C, and later codec initialization remain risks.
- A successful allocation, SDP add or handler entry does NOT demonstrate live A2DP Sink reception.
- The v8.3 post-hook is allowed only on the exact UUID and exact four-instruction signature.
- `KILL-NATIVE-SINK-ACP` remains untriggered until a role-exclusion branch is proven. A protocol REJECT remains diagnostic evidence, not an automatic kill.
