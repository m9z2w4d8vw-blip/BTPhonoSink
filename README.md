# BTPhonoSink v7.5 — Compressed SBC RTP transport research

BTPhonoSink is an experimental rootless ElleKit/Theos tweak for iPhone 13 on iOS 17.0 (Dopamine 3). The long-term goal is to receive Windows laptop A2DP audio and play it on the iPhone. **This is not a functioning A2DP Sink yet.**

**Start here:** [TESTING-v7.5.md](TESTING-v7.5.md).

## What is confirmed from the user's device tests?

- v7.4: The `bluetoothd` process successfully sent 70,560 bytes of synthetic PCM over 127.0.0.1 to `BTPSAudioHelper`; the helper acknowledged it, completed playback, and the user heard the 880 Hz tone.
- v7.4: 5/5 baseline hooks installed, six native Source endpoints registered, and the outgoing headphone path continued to work.
- v7.1–7.3: optional pass-through SDP observer saw local Audio Source (`0x110A`) record creation, not a Sink (`0x110B`) record. That is not an external discoverability test.

## Added in v7.5

- Compile a 15,996-byte, FFmpeg-encoded 440 Hz stereo SBC/RTP fixture into the `bluetoothd` tweak; the fixture contains **258 sequenced RTP packets and 258 valid SBC frames**.
- Add **Send Compressed SBC from bluetoothd (v7.5)** to Settings. It must be explicitly requested using a fresh token; the send runs on an independent worker queue with network timeouts.
- Extend `BTPSAudioHelper` with `--sbc` mode. The helper verifies the versioned message, exact payload size, token, CRC32, RTP sequence numbers and timestamps, profile metadata, SBC frame boundaries, and session identifiers. It extracts the compressed bitstream to a timestamped `.sbc` file under the mobile user's Documents directory.
- Export `diag.v75_sbc` status along with the previous v7.4 status using **Save Log to iCloud Drive**.
- Preserve the v7.4 `--daemon` (880 Hz) PCM and v7.3 default (660 Hz) PCM paths as separate tests.

**This fixture is generated offline and lives inside `bluetoothd`; it does not arrive over Bluetooth.** The new `--sbc` test **does not play audio**, decode SBC, register Sink SDP UUID `0x110B`, register an AVDTP Sink endpoint, or intercept incoming L2CAP data. Keep **Legacy Sink OFF** and optional SDP tracing OFF initially. The custom `sbc_decode.c` has a known severe clipping defect and remains excluded from v7.5 playback.

## Offline verification

Run `python3 -m unittest discover -s tests -v`. The regression suite includes native compiled tests for v7.5's compressed protocol, C fixture-to-binary equivalence, packet sequence continuity, and malformed-frame rejection, plus the previous hooks, PCM and SDP checks. The SBC PCM fidelity regression remains marked as one **expected failure** until fixed; an expected failure is not a passing decoder.

GitHub Actions runs these tests, builds a rootless `arm64e`-capable package, checks for the helper executable and publishes the `.deb` to the `nightly` release after a push to `main`.

For architecture and earlier testing details, see `docs/`, `TESTING-v7.4.md`, `TESTING-v7.3.md`, `TESTING-v7.2.md`, `TESTING-v7.1.md`.
