# v8.9: one-tap Start/Stop and audio output selection

This source patch builds on v8.8.2 (the idle-check guard is unchanged). It adds two things to
**Settings > Speaka**:

- A **Start** button that replaces "turn on both one-shot switches, then run
  `ssh ... "sudo killall -9 bluetoothd"` in PowerShell", plus a **Stop** button that restarts
  Bluetooth normally.
- An **Audio output** section to choose where the audio plays: the iPhone speaker, headphones or
  earbuds, or any device iOS is using.

Neither feature has been compiled against the iPhoneOS SDK or run on a phone yet. The GitHub build and
the device test below are still required.

## How Start works

1. Settings writes a short request (`SpeakaV89SessionRequest`: action, random nonce, time) to the
   tweak's existing preferences domain and posts the Darwin notification
   `com.parv.speaka.v89.session`. Settings never writes the one-shot switches itself.
2. The tweak, already running inside bluetoothd, handles the notification on its own serial queue. It
   deletes the request before acting, checks the action, the nonce and that the request is less than
   30 seconds old, then writes **the same two one-shot switches** (`SpeakaV81SevenOnce`,
   `SpeakaV82DecisiveOnce`) and turns the retired legacy flag off. It reads them back.
3. Only if everything reads back correctly does the tweak end its own process with `SIGKILL`, exactly
   what `killall -9 bluetoothd` did. launchd relaunches bluetoothd, and the existing one-shot code
   consumes the switches as before, so the crash-safety of v8.1/v8.2 is unchanged: a crashing trial
   still comes back with both switches OFF.
4. The relaunched daemon reports `diag.v89.session = start nonce=... pid=... result=ARMED`. Settings
   matches the nonce, then waits for the Sink registration (`diag.v82.sep ... register=0 SEID=7`) and
   tells you when the iPhone is ready.

No root helper, shell command or spawned process is involved. A Darwin notification on its own does
nothing; a fresh request must also be present in the tweak's preferences domain, which App Store apps
cannot write. If any check fails, Bluetooth is **not** restarted and Settings shows the reason. The
manual switches at the bottom of the page still work as before.

## Audio output

**Play audio on** has three modes. Changes apply immediately, even while audio is playing.

| Mode | Behaviour |
| --- | --- |
| iPhone speaker (default) | Unchanged v8.8.1 behaviour: always the built-in speaker. |
| Headphones or earbuds | Plays only on wired, USB or Bluetooth headphones (AirPods etc.). Waits silently while none is the current output. |
| Any device | Plays wherever iOS is playing: Bluetooth speakers, AirPlay, wired, CarPlay, or the speaker. |

iOS does not let an app pick one specific Bluetooth device. For the last two modes, choose the device
with **Choose output device...** (this opens iOS's own output picker) or in Control Center. The helper
then accepts or refuses that route according to the mode.

**The PC can show up as an output.** Because the PC is connected over Bluetooth, iOS lists it as an
audio output, and v8.8 once played into it (silence). If **Playing on** shows your PC's name, tap
**Never play to current device** once; it is remembered. The helper checks the route *before*
activating audio, so it never starts output on a never-play device.

The tweak also now listens only to the PC's own signaling channel for stream start/stop, learned from
the PC's SET_CONFIGURATION for SEID 7. Earbud signaling therefore cannot pause the PC's stream, even if
the two devices happen to use the same endpoint number.

## Device test

1. Install the new nightly `.deb`. Open **Settings > Speaka**; **Session** should read `Off`.
2. Tap **Start** and confirm. Bluetooth restarts once; AirPods and other devices reconnect by
   themselves. Wait for "The iPhone is now a Bluetooth speaker". No PowerShell is needed.
3. On the PC, connect to the iPhone, choose it as the audio output and play music.
4. **Speaker** (default): audio from the iPhone speaker; **Playing on** shows `iPhone speaker`.
5. **Earbuds**: set **Play audio on** to *Headphones or earbuds* and connect AirPods.
   - If **Playing on** shows the PC (for example `LAPTOP-...`), tap **Never play to current device**.
   - Then **Choose output device...** and pick the AirPods.
   - Expect audio in the earbuds.
6. **Any device**: try an AirPlay or Bluetooth speaker, or wired headphones.
7. Pause and resume from the PC, and switch modes while playing.
8. Tap **Stop**: Bluetooth restarts without the experiment.

Export both logs right after a test. The daemon log wipes itself at 512 KB, which is about 2.5 minutes
of streaming:

```powershell
scp mobile@<phone-ip>:/tmp/FTABHarvest/Speaka.log "$env:USERPROFILE\Downloads\Speaka-v89.log"
scp mobile@<phone-ip>:/tmp/FTABHarvest/BTPSAudioHelper-v88.log "$env:USERPROFILE\Downloads\BTPSAudioHelper-v89.log"
```

## What to look for

The Settings build label still reads `v8.8-continuous-sbc-ring`, as it did for v8.8.1 and v8.8.2.
`diag.v89.build` in the debug log's status block identifies this build.

Daemon log (`Speaka.log`):

| Line | Meaning |
| --- | --- |
| `V89 build v8.9-one-tap-output-select` | New tweak loaded |
| `V89_SESSION Settings Start/Stop listener ready` | Start/Stop available |
| `V89_SESSION start nonce=... one-shot switches ARMED; restarting bluetoothd` | Request accepted, restarting |
| `V89_SESSION relaunched for start nonce=... result=ARMED` | Relaunch armed the trial |
| `V89_SESSION REFUSED: ...` | Request rejected; Bluetooth was not restarted |

Helper log (`BTPSAudioHelper-v88.log`):

| Line | Meaning |
| --- | --- |
| `V889_HELPER build=v8.9-output-select` | New helper running |
| `V889_OUTPUT_SETTINGS mode=headphones never_play=1` | Settings read |
| `V889_AUDIO_ROUTE stage=started mode=... type=... name=... route_ok=1` | Playing on that route |
| `V889_ROUTE_REFUSED stage=candidate reason=... device=...` | Waiting; refused before activation |
| `V882_AUDIO_STOP reason=output_settings_changed` | Mode or never-play list changed |
| `V881_RENDER ... route_ok=1 mode=...` | Per-second render summary; the route field replaces `built_in_speaker` |

Settings messages:

| Message | Meaning |
| --- | --- |
| "Still waiting: No answer from the tweak" | The tweak is not loaded or is older; check *Loaded in daemon*, or use the manual switches |
| "Bluetooth was not restarted" | The request was refused (reason shown); nothing changed |
| "Speaker not started" | The daemon restarted but refused the trial; the `diag.v82.trial` text is shown |
| "Waiting: no headphones connected" | Connect or pick headphones |
| "Waiting: on the never-play list: X" | Pick another device |

## Limits

- Bluetooth earbud output means the iPhone receives A2DP from the PC and sends A2DP to the earbuds at
  the same time. This is untested and may add stutter; the earbuds also add their own latency.
- Still one Bluetooth session per Start, by design: after a reboot or any Bluetooth restart, tap Start
  again.
- If **Choose output device...** does not open the picker, use Control Center.
- The choppy start seen in the 19:05 log (no jitter buffer before playback) is not addressed by this
  patch.

## Apply and build

Prepared against repository main commit `e1d01de878b7c6188ddbb6f831b042794ba2e14e`.

Upload the ZIP's extracted contents to the **root of the existing repository**, preserving the
`btpsaudiohelper/`, `speakaprefs/` and `tests/` folders, and commit them together. On GitHub web,
use **Add file > Upload files** at the repository root, then **drag** the extracted files and folders
onto the page. The "choose your files" dialog drops folder paths, which would put files in the wrong
place. The 16 files are:

```text
BTPSShared.h
BTPSV88Daemon.c
BTPSV89Session.c            (new)
BTPSV89Session.h            (new)
Makefile
README.md
TESTING-v8.9.md             (new)
Tweak.xm
btpsaudiohelper/BTPSV88Stream.m
btpsaudiohelper/BTPSV89Output.h          (new)
speakaprefs/BTPSRootListController.h
speakaprefs/BTPSRootListController.m
speakaprefs/Makefile
speakaprefs/Resources/Root.plist
tests/test_v881_audio_output.py
tests/test_v89_session_output.py         (new)
```

The workflow and packaging scripts need no changes. Wait for GitHub Actions to pass, then install
that commit's nightly `.deb`.

## Validation and limits of validation

Host run: **172 tests: 167 passed, 3 skipped, 1 expected legacy-decoder failure, and 1 failure that
needs the libsbc download** (`test_v88_runtime`, the same as before this patch; CI fetches libsbc).
The new tests compile and run:

- the request validation;
- the output-route policy for every mode, including never-play matching and built-in exclusions;
- the channel-scoped stream control with a colliding earbud SEID.

They also check fail-closed ordering (consume, validate, verify, then restart) and that every selector
named in `Root.plist` exists in the controller. These and the touched v8.8.1/v8.8.2 tests also pass
under AddressSanitizer and UndefinedBehaviorSanitizer:

```sh
python3 -m unittest discover -s tests -v
BTPS_SANITIZE=1 python3 -m unittest tests.test_v89_session_output tests.test_v881_audio_output tests.test_v882_idle_guard -v
```

`BTPSV89Session.c` was type-checked with `-Wall -Wextra -Werror -Wformat=2` against CoreFoundation,
dispatch and notify prototypes. The Objective-C (Settings page and helper) could not be compiled on
the host; the GitHub build is its first compile.
