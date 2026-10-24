# BTPhonoSink — v5 safe diagnostics

An experimental rootless/arm64e iOS 17 jailbreak project exploring whether an iPhone 13 can act as an A2DP Bluetooth speaker for a Windows laptop **without Wi-Fi**. **It cannot receive Windows Bluetooth audio yet.**

## What works / does not work

| Item | v5 status |
|---|---|
| Injection into the tested `bluetoothd` version using ElleKit/Theos | Verified in earlier v4 device logs; v5 device confirmation pending |
| 5 guarded hooks, matched by code fingerprint | Code retained; v5 device confirmation pending |
| Observing native AVDTP Source endpoints and assigned 1-byte SEIDs | v5 instrumentation, requires a device log to verify |
| Additional Sink endpoint registration | **Disabled** in v5 (v4 filled the six slots; failed a native Source with 0x68) |
| Publish A2DP Sink SDP service `0x110B` | **Not implemented** (only offline record-format prototype) |
| AVDTP media receive / SBC decoding / iPhone speaker output | **Not connected**; files for later research are included but unused by these hooks |

**Do not expect Windows to list the iPhone as an AudioEndpoint in v5.** This is a diagnostic step to establish an undisturbed baseline. `AudioSinkSdp` in the daemon does not establish that it can advertise its own sink role.

## Build on GitHub (from existing repository)

The existing `.github/workflows/build.yml` runs on every push; a push to `main` builds a rootless `.deb` on macOS 15 with Theos and publishes it automatically to [the rolling `nightly` Release](https://github.com/m9z2w4d8vw-blip/BTPhonoSink/releases/tag/nightly). The v5 workflow also runs offline Python regression tests before compiling.

1. Replace the repository files with the **contents** of the updated v5 source ZIP, not the ZIP archive itself. Preserve the existing `.git` directory if working in a clone.
2. Commit and push to `main`.
3. Open the Actions > build run for that commit; check the Python tests, Theos build, and package validation are green.
4. Open Releases > nightly; download the latest **`.deb`** (not the source ZIP) and install with your normal package manager (Sileo/Filza). Keep the installed previous package available for rollback if necessary.
5. Start a fresh `bluetoothd` process (the package manager may prompt for restart; otherwise use a normal device reboot and re-jailbreak with Dopamine). Avoid repeated force-kill/restart loops if Bluetooth becomes unstable.
6. Open iPhone **Settings > BTPhonoSink**, verify Loaded in daemon = Yes, hooks=5 (in log), then tap **Copy log to clipboard**.
7. In the log, confirm `BTPhonoSink v5-safe-observe`, `native A2DP Source #1 accepted` through `#6 accepted`, and `six native Source endpoints registered; six-slot table is occupied; Sink injection skipped`. Exact counts can vary by launch/connected devices; do not assume success if you instead see `native Source registration FAILED` or any hook missing.
8. Keep **Legacy sink experiment flag** OFF. In v5 toggling it no longer creates endpoints. Verify existing Bluetooth playback **from iPhone to headset** still works, if you have a Bluetooth headset.
9. Send the full log, the GitHub Actions run link and any unexpected behavior back for next-stage SDP research.

### Windows check

Do **not** unpair/re-pair repeatedly expecting a speaker: this version cannot advertise `0x110B`. Windows audio discovery becomes a meaningful test only after a later version publishes a legitimate SDP record.

### Rollback / recovery

If Bluetooth misbehaves, uninstall BTPhonoSink using Sileo/your package manager, or disable its tweak injection in an available safe-mode/tweak-management tool, then restart/re-jailbreak normally. The project does not modify system files on disk but does hook a system daemon and can cause instability.

## Offline tests and reverse engineering

Run `python3 -m unittest discover -s tests -v` on Windows/macOS/Linux. `python3 tools/sdp_record.py` creates and locally decodes a Bluetooth A2DP Sink SDP **Data Element list** (L2CAP/AVDTP, UUID `0x110B`, profile `0x110D`, SupportedFeatures speaker bit), but the output is NOT the private OI_SDPDB API's in-memory record representation. `python3 tools/inspect_bluetoothd.py /path/to/bluetoothd` verifies the exact iOS 17 daemon SHA-256 plus the five function signatures if you have your previously extracted binary locally. No binary or device secrets are included.

See `docs/V5_STATIC_FINDINGS.md` for image-relative disassembly landmarks and unresolved SDP API arguments / endpoint allocation constraints.
