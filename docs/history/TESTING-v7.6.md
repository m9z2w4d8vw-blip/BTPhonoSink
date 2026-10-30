# Speaka v7.6 — decode captured SBC and play from helper

**Does not add an A2DP Sink or receive over-the-air Bluetooth audio.** The test sends a finite FFmpeg SBC fixture from `bluetoothd` over the established local IPC. The helper decodes it in the *separate process* using a pinned external Apache-2.0 SBC codec, saves the WAV, and attempts playback. The original research decoder inside the tweak is unchanged and remains unsuitable for playback.

## Installation

1. Commit this entire repository to GitHub `main`, including `.github`, `tools`, and `btpsaudiohelper`. GitHub Actions downloads pinned Google SBC source in a separate build step, runs native fidelity regression against the user's actual SBC/WAV pair, then builds the rootless `.deb`. **If the fidelity check or build fails, do not install.**
2. Keep your working v7.5 `.deb` as rollback. Install the newly built `.deb` using Sileo.
3. In Settings > Speaka, **Legacy Sink OFF**, **Trace existing SDP records OFF**. Only if necessary, restart Bluetooth:

```powershell
ssh -t mobile@10.5.82.212 "sudo killall -9 bluetoothd"
```

4. Confirm `build: v7.6-sbc-playback`, 5/5 hooks, 6/6 native sources, `diag.v75_sbc: ARMED`. Verify normal headphones first, then disconnect them for speaker testing.

## New SBC decoding test

On Windows PowerShell (update IP if it changes):

```powershell
ssh -t mobile@10.5.82.212 "/var/jb/usr/bin/BTPSAudioHelper --sbc-play"
```

The helper prints `BTPS_V76_SBC_PLAY_READY` and a fresh six-digit token. Keep SSH open. On iPhone open **Settings → Speaka → View debug log → Send SBC from bluetoothd (v7.5/7.6)**, enter the token and request the transfer **once**.

Terminal should show `SBC_RECEIVED` with `258` packets and `258` frames, `SBC_DECODE_PASS frames=258 samples_per_channel=33024 rate=44100 channels=2` and `SBC_DECODED_WAV_SAVED path=...`, then `SBC_AUDIO_STARTED` and `SBC_AUDIO_FINISHED` (if supported). The decoded audio is a short **440 Hz** tone; state whether it was actually audible. `BTPS_V76_RESULT ... decode=PASS audio_api=FINISHED` does **not** prove live A2DP reception.

If `SBC_DECODE_FAIL` or `SBC_FIDELITY_FAIL` appears, **do not claim successful decoding**; send logs and decoded WAV if saved. Otherwise send terminal output, exported Speaka debug log and audibility observation. You can download the saved decoded WAV by substituting the exact filename printed by the helper:

```powershell
scp "mobile@10.5.82.212:/var/mobile/Documents/<EXACT_WAV_FILENAME_FROM_HELPER>.wav" .
```

## Recovery

Restore v7.5 with Sileo if Bluetooth headphones stop working or the daemon repeatedly crashes. The old `--sbc` helper option still performs **silent** compressed-data validation; v7.4 `--daemon` still tests PCM output independently.

## Build provenance

The separate helper compiles Apache-2.0 Google `google/libsbc` at exact commit `6e505650145c9973d08a0bdd5e5f5e1914305e40`, fetched at GitHub Actions **build time** by `tools/fetch_google_sbc.sh`. LICENSE and upstream source are retained in the build folder. No network access on the phone. This requirement means an offline local `make package` needs `bash tools/fetch_google_sbc.sh` run first.
