#pragma once
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* SBC header constants */
#define SBC_SYNCWORD        0x9C
#define SBC_FREQ_16K        0
#define SBC_FREQ_32K        1
#define SBC_FREQ_44K        2
#define SBC_FREQ_48K        3
#define SBC_MODE_MONO       0
#define SBC_MODE_DUAL       1
#define SBC_MODE_STEREO     2
#define SBC_MODE_JOINT      3
#define SBC_ALLOC_LOUDNESS  0
#define SBC_ALLOC_SNR       1

/* Max frame PCM output: 16 blocks * 8 subbands * 2 channels = 256 samples per channel */
#define SBC_MAX_SAMPLES_PER_FRAME  256
#define SBC_MAX_CHANNELS           2
#define SBC_MAX_SUBBANDS           8
#define SBC_MAX_BLOCKS             16

typedef struct {
    uint8_t  sampling_freq;   /* SBC_FREQ_* */
    uint8_t  blocks;          /* 4, 8, 12, 16 */
    uint8_t  channel_mode;    /* SBC_MODE_* */
    uint8_t  alloc_method;    /* SBC_ALLOC_* */
    uint8_t  subbands;        /* 4 or 8 */
    uint8_t  bitpool;
    uint8_t  nchannels;       /* 1 or 2 */
    uint16_t frame_length;    /* bytes per frame including header */
    uint16_t sample_rate;     /* actual Hz: 16000 / 32000 / 44100 / 48000 */
} sbc_frame_header_t;

/*
 * Parse the header of one SBC frame (first 3 bytes starting at syncword).
 * Returns 0 on success, -1 if syncword mismatch.
 */
int sbc_parse_header(const uint8_t *buf, size_t len, sbc_frame_header_t *hdr);

/*
 * Decode one SBC frame into 16-bit signed PCM.
 *
 *   buf          pointer to start of SBC frame (syncword)
 *   buf_len      bytes available in buf (must be >= hdr->frame_length)
 *   hdr          previously filled by sbc_parse_header()
 *   pcm_out      output buffer, interleaved L/R, must hold
 *                hdr->blocks * hdr->subbands * hdr->nchannels samples
 *   pcm_samples  out: number of int16_t samples written (total across channels)
 *
 * Returns number of bytes consumed from buf on success, -1 on error.
 */
int sbc_decode_frame(const uint8_t *buf, size_t buf_len,
                     const sbc_frame_header_t *hdr,
                     int16_t *pcm_out, int *pcm_samples);

/*
 * Convenience: decode a raw A2DP media payload (after the 1-byte frame-count
 * header that immediately follows the 12-byte RTP header).
 *
 *   payload       pointer to first SBC frame
 *   payload_len   remaining bytes
 *   pcm_buf       caller-supplied output buffer
 *   pcm_capacity  max int16_t samples pcm_buf can hold
 *
 * Returns total samples written, or -1 on error.
 */
int sbc_decode_a2dp_payload(const uint8_t *payload, size_t payload_len,
                             int16_t *pcm_buf, int pcm_capacity,
                             sbc_frame_header_t *hdr_out);

#ifdef __cplusplus
}
#endif
