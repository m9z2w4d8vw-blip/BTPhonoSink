# v8.2 Live native A2DP Sink signaling trial — experimental

**NOT A WORKING BLUETOOTH SINK.** No verified media RX hook exists. `PASS` is never emitted by the tweak. Only real remote packet capture could establish acceptance. Use existing v8.1 package for rollback.

## Exact binary gates

- RegisterMultipoint image+0xCECF0, inspected instructions in `BTPSBuild.h`.
- Existing AVDTP config-getter image+0x1F5F20, one-shot config `(7,3,3)` from v8.1.
- SDP record-add image+0x1E8E78, exact four-word gate in `Tweak.xm`.
- Incoming SIGNALING dispatcher image+0xD3B08, exact four-word gate and ABI `(CID,packet*,len)` in `Tweak.xm`.
- The new SDP record uses persistent nested data elements, Source record structure recovered at image+0x91ABD0/0x91AC30/0x91AC50.
- SDP `0x0311` feature value 0x0001 identifies Headphone. No raw media listener installed; these diagnostics cannot establish incoming media.

## Safety

ARM BOTH independent Settings switches for ONE restart: `Arm seven slots for ONE restart` AND `Arm real Sink SDP + signaling ONCE`. Both are consumed before use; no autonomous retries. Leave Legacy Sink OFF, regular SDP trace OFF. Requires exact daemon UUID and instruction match. Native 6 Sources are allowed to register before additional Sink trial. Any error aborts dependent operations. Note the existing v8.1 one-shot preference is consumed by bluetoothd and should not be rearmed after trial.

## Protocol evidence

First check `V82 SEP RESULT`, `V82 SDP add`; neither proves remote discovery. Use Windows Classic Bluetooth discovery and attempt connection. Export log and look for `V82 RX_SIGNAL` and `V82 RX_RAW`. These are inbound signaling only and may also arise during ordinary SOURCE headset connections. The log DOES NOT observe transmitted ACCEPT/REJECT responses or the media channel, so **neither PASS nor KILL-NATIVE-SINK-ACP can be concluded from this log alone**. If Windows produces no incoming messages, use independent BlueZ `btmon` later.

No expected local tests claim the live path works. A successful CI build proves only compilation. Obtain remote SDP `0x110B` and a remote `DISCOVER` response with a Sink SEP before proceeding. Stop testing and restore v8.1 if Bluetooth breaks.
