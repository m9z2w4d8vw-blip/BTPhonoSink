# v8.9.2: Start actually reaches the tweak; Bluetooth toggles no longer fail silently

This source patch replaces v8.9.1. Audio output selection, the idle guard and the streaming path are
unchanged.

## What the 20:21 and 20:43 logs showed

Both logs come from the **same bluetoothd, pid 10073**, running continuously since about 19:02 with the
tweak built `Oct 29 22:57 UTC`, before v8.9 existed. Its status block has no `diag.v89.*` keys at all.

1. **Start had nobody to talk to.** Installing a `.deb` updates the Settings page immediately, but
   bluetoothd keeps running the tweak it launched with. The v8.9.0 and v8.9.1 Start listeners were never
   loaded, so "No answer from the tweak inside Bluetooth" was literally true. v8.9.1's premise, that
   v8.9.0's restart left Bluetooth down, was wrong: that code never ran.
2. **The laptop disconnects because the Sink was gone.** At 20:18:57 Bluetooth re-initialized **inside
   the same process**, the pattern of Bluetooth being switched off and on. Apple re-added all 12 of its SDP
   records and its six Source endpoints, but the tweak adds the Sink (SEID 7 and record `0x110B`) only once
   per bluetoothd launch. From 20:19 the PC connected seven times, sent DISCOVER, found no speaker endpoint,
   never configured a stream, and dropped.

Two more corrections to v8.9.1:

- **bluetoothd runs as `mobile`** (that is why Settings can read the preferences it writes), so
  `launchctl kickstart system/com.apple.bluetoothd` from inside it would be refused.
- **Turning Bluetooth off and on is not a restart** of bluetoothd, and it removes a running Sink. Advising
  it was wrong.

## What changed

| Change | Why |
| --- | --- |
| The package `postinst` restarts bluetoothd (`killall -9`, as root) after installing | A freshly installed tweak is always the one running, so Start always has a listener |
| Start/Stop restart bluetoothd by `SIGKILL` to itself again (v8.9.0's method) | launchd sees the same exit as after `killall -9`, which relaunches it on this phone; needs no privilege |
| Settings refuses to send Start to a daemon without `diag.v89.build`, and explains how to restart it once | No more silent 25-second waits |
| The tweak notices when Apple's endpoint registration runs again in the same process | Session shows `Off - Bluetooth was turned off and on; tap Start` instead of looking on |
| Every "toggle Bluetooth" suggestion is removed; the footer warns that a toggle removes the speaker | Following that advice caused the disconnect loop |

The tweak does **not** try to re-add the Sink after a toggle. The rebuilt endpoint table is back to six
slots, and repeating the private-memory steps on Apple's new objects without device testing is too risky.
Start (a real bluetoothd restart) brings it back.

## Device test

1. Install the new nightly `.deb`. Bluetooth restarts once during installation; devices reconnect.
2. **Settings > BTPhonoSink > View debug log:** the status block must show
   `diag.v89.build: v8.9.2-one-tap-output-select`. If it does not, the daemon is still old: run
   `sudo killall -9 bluetoothd` once or use Reboot Userspace in Dopamine.
3. Set **Play audio on** to **iPhone speaker** for this first test.
4. Tap **Start**. Bluetooth restarts once and Settings reports "The iPhone is now a Bluetooth speaker".
5. Connect from the PC, choose the iPhone as its output and play audio.
6. Optional: switch Bluetooth off and on. **Session** should change to
   `Off - Bluetooth was turned off and on; tap Start`. Tap Start and reconnect the PC.
7. Then try **Headphones or earbuds** with the earbuds connected. If **Playing on** shows the PC, use
   **Never play to current device**.
8. Tap **Stop** to end.

Daemon log lines:

| Line | Meaning |
| --- | --- |
| `V89 build v8.9.2-one-tap-output-select` | New tweak loaded |
| `V89_SESSION Settings Start/Stop listener ready` | Start/Stop will be answered |
| `V89_SESSION start nonce=... ARMED; restarting bluetoothd (SIGKILL, same as killall -9)` | Restarting |
| `V89_SESSION relaunched for start nonce=... result=ARMED` | Trial armed after relaunch |
| `V892 SINK_LOST native Source loop ran again ...` | Bluetooth was toggled; tap Start |

## Apply and build

Prepared on top of v8.9.1. Upload the ZIP's extracted contents to the repository root with **Add file >
Upload files**, dragging the files and folders so paths are preserved, and commit together:

```text
BTPSV89Session.c
README.md
TESTING-v8.9.1.md            (correction note added)
TESTING-v8.9.2.md            (new)
Tweak.xm
btphonosinkprefs/BTPSRootListController.m
btphonosinkprefs/Resources/Root.plist
layout/DEBIAN/postinst
tests/test_v89_session_output.py
```

The workflow's existing `chmod 0755` for `postinst` still applies.

## Validation

Host run: **176 tests: 171 passed, 3 skipped, 1 expected legacy-decoder failure, and 1 failure that
needs the libsbc download** (`test_v88_runtime`, unchanged; CI fetches libsbc). The five new or
rewritten v8.9 tests fail against v8.9.1 and pass here:

- self-`SIGKILL` restart with no `launchctl`;
- Settings version gate and no toggle advice;
- Sink-loss reporting, compiled from the real hook;
- the `postinst` restart (also syntax-checked with `sh -n`);
- request ordering.

They also pass under AddressSanitizer and UndefinedBehaviorSanitizer. `BTPSV89Session.c` type-checks with
`-Wall -Wextra -Werror -Wformat=2`. The Objective-C is first compiled by the GitHub build, and nothing
here has run on the phone yet.
