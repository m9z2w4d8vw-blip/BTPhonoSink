# Speaka v7.6.1 — Helper playback diagnostics and limited gain

This is a **helper-only** patch to the verified v7.6 source; the tweak's build tag remains `v7.6-sbc-playback`. It does not change the AVDTP or SDP hooks and does not receive live Bluetooth audio.

The v7.6 daemon's `diag.v75_sbc: PASS` is a **transport acknowledgement only**: the helper sends `SBC_VERIFIED` *before* attempting SBC decoding or speaker playback. The daemon debug log cannot prove decoder or audio API success. Only the helper's full PowerShell output can localize failure.

The reference WAV has low amplitude (~-24 dBFS RMS). The playback-only WAV now uses a gain of at most 4x and a 14,000/32768 peak limit. The saved `SBC_DECODED_WAV_SAVED` file remains the original *unamplified* output for waveform comparisons. This may help audibility, but does not fix an actual decoder or audio-session error.

New terminal diagnostics: `BTPS_HELPER_MODE=...`, `SBC_AUDIO_PREP original_peak=...`, `SBC_AUDIO_ROUTE port=... name=... volume=...`, and explicit `BTPS_V76_RESULT` when decoding or fidelity validation fails. These printed messages are available over SSH only; they are **not captured by the existing daemon debug log**.

## Install
1. In the repository replace `btpsaudiohelper/main.m`, add `tests/test_v761_helper_playback_diagnostics.py` and commit. Ensure the GitHub Actions build succeeds; install the new `.deb`. Retain your previous known-working package.
2. In Settings keep **Legacy Sink OFF** and **Trace existing SDP records OFF**. Verify 5/5 hooks and 6/6 Source endpoints after installation. Do not restart `bluetoothd` unless needed to load the replaced tweak.
3. Disconnect headphones (or check the route printed by helper) and set the iPhone volume to a clearly audible level.
4. Run this **exact** command in Windows PowerShell (IP may change):

```powershell
ssh -t mobile@10.5.82.212 "/var/jb/usr/bin/BTPSAudioHelper --sbc-play"
```

5. Verify the first line is `BTPS_HELPER_MODE=SBC_PLAY_DECODE_AND_OUTPUT`. If it says `SBC_VERIFY_ONLY_NO_SOUND`, you ran `--sbc` instead and silence is expected.
6. Within 120 seconds, in iPhone Settings > Speaka > Debug log, press `Send SBC from bluetoothd (v7.5/7.6)` and enter the fresh token.
7. Copy **the entire PowerShell output** back to the conversation. In particular include `SBC_DECODE_PASS/FAIL`, `SBC_AUDIO_PREP`, `SBC_AUDIO_ROUTE`, `SBC_AUDIO_STARTED/FINISHED`, and `BTPS_V76_RESULT`. State if the 440 Hz tone was audible.

**If the helper prints `SBC_DECODE_FAIL`**: decoding failed and playback never ran. **If it prints `SBC_FIDELITY_FAIL`**: playback was deliberately skipped. **If it prints `AUDIO_FAIL`**: playback initialization failed. **If it prints `SBC_AUDIO_FINISHED` but you hear nothing**, investigate routing and device volume; the API completing is not proof of sound. The daemon's `diag.v75_sbc: PASS` alone is not sufficient evidence for any of these stages.
