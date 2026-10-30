# v8.8.2: native idle-check guard

This source patch builds on v8.8.1. Playback remains on the **iPhone speaker**.
The new behavior needs an iOS build and a device test before it can be called a
confirmed fix for the repeated cutout.

## What the new log proves

The exported October 29 log captures successful forwarding, decoding and PCM
output up to a locally initiated suspension:

```text
13:50:31.868 V82 TX_SIGNAL #10 CID=0x108 tx=3 pkt=0 msg=0 sig=9 len=3
13:50:31.869 V82 TX_RAW #10 +0 30 09 d0
13:50:31.885 V88_STREAM active=0 generation=9
13:50:31.892 V82 RX_SIGNAL #10 CID=0x108 tx=3 pkt=0 msg=2 sig=9 len=2
13:50:31.910 V88_STREAM active=0 generation=10
13:50:31.992 V88_AUDIO status=1 rate=0
```

Signal 9 is AVDTP SUSPEND. The iPhone sends it and the PC accepts it. Just before
that, the captured PCM/render summaries show nonzero audio and no underrun
silence. A later `queue_running=0 query_status=-1` means the helper has disposed
its queue; `-1` here is our no-queue sentinel, not an AudioQueue API error.

The export covers only the end of this session. It establishes the SUSPEND
sequence, but does not identify which native caller initiated it.

## Targeted native behavior

The verified iOS 17.0 bluetoothd contains a dedicated idle-check function at
`+0x376034`. It looks up an audio-device entry, requires state 5, and reads its
mediaserverd-streaming flag via `+0x593398`. If false, it prepares suspension,
calls `AVDTP_Suspend` at `+0xD1DE8`, and sets native state 6.

That is a likely explanation for this experiment: the separate helper owns
playback, while native mediaserverd streaming is absent. Runtime
`V882_IDLE_GUARD action=keep` records are needed to confirm that this check fires
on the phone. If another native path sends SUSPEND, this patch intentionally
does not block it.

The replacement wraps the complete idle-check function. It skips that check only
when all of these conditions hold:

- Both existing one-shot switches armed this daemon lifetime and Sink registration
  succeeded.
- The owner pointer and handle match the latest SetConfigInd for local SEID 7.
  Both native paths use the same owner/key lookup. The wrapper reads no private
  object fields and performs no map lookup.
- The shared stream has a currently accepted START generation.
- Successful incoming packet publication and successfully enqueued decoded PCM
  have advanced within 1.5 seconds; the helper heartbeat advanced within 1 second.
- The helper reports a running AudioQueue on the built-in speaker, without an
  enqueue error, and its IPC connection is still open.
- A worker-issued 500 ms health lease is valid for this same generation.

Failed conditions call the original idle check. A real STOP invalidates the
lease immediately; another START must establish fresh health. Silence decoded
from valid SBC is permitted, while AudioQueue-generated underflow silence alone
does not count as PCM progress. Freshness is checked outside the receive callback.

The patch does not drop or fake AVDTP commands/responses, force a START, alter
native streaming flags, or override explicit Suspend/Close/Abort. It retains
the v8.8.1 speaker route and one-shot behavior. The shared-memory structure size
and protocol version are unchanged; helper health uses a new event kind.

## Apply and build

Prepared against repository main commit
`b232d06f5c095083c321f223a54ddb0bdef8ab9f` (the v8.8.1 upload).

Upload the ZIP's extracted contents to the existing repository root, preserving
the `btpsaudiohelper/` and `tests/` folders. Commit these nine files together:

```text
Tweak.xm
BTPSV88Daemon.c
BTPSV88Daemon.h
BTPSV88Shared.h
BTPSV882Health.h
btpsaudiohelper/BTPSV88Stream.m
tests/test_v881_audio_output.py
tests/test_v882_idle_guard.py
TESTING-v8.8.2.md
```

Wait for GitHub Actions on that commit to pass and install its new nightly `.deb`.
The ZIP contains source, not an installable package. The existing workflow and
maintainer-script permission fix need no changes.

## Device test — current IP 10.0.0.128

1. Install the new `.deb` and set the phone speaker to a moderate volume.
2. In **Settings > Speaka**, enable **Arm seven slots for ONE restart** and
   **Arm real Sink SDP + signaling ONCE**. Keep the legacy experiment off.
3. From **Windows PowerShell**, restart Bluetooth once:

   ```powershell
   ssh -t mobile@10.0.0.128 "sudo killall -9 bluetoothd"
   ```

4. Wait for Bluetooth to return. Both switches should have reset off. Reconnect
   the PC, select the phone as the PC's audio output and play music continuously
   for at least two minutes without pausing it.
5. Watch both logs in another PowerShell window:

   ```powershell
   ssh mobile@10.0.0.128 "tail -n 30 -f /tmp/FTABHarvest/Speaka.log /tmp/FTABHarvest/BTPSAudioHelper-v88.log"
   ```

   Ctrl+C stops log watching. The helper still uses the `v88` log filename.

Look for `V882_IDLE_GUARD installed` in the daemon log and
`V882_HELPER build=v8.8.2-idle-guard` in the helper log. The main Settings build
label remains `v8.8-continuous-sbc-ring`; `diag.v882.idle_guard` identifies the
new guard and retains its successful bypass count after older log lines roll off.

During playback, expect `V882_HEALTH ready=1` and continuing nonzero `V881_PCM`
and `V881_RENDER` counts. If the native idle check fires, a
`V882_IDLE_GUARD action=keep` record should appear while playback continues.
Then pause and resume from the PC, and disconnect, to verify intentional stops.

If audio cuts out, leave the PC playing for about five seconds and export both
logs before trying pause/resume:

```powershell
scp mobile@10.0.0.128:/tmp/FTABHarvest/Speaka.log "$env:USERPROFILE\Downloads\Speaka-v882.log"
scp mobile@10.0.0.128:/tmp/FTABHarvest/BTPSAudioHelper-v88.log "$env:USERPROFILE\Downloads\BTPSAudioHelper-v882.log"
```

New diagnostics distinguish the remaining possibilities:

- `V882_IDLE_GUARD action=keep`: the guarded native idle check was bypassed.
- `action=pass`: the configured Sink was inactive or its health lease was absent.
- `V882_HEALTH ready=0`: activity ages and playback state explain lost eligibility.
- `V882_CONTROL direction=TX ... sig=9 active=0`: another local suspension occurred.
- `V882_AUDIO_STOP reason=...`: distinguishes stream-generation change, media
  inactivity, interruption, route change, enqueue failure and IPC closure.

To end the trial, keep both switches off and restart Bluetooth with the same
command. To revert this patch, reinstall the previous v8.8.1 package.

## Validation and limits

Local validation completed **164 tests: 162 passed, one expected legacy-decoder
failure, one skipped legacy device-path test**. Seven targeted output/guard tests
also passed with AddressSanitizer and UndefinedBehaviorSanitizer. The complete
daemon C file compiles on the host with warnings treated as errors.

Tests cover the actual idle wrapper's owner/handle scoping and inactive paths,
stalled packet/heartbeat/PCM progress, disconnected IPC, generation changes,
counter wrap, lease expiry, STOP invalidation and late old-generation leases.
All seven native instruction fingerprints match the supplied daemon:

```text
UUID:   5491BA47-B5AE-3D44-9536-B30161DF1E90
SHA256: e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6
```

The same UUID and instruction gates are checked on-device before hook installation.
The 8-byte predicate at `+0x593398` is verified but not patched; the hook is at
the full idle-check function. CI does not contain the device binary, so its new
binary-fingerprint test skips unless `BTPS_BLUETOOTHD` is supplied.

```sh
python3 -m unittest discover -s tests -v
BTPS_SANITIZE=1 python3 -m unittest discover -s tests -p 'test_v88[12]*.py' -v
```

The host has no iPhoneOS SDK. Native hook execution, iOS compilation, and sustained
playback on the phone remain to be verified. No guarantee is made that this is
the only native path capable of suspending the connection.

Protocol reference: [BlueZ A2DP transport walkthrough](https://kernel.googlesource.com/pub/scm/bluetooth/bluez.git/+/a93047cd044fb17d687f43bef95289ec834876b2/doc/btmon-a2dp.rst).
