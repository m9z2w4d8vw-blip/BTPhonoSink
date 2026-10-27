# BTPhonoSink v8.3 — post-Source audio context trial

**Experimental, changes private bluetoothd heap state, may break Bluetooth. NOT a working Bluetooth sink.**

v8.3 changes ONLY one experimental element relative to the working v8.2+TX build: after `+0x3B4128` (native Source registration and Source SDP publication) returns successfully, it allocates a seven-entry higher-level audio table, shallow-copies six entries, allocates a seventh SBC audio capability array, preserves the old six-entry parent allocation, sets both counts to seven, then registers one new low-level Sink SEP and adds the Sink SDP record. Incoming/outgoing AVDTP signaling hooks are unchanged. This remains OFF by default.

## Before trying

Keep a locally accessible .deb of the working v8.2+TX build. Make sure SSH works and you can access Dopamine/Sileo without Bluetooth. Do not test if the phone must have reliable Bluetooth for another purpose.

### Safe baseline

1. Install v8.3 package made by GitHub Actions (do not assume CI passing means the device can receive Bluetooth audio).
2. Leave **Arm seven slots for ONE restart** OFF, **Arm real Sink SDP + signaling ONCE** OFF, Legacy Sink OFF, extra SDP trace OFF, config lookup trace OFF.
3. Verify native headphone music plays and build identifies `v8.3-post-source-audio-context`. If not, restore v8.2 and stop.

### One-shot experiment

1. Disconnect headphones; save current working log if desired.
2. Enable **Arm seven slots for ONE restart** and **Arm real Sink SDP + signaling ONCE**. Leave other experimental switches OFF.
3. Use the phone's current SSH IP (it may differ from `10.5.82.212`):
   `ssh -t mobile@10.5.82.212 "sudo killall -9 bluetoothd"`
4. In Settings > BTPhonoSink > Debug Log, check for `V83 NATIVE_SOURCE_LOOP RETURN ret=0`, `V83 AUDIO_TABLE SWAPPED`, `V83 SEP RESULT ret=0 seid=7`, `V83 SDP add ret=0`. If any are missing/failed, **stop** and export that session's log. Do NOT rearm/restart repeatedly.
5. With the session still active, from Windows PowerShell run the previously verified SDP scanner to query the iPhone's actual Classic address `80:54:E3:94:45:F2`: `py -3.10 .\btps_windows_sdp_query_v2.py 80:54:E3:94:45:F2 --save`. A remote 0x110B match is only a prerequisite.
6. Attempt ONE Windows Bluetooth connection. iPhone debug log should show `V82 RX_SIGNAL`, `V82 TX_SIGNAL`, and raw packets for sink SEID 7. Compare `SET_CONFIGURATION` ACCEPT (`msg=2`) vs REJECT (`msg=3`) with matched CID/transaction labels. Do not claim native Sink works without Sink-directed SET_CONFIGURATION, OPEN, START and inbound media bytes.
7. Export the complete iPhone log **before** restarting the daemon.
8. Verify both one-shot switches are OFF, restart `bluetoothd` one more time with no trial armed, verify native headphone playback. If it fails, reinstall the known-working v8.2 .deb with Dopamine's available tweak-disabled/Sileo recovery route.

## What remains unproven

The new higher-level entry is built by cloning a native Source SBC capability layout and setting the same field at +0x18 to 1. Apple's complete semantics for that byte, pointer caching, all count+0x6C consumers, thread synchronization, and Sink-direction-specific codec setup are not proven. A success in `V83 AUDIO_TABLE SWAPPED` proves only local memory changes. Neither `KILL-NATIVE-SINK-ACP` nor full PASS can be determined without native response and actual Bluetooth media evidence.

## Source provenance

See `docs/V83_BINARY_PROVENANCE.md`. Exact bluetoothd SHA-256 and hook prologue signature included. No system binary is packaged.
