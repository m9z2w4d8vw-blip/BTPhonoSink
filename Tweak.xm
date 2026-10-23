/*
 * BTPhonoSink — turns an iPhone 13 (iOS 17, rootless jailbreak) into a
 * Bluetooth A2DP audio sink (speaker).
 *
 * Injected into /usr/sbin/bluetoothd via Substrate.
 *
 * Binary analysis of this specific bluetoothd (arm64e, iOS 17):
 *   base VA           = 0x100000000  (ASLR slide added at runtime)
 *   AVDTP_RegisterMultipoint  offset = 0x000cecf4
 *   advertise_A2DP_SDP        offset = 0x00044de28  (logs "Advertising A2DP Source")
 *   SetConfigInd_handler      offset = 0x00037ae6c  (logs "SetConfigInd setting a2dp…")
 *   approve_incoming_stream   offset = 0x00037ab1c  (logs "Approved and configured…")
 *   SetConfig_accept_SBC      offset = 0x0003b03b8  (logs "Accepting remote SBC SEID…")
 *   readHandler_source        offset = 0x000593710  (logs "A2DPAudioDevice readHandler…")
 *   A2DP_send_data            offset = 0x000380af0  (logs "Sending data of length…")
 *   publish_audio_device      offset = 0x000376e50  (logs "Publishing audio device…")
 *   register_a2dp_source      offset = 0x000727268  (logs "Failed to register as an A2DP source")
 */

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#include <mach-o/dyld.h>
#include <os/log.h>
#include <substrate.h>
#include <string.h>
#include <stdint.h>
#include <stdio.h>

#include "SBCSink.h"
#include "sbc_decode.h"

#pragma mark - Logging

#define LOG(fmt, ...)  os_log(OS_LOG_DEFAULT, "[BTPhonoSink] " fmt, ##__VA_ARGS__)

/* =========================================================================
 * 0. AVDTP / SDP structures mirrored from Apple's OI Bluetooth stack
 * ========================================================================= */

/* AVDTP service category codes */
#define AVDTP_SERVICE_MEDIA_TRANSPORT  0x01
#define AVDTP_SERVICE_MEDIA_CODEC      0x07
/* Endpoint type */
#define AVDTP_TSEP_SRC                 0x00
#define AVDTP_TSEP_SNK                 0x01
/* Media type */
#define AVDTP_MEDIA_TYPE_AUDIO         0x00
/* SBC codec type */
#define A2DP_CODEC_SBC                 0x00

/*
 * OI_AVDTP_CAP — capability element passed to AVDTP_RegisterMultipoint.
 * Apple's internal layout matches the standard OI stack.
 */
typedef struct {
    uint8_t  serviceCategory;
    uint8_t  length;
    uint8_t *data;
} OI_AVDTP_CAP;

/* SBC codec capability data (6 bytes, A2DP spec §4.3.2) */
static uint8_t g_sbc_sink_codec_data[6] = {
    0x00,   /* media type (audio=0) << 4 */
    0x00,   /* codec type: SBC */
    0xFF,   /* all sampling freqs + all channel modes */
    0xFF,   /* all block lengths + all subbands + all alloc methods */
    0x02,   /* min bitpool */
    0x35,   /* max bitpool (53) */
};

static OI_AVDTP_CAP g_sink_caps[2] = {
    { AVDTP_SERVICE_MEDIA_TRANSPORT, 0,                      NULL               },
    { AVDTP_SERVICE_MEDIA_CODEC,     sizeof(g_sbc_sink_codec_data), g_sbc_sink_codec_data },
};

/* =========================================================================
 * 1. Runtime: locate bluetoothd base and build function pointers
 * ========================================================================= */

static uintptr_t g_btd_base = 0;

static void setup_base(void) {
    /* The main executable is always image 0 in the dyld list. */
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    g_btd_base = (uintptr_t)0x100000000 + (uintptr_t)slide;
    LOG("bluetoothd loaded at base 0x%lx (slide 0x%lx)", (unsigned long)g_btd_base,
                                                           (unsigned long)slide);
}

#define BTD_PTR(offset)  ((void *)(g_btd_base + (offset)))

/* =========================================================================
 * 2. AVDTP_RegisterMultipoint hook
 *
 * Original call: AVDTP_RegisterMultipoint(mediaType=0, count=1,
 *                   endpointType=SRC, caps, numCaps, tag)
 * We piggy-back an extra call with endpointType=SNK to register a sink.
 * ========================================================================= */

typedef int (*avdtp_register_multi_t)(uint8_t  mediaType,
                                       uint8_t  count,
                                       uint8_t  endpointType,
                                       OI_AVDTP_CAP *caps,
                                       uint8_t  numCaps,
                                       uintptr_t tag);   /* 6th arg, purpose TBD */

static avdtp_register_multi_t orig_AVDTP_RegisterMultipoint = NULL;

static int hook_AVDTP_RegisterMultipoint(uint8_t  mediaType,
                                          uint8_t  count,
                                          uint8_t  endpointType,
                                          OI_AVDTP_CAP *caps,
                                          uint8_t  numCaps,
                                          uintptr_t tag)
{
    int ret = orig_AVDTP_RegisterMultipoint(mediaType, count, endpointType,
                                             caps, numCaps, tag);

    /* Only add the sink endpoint when the source endpoint is being registered.
     * Avoid recursion and double-sink registration. */
    static int sink_registered = 0;
    if (!sink_registered && endpointType == AVDTP_TSEP_SRC &&
        mediaType == AVDTP_MEDIA_TYPE_AUDIO && ret == 0)
    {
        sink_registered = 1;
        LOG("Registering AVDTP SINK endpoint alongside source");
        int sink_ret = orig_AVDTP_RegisterMultipoint(AVDTP_MEDIA_TYPE_AUDIO,
                                                      count,
                                                      AVDTP_TSEP_SNK,
                                                      g_sink_caps,
                                                      2,
                                                      tag);
        LOG("AVDTP SINK endpoint registration result: %d", sink_ret);
    }
    return ret;
}

/* =========================================================================
 * 3. SDP advertising hook — add AudioSink service class
 *
 * "Advertising A2DP Source" is logged inside this function which calls
 * the internal SDP record registration.  We hook it to also register
 * an AudioSink SDP record.
 *
 * Apple's internal SDP UUID for AudioSink = 0x110B (Bluetooth SIG).
 * We write the preference key "AudioSinkSdp" = YES in com.apple.bluetooth
 * so bluetoothd's own code paths also see it enabled.
 * ========================================================================= */

typedef void (*advertise_a2dp_sdp_t)(void *self);
static advertise_a2dp_sdp_t orig_advertise_a2dp_sdp = NULL;

static void hook_advertise_a2dp_sdp(void *self)
{
    orig_advertise_a2dp_sdp(self);

    /* Write the AudioSinkSdp preference key so any internal
     * SDP-record builder can see it. */
    CFPreferencesSetValue(CFSTR("AudioSinkSdp"),
                          kCFBooleanTrue,
                          CFSTR("com.apple.bluetooth"),
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesAppSynchronize(CFSTR("com.apple.bluetooth"));

    LOG("AudioSink SDP preference written; calling internal AudioSink register");

    /*
     * TODO (step 2, needs Frida confirmation):
     *
     * The internal SDP register function for A2DP Source is called in
     * `advertise_a2dp_sdp` (this function).  Apple uses a companion
     * function — offset TBD — that does the same for AudioSink.
     * Once confirmed with Frida, add:
     *
     *   typedef void (*register_audiосink_sdp_t)(void *self);
     *   static register_audiosink_sdp_t orig_register_audiosink_sdp = NULL;
     *   if (orig_register_audiosink_sdp)
     *       orig_register_audiosink_sdp(self);
     *
     * For now, the `AudioSinkSdp` preference above may trigger the
     * existing SDP-builder code on its own, depending on how it is read.
     */
}

/* =========================================================================
 * 4. SetConfigInd handler hook
 *
 * Called when a remote source sends AVDTP SetConfig to our sink endpoint.
 * We start the audio engine here so it is ready for media data.
 * ========================================================================= */

/* Signature inferred from disassembly context — receives the a2dp handle
 * and a stream-info struct.  Exact layout is opaque; we only intercept
 * it to side-effect start our audio engine. */
typedef int (*setconfigind_handler_t)(void *a2dp_handle, void *stream_info,
                                       void *extra1, void *extra2);
static setconfigind_handler_t orig_SetConfigInd_handler = NULL;

/* Holds the sample rate of the accepted SBC stream (set by accept_sbc hook). */
static uint32_t g_accepted_sample_rate = 44100;
static uint8_t  g_accepted_nchannels   = 2;

static int hook_SetConfigInd_handler(void *a2dp_handle, void *stream_info,
                                      void *extra1, void *extra2)
{
    int ret = orig_SetConfigInd_handler(a2dp_handle, stream_info, extra1, extra2);

    if (ret == 0 && !btphonosink_is_running()) {
        LOG("SetConfigInd accepted — starting A2DP sink audio engine (%u Hz, %u ch)",
            g_accepted_sample_rate, g_accepted_nchannels);
        btphonosink_start(g_accepted_sample_rate, g_accepted_nchannels);
    }
    return ret;
}

/* =========================================================================
 * 5. SBC SetConfig acceptance hook
 *
 * "Accepting remote SBC SEID %u config with bitpool %d and sample rate…"
 * is logged in this function.  We read out the sample-rate argument so
 * the audio engine can be configured to the right format.
 * ========================================================================= */

typedef int (*setconfig_accept_sbc_t)(void *a2dp_obj, uint32_t remote_seid,
                                       double sample_rate_hz, int bitpool,
                                       void *extra);
static setconfig_accept_sbc_t orig_SetConfig_accept_SBC = NULL;

static int hook_SetConfig_accept_SBC(void *a2dp_obj, uint32_t remote_seid,
                                      double sample_rate_hz, int bitpool,
                                      void *extra)
{
    g_accepted_sample_rate = (uint32_t)sample_rate_hz;
    g_accepted_nchannels   = 2; /* stereo by default; update from joint/stereo mode if needed */
    LOG("Remote SBC SEID %u: %.0f Hz, bitpool %d", remote_seid, sample_rate_hz, bitpool);
    return orig_SetConfig_accept_SBC(a2dp_obj, remote_seid, sample_rate_hz, bitpool, extra);
}

/* =========================================================================
 * 6. Publish-audio-device hook  (fires when the AVDTP stream opens)
 *
 * We use this as a secondary trigger to ensure the engine is running.
 * ========================================================================= */

typedef void (*publish_audio_device_t)(void *self, void *device_addr);
static publish_audio_device_t orig_publish_audio_device = NULL;

static void hook_publish_audio_device(void *self, void *device_addr)
{
    orig_publish_audio_device(self, device_addr);

    if (!btphonosink_is_running()) {
        LOG("publish_audio_device fired — starting audio engine as fallback");
        btphonosink_start(g_accepted_sample_rate, g_accepted_nchannels);
    }
}

/* =========================================================================
 * 7.  Media-data receive (THE CRITICAL HOOK)
 *
 * This is the hook that delivers decoded SBC audio to our player.
 *
 * There are two candidate approaches, both described below.
 * Approach A is wired in now; approach B needs one Frida session to
 * confirm the exact offset.
 *
 * ── Approach A: hook readHandler_source (offset 0x593710) ──────────────
 *
 *   readHandler is called when audio data arrives on the Skywalk ring
 *   buffer that BTAudioHALPlugin writes into.
 *   For SOURCE direction this data is encoded PCM on its way OUT to BT.
 *   We instrument it here to verify the data format.
 *
 *   For true SINK receive this hook does NOT fire —  incoming A2DP data
 *   comes through a different path.  Its offset needs Frida confirmation.
 *
 * ── Approach B: media channel L2CAP receive (offset TBD) ───────────────
 *
 *   When we register a SINK endpoint (hook #2 above) and a remote source
 *   connects + sends AVDTP_Start, the AVDTP stack delivers each incoming
 *   media L2CAP packet to a registered `pMediaChannel` callback.
 *
 *   To find the callback's address:
 *     1. Install the tweak (hooks 2-6 only).
 *     2. Connect from the Legion as a Bluetooth source.
 *     3. Run:
 *          frida -p $(pidof bluetoothd) -l find_media_cb.js
 *        where find_media_cb.js traces calls made shortly after
 *        AVDTP_Start is accepted.
 *     4. The first function called with a ~900 byte buffer is the one.
 *
 *   Once the offset is known:
 *
 *     typedef void (*media_recv_t)(uint32_t handle, uint8_t *data, uint32_t len, void *ctx);
 *     static media_recv_t orig_media_recv = NULL;
 *     static void hook_media_recv(uint32_t handle, uint8_t *data, uint32_t len, void *ctx) {
 *         if (data && len > 12) {
 *             // skip 12-byte RTP header
 *             btphonosink_on_media_payload(data + 12, len - 12);
 *         }
 *         orig_media_recv(handle, data, len, ctx);
 *     }
 *
 *   Then in ctor, add:
 *     MSHookFunction(BTD_PTR(MEDIA_RECV_OFFSET),
 *                    (void*)hook_media_recv,
 *                    (void**)&orig_media_recv);
 *
 * ========================================================================= */

typedef void (*read_handler_t)(void *a2dp_device, uint8_t *data,
                                size_t data_len, uint32_t frame_count,
                                uint32_t max_frame_count);
static read_handler_t orig_readHandler_source = NULL;

static void hook_readHandler_source(void *a2dp_device, uint8_t *data,
                                     size_t data_len, uint32_t frame_count,
                                     uint32_t max_frame_count)
{
    /* This fires for SOURCE direction (data going OUT to BT headphones).
     * We call the original unchanged.  The real sink receive needs
     * Approach B above wired in.                                        */
    orig_readHandler_source(a2dp_device, data, data_len, frame_count, max_frame_count);
}

/* =========================================================================
 * 8. Constructor — wire everything up at load time
 * ========================================================================= */

static void install_hooks(void) {
    /*
     * These offsets are valid for the specific bluetoothd binary
     * uploaded for analysis (iOS 17, iPhone 13, arm64e, 10,196,720 bytes).
     * If bluetoothd is updated, run the analysis script again to update.
     */
    struct { uintptr_t offset; void *hook; void **orig; const char *name; } hooks[] = {
        { 0x000cecf4, (void*)hook_AVDTP_RegisterMultipoint,
                      (void**)&orig_AVDTP_RegisterMultipoint,
                      "AVDTP_RegisterMultipoint" },

        { 0x00044de28, (void*)hook_advertise_a2dp_sdp,
                       (void**)&orig_advertise_a2dp_sdp,
                       "advertise_A2DP_SDP" },

        { 0x00037ae6c, (void*)hook_SetConfigInd_handler,
                       (void**)&orig_SetConfigInd_handler,
                       "SetConfigInd_handler" },

        { 0x0003b03b8, (void*)hook_SetConfig_accept_SBC,
                       (void**)&orig_SetConfig_accept_SBC,
                       "SetConfig_accept_SBC" },

        { 0x000376e50, (void*)hook_publish_audio_device,
                       (void**)&orig_publish_audio_device,
                       "publish_audio_device" },

        { 0x000593710, (void*)hook_readHandler_source,
                       (void**)&orig_readHandler_source,
                       "A2DPAudioDevice_readHandler" },
    };

    for (size_t i = 0; i < sizeof(hooks)/sizeof(hooks[0]); i++) {
        void *target = BTD_PTR(hooks[i].offset);
        MSHookFunction(target, hooks[i].hook, hooks[i].orig);
        LOG("Hooked %s at %p", hooks[i].name, target);
    }
}

%ctor {
    setup_base();
    install_hooks();
    LOG("BTPhonoSink loaded — iPhone will appear as A2DP sink after hook #7 is wired");
}

%dtor {
    btphonosink_stop();
}
