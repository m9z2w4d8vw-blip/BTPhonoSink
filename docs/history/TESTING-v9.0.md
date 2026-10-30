# v9.0: Speaka everywhere

Builds on v8.9.4. Nothing about how the speaker works changes. This version finishes the rename to Speaka, including
the names the components use to find each other, so all of them must be updated together.

## What changed

| Part | Now |
| --- | --- |
| Package | `com.parv.speaka`, named Speaka in Sileo; released as `Speaka_<version>_iphoneos-arm64.deb` |
| Tweak inside Bluetooth | `Speaka.dylib` with its filter `Speaka.plist` |
| Settings page | the `SpeakaPrefs` bundle, shown as Settings > Speaka |
| Audio helper's launchd job | `com.parv.speaka.audio`, same port and binary as before |
| Settings stored in `com.apple.bluetooth` | `Speaka...` keys, for example `SpeakaStatus` and `SpeakaV89OutputMode` |
| Darwin notifications | `com.parv.speaka.*` |
| Log file | `/tmp/FTABHarvest/Speaka.log` (the helper keeps `BTPSAudioHelper-v88.log`) |
| The app | version 1.2, which uses the new names; earlier app versions cannot talk to this tweak |

The `BTPS` prefix in source file and function names is an internal abbreviation and stays.

## One-time switch on the phone

Because the package ID changed, the package manager treats this as a new tweak. Remove the earlier package first,
otherwise both would be installed and the new helper cannot take the port the old one holds.

1. Find the earlier package: `dpkg -l 'com.parv.*'` lists it next to any `com.parv.speaka`.
2. Remove it with `sudo dpkg -r <its package ID>` (or in Sileo). This also unloads its audio helper.
3. Install `Speaka_<version>_iphoneos-arm64.deb`. Bluetooth restarts once.
4. Open `Speaka.tipa` (or `Speaka.ipa`) with TrollStore to update the app to 1.2.
5. Choose **Play audio on** again: the earlier choice and never-play list were stored under the old names, so they start
   fresh (iPhone speaker, empty list).
6. Tap **Start**. Check for `diag.v89.build: v9.0.0-one-tap-output-select` under **View debug log**.

If step 3 stops with "the audio helper could not start", the earlier package is still installed: do steps 1 and 2,
then install again.

Even if both tweaks end up installed, Bluetooth stays safe. Each checks the first instructions of every function
before hooking it, so whichever loads second sees the first one's hook and stands down.

## Validation

Every file and path was renamed; `tests/test_speaka_app.py` fails CI if the former name ever reappears anywhere. It
stores only the name's SHA-256, so the test itself does not contain it. A planted occurrence in a string, an
identifier and a file name was caught each time. The full suite passes except `test_v88_runtime`, which needs the
libsbc download that CI performs.
