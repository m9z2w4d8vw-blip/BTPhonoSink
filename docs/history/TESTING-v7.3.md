# BTPhonoSink v7.3: cross-process PCM playback experiment

**Purpose:** Learn whether a separate, ordinary mobile-user command-line process can receive
raw PCM from Preferences.app over a loopback connection and render it using AVAudioPlayer.
**This is not Windows → iPhone Bluetooth audio.** The data is synthetically generated in Settings,
never received via Bluetooth, and the known-invalid SBC decoder is not involved.

## What changed

- Installs a standalone command-line executable: `/var/jb/usr/bin/BTPSAudioHelper`.
  It does not auto-start, add a LaunchDaemon, request elevated privileges, or touch bluetoothd.
- Adds **Send PCM to Separate Helper (v7.3)** inside Settings > BTPhonoSink > View debug log.
- The Settings button generates 0.8 seconds of **660 Hz** mono, 16-bit PCM at 44.1 kHz;
  it transmits those 70,560 bytes to the helper via loopback-only TCP `127.0.0.1:37593`.
- Frame carries magic, protocol version, exact format, six-digit one-shot token and CRC32.
  The helper validates these before playing. The listening socket exists only while the SSH
  tool is running. The receiver stops after **one** connection or the deadline (default 120 s).
- The helper prints clear `IPC_RECEIVED`, `AUDIO_STARTED`, `AUDIO_FINISHED` / `AUDIO_FAIL`, and
  `BTPS_V73_TEST_RESULT` lines so audio transport can be separated from CoreAudio permissions.
- The Settings response gets saved in the existing log exporter (iCloud Drive).
- No changes to the AVDTP endpoint registration strategy: **Legacy Sink remains OFF**;
  existing five hooks and optional SDP observer remain passive.

## Install and verify the build

1. Keep the **working v7.2 .deb** for rollback.
2. Upload **all** files from `BTPhonoSink-main/` to the existing GitHub repository root,
   including `.github/workflows/build.yml`, `btpsaudiohelper/`, `BTPSIPCProtocol.c/h`,
   `btphonosinkprefs/` and `tests/`. Do NOT upload the ZIP alone.
3. Commit; verify a green GitHub Actions **build** workflow. Its package verification
   now **fails** if the helper executable is missing from `var/jb/usr/bin/`.
4. Install the newly created `.deb` from the latest GitHub nightly release via Sileo.
5. Keep Legacy Sink OFF. SDP probe can remain OFF for the IPC test.
6. Restart bluetoothd once as on previous builds:
   `ssh -t mobile@10.5.79.217 "sudo killall -9 bluetoothd"`.
7. Confirm `build: v7.3-ipc-audio-probe`, 5/5 hooks, 6/6 native Sources,
   and working normal headphone playback. Unpairing or changing firmware is unnecessary.
8. If GitHub package verification fails, **do not** install an older .deb assuming it is v7.3.

## Run the cross-process test

1. Disconnect your headphones if you want to hear the iPhone's built-in speaker. Turn up volume.
2. Keep the phone unlocked with Settings > BTPhonoSink > **View debug log** open.
3. Open **Windows PowerShell** on the laptop and execute exactly:

   ```powershell
   ssh -t mobile@10.5.79.217 "/var/jb/usr/bin/BTPSAudioHelper"
   ```

   Enter your SSH password if prompted. **Leave the PowerShell window running.**
   It should say:

   ```text
   BTPS_V73_HELPER_READY pid=... port=37593 token=123456 timeout=120s
   ```

   The token is newly randomized; `123456` is just an example.
4. On the iPhone's Debug log screen tap **Send PCM to Separate Helper (v7.3)**.
   Enter the actual six-digit token from PowerShell, then tap **Send to helper**.
   Do this while the helper is waiting. If the helper timed out, start it again and use its new token.
5. Look at **both** outputs:

   | Settings says | PowerShell says | Interpretation |
   |---|---|---|
   | `IPC PASS` | `IPC_RECEIVED ... CRC32=verified` | IPC succeeded, independent of sound |
   | `IPC PASS` | `AUDIO_STARTED` then `AUDIO_FINISHED` | Helper audio API ran; report if tone actually audible |
   | `IPC PASS` | `AUDIO_FAIL stage=session` | PCM reached helper; audio entitlement/process context problem |
   | `IPC FAIL ... connect` | No `IPC_RECEIVED` | Helper not running, port unavailable, or loopback denied |
   | `IPC FAIL` | `IPC_REJECT` | Token mismatch, truncated data, or CRC/frame failure |

6. The helper normally stops automatically after one test (success or failure).
   Run the SSH command again for a new test with a **new** token.
7. Export the Debug log via **Save Log to iCloud Drive…**, attach it here,
   and paste the entire PowerShell output. Also tell us **whether you physically heard a 660 Hz tone**.

## Recovery

- If the helper refuses to start, record the exact shell error. It does not require
  running as root or changing permissions to bypass sandboxing; don't force system entitlements.
- If it times out, retry and verify the phone screen stayed open. The helper exits after 120 seconds.
- If Bluetooth headphones stop playing, use the earlier verified daemon restart or restore v7.2.
- These results cannot establish `bluetoothd` → helper IPC, successful live RTP/SBC decode,
  or remote Windows SDP visibility. Those are later stages.

## Research constraints

A standalone SSH-launched program may not be authorized to use iOS playback services.
If this happens, the hypothesis that *any* process outside bluetoothd can render PCM is
**disproved**; the successful v7.2 Preferences tone alone does not confer privileges on CLI tools.
A future design may need a foreground Settings-hosted renderer or a properly approved app context.

Never enable Legacy Sink; v4 caused normal A2DP Source registration interference.
