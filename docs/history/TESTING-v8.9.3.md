# v8.9.3: logs that cover the whole session and show where the audio went

This patch builds on v8.9.2 and changes **diagnostics only**: what is logged and what the Settings export contains.
The audio path, the Start button and the idle guard behave exactly as in v8.9.2.

## What the 21:06 log showed

v8.9.2 works as intended. Start relaunched bluetoothd (`diag.v89.session ... result=ARMED`), the Sink registered, the
PC stayed connected, and every packet in view was forwarded and decoded cleanly.

The cutoff at the end:

| Time | Event |
| --- | --- |
| 21:05:36 to 21:05:41 | The PC sends exact digital silence (`nonzero=0`) while packets keep arriving; most likely a song change |
| 21:05:41.17 | The audio helper reports it stopped playing |
| 21:05:41.18 | The **phone itself** sends AVDTP SUSPEND to the PC; music stops while Bluetooth stays connected |

The idle guard logged nothing before that SUSPEND, so this was not the v8.8.2 idle-check path. The helper also
reported its output volume as 0%.

The log could not show which device the helper played to, and it covered only the last 7.5 seconds of a 3-minute
session: 453 of its 480 lines were per-packet `V88_FORWARD` / `V88_DECODE` success lines.

**Leading hypothesis (not confirmed):** in *Headphones or earbuds* or *Any device* mode, iOS can route the audio back
into the laptop's own Bluetooth connection, which appears as a headphone-type output. That would explain no sound from
the iPhone or the earbuds. iOS pausing that connection once it carried only silence would explain the stop on a song
change. In *iPhone speaker* mode the helper's audio never touches Bluetooth. The export from the test below will
confirm or rule this out.

## What changed

| Change | Effect |
| --- | --- |
| Daemon counts packets and writes one `V893_RX` summary every 2 s and before every stream state change | The same log now covers about 6 minutes instead of 7 seconds |
| Abnormal forward/decode results are still logged one per line, up to 8 per window | Errors stay visible; `held_back=` counts the rest |
| `V881_PCM` and `V881_RENDER` are written as one line | Half the lines for audio levels |
| The Settings export gains an **AUDIO HELPER** section | Mode, never-play list, helper status with output device, type and volume, plus the helper's own log |
| Helper log lines are timestamped like the daemon log | The two logs can be matched line by line |
| **Playing on** names the device type, e.g. `LAPTOP-... (Bluetooth)`, and flags `volume 0%` | Routing to the laptop, or a muted route, is visible at a glance |

## Device test

1. Install the new nightly `.deb` (Bluetooth restarts once). Under **View debug log**, check for
   `diag.v89.build: v8.9.3-one-tap-output-select`.
2. **Test A, speaker:** set **Play audio on** to **iPhone speaker**, tap **Start**, connect from the PC and play music.
   Turn the iPhone volume up while it plays. Change songs a few times, then pause and resume. Note whether audio
   continues after each change.
3. **Test B, earbuds:** connect the earbuds, set **Headphones or earbuds**, and while music plays look at **Playing on**.
   - If it names the laptop with `(Bluetooth)`, tap **Never play to current device**.
   - Then use **Choose output device...** and pick the earbuds.
   - Change songs again.
4. Right after each test, open **View debug log** and use **Save Log to iCloud Drive** (or **Copy log to clipboard**).
   No scp is needed; the export now includes the helper.

Lines to look for:

| Line | Meaning |
| --- | --- |
| `V893_RX 2000ms forwarded=62 ok=62 ... decoded=62 ok=62 ...` | Two seconds of healthy reception |
| `V881_PCM samples=... nonzero=... peak=... \| RENDER ... silence_frames=...` | Audio level and underruns |
| `V82 TX_SIGNAL ... msg=0 sig=9` | The phone sent SUSPEND |
| `V82 TX_SIGNAL ... msg=0 sig=7` | The phone sent START, i.e. iOS tried to use the PC as an output |
| Helper `V889_AUDIO_ROUTE stage=started mode=... type=... name=...` | Exactly where the audio went |
| Helper `V882_AUDIO_STOP reason=...` | Why the helper stopped |

## Apply and build

Prepared on top of v8.9.2. Upload the ZIP's extracted contents to the repository root with **Add file > Upload files**,
dragging the files and folders so paths are preserved, and commit together:

```text
BTPSShared.h
BTPSV88Daemon.c
README.md
TESTING-v8.9.3.md                         (new)
Tweak.xm
btpsaudiohelper/BTPSV88Stream.m
speakaprefs/BTPSLogReader.m
speakaprefs/BTPSRootListController.m
tests/test_v893_diagnostics.py            (new)
```

## Validation

Host run: **181 tests: 176 passed, 3 skipped, 1 expected legacy-decoder failure, and 1 failure that needs the libsbc
download** (`test_v88_runtime`, unchanged; CI fetches libsbc). The five new tests fail against v8.9.2 and pass here.
The main one compiles the real daemon source with a fake event queue and checks the summary arithmetic, the
per-window error cap and the PCM/RENDER pairing. They also pass under AddressSanitizer and
UndefinedBehaviorSanitizer, together with the v8.8.1, v8.8.2 and v8.9 tests. The helper's timestamp function was
compiled and run on its own; the Objective-C is first compiled by the GitHub build.
