# BTPhonoSink v7.6 — encoded SBC → decoded PCM → helper playback

**Research-only; still not a Bluetooth A2DP Sink.** Bluetooth daemon hooks remain passive, with normal Source functionality preserved; **never enable Legacy Sink**. This iteration builds upon v7.5's verified 258 RTP packet / 258 SBC frame transfer by adding an opt-in separate-helper decode-and-play test.

- Existing `BTPSAudioHelper --sbc`: transfer verification, compressed capture, **no sound**.
- New `BTPSAudioHelper --sbc-play`: same locally generated compressed fixture from `bluetoothd`; decode with a pinned Apache-2.0 Google SBC implementation in the helper; verify basic output levels; save stereo WAV; play through the helper's AVAudioSession. A short 440 Hz tone should be audible. These inputs are **not live RF/Bluetooth**.
- Does not enable SDP `0x110B`, register Sink SEP, receive media from Windows, or modify audio handling in `bluetoothd`.
- Original `sbc_decode.c` remains available for research, but it is not used by the helper only for packet-boundary parsing; its *PCM synthesis* is not invoked and its known fidelity defect remains tracked separately.

**[Testing instructions](TESTING-v7.6.md)** provide the exact GitHub build, SSH and iPhone sequence. GitHub Actions fetches source code pinned at `google/libsbc` commit `6e505650145c9973d08a0bdd5e5f5e1914305e40` before compiling the helper. See `btpsaudiohelper/vendor_sbc/README.md` for attribution/licensing; this ZIP does not include the upstream source snapshot itself. The GitHub Actions environment needs network access to fetch that pinned commit.
