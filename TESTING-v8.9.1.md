# v8.9.1: fix the Start button leaving Bluetooth down

This is a source patch on top of v8.9. It fixes one serious bug in the v8.9.0 Start button and nothing
else. Audio output selection, the idle guard, the streaming path and the manual switches are unchanged.

## The bug in v8.9.0

v8.9.0's **Start** armed the two one-shot switches, then restarted Bluetooth by having the tweak run
`kill(getpid(), SIGKILL)` from inside bluetoothd. On at least one device, launchd did **not** relaunch
bluetoothd after that, so the whole Bluetooth stack stayed down: the iPhone disappeared as an audio
device, and Settings showed "Still waiting ... reinstall the package", which was misleading because
the tweak was loaded and working.

A daemon killing *itself* is not the same as an external `killall -9 bluetoothd` (which is what
actually triggers the relaunch). That is the root cause.

Recovery if you hit it on v8.9.0: toggle **Bluetooth off and on** (or Airplane Mode off/on), or reboot.
Nothing is damaged.

## The fix

v8.9.1 restarts bluetoothd with:

```
launchctl kickstart -k system/com.apple.bluetoothd
```

`kickstart -k` kills **and** relaunches the service in a single launchd operation, so bluetoothd can
never be left down. The tweak `posix_spawn`s `launchctl` while bluetoothd is still alive and running as
root, so the child inherits the privilege it needs; bluetoothd is then torn down by launchd as part of
the same kickstart, already committed to coming back.

Key safety properties, enforced by tests:

- The v8.9.0 self-kill (`kill(getpid())`, `SIGKILL`, `_exit`) is gone from the code.
- The only child process ever spawned is `launchctl`; there is no shell, `system()`, or exec of
  anything else.
- If `launchctl` cannot be found or spawned (for example, if bluetoothd's sandbox denies
  `process-exec`), the tweak **reports and returns** with Bluetooth still running and the switches
  still armed. It never kills anything on the failure path.
- In that blocked case, Settings now says "Almost there - restart Bluetooth" and tells you to toggle
  Bluetooth; it no longer tells you to reinstall unless the tweak is genuinely not loaded.

## Is the spawn allowed?

This is the open question that needs the device test. bluetoothd is sandboxed, and this project has
already seen it deny several operations (audio bootstrap services, most directories). Spawning
`launchctl` may be allowed or may be denied. Either way bluetoothd stays up:

- **Allowed:** Start works end to end, no PowerShell, as intended.
- **Denied:** Start arms the switches, Bluetooth keeps running, and Settings tells you to toggle
  Bluetooth once to apply. That is strictly better than v8.9.0, which could strand Bluetooth.

If the spawn is denied, the fallback plan (not in this patch) is a second, root-owned launchd job
installed by the package whose only job is to kickstart bluetoothd on request. Tell me the device-test
result and I will add it if needed.

## Device test (Dopamine / rootless)

1. Install the new nightly `.deb`. Open **Settings > BTPhonoSink**; **Session** should read `Off`.
2. Tap **Start** and confirm.
   - **Success:** Bluetooth restarts once and Settings reaches "The iPhone is now a Bluetooth speaker".
     The daemon log shows `V89_SESSION ... restarting bluetoothd via launchctl kickstart -k` and, after
     relaunch, `V89_SESSION relaunched for start ... result=ARMED`.
   - **Blocked spawn:** Settings shows "Almost there - restart Bluetooth". The log shows
     `V89_SESSION could not spawn launchctl; switches remain armed, Bluetooth left running`. Toggle
     Bluetooth off/on; the trial runs on the next start. **Bluetooth should never stay down on its own.**
3. Connect from the PC and choose the iPhone as its audio output; test your chosen **Audio output**.
4. Tap **Stop**: Bluetooth restarts (or asks you to toggle it) back to normal.

The Settings build label still reads `v8.8-continuous-sbc-ring`. `diag.v89.build` now reads
`v8.9.1-one-tap-output-select`.

Export both logs right after a test (the daemon log wipes at 512 KB):

```powershell
scp mobile@<phone-ip>:/tmp/FTABHarvest/BTPhonoSink.log "$env:USERPROFILE\Downloads\BTPhonoSink-v891.log"
scp mobile@<phone-ip>:/tmp/FTABHarvest/BTPSAudioHelper-v88.log "$env:USERPROFILE\Downloads\BTPSAudioHelper-v891.log"
```

## Apply and build

Prepared against the v8.9 upload (repository build 11). Upload the ZIP's extracted contents to the
**root of the existing repository** with **Add file > Upload files**, dragging the files and folders so
the paths are preserved, and commit together:

```text
BTPSV89Session.c
TESTING-v8.9.1.md            (new)
Tweak.xm
btphonosinkprefs/BTPSRootListController.m
btphonosinkprefs/Resources/Root.plist
tests/test_v89_session_output.py
```

Wait for GitHub Actions to pass, then install that commit's nightly `.deb`. No workflow or packaging
changes are needed.

## Validation

Host run: **174 tests: 169 passed, 3 skipped, 1 expected legacy-decoder failure, and 1 failure that
needs the libsbc download** (`test_v88_runtime`, unchanged by this patch; CI fetches libsbc). The ten
v8.9 tests, including the new `test_restart_uses_launchctl_kickstart_and_fails_safe` and
`test_settings_poll_handles_blocked_restart_without_advising_reinstall`, pass under AddressSanitizer
and UndefinedBehaviorSanitizer. `BTPSV89Session.c` type-checks with `-Wall -Wextra -Werror -Wformat=2`
against CoreFoundation, dispatch, notify and spawn prototypes. The Objective-C (Settings page) is first
compiled by the GitHub build.

```sh
python3 -m unittest discover -s tests -v
BTPS_SANITIZE=1 python3 -m unittest tests.test_v89_session_output -v
```
