# BTPhonoSink v7.7 — experimental AVDTP Sink SEP capacity trial

**A2DP Sink is not functional yet.** This build preserves v7.6.1's verified prerecorded-SBC → daemon IPC → helper decode/playback tests, and adds a **separately gated, OFF-BY-DEFAULT, one-shot** AVDTP Sink SEP registration test. This is an invasive private-stack experiment and may disrupt Bluetooth if enabled. Follow [TESTING-v7.7.md](TESTING-v7.7.md) and keep the known-working v7.6.1 `.deb` for rollback.

- Default: 5 passive hook observers and six normal Apple Source endpoints, **no additional registration**.
- Legacy Sink remains **inactive**, even if its old preference is ON. The separate "Trial extra Sink endpoint (advanced)" switch requires Legacy Sink OFF.
- When that switch is ON *before restarting bluetoothd*, after six successful native Source registrations this build prepares private SBC capabilities copied into permanent, distinct storage, and calls the original AVDTP registration trampoline **once** with `TSEP=Sink`, a fresh one-byte SEID output and `count=1`. It logs the raw return code and assigned SEID without interpreting private status semantics as definitive success.
- The trial cannot run unless the exact analyzed `bluetoothd` UUID is present, every baseline trampoline was installed, no Source registration failed, stable SBC capabilities were captured, and the switch was enabled at daemon startup.
- No SDP Audio Sink UUID `0x110B` is advertised. No live AVDTP media input/negotiation to helper is connected. The Windows laptop won't see a functional Bluetooth speaker from this update.
- Existing `--sbc-play` and other helper modes are unchanged; no third-party decoder files are added to the upload. GitHub Actions still fetches pinned libsbc before the iOS build.

This experiment is intended to measure whether a seventh SEP can be registered **without preempting Apple's native six Sources**, a question the earlier v4 injection experiments couldn't safely answer. If the native table is full, a nonzero return is likely; keep the exact code rather than guessing at its meaning.
