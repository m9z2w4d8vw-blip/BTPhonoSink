# BTPhonoSink v7.9 — read-only Bluetooth endpoint allocation research

The iPhone's AVDTP stack currently registers six native A2DP Source endpoints and the v7.7
seventh Sink trial returned `0x68`. v7.8 verified **6/6 occupied endpoint slots**.

The exact device's `bluetoothd` binary additionally shows that initialization reads
**configuration block 3** and allocates three arrays sized **config[0]×40**,
**config[1]×144**, and **config[2]×64** bytes. The first requested size is the endpoint
array. v7.9 reads the original three configuration bytes and the corresponding live state,
without changing anything, so we can establish how the endpoint capacity is provisioned.

**There is NO slot expansion, Sink registration, SDP 0x110B publication or live Bluetooth
reception in v7.9.** Legacy Sink remains disabled. All five passive hooks, the optional
read-only SDP observer (OFF by default), original headphones behavior, iCloud export, and
previous manually triggered IPC/SBC helper playback tests are preserved.

- [v7.9 testing instructions](TESTING-v7.9.md)
- [Disassembly-based allocation research](docs/V79_AVDTP_ALLOCATION_FINDINGS.md)
- [v7.8 endpoint search and error 0x68](docs/V78_AVDTP_CAPACITY_FINDINGS.md)
