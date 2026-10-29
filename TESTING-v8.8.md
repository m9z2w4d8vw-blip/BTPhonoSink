# v8.8 continuous SBC forwarding

v8.8 replaces the native no-op media callback with shared-memory forwarding to
BTPSAudioHelper. It is still an explicitly armed, one-restart experiment for the
analysed iOS 17.0 bluetoothd. Compilation and host tests do not establish that
live CoreAudio output or launchd activation works on the phone.

## Install and test

1. Install the new nightly `.deb`. Package installation registers a socket-activated
   helper; it does not restart Bluetooth or arm a trial. Keep your v8.7 package.
2. In Settings > BTPhonoSink enable **Arm seven slots for ONE restart** and
   **Arm real Sink SDP + signaling ONCE**. Keep the legacy experiment OFF.
3. From Windows PowerShell restart Bluetooth once:
   `ssh -t mobile@10.5.4.185 "sudo killall -9 bluetoothd"`
4. Check the debug log for `v8.8-continuous-sbc-ring`, `V88_PREPARE ready`,
   `V88_CALLBACK installed`, and the existing successful SEID 7/SDP registration.
   A failed gate refuses live forwarding. Both switches must already read OFF.
5. Connect from the PC, select the phone as its audio output, and play music.
   Begin at moderate phone volume. No manual helper command or token is needed.
6. Look for `V88_CONFIG handle=...`, `V88_STREAM active=1`,
   `V88_HELPER mapped shared ring`, `V88_FORWARD bytes=... result=0`,
   `V88_DECODE frames=... result=0`, and `V88_AUDIO status=0 rate=...`.
   Pause, resume, and disconnect. The helper stops output after two seconds without
   packets; explicit Suspend/Close/Abort stop it sooner. A new accepted START resumes.
7. To end the trial, leave both switches OFF and restart Bluetooth once. The helper
   connection closes when bluetoothd exits; launchd leaves the helper dormant.

Export both process logs from PowerShell if silent or unstable:

```powershell
scp mobile@10.5.4.185:/tmp/FTABHarvest/BTPhonoSink.log "$env:USERPROFILE\Downloads\BTPhonoSink-v88.log"
scp mobile@10.5.4.185:/tmp/FTABHarvest/BTPSAudioHelper-v88.log "$env:USERPROFILE\Downloads\BTPSAudioHelper-v88.log"
```

`V88_FORWARD result=-1` means inactive; `-3` wrong handle; `-4` native error;
`-5` zero/null payload or payload over 2048 bytes. `-2` means a pinned queue slot
prevented bounded enqueue.
`V88_DECODE result=1` is an incomplete SBC fragment; negative values reject malformed
payloads. `V88_AUDIO` errors distinguish session/queue failure from successful decode.
`V88_DROP` reports packet and deferred-log loss. Audio-route names appear in the helper
log. Do not infer audible output from decode or AudioQueue start success alone.

## Architecture and limits

- The verified callback is only a four-byte RET. No instruction at `+0x385DFC` is
  patched. A process-lifetime copy of all 27 native callback pointers replaces the
  table at AVDTP context `+0x18`; only slot `+0xB0` changes. The replacement uses
  ARM64e IA signing with discriminator zero, matching `braaz x8` at `+0xD8FA4`.
  Existing callback pointers retain their exact signed bits.
- Callback ABI: x0 stream handle, w1 RTP sequence, w2 timestamp, x3 stripped payload,
  w4 length, w5 payload type, w6 marker, w7 error. The first payload byte is the A2DP
  SBC media header, not SBC sync. The callback preserves the old x0 return value.
- SetConfigInd supplies the Sink handle (x2), local SEID (x3), remote SEID (x4).
  Only that handle is forwarded after a correlated START accept. No private CID
  lookup, channel-structure reads, thread-local allocation, or log I/O on media RX.
- Shared memory is a 0600, random-name, MAP_SHARED file in the daemon's existing
  writable `/tmp/FTABHarvest` directory. The entire mapping is initialized and
  locked before callback installation; failed `mlock` refuses the trial.
  It contains 32 x 2048-byte payload slots (64 KiB), metadata and bounded log queues.
  Payload copies publish atomically using per-slot release/acquire sequence numbers.
- Producer drops the oldest complete packet when full. A reader owns its slot
  through copy completion. All retries are bounded; if a preempted owner pins a
  slot, a new packet may be dropped instead. No consumer memory is overwritten.
  Helper death during a claimed dequeue can pin a slot for this daemon lifetime;
  end the trial and restart Bluetooth before rearming in that case.
- Every callback queues a `V88_FORWARD` record; every helper decode queues a
  `V88_DECODE` record back to the daemon worker. Logs are deferred, not synchronous.
  Sustained logger stalls can drop records; `V88_DROP log_records=N` makes that
  visible. The heartbeat timer multiplication bug is fixed as part of this change.
- A shared atomic doorbell signals new data. The helper polls at 5ms; the daemon
  worker polls control/logs at 20ms. Socket connect, activation, sleeps, decode,
  allocation and AudioQueue setup occur outside the Bluetooth receive callback.
- Reuses the v7.4 loopback connector and timeouts, with live protocol on **37594**.
  Existing diagnostic fixture modes keep **37593**. A separate socket avoids
  breaking their manual listeners. v7.4 by itself could not launch a helper;
  launchd socket activation now does that only when the worker connects after START.
- Continuous pinned Google libsbc decoder supports 44.1/48 kHz, mono duplicated to
  stereo, multiple frames, SBC fragment reassembly, sequence-wrap and loss reset.
  Partial/malformed packets are rejected. AudioQueue consumes stereo signed 16-bit
  PCM; underflow or a busy PCM buffer produces silence, overflow drops old PCM.
  Interruption notifications stop output and reset decoding. Native source roles
  remain registered; simultaneous source+sink audio routing needs a device test.
- Shared files survive `kill -9` and are not reused by a later PID/token. They contain
  recent compressed audio, not a recording archive. To remove stale files, end the
  trial and restart Bluetooth with switches OFF, then remove only
  `/tmp/FTABHarvest/BTPS-v88-*.shm` belonging to terminated trial processes.

## Binary provenance

SHA-256 `e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6`;
UUID `5491BA47-B5AE-3D44-9536-B30161DF1E90`.
Runtime gates require the exact UUID, baseline hooks, media prologue, original table
address `+0x92A248`, all 27 stripped callback targets, `RET` at `+0x385DFC`,
`ldr x0,[x8,#0xB0]` at `+0xD8F28`, `braaz x8` at `+0xD8FA4`, and
`str x22,[x8,#0x18]` at `+0xCE3D4`. Native register stores a borrowed static table;
the replacement table has process lifetime and is never freed.

Apple references: [launch_activate_socket](https://developer.apple.com/documentation/xpc/launch_activate_socket),
[Audio Queue Services](https://developer.apple.com/documentation/audiotoolbox/audio-queue-services),
[Clang pointer authentication](https://clang.llvm.org/docs/PointerAuthentication.html).

## Validation

Run `bash tools/fetch_google_sbc.sh` then `python3 -m unittest discover -s tests -v`.
`BTPS_SANITIZE=1 python3 -m unittest discover -s tests -p test_v88_runtime.py -v`
runs the new portable code with address/undefined-behavior sanitizers. Pinned
upstream SBC uses signed fixed-point shifts, so it receives ASan only; our adapter,
queues, and control receive both. LeakSanitizer is disabled because this runner
cannot inspect /proc tasks.

New tests exercise overflow, a pinned reader, 100,000 cross-process packets, START
transaction matching and 500 repeats, bit-for-bit PCM equivalence to v7.6 over the
258-frame fixture, sequence gaps/wrap, fragment reassembly, CRC/truncation rejection,
real 48 kHz stereo/mono encoding, and 10,000 malformed payloads. Existing fixture
waveform tests compare the pinned decoder against the exported FFmpeg WAV.
