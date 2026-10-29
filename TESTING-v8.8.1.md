# v8.8.1 speaker-route test

This is a source update for the existing v8.8 installation. Rebuild and install
the resulting `.deb` before testing. This diagnostic build selects the **iPhone's
built-in speaker**; external headphones are outside this test.

## What the supplied logs establish

The supplied daemon-log segment contains 769 successful media forwards and 770
successful decode calls, totaling 6,160 SBC frames. The log starts mid-stream, so
the one-record difference is not evidence of lost or corrupted audio.

Both helper-log entries report:

```text
V88_AUDIO_ROUTE type=BluetoothA2DPOutput name=LAPTOP-UGIVBIA5 rate=44100 volume=0.550
```

The output route is the sending laptop. Decode success alone does not establish
nonzero PCM or audible playback. The `-66632` enqueue error appears after the
stream stops; a stop/callback race is consistent with that ordering and is guarded
in this patch.

## Changes

- Configure `PlayAndRecord` with `DefaultToSpeaker`, explicitly override to the
  speaker, and check the selected route before starting AudioQueue. Bluetooth and
  AirPlay output options are not enabled. No recording or input queue is created.
- If the speaker cannot be selected, log the failed stage and refuse to start
  output. Observe route changes and restart speaker output if the route changes
  away from the built-in speaker.
- Add decoded PCM sample counts, nonzero counts and absolute peak; add AudioQueue
  callback, enqueued PCM, underrun, queue-running and route diagnostics.
- Mark output as stopping before stopping/disposal, and suppress enqueue errors
  caused by teardown so they cannot carry into the next START.

The new diagnostic events use the existing event layout. The media callback,
shared-memory protocol version, SBC decoder and one-shot activation remain as in
v8.8. The Settings/daemon build label still says `v8.8-continuous-sbc-ring`; the
new helper identifies itself with `V881_HELPER build=v8.8.1-speaker-route`.

## Apply and build

The ZIP contains these files at their repository-relative paths:

```text
BTPSV88Daemon.c
BTPSV88Shared.h
btpsaudiohelper/BTPSV88Stream.m
tests/test_v881_audio_output.py
TESTING-v8.8.1.md
```

Upload the extracted files and folders into the **root of the existing repository**
and commit them together. Preserve the `btpsaudiohelper/` and `tests/` paths.
This patch was prepared against main commit
`9448b69d5c07f55f35fa9af8dc66d472b8bd704d`.

Wait for the build workflow on that commit to pass, then install its new nightly
`.deb`. A source ZIP is not an installable package. The existing workflow runs
the tests, builds arm64 and arm64e with the iPhoneOS SDK, and publishes the package.

## Run on the phone

1. Disconnect other headphones for this speaker test. Set the phone to a moderate
   volume. Install the new `.deb`; its post-install script reloads the helper service.
2. In **Settings > BTPhonoSink**, enable **Arm seven slots for ONE restart** and
   **Arm real Sink SDP + signaling ONCE**. Keep the legacy experiment off.
3. Run this in **Windows PowerShell**:

   ```powershell
   ssh -t mobile@10.5.4.185 "sudo killall -9 bluetoothd"
   ```

4. Wait for Bluetooth to return. Both one-shot switches should now be off. Connect
   from the PC, select the iPhone as the PC's audio output, and play music for at
   least 20 seconds. The helper starts automatically after accepted START.
5. Watch the helper log from another PowerShell window:

   ```powershell
   ssh mobile@10.5.4.185 "tail -n 40 -f /tmp/FTABHarvest/BTPSAudioHelper-v88.log"
   ```

   Press **Ctrl+C** to stop watching the log. This does not stop the stream.

The log path still contains `v88`; use the new `V881_` records to identify this
build. During music, look for:

| Record | Expected signal |
| --- | --- |
| `V881_HELPER` | `build=v8.8.1-speaker-route` |
| `V881_AUDIO_ROUTE` | `built_in_speaker=1` |
| `V881_PCM` | During music: `samples>0`, `nonzero>0`, `peak>0` |
| `V881_RENDER` | `callbacks>0`, `pcm_frames>0`, `nonzero_samples>0`, `queue_running=1`, `query_status=0`, `built_in_speaker=1` |

`V881_PCM` and the callback/enqueue counters are **per reporting interval**, not
cumulative totals or exact per-second rates. Reports occur about once a second.
`dropped_frames` is cumulative. `pcm_frames` counts successfully enqueued stereo
frames; it does not prove that a speaker physically produced sound.

If still silent, export both logs while music is playing:

```powershell
scp mobile@10.5.4.185:/tmp/FTABHarvest/BTPhonoSink.log "$env:USERPROFILE\Downloads\BTPhonoSink-v881.log"
scp mobile@10.5.4.185:/tmp/FTABHarvest/BTPSAudioHelper-v88.log "$env:USERPROFILE\Downloads\BTPSAudioHelper-v881.log"
```

- No `V881_HELPER` entry: verify that the new package installed and a new helper
  process was launched.
- `V881_AUDIO_FAIL`: its stage and NSError domain/code identify session failure;
  `V88_AUDIO status=-102` means the built-in speaker route was not established.
- Nonzero decoded PCM with no callbacks or `queue_running=0`: playback setup or
  interruption is the next fault to investigate.
- Callbacks with only `silence_frames`: examine PCM availability and underruns.
- Nonzero PCM being enqueued with speaker selected and queue running: retain both
  logs and report whether other audio apps can play through the iPhone speaker.

To end the trial, leave both one-shot switches off and run the same Bluetooth
restart command once. To revert the code, reinstall the prior v8.8 package.

## Validation and limits

Host validation: **159 tests completed, with one expected legacy-decoder failure
and one skipped device-binary test**. The new test compiles the actual PCM callback
against a fake AudioQueue and exercises wraparound, short-buffer silence, lock
contention, stop/enqueue overlap, error reporting and sample-level measurements.
It also passes with AddressSanitizer and UndefinedBehaviorSanitizer.

```sh
python3 -m unittest discover -s tests -v
BTPS_SANITIZE=1 python3 -m unittest discover -s tests -p test_v881_audio_output.py -v
```

The local host has no iPhoneOS SDK. This patch has not yet been compiled against
that SDK or tested for audible output on the phone; the GitHub build and device
test are still required.

Apple documents the speaker override's PlayAndRecord requirement and its
route-change behavior in
[overrideOutputAudioPort](https://developer.apple.com/documentation/avfaudio/avaudiosession/overrideoutputaudioport(_:))
and [QA1754](https://developer.apple.com/library/archive/qa/qa1754/_index.html).
