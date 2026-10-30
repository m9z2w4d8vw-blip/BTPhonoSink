#import "SBCSink.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include <os/log.h>
#include <pthread.h>

#define LOG_SINK(fmt, ...) os_log(OS_LOG_DEFAULT, "[Speaka] " fmt, ##__VA_ARGS__)

/* -------------------------------------------------------------------------
 * Mutex-protected ring buffer for decoded PCM
 * Holds up to 8192 stereo int16 samples (32KB) to smooth jitter.
 * ------------------------------------------------------------------------- */
#define RING_SAMPLES (8192 * 2)   /* stereo interleaved */

static struct {
    int16_t  buf[RING_SAMPLES];
    uint32_t read_pos;
    uint32_t write_pos;
} g_ring;

static pthread_mutex_t g_ring_lock = PTHREAD_MUTEX_INITIALIZER;

static void ring_reset(void) {
    pthread_mutex_lock(&g_ring_lock);
    g_ring.read_pos = g_ring.write_pos = 0;
    pthread_mutex_unlock(&g_ring_lock);
}

/* Returns all samples written or zero (no partial packets). */
static int ring_write(const int16_t *in, int count) {
    pthread_mutex_lock(&g_ring_lock);
    int avail = (int)(RING_SAMPLES - (g_ring.write_pos - g_ring.read_pos));
    if (avail < 0) avail = 0;
    /* All or nothing: never enqueue only part of an SBC packet. */
    if (count > avail) {
        pthread_mutex_unlock(&g_ring_lock);
        return 0;
    }
    for (int i = 0; i < count; i++)
        g_ring.buf[(g_ring.write_pos + i) % RING_SAMPLES] = in[i];
    g_ring.write_pos += (uint32_t)count;
    pthread_mutex_unlock(&g_ring_lock);
    return count;
}

/* Returns samples read (may be less than count if ring is empty). */
static int ring_read(int16_t *out, int count) {
    pthread_mutex_lock(&g_ring_lock);
    int avail = (int)(g_ring.write_pos - g_ring.read_pos);
    if (avail < 0) avail = 0;
    int n = (count < avail) ? count : avail;
    for (int i = 0; i < n; i++)
        out[i] = g_ring.buf[(g_ring.read_pos + i) % RING_SAMPLES];
    g_ring.read_pos += n;
    pthread_mutex_unlock(&g_ring_lock);
    return n;
}

/* -------------------------------------------------------------------------
 * AVAudioEngine / AVAudioSourceNode output
 * ------------------------------------------------------------------------- */
static AVAudioEngine      *g_engine       = nil;
static AVAudioSourceNode  *g_source_node  = nil;
static dispatch_queue_t    g_setup_queue;
static uint32_t            g_sample_rate  = 44100;
static uint8_t             g_nchannels    = 2;
static int                 g_running      = 0;

/* decode scratch buffer – enough for one large A2DP packet (16 blocks × 8sb × 2ch) */
#define DECODE_SCRATCH (BTPS_MEDIA_MAX_FRAMES * 16 * 8 * 2) /* worst case 15 SBC frames */
static int16_t g_decode_scratch[DECODE_SCRATCH];

void speaka_on_media_payload(const uint8_t *payload, size_t payload_len)
{
    if (!g_running || !payload || payload_len < 4) return;

    /* Skip the 1-byte A2DP media payload header (frame count) if present.
     * We detect SBC syncword 0x9C at offset 0 or 1. */
    size_t start = 0;
    if (payload[0] != 0x9C && payload_len > 1 && payload[1] == 0x9C)
        start = 1;

    sbc_frame_header_t hdr;
    int samples = sbc_decode_a2dp_payload(payload + start,
                                           payload_len - start,
                                           g_decode_scratch,
                                           DECODE_SCRATCH,
                                           &hdr);
    if (samples <= 0) return;

    ring_write(g_decode_scratch, samples);
}

/* Integration point for the future live RTP media receiver. The input has to be a
 * COMPLETE A2DP RTP packet; do not strip a fixed 12-byte header, since CSRCs,
 * RTP extension data and padding can change its length. No daemon hook invokes this
 * until live Sink negotiation and audio-output IPC are implemented. */
int speaka_on_rtp_packet(const uint8_t *packet, size_t packet_len)
{
    if (!g_running) return BTPS_MEDIA_INVALID;
    size_t count = 0;
    btps_media_result_t rc = btps_media_decode_rtp_sbc(packet, packet_len,
                                                        g_decode_scratch,
                                                        DECODE_SCRATCH, &count, NULL);
    if (rc != BTPS_MEDIA_OK) return (int)rc;
    if (count == 0 || ring_write(g_decode_scratch, (int)count) != (int)count)
        return BTPS_MEDIA_BACKPRESSURE;
    return BTPS_MEDIA_OK;
}

static void engine_start_internal(void)
{
    if (g_engine) {
        [g_engine stop];
        g_engine = nil;
        g_source_node = nil;
    }

    AVAudioFormat *fmt = [[AVAudioFormat alloc]
        initWithCommonFormat:AVAudioPCMFormatInt16
                  sampleRate:g_sample_rate
                    channels:g_nchannels
                 interleaved:YES];
    if (!fmt) {
        LOG_SINK("Failed to create audio format %u Hz %u ch", g_sample_rate, g_nchannels);
        return;
    }

    g_engine = [[AVAudioEngine alloc] init];

    /* AVAudioSourceNode pulls PCM from our ring buffer on the render thread */
    AVAudioSourceNode *src = [[AVAudioSourceNode alloc]
        initWithFormat:fmt
           renderBlock:^OSStatus(BOOL             *isSilence,
                                  const AudioTimeStamp *ts,
                                  AVAudioFrameCount    frameCount,
                                  AudioBufferList     *outputData)
    {
        int16_t *out = (int16_t *)outputData->mBuffers[0].mData;
        int need    = (int)(frameCount * g_nchannels);
        int got     = ring_read(out, need);
        if (got < need) {
            /* pad with silence if underrun */
            memset(out + got, 0, (need - got) * sizeof(int16_t));
            if (got == 0) *isSilence = YES;
        }
        outputData->mBuffers[0].mDataByteSize = frameCount * g_nchannels * sizeof(int16_t);
        return noErr;
    }];

    g_source_node = src;
    [g_engine attachNode:src];
    [g_engine connect:src to:g_engine.outputNode format:fmt];

    NSError *err = nil;
    if (![g_engine startAndReturnError:&err]) {
        LOG_SINK("AVAudioEngine start failed: %@", err);
        g_engine = nil;
        g_source_node = nil;
        return;
    }

    LOG_SINK("AVAudioEngine started: %u Hz, %u ch", g_sample_rate, g_nchannels);
}

void speaka_start(uint32_t sample_rate, uint8_t nchannels)
{
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_setup_queue = dispatch_queue_create("com.parv.speaka.setup",
                                              DISPATCH_QUEUE_SERIAL);
    });

    g_sample_rate = sample_rate ? sample_rate : 44100;
    g_nchannels   = nchannels   ? nchannels   : 2;
    g_running     = 1;
    ring_reset();

    dispatch_async(g_setup_queue, ^{
        engine_start_internal();
    });
}

void speaka_stop(void)
{
    g_running = 0;
    if (g_engine) {
        [g_engine stop];
        g_engine     = nil;
        g_source_node = nil;
    }
    ring_reset();
    LOG_SINK("Audio engine stopped");
}

int speaka_is_running(void)
{
    return g_running;
}
