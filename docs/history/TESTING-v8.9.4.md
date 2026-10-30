# v8.9.4: earbuds without replugging, and switching outputs without reconnecting the PC

Builds on v8.9.3. The 21:39 export, the first to include the audio helper's own log, explained both symptoms.

## What the log proved

**1. "Headphones" played into the laptop.** iOS lists the sending PC as a Bluetooth A2DP output and sends the Playback
category to the most recently connected output. The PC connects after the earbuds, so every headphones-mode start
went to `type=BluetoothA2DPOutput name=LAPTOP-UGIVBIA5`, and the earbuds stayed silent. Replugging the earbuds made
them the newest output again, which is why only that worked.

**2. Leaving the laptop route killed the stream.**

| Time | Event |
| --- | --- |
| 21:35:27.782 | You switch to iPhone speaker; the helper stops playing to the laptop |
| 21:35:27.813 | 2 ms later the phone sends AVDTP SUSPEND (`TX ... msg=0 sig=9`) |
| 21:35:31.561 | The PC closes the stream (`RX ... sig=8`) |
| 21:35:33.905 | The PC reconnects on a new channel; speaker then plays for 68 s |

That is why the speaker only worked after reconnecting the PC.

**3. The helper never noticed a route change.** Across all six logs, not one route change or interruption was handled,
although earbuds were plugged in during playback. The helper's stream loop runs on its main thread and never ran
that thread's run loop. If AVAudioSession delivers these notifications there, they could never arrive.

Speaker mode itself is solid: 68 s and 57 s of continuous playback, PC pauses and resumes handled, and the idle guard
kept the stream 6 times.

## What changed

| Change | Effect |
| --- | --- |
| **Wired headphones or earbuds** mode uses Play-and-Record **without** any Bluetooth option | Bluetooth outputs, including the PC, can't be used at all, and a plugged-in wired or USB headset wins even if the PC connected later. No replugging; the sound never goes back to the PC, so switching modes no longer triggers the phone's SUSPEND. |
| The same mode never falls back to the loudspeaker | With nothing plugged in it waits; Playing on says "no wired headphones plugged in" |
| The helper drains its main run loop every 5 ms | Route changes and interruptions can now be delivered: plug-in, unplug and calls are noticed |
| An interruption is cleared by pause/play on the PC or by a settings change | Now that interruptions arrive, one without an "ended" can't mute the helper until Bluetooth restarts |
| `V882_HEALTH ... why=0x..` gives the helper's reason for not playing | 0x4 queue stopped, 0x10 enqueue error, 0x20 route not right for the mode (and others); explains the two unexplained 34 s health drops in speaker mode |

**Bluetooth earbuds** can't use the wired mode. Use **Any device**, tap **Never play to current device** once while
Playing on shows the PC, then pick the earbuds with **Choose output device...**. Your stored choice `headphones`
now means the wired mode.

## Device test

1. Install the new `.deb` (Bluetooth restarts once). Under **View debug log**, check for
   `diag.v89.build: v8.9.4-one-tap-output-select`.
2. Plug the earbuds in **first**. Choose **Wired headphones or earbuds**, tap **Start**, connect the PC and play.
   Audio should come out of the earbuds with no replugging. **Playing on** shows `Headphones (wired)`.
3. While it plays, switch to **iPhone speaker** and back a few times. Audio should keep going without reconnecting
   the PC.
4. In wired mode, unplug the earbuds (audio stops and it waits), then plug them back in (audio resumes within about
   a second).
5. Save the log from **View debug log**.

New lines to look for:

| Line | Meaning |
| --- | --- |
| Helper `V889_AUDIO_ROUTE stage=changed ...` | A route change was delivered: the run-loop fix works |
| Helper `V882_INTERRUPTION type=began reason=...` and `V894_INTERRUPTION_CLEARED by=...` | Interruption handling |
| `V882_HEALTH ... why=0x20` | Route not right for the selected mode |
| No `TX_SIGNAL ... msg=0 sig=9` right after a mode switch | The phone no longer pauses the PC's stream |

## Apply and build

Prepared on top of v8.9.3. Upload the ZIP's extracted contents to the repository root with **Add file > Upload files**,
dragging the files and folders so paths are preserved, and commit together:

```text
BTPSV88Daemon.c
README.md
TESTING-v8.9.4.md                          (new)
Tweak.xm
speakaprefs/Resources/Root.plist
btpsaudiohelper/BTPSV88Stream.m
btpsaudiohelper/BTPSV89Output.h
tests/test_v881_audio_output.py
tests/test_v89_session_output.py
tests/test_v894_wired_output.py            (new)
```

## Validation

Host run: **188 tests: 183 passed, 3 skipped, 1 expected legacy-decoder failure, and 1 failure that needs the libsbc
download** (`test_v88_runtime`, unchanged; CI fetches libsbc).

The seven new tests fail against v8.9.3. Each of these deliberate regressions is caught by at least one test:

- the interruption no longer cleared by a new stream;
- the wired pre-check refusing every candidate;
- the run loop no longer drained;
- Bluetooth counted as headphones;
- the wired mode allowed to use A2DP.

Two compiled tests run the real route policy and the daemon's health intake. Everything passes under
AddressSanitizer and UndefinedBehaviorSanitizer together with the v8.8.1, v8.8.2, v8.9 and v8.9.3 tests. Two
earlier tests were updated for the intended change: Play-and-Record now has exactly two uses, speaker and wired, and
the source must contain no recording, input, Bluetooth or AirPlay option anywhere. The Objective-C is first compiled
by the GitHub build.
