# v7.1 receive-side foundation: complete RTP packets to stereo PCM

This is **new executable functionality** beyond v6 diagnostics. It is also deliberately
**not a working Windows-to-iPhone Bluetooth path**: the private incoming AVDTP media
callback has not been safely identified/hooked; Apple's Sink endpoint and SDP record
have not been registered. Audio services cannot safely be started from `bluetoothd`
under the observed sandbox restrictions.

## Code actually implemented

1. `BTPSMedia.h/c`: accepts a complete RTP v2 packet with an A2DP SBC payload and
   checks version, CSRC count, extension length, padding, SBC media frame count,
   frame boundaries, bitpool bounds and consistent channel/sample-rate settings.
   Fragmented SBC media is explicitly rejected, as is extra unparsed data.
2. `sbc_decode.c`: corrected the previously incorrect 3-byte SBC header accounting
   to include the mandatory fourth CRC byte both in frame-length calculations and
   bitstream positioning. This decoder's CRC check and bit-exact audio fidelity are
   **NOT verified**, so synthesized audio quality must not yet be trusted.
3. `BTPSMedia.c`'s `btps_media_decode_rtp_sbc`: decodes SBC frames into caller-owned,
   stereo-interleaved 16-bit PCM using the project's existing research decoder. PCM
   capacity is validated before any frame is decoded.
4. `SBCSink.mm`: `btphonosink_on_rtp_packet()` can feed such decoded PCM into the
   existing ring buffer, conditional on the audio engine having been started in an
   output-authorized process. **No daemon hook calls it yet**.
5. `tools/decode_rtp_sbc.py`: host-side offline converter of *one complete raw RTP
   packet* to a WAV for test data. This is not a PCAP/L2CAP capture parser. C compiler
   required; output is only an experimental decoding check.
6. `tests/test_media_packet.py`: compiles the real C code and tests framing, bounds,
   malformed data, extensions, padding, declared packet frame count and decoder
   output count.

## Next implementation gates

* Test optional SDP observer against the actual device and collect the exported
  `SDP_PROBE` logs without altering existing service records.
* Reconstruct the private service record registration ABI and lifetime rules from
  several callers. Identify a safe way to register a *real* A2DP Sink SEP without
  exhausting the six existing Source slots.
* Only after an actual remote peer sees Audio Sink SDP `0x110B` and can negotiate
  SetConfiguration, trace the incoming AVDTP/L2CAP **media** callbacks and route raw
  complete packets to this parser.
* Move decoded PCM through an explicit, bounded IPC channel to an audio-output
  process permitted to use the iPhone speaker. `bluetoothd` bootstrap probes have
  denied several audio services; direct `AVAudioEngine` inside it is not a viable
  assumption.
* Add CRC validation, codec fixture tests with known/reference output, sequence-loss
  handling, fragmentation/reassembly, jitter buffering and lifecycle recovery.

## Security notes

* Passive observer OFF by default; exact daemon UUID and first-four-instruction
  guard for the optional SDP hook. Existing hooks remain pass-through.
* No new AVDTP Sink endpoint is allocated in this build; no SDP advertising altered.
* No audio capture or cloud network upload occurs. iCloud export is a user-selected
  Files document picker in Settings.app; the tweak never gains iCloud permissions.
