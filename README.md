# BTPhonoSink v7.2: SDP observer + media foundation + iCloud export

The v7.2 build preserves all five v6 baseline hooks and **does not** add an A2DP Sink endpoint or SDP 0x110B record. In Settings, a new OFF-by-default switch enables an **additional** pass-through hook that logs the daemon's *existing* SDP record-add metadata. Switch ON and restart `bluetoothd` **once** if choosing the advanced test; turn OFF and restart to recover the safe v6 baseline. See `TESTING-v7.1.md`.

# BTPhonoSink — v7.1 combined development build

Research project for receiving Windows A2DP audio through classic Bluetooth on a jailbroken iPhone 13 (iOS 17, Dopamine/ElleKit, rootless arm64e), without Wi-Fi.

**Status: the iPhone is not yet an A2DP Sink.** This version collects better information and adds an offline-testable media receive/decoder building block without introducing unverified Sink endpoints or editing SDP records. The user's v6 device log confirmed six successful native Source endpoint registrations, an SBC configuration and audio publication callback, and a live daemon heartbeat. Prior testing confirmed headphone output can work after restarting `bluetoothd`.

## Current capabilities

| Area | Implementation / evidence |
|---|---|
| Guarded hooks in `bluetoothd` | 5 original entrypoints; specific daemon UUID and first-four-instruction checks |
| Optional SDP observer | OFF by default; guarded sixth pass-through hook inspecting existing SDP record-add metadata |
| Native Source registrations | Observed and logged without modification; v5 device log showed six successes (SEIDs 1–6) |
| Capability inspection | Decode the observed private 16-byte array with media codec at byte `+2`, covering SBC/AAC/vendor |
| Session identity | Build tag, PID, startup session ID, hooks installed and source counts |
| Detailed callback diagnostics | Raw args, raw return codes, and elapsed µs for the first 25 calls of each observer hook |
| Log export | Settings debug view + clipboard copy; ~480 most recent lines per in-memory run; `/tmp/FTABHarvest` when sandbox permits |
| Source/Sink endpoint mutation | **Disabled** (no extra calls to register any endpoint) |
| Publish A2DP Sink SDP UUID `0x110B` | **Not implemented**; do not claim this from Source advertising callbacks |
| RTP/SBC media depacketizer and decoding adapter | **Implemented, offline-tested**; handles complete RTP packets and produces PCM, but no live Bluetooth receive hook yet |
| Receive live audio / play on iPhone | **Not implemented**; SDP/SEP/media transport/authorized playback helper still missing |
| iCloud log export | Settings uses native Files picker to save a timestamped `.txt` snapshot to user-selected iCloud Drive folder |

### What changed in v6 and v7.1

- Fixed the incorrect codec decode (`record+2` instead of `record+4`), checked against your three native codec headers.
- Added portable bounded parser `BTPSDiagnostics.c` with FNV-1a fingerprint, category counts and explicit raw-return labeling.
- Added passive runtime timing/return-code traces for the existing registration, advertisement, configuration, SBC acceptance and audio publication hooks.
- Added a compact diagnostic checklist at the top of the Settings log view, session ID, once-per-minute heartbeat, and detection of potentially stale events.
- Expanded log retention to 480 lines; fixed a race when scheduling preferences flushes.
- Added the log triage script `python3 tools/triage_log.py exported.txt` and offline C unit tests.
- Added an optional read-only Windows PnP inspection script; it does not install drivers or alter pairing.
- **v7:** Added separately opt-in SDP record-add observer at the verified entry `0x1e8e78`. Inspects descriptor lists, attribute IDs/types, a tentative service class ID, raw return, and assigned record handles, without modifying any SDP record or AVDTP registration.

- **v7.1:** Added a native iOS Files export button in the Settings debug view, a bounded RTP/SBC media depacketizer and offline-tested decoder entry point. Fixed the SBC frame header length and CRC-byte position. See `docs/V7_1_MEDIA_PATH.md`.

## Safe deployment and testing

Upload all contents of this repository to [BTPhonoSink on GitHub](https://github.com/m9z2w4d8vw-blip/BTPhonoSink), including `.github/`. The already configured GitHub Actions workflow runs tests, builds the rootless `.deb`, and publishes to the rolling [`nightly` release](https://github.com/m9z2w4d8vw-blip/BTPhonoSink/releases/tag/nightly) after commits to `main`.

**See [`TESTING-v7.1.md`](TESTING-v7.1.md) for exact two-stage steps and expected messages.** In particular verify `build: v7.1-sdp-media-foundation`, all 5 baseline hooks, six Source registrations, and working iPhone → headphone playback before enabling the separate observer. Do not expect Windows → iPhone audio from this build.

Before changing installed tweaks, keep your working v6 `.deb` available. If the iPhone's normal Bluetooth is interrupted, stop the test, remove the experimental tweak, and restart the daemon through your usual jailbreak workflow. The five hooks are pass-through but still touch a system daemon; no zero-risk guarantee is possible.

## Offline developer commands

```sh
python3 -m unittest discover -s tests -v
python3 tools/sdp_record.py
python3 tools/triage_log.py path/to/BTPhonoSink-exported.txt
python3 tools/inspect_bluetoothd.py path/to/your/bluetoothd
```

The OI SDP builder requires private in-memory descriptors; the wire-format sample from `tools/sdp_record.py` must **not** be cast to the builder's pointer format. See [`docs/V6_SDP_AND_MEDIA_PLAN.md`](docs/V6_SDP_AND_MEDIA_PLAN.md) for next steps.

## v7.2: device-side test checklist and output-process probe

This version adds a **Verify Test Checklist** button on the Debug log screen. It
checks the *current reported session* for the expected v7.2 build, five hooks,
six native Source registrations, Legacy Sink OFF, and optional SDP observation.
Headphone audibility must still be confirmed by a human; a successful callback
alone cannot prove sound.

A **Test iOS Audio Output (440 Hz)** button produces a known-good PCM/WAV test
signal in **Preferences.app**, using AVAudioPlayer. Disconnect headphones to
hear it on the built-in speaker. This tests a non-bluetoothd process's output
path, not SBC decoding or Windows-to-iPhone Bluetooth receiving. The result is
included in exported debug logs (reported API completion, NOT evidence it was
heard).

SDP observation now separately records when a locally observed `0x110A` Audio
Source record-add returned success and if a `0x110B` class candidate ever does.
These do **not** establish the remotely visible SDP catalog; a peer query is
still required to confirm real discoverability.

### Important decoder validation finding

While preparing a packet-level playback test, an **actual ffmpeg-encoded 440 Hz
SBC clip** was fed through the existing `BTPSMedia`/`sbc_decode.c` path. The
current research decoder produced **>99% samples clipped** and did not
reconstruct the 440 Hz tone. Earlier packet tests only checked successful
parsing and sample counts, not audio fidelity. **Do not activate the live RTP
receive hook** until the decoder is replaced or validated against known-good
reference PCM and CRC/bit allocation cases. The Settings audio test deliberately
uses uncompressed PCM to isolate iOS output access from decoder correctness.
