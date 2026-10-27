# BTPhonoSink v7.8 — read-only AVDTP capacity audit

## Install
1. Apply the small patch to your existing v7.7 GitHub repository preserving paths, commit to `main`, and wait for GitHub Actions `make package` to succeed. Keep your known-good v7.7 and v7.6.1 `.deb` copies.
2. Install the newly built `.deb` using Sileo. In Settings -> BTPhonoSink, keep **Legacy Sink OFF**, **Trace existing SDP records OFF**. The v7.7 trial toggle has been removed because it is no longer safe or useful to repeat.
3. Restart Bluetooth if the tweak does not reload: `ssh -t mobile@10.5.82.212 "sudo killall -9 bluetoothd"` (update IP if changed).
4. Reconnect Bluetooth headphones and verify music plays. In debug log look for `build: v7.8-readonly-capacity-audit`, `5 / 5` hooks, `6 / 6` native Sources, and `V78_TABLE RESULT`.
5. Export debug log to iCloud Drive. Send `diag.v78_table`, `diag.capacity`, the `V78_TABLE slot[...]` lines, and report headphone behavior.

**Expected** (not guaranteed until device test): `V78_TABLE RESULT slots=6 occupied=6 free=0 nextSEID=7 duplicates=0`. If table metadata is unreadable, report that exact result; do not try injecting another endpoint. The 0x68 meaning inferred from static disassembly does not prove a workaround exists.

## Recovery
For crashes or no Bluetooth audio, restore v7.7 with its experiment OFF (or v7.6.1); restart daemon. This build performs NO extra registration calls.
