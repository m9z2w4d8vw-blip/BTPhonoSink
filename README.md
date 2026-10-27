# BTPhonoSink v7.8 — read-only AVDTP endpoint capacity audit

The iPhone's v7.7 extra A2DP Sink SEP request returned **0x68** and SEID **0** after all six Source SEPs succeeded. Disassembly of the exact device `bluetoothd` at image+`0xCECF0` shows that `0x68` is the default return when the routine exhausts its candidate-SEID/slot search without finding a free slot.

**v7.8 is passive.** It DISABLES the v7.7 one-shot Sink registration even if the old switch is stored as ON. Following successful registration of Apple's six normal Sources, it safely reads the private table pointer, count, SEID cursor, and up to 32 endpoint records, and logs occupancy (0x28-byte stride, nonzero byte at +0x19). It does not change the table, add endpoints or SDP services, receive live media, or affect the proven PCM/SBC helper pipeline.

The read is gated on the exact binary UUID, and six hardcoded instruction-word signatures must match the **same** binary. An unexpected pointer, large table, or unreadable page aborts the snapshot without a crash. Unsupported firmware produces an `UNAVAILABLE` status.

[Disassembly and reason for 0x68](docs/V78_AVDTP_CAPACITY_FINDINGS.md) | [Testing procedure](TESTING-v7.8.md).

**Workarounds under investigation, not yet implemented:** separate/sidecar AVDTP service outside Apple's fixed endpoint array (requires private controller access); deliberate reduction of redundant native Source registrations (would sacrifice native profiles and is risky); changing Apple stack allocation and count (requires understanding allocation, owners, lifetimes and all usages, not just patching a counter). We will not write past the current allocation.
