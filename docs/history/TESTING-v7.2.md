# Speaka v7.2 — verified test sequence

1. Keep **Legacy sink experiment flag** OFF (it must NEVER be enabled).
2. Keep your prior working v7.1 `.deb` for rollback.
3. Upload the full v7.2 repository to GitHub, including `.github/`, and ensure
   that the latest Actions build **passes**. Do not install a failed build.
4. Install the latest versioned `.deb` from `nightly` in Sileo. Fully close and
   reopen Settings. Confirm `build: v7.2-sdp-checklist`.
5. Explicitly switch **Trace existing SDP records (advanced)** OFF first,
   because a previous v7.1 setting may persist after upgrade. Restart `bluetoothd` once
   using `ssh -t mobile@10.5.79.217 "sudo killall -9 bluetoothd"` from Windows.
   This briefly interrupts all Bluetooth connections; daemon should relaunch.
6. Reconnect your Bluetooth headphones. **Listen to a real music clip**. If
   playback fails, disable the tweak, restart daemon, and restore v7.1.
7. Open `Debug log` > **Verify Test Checklist**. Confirm 5 hooks / 6 Sources
   and Legacy OFF. Optional SDP will show NOT ENABLED; this is expected.
8. **Disconnect headphones**. Tap **Test iOS Audio Output (440 Hz)** and
   confirm a short tone is actually audible on the iPhone speaker. If the
   alert says successful but you hear nothing, report that distinction.
9. Turn ON **Trace existing SDP records (advanced)**, restart `bluetoothd`
   again, then check the checklist for optional SDP observer and the local
   `0x110A` Source record add. Verify headphone playback again.
10. Tap **Save Log to iCloud Drive…** and upload the `.txt` file here. Tell me:
    (a) whether headphones worked both times; (b) whether the test tone was
    audible on the phone; and (c) your GitHub Actions build link.

**Do not enable Legacy Sink**, do not expect Windows to discover the iPhone as
an A2DP speaker yet, and do not claim `0x110B` is remotely advertised just
because a local callback ran. Bluetooth Sink endpoint and incoming media remain
unimplemented. The bundled SBC decoder has a known quality defect and must not
be trusted for playback until it passes reference audio comparison.
