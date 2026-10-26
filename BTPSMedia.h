/*
 * BTPSMedia.h - platform-independent A2DP RTP/SBC depacketizer.
 * No Bluetooth APIs, allocations, audio services, or daemon hooks.
 *
 * This prepares the receive path; it does NOT receive Bluetooth packets.
 * RTP packet memory must remain valid while using view.frame_offsets[].
 */
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define BTPS_MEDIA_MAX_FRAMES 15u

typedef enum {
    BTPS_MEDIA_OK = 0,
    BTPS_MEDIA_INVALID = -1,
    BTPS_MEDIA_TRUNCATED = -2,
    BTPS_MEDIA_UNSUPPORTED_FRAGMENT = -3,
    BTPS_MEDIA_BAD_SBC = -4,
    BTPS_MEDIA_BUFFER_SMALL = -5,
    BTPS_MEDIA_BACKPRESSURE = -6
} btps_media_result_t;

typedef struct {
    uint16_t sequence;
    uint32_t timestamp;
    uint32_t ssrc;
    uint8_t payload_type;
    uint8_t marker;
    uint8_t frame_count;
    uint8_t channels;          /* same across all SBC frames */
    uint32_t sample_rate;       /* same across all SBC frames */
    size_t media_offset;        /* byte offset to first SBC syncword in RTP packet */
    size_t media_length;        /* SBC data bytes, without RTP padding */
    uint16_t frame_offsets[BTPS_MEDIA_MAX_FRAMES]; /* relative to media_offset */
    uint16_t frame_lengths[BTPS_MEDIA_MAX_FRAMES];
} btps_media_view_t;

/* Strictly validate a complete RTP(v2)/A2DP-SBC packet, including CSRCs,
 * header extensions, RTP padding, declared frame count, and SBC boundaries.
 * Fragmented SBC media packets are explicitly unsupported.
 */
btps_media_result_t btps_media_parse_rtp(const uint8_t *packet, size_t length,
                                          btps_media_view_t *out);

/* Decode one *validated* packet to signed, stereo interleaved PCM.
 * Caller owns storage. Returns the number of int16 samples through samples_out.
 * Decoder is a research implementation (no verified bit-exact SBC/CRC).
 */
btps_media_result_t btps_media_decode_rtp_sbc(const uint8_t *packet, size_t length,
                                               int16_t *pcm_out, size_t pcm_capacity,
                                               size_t *samples_out,
                                               btps_media_view_t *view_out);
#ifdef __cplusplus
}
#endif
