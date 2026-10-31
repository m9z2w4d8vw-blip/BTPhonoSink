# v9.1: no more Headphones / PC flicker

Builds on v9.0. With wired earbuds plugged in and **iPhone speaker** selected, Control Center switched between
*Headphones* and *LAPTOP-UGIVBIA5* about every 0.7 s and nothing played. The audio helper was causing it.

## What the 23:33 log and screen recording showed

The recording flips every 0.71 s, measured frame by frame. The log loops at the same rate, 0.73 s per cycle. One cycle
from the log:

| Time | Event |
| --- | --- |
| 23:32:56.206 | The helper stops its AudioQueue and deactivates its session: the stream generation changed |
| 23:32:56.338 | The PC accepts a START that **the phone** sent (`RX ... msg=2 sig=7`) |
| 23:32:56.445 | **The phone** sends SUSPEND (`TX ... msg=0 sig=9`) |
| 23:32:56.903 | The helper has activated its session again, on the speaker |
| 23:32:56.952 | Its AudioQueue starts... |
| 23:32:56.965 | ...and is stopped 13 ms later: the generation changed again |

Across the loop:

- All 25 STARTs and all 25 SUSPENDs came from the phone. The PC only accepted them. Its first command of its own was
  the SUSPEND at 23:33:44, after it had been sending silence for a while.
- Each START or SUSPEND moved the stream generation (+3 per cycle: 649, 652, 655...), and the helper restarted its
  output on every move. No AudioQueue lived longer than 30 ms (median 13 ms).

**Why the phone does this.** iOS lists the PC as a Bluetooth output because bluetoothd hands the PC to the audio
system like any A2DP device: `publish_audio_device` runs right after the PC's SET_CONFIGURATION. Apple's code then
starts and suspends the PC's stream from the phone whenever iOS's audio routing changes. Every time the helper
activated or deactivated its session, it changed that routing.

**Why it worked before.** The v8.8.1 and v8.9.4 speaker tests were run without headphones plugged in (the v8.8.1
instructions said so). With wired earbuds plugged in, the helper's session changes visibly move iOS's route between
the earbuds and the PC.

**Not explained yet.** At 23:33:12.941 the speaker override failed with error 4097. After that, iOS reported the PC as
the route even for Play-and-Record sessions, so the helper refused to play, correctly. Switching to wired mode at
23:33:27 did not change that. The new `V91_SESSION_CONFIG` and `V91_MEDIA_SERVICES_RESET` lines are there to explain
it next time.

The log does not show which helper action triggers which command (session activation or AudioQueue start). v9.1 does
not depend on the answer: `tests/test_v91_output_hold.py` models both, and the v9.0 rule loops under each.

## What changed

| Change | Effect |
| --- | --- |
| A running output is kept through every stream change (START, SUSPEND, close, reopen) | The audio session no longer changes because the stream did, which removes the loop |
| The output is released only after 8 s without audio | Covers Windows closing and reopening the stream after the phone suspends it (6.1 s in the 21:35 log, TESTING-v8.9.4) |
| After letting go on its own, the helper waits 3 s before activating again | Whatever iOS does, the helper cannot switch the route around faster than that |
| Starting from idle needs audible audio | A stream of exact digital silence never activates the session |
| Speaker mode re-applies its override on the live session after a route change | iOS drops the override on every route change; v9.0 deactivated instead, which re-routed iOS again |
| A new sample rate rebuilds only the AudioQueue | No session change |
| Route changes the helper caused itself no longer reset its retry backoff | After 23:33:12 it retried every 0.9 s |
| A media-services reset stops the output and configures from scratch | Previously not observed |
| The tweak logs `by=phone` or `by=pc` on every `V882_CONTROL` line | Logging only; nothing inside bluetoothd behaves differently |

The policy is plain C in `btpsaudiohelper/BTPSV91Hold.h`, like the route policy in `BTPSV89Output.h`.

**What it can't fix.** iOS still lists the PC as an output, because that happens inside bluetoothd. If the phone
suspends the stream when the helper first activates, playback starts once Windows reopens the stream (about 6 s), then
stays.

## Device test

1. Install the new nightly `.deb` (Bluetooth restarts once). Under **View debug log**, check for
   `diag.v89.build: v9.1.0-one-tap-output-select` and the helper line `V889_HELPER build=v9.1.0-output-select`.
2. Set up as at 23:33: plug in the wired earbuds, set **Play audio on** to **iPhone speaker**, tap **Start**, connect
   the PC and play music.
3. Watch Control Center's output list for about 20 seconds. Expect no flicker, and audio from the iPhone speaker
   within about a second, or about 6 seconds if Windows reopens the stream once.
4. Pause on the PC for 15 seconds, then play again. Then switch to **Wired headphones** while it plays, and back.
5. Repeat step 2 with the earbuds unplugged, the setup that already worked in v8.9.4, to check nothing regressed.
6. Right after, open **View debug log** and use **Save Log to iCloud Drive**.

Lines to look for:

| Line | Meaning |
| --- | --- |
| `V882_CONTROL ... by=phone` | The phone itself started or suspended the PC's stream |
| `V882_CONTROL ... by=pc` | The PC did |
| Helper `V91_SESSION active=1 why=speaker` | The helper activated its session. Expect one per playback, not one per second |
| Helper `V91_SESSION active=0 why=...` | It deactivated, and why |
| Helper `V91_STREAM_CHANGE ... output=kept` | A stream change that no longer restarts the output |
| Helper `V91_HOLD_EXPIRED no_media_ms=...` | The output was released after 8 s without audio |
| Helper `V91_START_DEFERRED reason=rearm_wait` or `silent_stream` | Why the helper is waiting to start |
| Helper `V91_ROUTE_CHANGE reason=... own_echo=...` | Every route change, and whether the helper caused it |
| Helper `V91_SPEAKER_REASSERT ok=1 selected=1` | Speaker mode won the speaker back without re-routing iOS |
| Helper `V91_SESSION_CONFIG category=...` | The category actually in effect at each start |
| Helper `V91_MEDIA_SERVICES_RESET` | iOS's audio server restarted |

If the flicker is still there, the export now shows which helper session changes line up with each `by=phone` START
and SUSPEND. That decides the next step: keeping bluetoothd from publishing the PC as an output at all, which needs the
daemon binary to verify first.

## Apply and build

Prepared on top of v9.0 (commit `e0f7a1241c7be84fa325bad78e3ce7a177661596`). Copy the ZIP's contents over your clone of
the repository, keeping the folder paths, and commit together:

```text
README.md
Tweak.xm
btpsaudiohelper/BTPSV88Stream.m
btpsaudiohelper/BTPSV91Hold.h              (new)
docs/history/TESTING-v9.1.md               (new)
tests/test_v894_wired_output.py
tests/test_v91_output_hold.py              (new)
```

## Validation

Host run: **215 tests: 210 passed, 3 skipped, 1 expected legacy-decoder failure, and 1 failure that needs the libsbc
download** (`test_v88_runtime`, unchanged; CI fetches libsbc). The four new tests also pass under AddressSanitizer and
UndefinedBehaviorSanitizer.

- The policy test runs the real header through the 23:33 pattern and checks that the output is kept on every change,
  released exactly once after the PC stops, and that automatic activations stay at least 3 s apart.
- The model test drives the v9.0 rule and the v9.1 policy through both possible mechanisms with the timing from the
  log. v9.0: 97 and 84 activations a minute, nothing played. v9.1: one activation, 59.4 s and 53.7 s of 60 s played.
- The control-log test feeds the exact PDUs from the 23:33 log through the tweak's real signal handler and checks
  every `by=`.
- One existing test was updated for the intended change: the helper now registers three notification observers
  (media-services reset is the new one).

The Objective-C is first compiled by the GitHub build; there is no Apple compiler on the host. The helper changes were
applied as exact-match edits and checked for balanced brackets and declaration order.
