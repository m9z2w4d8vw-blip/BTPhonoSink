# Next implementation stage: A2DP Sink discovery and incoming audio

## On-device evidence from the user's v5 debug log

- Tested `bluetoothd` image UUID `5491BA47-B5AE-3D44-9536-B30161DF1E90`; all five `pacibsp` entrypoint hooks installed and returned to original functions.
- Six native AVDTP **Source** endpoint registrations returned 0; assigned SEIDs 1..6.
- Capability headers from those calls: `07 00 00 04 00` (SBC), `07 00 02 06 00` (AAC), `07 00 ff 0e 00` (vendor-specific), each occurring twice. The codec identifier is byte `+2`; byte `+4` is zero in these captures and was incorrectly decoded by v5.
- `advertise_A2DP_source` was called twice; these observations do **not** mean Audio Sink UUID `0x110B` is published.
- The project has not registered or published a Sink in v5/v6. Headphone playback from iPhone works in the user's test after restarting `bluetoothd`.
- In-process probes of `AURemoteIOServer`, `AudioQueueServer`, `AudioComponentRegistrar` returned bootstrap error 1100 (sandbox denied). The `AudioSession` probe was reachable; this does not prove usable playback.

## Static evidence from the supplied iOS 17 bluetoothd binary

- The `AVDTP_RegisterMultipoint` entry is image+`0x0CECF0`; disassembly at `0x0CEEE8` performs a byte store of SEID (`strb w8, [x19]`) through argument x5.
- Its slot-search path advances by `0x28` bytes and loads `0x68` on one registration-failure path. v4's failure after interleaving Sinks is consistent with exhaustion, but *slot count and meaning of every error code need further runtime proof*.
- Near image+`0x0AB990`, code prepares x0=sp, x1=pointer and calls image+`0x1E8E78`. The same branch logs `OI_SDPDB_AddServiceRecord failed` if nonzero. This is a **candidate** private record-add function. The memory descriptor layout and owner lifetimes are not sufficiently verified to call it safely.
- Existing Source advertising at image+`0x44DF14` constructs data involving UUID `0x110A`. Do not replace `0x110A` with `0x110B`; that would degrade existing Source advertising.

## Implementation gates (in order)

1. **Protect the baseline**: observe six native Source registrations and verify normal headphones work on every build. No new endpoint calls until a free slot or a safe registered Source trade-off is demonstrated.
2. **Reverse SDP builder**: inspect multiple confirmed caller sites of the potential AddServiceRecord routine. Determine exact record and attribute representation, callback/release semantics, service lifetime, and error status values before adding any registration code.
3. **Prove available AVDTP Sink SEP**: a Windows SDP record alone is not enough; Windows must also find a Sink SEP that can accept configuration. Explore safe capacity strategy offline; never patch an array length alone.
4. **Publish SDP**: use a confirmed live record API with `Audio Sink 0x110B`, audio profile `0x110D`, L2CAP PSM `0x0019` and an AVDTP protocol descriptor. Verify from Windows/another peer. Only enable behind an explicit *new* experimental gate after separate fail-safe tests.
5. **Receive audio**: trace AVDTP/L2CAP media callbacks and packet boundaries; validate RTP sequence number/CSRC/extension/header length and SBC frame count, negotiate supported codecs, queue and decode frames without changing outgoing Bluetooth.
6. **Play PCM in a permitted audio process**: because bluetoothd is sandbox-restricted for several audio services, design an IPC boundary to a trusted helper with access to the output path. Do not add unverified AVAudioEngine startup code directly to bluetoothd.

v6 implements only Gate 1 (more detailed observation) and offline SDP data-element generation tests. Its `tools/sdp_record.py` creates wire-format SDP elements, **not** the private OI record descriptor required by the suspected `AddServiceRecord` routine. The existence of source-level `SBCSink.mm` and `sbc_decode.c` does not mean the media path is wired or tested on iOS.
