# Static disassembly landmarks

All addresses are **image-relative**; add `0x100000000` for the unslid Mach-O VM addresses of this binary.

- `0x0CECF0`: AVDTP_RegisterMultipoint (verified PAC instruction, 4-word signature).
- `0x0CED14`: `mov x19, x5` retains sixth parameter.
- `0x0CEDD4..0x0CEDDC`: validate x5, caps pointer and number of caps.
- `0x0CEDE4..0x0CEE08`: load endpoint table state; `state+0x60` carries the number of slots considered by the loop.
- `0x0CEE30..0x0CEE38`: advance candidate by `#0x28` (40-byte entry).
- `0x0CEE14`: load status 0x68 for failed registration.
- `0x0CEEE8`: `strb w8, [x19]`, demonstrating **one-byte** SEID output via sixth parameter.
- `0x0AB990..0x0AB99C`: passes x0=sp and x1 to `bl 0x1001E8E78` near error message “OI_SDPDB_AddServiceRecord failed”; exact private ABI needs additional call-site tracing.
- `0x44E170`: writes class UUID `0x110A` for Source; directly switching it to `0x110B` would remove an existing Source advertisement and is not an acceptable sink-only implementation.

**Critical limitation:** this does not demonstrate how much memory was allocated for the endpoint array, whether the SDP “add” routine is initialized at an arbitrary hook call, or how to publish an audio playback path. Do not change capacity fields blindly or call unknown ABI pointers.

## Additional SDP ABI evidence from disassembly (not a complete API contract)

At `image+0x0AB888`, the daemon constructs a 32-byte temporary SDP record descriptor:

- `sp+0x00`: pointer to attribute array (`0x10091A078` in the unslid image).
- `sp+0x08`: 16-bit attribute count = 3.
- `sp+0x10`: pointer loaded from the data structure at `0x10096DD78`.
- `sp+0x18`: 16-bit count loaded from `0x10096DD80`.

It later calls `0x1001E8E78` with `x0=sp`, `x1=out_handle_pointer` at `image+0x0AB998`. The callee allocates an `0x50`-byte internal node, copies the pointer/count pairs into fields at `+0x10/+0x18` and `+0x20/+0x28`, and writes a 32-bit record handle through x1 if non-NULL. It retains pointers, rather than deep-copying the attribute array in its entry path, making record lifetime/ownership a critical issue. It returns zero on apparent success and error codes on failures.

The callee scans the first array's 24-byte attribute descriptors to locate ServiceClassIDList (`0x0001`). This supports (but does not definitively prove) the provisional signature `OI_STATUS AddServiceRecord(const RecordDescriptor *record, uint32_t *handle)`. Before using this in a tweak, verify the attribute data-element structure and a known-good native Source publisher; a wire-format SDP sequence cannot simply be supplied as `RecordDescriptor`.
