# BTPhonoSink v8.0 — optional read-only config lookup timing observation

**No Bluetooth Sink has been implemented.** v7.9 verified that the three allocation
counts match `(6,3,3)` at runtime. The next question is whether our injected tweak
can see the configuration getter call for index 3 **before** native endpoints are
registered. This build provides one additional, OFF-by-default pass-through hook
at the exact build-verified getter entry `bluetoothd+0x1f5f20`.

This observer logs the getter's unchanged result and the three existing count bytes.
It does not expand the table, modify memory, change SDP, or receive Bluetooth media.
The existing five working hooks and read-only v7.8/v7.9 diagnostics remain unchanged.

See `TESTING-v8.0.md` for instructions. Keep both legacy Sink and SDP tracing OFF.

# BTPhonoSink v8.0 — read-only Bluetooth endpoint allocation research

The iPhone's AVDTP stack currently registers six native A2DP Source endpoints and the v7.7
seventh Sink trial returned `0x68`. v7.8 verified **6/6 occupied endpoint slots**.

The exact device's `bluetoothd` binary additionally shows that initialization reads
**configuration block 3** and allocates three arrays sized **config[0]×40**,
**config[1]×144**, and **config[2]×64** bytes. The first requested size is the endpoint
array. v8.0 reads the original three configuration bytes and the corresponding live state,
without changing anything, so we can establish how the endpoint capacity is provisioned.

**There is NO slot expansion, Sink registration, SDP 0x110B publication or live Bluetooth
reception in v8.0.** Legacy Sink remains disabled. All five passive hooks, the optional
read-only SDP observer (OFF by default), original headphones behavior, iCloud export, and
previous manually triggered IPC/SBC helper playback tests are preserved.

- [v8.0 testing instructions](TESTING-v8.0.md)
- [Disassembly-based allocation research](docs/V79_AVDTP_ALLOCATION_FINDINGS.md)
- [v7.8 endpoint search and error 0x68](docs/V78_AVDTP_CAPACITY_FINDINGS.md)
