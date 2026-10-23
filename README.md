# BTPhonoSink

Turns a jailbroken iPhone 13 (iOS 17, rootless, arm64e) into a Bluetooth A2DP audio sink — your Legion (or any A2DP source) sees it as a speaker in the Bluetooth menu.

## What it does (confirmed)

| Hook | What it does | Status |
|------|-------------|--------|
| AVDTP_RegisterMultipoint | Registers a SINK endpoint alongside the existing source | ✅ Wired |
| advertise_A2DP_SDP | Writes AudioSinkSdp=YES preference so SDP builder sees it | ✅ Wired |
| SetConfigInd_handler | Starts AVAudioEngine when remote source sends SetConfig | ✅ Wired |
| SetConfig_accept_SBC | Captures sample rate (44.1 or 48 kHz) from accepted config | ✅ Wired |
| publish_audio_device | Fallback trigger to ensure audio engine is started | ✅ Wired |
| **media data receive** | Delivers raw SBC frames to the SBC decoder | ⚠️ Needs offset from Frida |

## Build

```bash
# On your Mac/Linux Theos box
cd BTPhonoSink
make package FINALPACKAGE=1

# Copy to phone and install
scp packages/*.deb root@<phone-ip>:/tmp/
ssh root@<phone-ip> 'dpkg -i /tmp/BTPhonoSink_*.deb'
# bluetoothd restarts automatically
```

Requires Theos with arm64e support and the iOS 17 SDK.

## Two-phase deployment

### Phase 1 (install now — no Frida needed)

The tweak already:
- Registers the A2DP sink AVDTP endpoint
- Writes the AudioSinkSdp preference
- Sets up the AVAudioEngine output player

After installing, open Bluetooth on your Legion. The iPhone should appear in the device list. Pair and connect. The system may accept the connection (SetConfig will go through) but audio won't play yet because hook #7 is not wired.

### Phase 2 (wire up the media receive — one Frida session)

1. Pair and connect the Legion as A2DP source (Phase 1 complete).
2. Start playing audio on the Legion.
3. On the iPhone via SSH:
   ```bash
   frida -p $(pidof bluetoothd) -l /var/mobile/Documents/find_media_cb.js
   ```
4. Watch for the line:
   ```
   [MEDIA_CB] *** CANDIDATE FOUND ***
     offset = 0x...
   ```
5. Open `Tweak.xm`, scroll to the TODO in hook #7, and add:
   ```objc
   // replace MEDIA_RECV_OFFSET with the offset from step 4
   #define MEDIA_RECV_OFFSET 0x<offset>

   typedef void (*media_recv_t)(uint32_t handle,
                                uint8_t *data, uint32_t len,
                                void *ctx);
   static media_recv_t orig_media_recv = NULL;

   static void hook_media_recv(uint32_t handle,
                                uint8_t *data, uint32_t len,
                                void *ctx) {
       if (data && len > 12)
           btphonosink_on_media_payload(data + 12, len - 12);
       if (orig_media_recv)
           orig_media_recv(handle, data, len, ctx);
   }
   ```
6. In the `hooks[]` array in `%ctor`, add:
   ```objc
   { MEDIA_RECV_OFFSET, (void*)hook_media_recv,
     (void**)&orig_media_recv, "media_recv" },
   ```
7. `make package FINALPACKAGE=1`, reinstall. Audio now plays through the iPhone speaker.

## SBC decoder

`sbc_decode.c` implements the full A2DP SBC decoder from the Bluetooth spec —
no external dependencies. It handles:
- 44.1 kHz / 48 kHz
- Mono, Stereo, Dual Channel, Joint Stereo
- 4 or 8 subbands, 4/8/12/16 blocks
- Loudness and SNR bit allocation

## Binary offsets used (iOS 17, iPhone 13, 10,196,720-byte bluetoothd)

```
AVDTP_RegisterMultipoint  0x000cecf4
advertise_A2DP_SDP        0x00044de28
SetConfigInd_handler      0x00037ae6c
SetConfig_accept_SBC      0x0003b03b8
publish_audio_device      0x000376e50
A2DPAudioDevice_readHndlr 0x000593710
A2DP_send_data            0x000380af0
approve_incoming_stream   0x00037ab1c
register_a2dp_source      0x000727268
```

If bluetoothd is updated, re-run the binary analysis to get new offsets.

## How the audio path works

```
Legion (BT source)
   │  Bluetooth A2DP (SBC encoded)
   ▼
bluetoothd (iPhone)
   │  AVDTP media channel L2CAP receive  ← hook #7 wires here
   │  strip 12-byte RTP header
   ▼
btphonosink_on_media_payload()
   │  sbc_decode_a2dp_payload()          ← SBC decoder in sbc_decode.c
   │  writes int16 PCM to ring buffer
   ▼
AVAudioEngine / AVAudioSourceNode        ← SBCSink.mm
   │  pulls from ring buffer on render thread
   ▼
iPhone speaker / AirPods / etc.
```
