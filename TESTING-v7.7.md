# BTPhonoSink v7.7 — two-phase testing

**Do not immediately turn ON the new experiment after installing.** This build executes private AVDTP registration only when the *separate* v7.7 toggle is enabled **at daemon launch**. It may cause Bluetooth instability. v7.6.1 is the rollback package. No actual Windows-to-iPhone A2DP playback exists yet.

## Phase A: safe baseline (mandatory)

1. Upload only the changed files from the v7.7 patch or push the complete repository with Git on Windows. Commit on `main`. Confirm GitHub Actions tests/build succeed; install the fresh `.deb` with Sileo.
2. In Settings → BTPhonoSink keep **Legacy sink experiment flag OFF**, **Trace existing SDP records OFF**, and **Trial extra Sink endpoint (advanced) OFF**.
3. Restart Bluetooth if necessary, via Windows PowerShell:

```powershell
ssh -t mobile@10.5.82.212 "sudo killall -9 bluetoothd"
```

4. Verify `build: v7.7-sink-capacity-trial`, `hooks installed: 5 / 5`, `native sources: 6 / 6`, and `diag.v77_sink_trial: OFF (default)`. Connect headphones; verify they still play audio. Export the log with Save Log to iCloud Drive.

**Do not proceed** if the baseline is unstable, any hook failed, or six Sources did not register.

## Phase B: ONE high-risk Sink capacity trial (optional)

1. Keep **Legacy Sink OFF** and **SDP tracing OFF**. Turn **Trial extra Sink endpoint (advanced) ON**. This preference is read on the next `bluetoothd` start; changing it while running does not register an endpoint.
2. Restart `bluetoothd` once with the command above. **Stop immediately if Bluetooth crashes or headphones cease functioning.**
3. Open debug log. Look for `V77_SINK captured stable SBC`, `V77_SINK ONE SHOT`, `V77_SINK RESULT raw_ret=... private_SEID=...`, or `V77_SINK refused`. Read `diag.v77_sink_trial`. Check *all six* original native Source registrations and test headphone playback again.
4. Switch the new v7.7 trial OFF **before any subsequent restart**, restart `bluetoothd` again to return to baseline, and export the diagnostic log. Save the trial log BEFORE resetting if you want to preserve the raw result.
5. Send the log, particularly `V77_SINK RESULT`, and report whether headphones worked. A raw return of zero alone does not prove a functional Sink or SDP visibility.

## Recovery

If Bluetooth hangs, disconnect headphones, turn the new trial OFF in Settings (if accessible), restart `bluetoothd`, or reboot and restore the v7.6.1 `.deb` with Sileo. The v7.7 trial is optional; it is *not* recommended as a daily-use setting. **Never enable the old Legacy Sink experiment.**

## Non-goals

This does not publish `0x110B`, expose an A2DP Sink service to Windows, create a media transport receive path, or guarantee the private registration routine supports a Sink role. No radio audio is captured.
