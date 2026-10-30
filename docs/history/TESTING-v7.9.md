# Speaka v7.9 — read-only allocation geometry audit

This build **does not expand endpoint capacity**. It validates the existing initializer's
allocation sizes and configured counts on the device, before attempting any write in a future
build. The v7.7 Sink trial remains retired and cannot run, even if a preference is still ON.

1. Apply `Speaka-v7.9-patch.zip` file contents **inside their matching folders**
   in your current GitHub repository. If using GitHub web upload, do not upload the ZIP itself:
   upload individual changed files, including `.github` only if present in this patch.
2. Commit to `main`, confirm GitHub Actions is green, install the new `.deb` via Sileo.
   Preserve your working v7.8 `.deb` for rollback.
3. Set **Legacy Sink = OFF** and **Trace existing SDP records = OFF**. There is no active
   Sink trial switch in v7.9.
4. Restart bluetoothd **once** if the new build's log is stale:

   ```powershell
   ssh -t mobile@10.5.82.212 "sudo killall -9 bluetoothd"
   ```
   Update the IP if you changed Wi-Fi networks.
5. Reconnect your headphones and confirm actual audio plays normally. Open Settings →
   Speaka → View debug log. Expect `v7.9-readonly-allocator-audit`, five baseline hooks,
   six native Source registrations, plus `V78_TABLE RESULT` and `V79_ALLOC RESULT`.
6. Look for `diag.v79_allocator: READ-ONLY config=(...) live=(...) request_bytes=(...)`.
   `config=(6,...)` and `live=(6,...)` would confirm the allocation's first dimension;
   the remaining two counts have not yet been observed. A mismatch or `UNREADABLE` is a
   useful diagnostic; **do not** switch on old Sink experiments to compensate.
7. Save the debug log to iCloud Drive and send it with a note confirming whether headphones play.

Expected: no new audio tone and no new Windows Bluetooth device. Previous compressed SBC
helper playback is preserved but does not need re-testing.

**Recovery:** if Bluetooth playback regresses, restore the v7.8 package and restart the daemon.
