# BTPhonoSink v7.4 — bluetoothd → independent audio helper test

**Purpose:** Confirm whether the exact `bluetoothd` process that receives Bluetooth packets can send its **own synthetic** 0.8-second, 44.1 kHz, 16-bit mono 880 Hz PCM packet to the existing separate helper over **local loopback only**. No Bluetooth media packet is received, no Sink endpoint/SDP 0x110B record is installed, and no real Bluetooth audio is decoded. Normal outgoing Bluetooth stays as before.

This is a **diagnostic, explicit one-shot test**, NOT a music streaming feature. The v7.4 `bluetoothd` component never opens an audio output service and does not write or mutate AVDTP endpoints or SDP records. The Settings-to-helper v7.3 test remains available (660 Hz). 880 Hz identifies the *new* test. The helper only binds `127.0.0.1:37593` and requires a fresh six-digit token plus the v2 frame tag; that tag is diagnostic only, not cryptographic process authentication.

## Install and baseline

1. Keep your known-working v7.3 `.deb` for recovery. Upload **all** files in the v7.4 repository root to GitHub `main`, including hidden `.github/`, `BTPSDaemonProbe.c/.h`, `BTPSV74Tone.c/.h`, and the `btpsaudiohelper` subproject. Commit.
2. GitHub Actions must show a green **build** run with `python3 -m unittest discover -s tests -v` passing. The one marked `expected failure` about existing SBC decoder audio fidelity is documented; a real failure is **not** acceptable. The released `.deb` must contain `/var/jb/usr/bin/BTPSAudioHelper`.
3. Download the `nightly` `.deb` and install it in Sileo. After installation, in Windows PowerShell, restart the Bluetooth daemon **once**:

   ```powershell
   ssh -t mobile@10.5.82.212 "sudo killall -9 bluetoothd"
   ```

   Adjust the IP if you change networks again.
4. Open Settings → BTPhonoSink → View debug log. The current session must say `v7.4-daemon-to-helper-probe`, 5/5 original hooks, and 6/6 native Source endpoints. **Legacy Sink OFF.** For first testing, turn the optional SDP observer OFF (restart once after changing its switch). The status `diag.v74_ipc` should show **`ARMED: awaiting explicit Settings request`**.
5. Test Bluetooth headphones with regular iPhone music. If damaged, remove the tweak or restore v7.3 and restart `bluetoothd`; do not proceed.

## v7.4 one-shot test

6. Disconnect the headphones if you want output on the iPhone speaker. In **Windows PowerShell** start the helper and leave that window open:

   ```powershell
   ssh -t mobile@10.5.82.212 "/var/jb/usr/bin/BTPSAudioHelper --daemon"
   ```

7. Expect `BTPS_V74_DAEMON_READY ... token=NNNNNN ...`. This token changes each run; **do not reuse the one from v7.3**. There is a default 120-second window to submit it.
8. On the iPhone open **Settings → BTPhonoSink → View debug log → Send PCM from bluetoothd (v7.4)**. Enter the new token, then tap **Request daemon transfer**. Unlike v7.3, the Settings app only writes the request preference and posts a Darwin notification; **it does not generate the test tone or open a socket**.
9. Look in both places:

   **SSH helper output (success example, not an availability promise):**

   ```text
   BTPS_V74_DAEMON_READY pid=... port=37593 token=NNNNNN timeout=120s
   IPC_RECEIVED mode=bluetoothd bytes=70560 CRC32=verified sampleRate=44100 channels=1 duration=0.8s
   AUDIO_STARTED process=BTPSAudioHelper pid=... duration=0.8s frequency=880Hz source=bluetoothd-request
   AUDIO_FINISHED API finished; human must confirm sound was heard
   BTPS_V74_TEST_RESULT source=bluetoothd ipc=PASS audio_api=FINISHED
   ```

   **Daemon log status:** `diag.v74_ipc: PASS: helper verified v2 880Hz PCM CRC, audible sound unverified` and `V74_IPC PASS`. These together indicate that `bluetoothd` initiated a validated PCM send and the helper received it.
10. Confirm **whether you heard the 880 Hz tone** (not the older 660 Hz test). Then export the log to iCloud Drive, send it alongside the entire SSH terminal output, and mention whether headphones still play normally.

## Interpreting failures

- `diag.v74_ipc: UNAVAILABLE: notify_register_dispatch=...`: Darwin notification registration not permitted or failed. Do not assume any PCM send occurred.
- Settings says `notify_post failed`: the request wasn't successfully posted.
- Settings says `Request notification posted` but daemon remains `ARMED`: post occurred, but handler was not observed. Investigate notification delivery and prefs domain; **do not** claim daemon IPC success.
- `diag.v74_ipc: REQUEST IGNORED`: malformed/missing request preference or invalid token/UUID format.
- `diag.v74_ipc: FAIL: socket denied errno=1` or `connect errno=...`: `bluetoothd` is restricted by its sandbox or the helper is absent. Record the exact errno.
- `diag.v74_ipc: PASS` but you heard nothing: packet delivery worked, but output may have been inaudible or routed elsewhere. Confirm helper output route/volume. API `AUDIO_FINISHED` alone never proves audibility.
- `IPC_REJECT`: token, frame version/tag, CRC or sample metadata mismatch; check you started the helper with `--daemon`.
- `IPC_TIMEOUT`: helper was left listening without a successful connection or the 120 seconds elapsed.
- `THROTTLED`: wait at least 10 seconds and start a **new** helper with a **new** token.
- Headphones stop working: stop experimentation and restore v7.3 rather than trying additional switches.

## Safety and technical boundaries

`BTPSDaemonProbe.c` registers a callback on a dedicated serial GCD queue; the main hook logic continues forwarding Apple's five private callbacks unmodified. The test uses one bounded 70,588-byte packet (28-byte v2 header + 70,560-byte PCM) and closes the socket. Loopback connect timeout is 1 second; send and receive timeouts are 2 seconds. No public listening socket is opened inside `bluetoothd`. Requests are UUID-deduplicated and throttled. An optional SDP observer can remain disabled throughout.

The in-process test does **not** prove a production-quality secure or continuous audio transport. The v2 `BTD4` tag is not trusted process identity. The 6-digit token is short-lived convenience for test correlation, not a secret suitable for exposing this protocol beyond local loopback.

Even with a fully successful v7.4 test, this project has not achieved an **A2DP Sink**: the inbound Bluetooth SEP, published SDP 0x110B record, media L2CAP transport, and validated SBC decode/PCM playback pipeline are all still needed. The bundled research SBC decoder's waveform-fidelity regression remains an expected failure; do not enable real SBC playback yet.
