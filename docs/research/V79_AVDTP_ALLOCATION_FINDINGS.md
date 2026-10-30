# v7.9: Where the six-entry AVDTP table comes from

**Evidence:** User-provided iOS 17.0 `bluetoothd`, SHA-256
`e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6`, UUID
`5491BA47-B5AE-3D44-9536-B30161DF1E90`. Analyzed with
`llvm-objdump --disassemble --start-address=0x1000ce3f8 --stop-address=0x1000ce550 bluetoothd`
and `--start-address=0x1001f5f20 --stop-address=0x1001f5f68`.

## What static disassembly actually proves

The initializer around image offset `0xCE3F8` obtains **configuration index 3** and allocates:

| image offset | instruction | consequence |
|---|---|---|
| `0xCE3F8` | `mov w0, #3` | Select configuration index 3 |
| `0xCE3FC` | `bl 0x1001f5f20` | Receive pointer to configuration data in x0 |
| `0xCE408` | `mov w0,#0x68` | Request a 104-byte private context object |
| `0xCE40C` | `bl 0x1000aa09c` | Private wrapper around allocator |
| `0xCE414` | `str x0,[x27,#0x8b0]` | Save context pointer in private global |
| `0xCE41C` | `ldrb w8,[x23]` | Read endpoint-table count from config byte zero |
| `0xCE420`, `0xCE424` | `add x8,x8,x8,lsl #2`; `lsl x0,x8,#3` | Compute **count × 40 bytes** |
| `0xCE428` | `bl 0x1000aa09c` | Allocate endpoint array via private wrapper |
| `0xCE434` | `str x24,[x0]` | Save endpoint-array pointer to context+0 |
| `0xCE448`–`0xCE464` | initialization loop | Zero each endpoint's byte +0x19 (SEID slot marker) |
| `0xCE468`–`0xCE474` | second count, `x8 + x8*8`, `<<4` | Request config byte 1 × **144 bytes** |
| `0xCE480` | `str x8,[x0,#8]` | Save second allocation pointer to context+8 |
| `0xCE4D0`–`0xCE4D8` | config byte 2 × **64 bytes** | Request third allocation |
| `0xCE4E8` | `str x8,[x0,#0x10]` | Save third allocation pointer to context+16 |
| `0xCE4F4` | `strb w8,[x0,#0x60]` | Persist config byte 0 as the **live endpoint count** |
| `0xCE4F8` | `ldurh w8,[x23,#1]` | Fetch config bytes 1 and 2 |
| `0xCE4FC` | `sturh w8,[x0,#0x61]` | Persist other two live counts |

The getter at image+`0x1F5F20` uses a pointer table at image+`0x984a48`; for index 3,
`0x984a48 + 3*8 = 0x984a60` is the configuration pointer entry.
The private allocator wrapper at image+`0xAA09C` forwards to an allocator abstraction. The
actual heap ownership, memory-zone behavior and lifetime still need analysis. **An allocation
request size is NOT proof of the allocator's physical usable capacity.**

## New on-device read-only check

After six normal Source endpoint registrations, v7.9:

1. Verifies the exact build UUID and twelve exact instructions across initializer/getter.
2. Reads, without calling, the configuration pointer at image+`0x984a60`.
3. Reads only three config bytes, three count bytes at context+`0x60`, and the three table pointers.
4. Compares configured and live counts; reports requested allocation byte lengths (40/144/64 strides), and whether required table pointers exist.
5. Leaves all allocations, pointers, private configuration, SEIDs, SDP and registered endpoints **unchanged**.

A possible log looks like:

```
V79_ALLOC RESULT config=(6,?,?) live=(6,?,?) request_bytes=(240,?,?) match=yes missing_mask=0; READ ONLY
```

The extra counts are unknown until the iPhone runs the audit. The example is *not* a device result.

## Implications and next research

A carefully placed intervention at initialization might supply a larger configuration count,
causing the daemon to allocate and initialize a bigger endpoint array in its existing code.
That would be structurally preferable to increasing only context+`0x60` at runtime.
However we must first trace (a) where configuration block 3 originates, (b) whether it is
immutable/shared with other components, (c) the initialization/error cleanup paths and
(d) whether any parallel count / slot assumptions elsewhere prevent expansion.

**Do NOT yet patch config byte 0 or install a hook on either the config getter or allocator.**
We have only established the allocation arithmetic, not the safety or lifecycle of a new count.
No new SDP record or audio receive mechanism is implemented in v7.9. The new module performs no allocation and makes no private initializer calls.
