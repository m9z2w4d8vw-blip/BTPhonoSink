# BTPhonoSink — v6 detailed passive diagnostics

Research project for receiving Windows A2DP audio through classic Bluetooth on a jailbroken iPhone 13 (iOS 17, Dopamine/ElleKit, rootless arm64e), without Wi-Fi.

**Status: the iPhone is not yet an A2DP Sink.** This version collects better information without introducing unverified Sink endpoints or editing SDP records. Ordinary headphone output from the iPhone was reported working with v5 after restarting `bluetoothd`, with six native Source endpoints registering successfully.

## Current capabilities

| Area | Implementation / evidence |
|---|---|
| Guarded hooks in `bluetoothd` | 5 original entrypoints; specific daemon UUID and first-four-instruction checks |
| Native Source registrations | Observed and logged without modification; v5 device log showed six successes (SEIDs 1–6) |
| Capability inspection | Decode the observed private 16-byte array with media codec at byte `+2`, covering SBC/AAC/vendor |
| Session identity | Build tag, PID, startup session ID, hooks installed and source counts |
| Detailed callback diagnostics | Raw args, raw return codes, and elapsed µs for the first 25 calls of each observer hook |
| Log export | Settings debug view + clipboard copy; ~480 most recent lines per in-memory run; `/tmp/FTABHarvest` when sandbox permits |
| Source/Sink endpoint mutation | **Disabled** (no extra calls to register any endpoint) |
| Publish A2DP Sink SDP UUID `0x110B` | **Not implemented**; do not claim this from Source advertising callbacks |
| Receive audio frames / decode / play to iPhone | **Not implemented**; bundled decoder is not wired to a live stream |

### What changed from v5

- Fixed the incorrect codec decode (`record+2` instead of `record+4`), checked against your three native codec headers.
- Added portable bounded parser `BTPSDiagnostics.c` with FNV-1a fingerprint, category counts and explicit raw-return labeling.
- Added passive runtime timing/return-code traces for the existing registration, advertisement, configuration, SBC acceptance and audio publication hooks.
- Added a compact diagnostic checklist at the top of the Settings log view, session ID, once-per-minute heartbeat, and detection of potentially stale events.
- Expanded log retention to 480 lines; fixed a race when scheduling preferences flushes.
- Added the log triage script `python3 tools/triage_log.py exported.txt` and offline C unit tests.
- Added an optional read-only Windows PnP inspection script; it does not install drivers or alter pairing.

## Safe deployment and testing

Upload all contents of this repository to [BTPhonoSink on GitHub](https://github.com/m9z2w4d8vw-blip/BTPhonoSink), including `.github/`. The already configured GitHub Actions workflow runs tests, builds the rootless `.deb`, and publishes to the rolling [`nightly` release](https://github.com/m9z2w4d8vw-blip/BTPhonoSink/releases/tag/nightly) after commits to `main`.

**See [`TESTING-v6.md`](TESTING-v6.md) for exact steps and expected messages.** In particular verify `build: v6-detailed-observe`, all 5 hooks, six Source registrations, and working iPhone → headphone playback. Do not expect Windows → iPhone audio from this build.

Before changing installed tweaks, keep your working v5 `.deb` available. If the iPhone's normal Bluetooth is interrupted, stop the test, remove the experimental tweak, and restart the daemon through your usual jailbreak workflow. The five hooks are pass-through but still touch a system daemon; no zero-risk guarantee is possible.

## Offline developer commands

```sh
python3 -m unittest discover -s tests -v
python3 tools/sdp_record.py
python3 tools/triage_log.py path/to/BTPhonoSink-exported.txt
python3 tools/inspect_bluetoothd.py path/to/your/bluetoothd
```

The OI SDP builder requires private in-memory descriptors; the wire-format sample from `tools/sdp_record.py` must **not** be cast to the builder's pointer format. See [`docs/V6_SDP_AND_MEDIA_PLAN.md`](docs/V6_SDP_AND_MEDIA_PLAN.md) for next steps.
