# BTPhonoSink v7 — optional SDP registration observation

This version adds **zero AVDTP Sink endpoints**, publishes **zero 0x110B SDP records**, and does **not** receive/play Bluetooth media. It preserves the five working v6 hooks. It adds a separately opt-in, **sixth pass-through hook** for an iOS 17 private SDP record-add routine, researched from the exact `bluetoothd` image in `BTPSBuild.h`.

## Stage 1 — verify safe baseline (SDP observer OFF)

1. Back up the working v6 `.deb`. Extract this repository ZIP, upload its contents (including `.github`) to your GitHub repo, commit, and verify GitHub Actions builds a new `.deb` successfully. Download the newly built `.deb` from the `nightly` release, checking its version/date.
2. Keep **Trace existing SDP records (advanced)** **OFF** (the default) in Settings > BTPhonoSink. Install the new `.deb` and restart `bluetoothd` **once** to load it: `ssh -t mobile@10.5.79.217 "sudo killall -9 bluetoothd"` (only if the iPhone is still reachable at that IP). Reboot/re-jailbreak with Dopamine if necessary.
3. Check Debug log: `build: v7-sdp-probe`, five original hooks installed, six native Sources accepted with SEIDs 1..6, and `diag.sdp_probe: OFF (default); no SDP hook installed`. Confirm Bluetooth headphone playback still works. If anything fails, **do not proceed to Stage 2**.

## Stage 2 — experimental passive SDP observer (opt-in)

4. Switch **Trace existing SDP records (advanced)** ON. Do **not** activate the inactive legacy Sink experiment switch.
5. Restart `bluetoothd` **once** using the SSH command above. Check the NEW session PID and `diag.sdp_probe: installed (optional 6th hook, non-mutating)`. If the status says REFUSED, save the log: the exact UUID/code guard did its job. If the tweak crashes or headphones stop playing, switch this observer OFF and restart to restore the five-hook baseline.
6. Examine `SDP_PROBE #N` log lines. The optional observer logs the two descriptor list counts, bounded attribute IDs/types, a *candidate* Service Class UUID for descriptor type 6 (unverified until matched against known records), raw original function return code, and the outgoing 32-bit record handle. On this exact build the function is at image+`0x1e8e78` and at least 20 call sites exist. It is *not* a stable API.
7. Test iPhone -> Bluetooth headphones again. Connect/pair the iPhone from Windows if possible; Windows **should not** list the iPhone as a Bluetooth audio output yet. Save Windows Bluetooth/audio service snapshot by running `powershell -ExecutionPolicy Bypass -File .\tools\windows_bluetooth_snapshot.ps1`. Cached UUID 0x110B hits could belong to headphones, not the iPhone.
8. Copy the full v7 Debug log and send it with the Actions build URL, headphone playback result, and Windows snapshot. Lines around `SDP_PROBE` are especially important. Do not post full Bluetooth addresses or pairing keys if any appear in supplementary diagnostics.

## Important risk and rollback

This optional SDP observer hooks an internal arm64e routine. The exact `pacibsp` prologue and UUID are signature-gated and its callback is intended as pass-through, but even passive hooks may affect stability. If Bluetooth repeatedly fails, turn the **optional SDP observer OFF**, restart the daemon, or uninstall this build and restore v6. Avoid restart loops. Do not interpret a successful hook installation as proof the phone is an A2DP Sink.

## New source of information

The candidate record-add routine at `0x1e8e78` is called by at least 20 direct sites. It consumes two pointer/count lists and possibly writes a 32-bit record handle via its second argument. Instrumentation can validate our static ABI hypothesis and identify record service classes. This analysis is NOT sufficient to call the private routine with newly constructed Sink records or guarantee a usable incoming AVDTP media path.
