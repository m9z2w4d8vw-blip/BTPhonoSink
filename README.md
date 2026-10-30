> Current version: **v8.9.4** (wired earbuds without replugging, no reconnect after switching outputs; see
> [TESTING-v8.9.4.md](TESTING-v8.9.4.md)) on v8.9.3 (complete logs; see [TESTING-v8.9.3.md](TESTING-v8.9.3.md)) on
> v8.9.2 (fixes Start;
> see [TESTING-v8.9.2.md](TESTING-v8.9.2.md)), on top of
> **v8.9 one-tap Start/Stop and audio output selection** ([TESTING-v8.9.md](TESTING-v8.9.md)). Settings > BTPhonoSink > **Start** now arms the trial and restarts
> Bluetooth for you (no PowerShell), and **Audio output** chooses the speaker, headphones or any device.
> The streaming design is v8.8's: [TESTING-v8.8.md](TESTING-v8.8.md) covers architecture, logs, and limits.
> Earlier sections below describe previous research stages.

# BTPhonoSink v8.2 — opt-in native A2DP Sink signaling research

This source incorporates the prior v8.1 verified 7-slot initialization shadow and adds one gated **real Sink-role (TSEP=1) SEP registration**, a separate long-lived local `0x110B` SDP record, and raw RX logging of native AVDTP **signaling**. Both independent one-shot switches must be explicitly armed; default behavior preserves the previous passive hooks. Rootless tweak targets the *exact* supplied iOS 17.0 `bluetoothd` SHA-256 and LC_UUID.

**No claim of functionality:** RX commands do not prove TX acceptance, SEP state transitions, or arrival of media bytes. The final native-Sink feasibility verdict remains **INCONCLUSIVE** without a remote negotiation and media-channel evidence. A successful `.deb` build also provides no evidence of live Bluetooth functionality.

Read `TESTING-v8.2.md` and `PROVENANCE-v8.2.md` before attempting a trial. Preserve your known working v8.1 package and recovery access. The underlying Apple private API is not supported and can destabilize Bluetooth.
