# v7.5 test — bluetoothd → helper, compressed A2DP RTP/SBC (fixture only)

## Goal and limits

v7.4 proved actual daemon-to-helper IPC with audible PCM. v7.5 now transfers a real FFmpeg-encoded SBC clip wrapped as 258 RTP/A2DP-SBC packets, **originating from a compiled-in fixture in bluetoothd**, across the same 127.0.0.1:37593 channel. The helper independently checks protocol version, one-time token, CRC32, SBC headers and sizes, sequential RTP sequence numbers and timestamps, payload format and stable SSRC, then extracts the SBC audio data to a file for later decoding. **There is no sound in this test by design.** No actual Bluetooth Sink SEP, SDP 0x110B or incoming L2CAP media is registered or received, and the known-broken research SBC decoder is **not used** for playback.

## Installation

1. Replace the entire GitHub repository with the contents of this ZIP, including hidden `.github` and `btpsaudiohelper/`. Commit to `main` and wait for the GitHub Actions build to succeed.
2. Keep the working v7.4 `.deb` as a fallback, and install the resulting v7.5 `.deb` from the release.
3. Leave **Legacy Sink OFF** and **Trace existing SDP records OFF**. Restart `bluetoothd` using `ssh -t mobile@10.5.82.212 "sudo killall -9 bluetoothd"` (update IP as needed).
4. Verify headphones still work. Confirm Settings > BTPhonoSink > Debug log reports `v7.5-sbc-rtp-ipc-probe`, `5 / 5` baseline hooks, `6 / 6` native Source endpoints, and `diag.v75_sbc: ARMED`.

## Compressed media test

5. On Windows PowerShell run `ssh -t mobile@10.5.82.212 "/var/jb/usr/bin/BTPSAudioHelper --sbc"`. Keep SSH open and note its six-digit token. This helper runs only when launched manually.
6. On your phone go to Settings > BTPhonoSink > Debug log > **Send Compressed SBC from bluetoothd (v7.5)**. Enter the token and send the request.
7. SSH should report `SBC_RECEIVED ... bytes=15996 ... packets=258 frames=258 ... extractedSBC=12126` then `SBC_CAPTURE_SAVED path=/var/mobile/Documents/...sbc` and `BTPS_V75_RESULT ipc=PASS rtp=PASS sbc_frames=PASS pcm_decode=NOT_TESTED live_bluetooth=NO`.
8. Expect **NO TONE** in this test. Debug log should say `diag.v75_sbc: PASS`. Export the log with the iCloud Drive button and send it, together with the SSH output. If needed retrieve the `.sbc` capture using PowerShell `scp mobile@10.5.82.212:<PATH_PRINTED_BY_HELPER> .` with the actual path.

If validation fails: capture `SBC_REJECT` or the daemon's exact `diag.v75_sbc` status; do not enable Legacy Sink. You can independently decode the extracted `.sbc` using FFmpeg on Windows with `ffmpeg -f sbc -i capture.sbc -c:a pcm_s16le -y decoded.wav` (this is an offline reference verification, not iOS decoder validation). Beware very short clip volume. 

## What constitutes a pass

A verified compressed transfer means the synthetic *encoded* packets passed from the running Bluetooth daemon to the separate helper without corruption. It does **not** prove the real Bluetooth radio/AVDTP receiving path; separate Sink registration and incoming L2CAP media hooks are still required. The existing custom SBC decoder remains excluded until an audio fidelity regression test passes.
