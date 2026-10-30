# Speaka v6 — exact device testing procedure

This is a diagnostic-only build. Windows cannot stream sound to the iPhone with this version.

## Before deployment

1. Save the old working v5 `.deb` for rollback.
2. Replace files in the GitHub repository with this ZIP's **contents**, including the hidden `.github` directory (do not push the ZIP as a file).
3. Push to `main`. Open Actions > latest `build` and verify the Python tests, compilation, package checks, and release task all succeed.
4. Open Releases > `nightly` and download **the newly produced `.deb`**; verify the release's commit matches your push.

## On your iPhone

1. Keep the legacy Sink experiment switch OFF. Install the new `.deb` with your usual package manager.
2. Restart `bluetoothd` **once** after installation. You previously found that `ssh -t mobile@10.5.79.217 "sudo killall -9 bluetoothd"` restored normal playback; use the same command if that IP is still assigned to the phone. If necessary, reboot and re-jailbreak with Dopamine instead. Do not repeatedly kill the daemon in a loop.
3. Wait for Bluetooth services to return. Open Settings > Speaka > Debug log; the first lines should show:

   ```text
   build: v6-detailed-observe, ...
   hooks installed: installed / 5
   diag.sdp_sink_0x110b: no local Sink SDP publishing implemented; verify externally
   ```

4. Confirm five `hook.*: installed` statuses, `diag.native_source_ok: 6` (expected from your previous device capture), and a `MILESTONE all six observed native Source endpoints registered` line.
5. Inspect the three codecs: expect **SBC `0x00`**, **AAC `0x02`**, **vendor `0xFF`**, not six SBC entries. Each registration should show raw return `0x0`, a duration, and SEID output bytes.
6. Connect your Bluetooth headphones and play audio FROM iPhone TO headphones. Confirm sound; then disconnect and reconnect once and play again. This validates a non-regression only, not Sink reception.
7. If you leave the phone idle for at least 60 seconds, a `HEARTBEAT bluetoothd pid=...` line and a `diag.heartbeat` status should appear. This lets us distinguish an idle daemon from stale old log data.
8. In Settings > Speaka use **Copy log to clipboard**. Paste it back into the chat, along with whether playback survived reconnecting and the GitHub Actions run URL.

## Optional Windows observation (not a Sink test)

Run `powershell -ExecutionPolicy Bypass -File .\tools\windows_bluetooth_snapshot.ps1` in a PowerShell window on your Windows laptop. It prints Bluetooth device names, audio endpoints and whether **any** cached BTHENUM service instance mentions the `0x110B` Sink UUID. This is not per-device proof; your paired headphones may independently advertise `0x110B`. You can paste the output but remove any device names you prefer to keep private.

## When something fails

- **Build fails:** send the failing GitHub Actions step and exact compiler error; do not install an older release by mistake.
- **v5 still shown:** the daemon is running the old tweak; reinstall the new `.deb` and restart the daemon once, checking the actual installed package version.
- **Fewer than five hooks:** send the full signature and UUID mismatch lines, and avoid further forced restarts.
- **A native Source registration fails:** send the raw return code and the entire current-session log. Do not turn on legacy Sink experiments.
- **Headphones connect but are silent:** collect the log *before* any restart. If restarting `bluetoothd` restores sound again, record that; it may be an existing Bluetooth state issue rather than a new regression.
- **Continuous restarts or loss of Bluetooth:** remove the tweak using the package manager or disable injection using your jailbreak's management tooling. Restart/re-jailbreak normally to restore a known-good baseline.

`/tmp/FTABHarvest/Speaka.log` contains additional current and past session lines when sandbox permissions permit writing. It is append-only across daemon restarts and may therefore contain **old v4/v5 observations**. Use the v6 session ID or PID to correlate events and avoid assuming a historical failure happened in the current run.
