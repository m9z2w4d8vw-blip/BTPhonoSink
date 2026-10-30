# Speaka v8.7 — Raw media-handler entry counter

**Change relative to v8.6:** replace ONLY the media hook's inspection logic. The experimental v8.5/v8.6 endpoint, SDP, seven-entry audio table, 44.1/48kHz SBC settings, RX/TX signaling, and existing one-shot controls are unchanged. There is no live SBC forwarding or playback in v8.7.

## Binary provenance

Uploaded `bluetoothd` SHA-256:
`e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6`

UUID: `5491BA47-B5AE-3D44-9536-B30161DF1E90`.

The only media hook is `bluetoothd` image offset `+0xD8CF8`, with required first four ARM64e instruction words:
`d503237f d10203ff a90367fa a9045ff8`.

`+0xD8D18: mov x20, x2` and `+0xD8D1C: mov x21, x1` identify input registers: `w0` is local L2CAP CID, `x1` is packet pointer, `w2` is incoming buffer length. The observer does **not** dereference `x1` or any L2CAP channel entry, call the private CID lookup, inspect RTP bytes, or patch the `+0x385DFC` no-op callback.

The one-shot trial must install the media hook before experimental Sink SEP registration. If the hook fails signature verification or fails to return a trampoline, the Sink trial is refused.

## Recording semantics

- On entry: increments global `g_v87_media_calls`; stores **raw `w0` CID and raw `w2` length** with a sequence number into an 8-entry circular history.
- Logs a `V87_MEDIA_ENTER` line on the first 8 calls and each 64th call. This is an early breadcrumb in case Apple's original handler crashes before returning.
- Calls Apple's original handler with all original integer argument registers, once and unchanged.
- If the original returns: adds the raw length to a running total and emits `V87_MEDIA_RX cid=... bytes=... total=...` on the same sample schedule; updates existing `diag.v86.media` status key (for compatibility with the current Settings viewer).
- The global eight-entry ring is **in-process volatile diagnostic memory**. It is *not persisted across a crash*. Only emitted log lines persist in the existing debug logger.
- Both totals are **raw L2CAP media-handler input bytes**, *not proven SBC payload bytes*. A call before Sink START or on another CID does not prove the bytes belong to Sink SEID 7. This version intentionally does not parse/correlate channel structures; correlate by event timing and later peer capture.

## Controlled test

1. Install the completed CI `.deb`. Keep a functioning v8.5 backup. With the two one-shot switches OFF, verify regular headphones still work. Disconnect them.
2. In Settings > Speaka, enable **Arm seven slots for ONE restart** and **Arm real Sink SDP + signaling ONCE**; keep Legacy Sink OFF.
3. Restart `bluetoothd` *once* via the current reachable IP (historically `10.5.106.42`):
   `ssh -t mobile@10.5.106.42 "sudo killall -9 bluetoothd"`
4. Confirm `build: v8.7-raw-media-entry-counter`, `V87 MEDIA hook installed`, `V83 AUDIO_TABLE SWAPPED`, `V83 SEP RESULT ret=0 seid=7`, `V83 SDP add ret=0` in the initial debug log. If any fails, stop and export; do not pair Windows.
5. Connect once from Windows. Play ordinary continuous audio for up to 30 seconds. If the daemon disconnects, **do not restart or rearm immediately**. Capture `/tmp/FTABHarvest/Speaka.log` or the Settings log containing *both* the active and replacement sessions.
6. Inspect `V86 SINK_START_ACCEPT_QUEUED`, `V87_MEDIA_ENTER`, and `V87_MEDIA_RX` for the active PID and timestamps. If START occurs but *no* `V87_MEDIA_ENTER`, the media callback may not have been entered, may have failed before logging, or an earlier path may have crashed. If an ENTER occurs but no matching RX, Apple's original handler or logging path may not have returned; investigate rather than claiming the hook is safe. If RX is nonzero and daemon remains stable, inbound data reached the handler; do **not** infer which CID belongs to Sink without additional correlation.
7. After exporting, ensure both one-shot settings are OFF; restart Bluetooth once to restore ordinary operations. If instability persists, reinstall the known-good `.deb`.

## Experiment limitations

- An ordinary source connection can also call the media handler; `V87_MEDIA_RX` alone is not a verified Sink media transfer.
- A crash despite the simpler observer does *not* establish the native audio table as the cause: the hook/trampoline, original media handler, and logging code remain possible causes. A crash report or a comparison without the hook is required to isolate causation.
- `V87_MEDIA_RX` occurs *after* the original handler returns. If it crashes inside, only the sampled `V87_MEDIA_ENTER` breadcrumb may survive.
- This is low-level code injected into `bluetoothd` and is not guaranteed safe until tested with a real device. Local tests and compilation checks do not count as Bluetooth evidence.
