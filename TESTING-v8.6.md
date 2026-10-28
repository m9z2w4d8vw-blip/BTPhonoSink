# BTPhonoSink v8.6 — One-shot, receive-only media CID trial

**Purpose:** determine whether live RTP-like AVDTP media bytes reach the incoming
L2CAP media handler on this exact iOS `bluetoothd` build. Do **not** decode,
forward, or play Bluetooth media in this release.

## Required binary (identity checked at runtime)

`bluetoothd` SHA-256:
`e9408df54c3eebfd263eb745a0b06cf1130dd3228f56c104697f92264c91dbd6`

UUID: `5491BA47-B5AE-3D44-9536-B30161DF1E90`.

The new `+0xD8CF8` hook runs only with the **existing two one-shot switches**:
"Arm seven slots for ONE restart" and "Arm real Sink SDP + signaling ONCE".
Legacy Sink remains OFF. There is no additional automatic retry.

## What v8.6 instruments

- Hook `+0xD8CF8`, validated by four exact instruction words.
- Call verified, side-effect-free CID lookup `+0xD917C` to obtain the 0x90-byte
  L2CAP channel entry. Verify stored CID at `entry+0x80`, media callback gate
  at `+0x84`, state 4 at `+0x86`, valid marker at `+0x88`.
- Only after an ACCEPT was locally queued for START addressed to Sink SEID 7,
  consider packets on a **different** CID from that Sink signaling channel.
- For a valid media-like packet, use the same RTP payload calculation observed
  at the native `braaz`: `ptr + 12 + (header0 & 0x0f)`, and
  `length - (12 + (header0 & 0x0f))`. Log first four payload bytes.
- Track the first candidate media CID, its packet count, and
  `MEDIA_BYTES_RECEIVED`; sample logs for first 8 packets and every 64th
  packet, so the daemon is not asked to log each Bluetooth packet.
- Pass **every original argument** to `+0xD8CF8` and return its result.
  `+0x385DFC` remains Apple's original one-instruction `ret` stub.

This is *not* conclusive mapping of a remote Bluetooth address to the channel.
Avoid other concurrent Bluetooth audio sessions: only one Windows-to-iPhone
Sink connection should be active. A separate media CID, active channel state,
and accepted SEID7 START form the practical candidate correlation. Peer-side
L2CAP tracing is required to prove the remote-to-local connection pairing.

## Trial steps

1. Install a successful GitHub Actions **v8.6** `.deb` and verify regular
   headphones with both one-shot switches OFF. Disconnect headphones.
2. Enable the two switches and ensure Legacy Sink is OFF.
3. Restart `bluetoothd` **once** using the current device IP, for example:
   `ssh -t mobile@10.5.106.42 "sudo killall -9 bluetoothd"`.
4. Before Windows playback, inspect Settings > BTPhonoSink > Debug Log:
   expect `V86 MEDIA hook installed`, `V83 AUDIO_TABLE SWAPPED`,
   `V83 SEP RESULT ret=0 seid=7`, and `V83 SDP add ret=0`.
   If the media hook is refused or missing, **stop** and export the log.
5. On Windows, connect to *Loyal Harden Fanatic*, select its usable audio
   output, and play normal audio continuously for 30 seconds.
6. Export the iPhone debug log to iCloud Drive **immediately**. Look for
   `V86 SINK_START_ACCEPT_QUEUED` and `V86 MEDIA_RX` with
   `MEDIA_BYTES_RECEIVED=`. Supply the complete log, not just the counter.
7. Turn both one-shot settings OFF if necessary, then restart `bluetoothd`
   once and verify headphones work again. Stop if Bluetooth becomes unstable.

## Interpret results correctly

- **Positive:** nonzero media bytes on a distinct active CID, after a Sink
  SEID 7 START ACCEPT was queued. This is strong evidence of a live ingress
  path, not decoded audio or confirmed end-to-end delivery.
- **Zero after 30 seconds:** no qualifying packets observed by this hook.
  It does **not necessarily prove** Windows never transmitted media; possible
  explanations include dropped packets, a different path, missing START,
  state/gate mismatch, or a different CID association. Use handler-call lines
  to distinguish missing packets from failed filtering.
- **No START ACCEPT** or **hook failure**: invalid experiment; do not infer
  native media unavailability.

No SBC helper forwarding, no codec patch, no HAL changes, no new audio route.
Local syntax/tests are not evidence of Bluetooth reception.
