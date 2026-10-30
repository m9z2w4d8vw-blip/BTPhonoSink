# BTPhonoSink v7.1 — One combined install: iCloud export + SDP research + media foundation

## What is implemented

- Settings debug screen has a persistent **Save Log to iCloud Drive…** button.
  iOS displays a Files document-export picker; choose iCloud Drive and a folder.
- The five existing v6 hooks continue to observe without changing normal endpoints.
- Optional **Trace existing SDP records (advanced)** switch, OFF by default,
  observes Apple's existing service record-add calls at a binary-verified address.
- The standalone `BTPSMedia.c/h` and `SBCSink.mm` expose a bounded RTP/SBC-to-PCM
  entry point for future incoming media integration. No live stream reaches it yet.

## Build and install

1. Preserve the **previously working v6 .deb** as a rollback option.
2. Unzip this source archive. Upload the **contents** of its `BTPhonoSink-main/`
   folder, including `.github/`, to the root of your GitHub repo, overwriting
   matching files. Do not upload the ZIP as a single file.
3. Commit to `main`; GitHub Actions runs Python and compiled-C tests, builds the
   rootless `.deb`, and updates the `nightly` release only on a successful build.
4. Check the Action run for errors. Download the .deb from the NEW nightly release;
   install using your usual package installer.
5. Fully close and reopen Settings to load the new Preferences UI.
6. On iPhone, go to Settings → BTPhonoSink. **Leave the optional SDP probe OFF.**
7. Restart bluetoothd once (your PowerShell command, on your own network):

   `ssh -t mobile@10.5.79.217 "sudo killall -9 bluetoothd"`

8. Open Debug log; verify `build: v7.1-sdp-media-foundation`, original five hooks
   installed, six native Source endpoints accepted, and `diag.sdp_probe: OFF`.
9. Play audio from iPhone through your Bluetooth headphones. Reconnect once.
   **Stop if outgoing audio breaks**; return to your v6 package.

## Test iCloud Drive export

1. In Settings → BTPhonoSink → View debug log, tap **Save Log to iCloud Drive…**.
2. The Files picker opens. Select **iCloud Drive** (not On My iPhone), choose a
   folder, tap Save/Move as offered by iOS.
3. Open Files → Browse → iCloud Drive and confirm a new `BTPhonoSink-*.txt` file
   exists and contains the same STATUS + LOG content as the screen.
4. This saves a snapshot via Files; it does not automatically transmit logs or
   bypass the iOS file picker. You can then share that file in chat.

## Optional: collect SDP service-add evidence

1. Only after the above baseline succeeds, enable **Trace existing SDP records
   (advanced)** in Settings → BTPhonoSink.
2. Restart bluetoothd with the same command. A sixth SDP observer should report
   `diag.sdp_probe: installed (optional 6th hook, non-mutating)`.
3. Wait for the daemon to initialize, connect headphones and verify playback.
4. Export the full log with the new iCloud button. Look for `SDP_PROBE #...` lines.
5. Turn the SDP observer OFF afterward and restart bluetoothd once to remove it.
   If Bluetooth acts abnormally, switch it off immediately or reinstall v6.

## What to send back

- GitHub Actions build run URL and whether it succeeded.
- The exported `.txt` from the iCloud Files picker.
- Whether headphones played normally with SDP observer OFF and (if tried) ON.
- How many `SDP_PROBE` calls appeared and their return values (no need to hand
  transcribe the records—send the exported file).

**Do not expect the laptop to detect an iPhone audio speaker yet.** v7.1 does not
publish service UUID `0x110B`, register a usable Sink SEP, receive live Bluetooth
SBC packets, or start playback in an authorized audio helper.
