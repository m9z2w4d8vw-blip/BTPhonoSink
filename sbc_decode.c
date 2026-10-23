#include "sbc_decode.h"
#include <string.h>
#include <math.h>
#include <stdlib.h>

/* -----------------------------------------------------------------------
 * SBC synthesis filter-bank proto-window coefficients (8-subband version)
 * From the Bluetooth SBC specification, Table 12.9
 * ----------------------------------------------------------------------- */
static const float SBC_PROTO_8[80] = {
     0.00000000e+00f,  5.36548976e-04f,  1.49188357e-03f,  2.73370904e-03f,
     3.83720193e-03f,  3.89205149e-03f,  1.86581691e-03f, -3.06012286e-03f,
     1.09137620e-02f,  2.04385087e-02f,  2.88757392e-02f,  3.21939290e-02f,
     2.58767811e-02f,  6.13245186e-03f, -2.88217274e-02f, -7.76463494e-02f,
     1.35593274e-01f,  1.94987841e-01f,  2.46636662e-01f,  2.81828203e-01f,
     2.94315332e-01f,  2.81828203e-01f,  2.46636662e-01f,  1.94987841e-01f,
     1.35593274e-01f, -7.76463494e-02f, -2.88217274e-02f,  6.13245186e-03f,
     2.58767811e-02f,  3.21939290e-02f,  2.88757392e-02f,  2.04385087e-02f,
     1.09137620e-02f, -3.06012286e-03f,  1.86581691e-03f,  3.89205149e-03f,
     3.83720193e-03f,  2.73370904e-03f,  1.49188357e-03f,  5.36548976e-04f,
    /* second half (mirror) */
     0.00000000e+00f,  5.36548976e-04f,  1.49188357e-03f,  2.73370904e-03f,
     3.83720193e-03f,  3.89205149e-03f,  1.86581691e-03f, -3.06012286e-03f,
     1.09137620e-02f,  2.04385087e-02f,  2.88757392e-02f,  3.21939290e-02f,
     2.58767811e-02f,  6.13245186e-03f, -2.88217274e-02f, -7.76463494e-02f,
     1.35593274e-01f,  1.94987841e-01f,  2.46636662e-01f,  2.81828203e-01f,
     2.94315332e-01f,  2.81828203e-01f,  2.46636662e-01f,  1.94987841e-01f,
     1.35593274e-01f, -7.76463494e-02f, -2.88217274e-02f,  6.13245186e-03f,
     2.58767811e-02f,  3.21939290e-02f,  2.88757392e-02f,  2.04385087e-02f,
     1.09137620e-02f, -3.06012286e-03f,  1.86581691e-03f,  3.89205149e-03f,
     3.83720193e-03f,  2.73370904e-03f,  1.49188357e-03f,  5.36548976e-04f,
};

static const float SBC_PROTO_4[40] = {
     0.00000000e+00f,  1.56575398e-04f,  3.43256425e-04f,  5.54620202e-04f,
     8.23919506e-04f,  1.13992507e-03f,  1.47640169e-03f,  1.78371725e-03f,
     2.01182542e-03f,  2.10371989e-03f,  1.99454554e-03f,  1.60586087e-03f,
     9.02154502e-04f, -1.78805361e-04f, -1.64973098e-03f, -3.49717454e-03f,
     5.65949473e-03f,  8.02941163e-03f,  1.04584443e-02f,  1.27472335e-02f,
     1.46525263e-02f,  1.59045603e-02f,  1.62208471e-02f,  1.53184106e-02f,
     1.29371806e-02f,  8.85757540e-03f,  2.92408425e-03f, -4.91578024e-03f,
    -1.46404076e-02f, -2.61098752e-02f,  3.89205149e-02f,  5.44242225e-02f,
     7.03597977e-02f,  8.59837636e-02f,  1.00455540e-01f,  1.12932890e-01f,
     1.23421765e-01f,  1.30892365e-01f,  1.35748975e-01f,  1.37500274e-01f,
};

/* Loudness offset tables (from SBC spec Table 12.5 and 12.6) */
static const int8_t LOUDNESS_OFFSET_4[4][4] = {
    { -1,  0,  0,  0 },
    { -2,  0,  0,  1 },
    { -2,  0,  0,  1 },
    { -2,  0,  0,  1 },
};
static const int8_t LOUDNESS_OFFSET_8[4][8] = {
    { -2,  0,  0,  0,  0,  0,  0,  1 },
    { -3,  0,  0,  0,  0,  0,  1,  2 },
    { -4,  0,  0,  0,  0,  0,  1,  2 },
    { -4,  0,  0,  0,  0,  0,  1,  2 },
};

/* -----------------------------------------------------------------------
 * Bitstream reader
 * ----------------------------------------------------------------------- */
typedef struct {
    const uint8_t *buf;
    size_t         len;
    size_t         byte_pos;
    int            bit_pos;   /* 7..0, MSB first */
} bs_t;

static void bs_init(bs_t *bs, const uint8_t *buf, size_t len) {
    bs->buf = buf; bs->len = len; bs->byte_pos = 0; bs->bit_pos = 7;
}

static uint32_t bs_read(bs_t *bs, int nbits) {
    uint32_t val = 0;
    for (int i = 0; i < nbits; i++) {
        if (bs->byte_pos >= bs->len) return 0;
        val = (val << 1) | ((bs->buf[bs->byte_pos] >> bs->bit_pos) & 1);
        if (--bs->bit_pos < 0) { bs->bit_pos = 7; bs->byte_pos++; }
    }
    return val;
}

static size_t bs_byte_pos(const bs_t *bs) {
    return bs->byte_pos + (bs->bit_pos < 7 ? 1 : 0);
}

/* -----------------------------------------------------------------------
 * Synthesis filter bank state (one per channel)
 * ----------------------------------------------------------------------- */
typedef struct {
    float V[160];  /* shift register for 8-subband, or [80] for 4-subband */
} synth_state_t;

static synth_state_t g_synth[2];  /* one per channel, persists between frames */

/* Apply 8-subband synthesis filter bank. Outputs 8 PCM samples. */
static void synth8(synth_state_t *st, const float *sb_samples, int16_t *pcm_out) {
    float *V = st->V;
    /* shift */
    memmove(V + 16, V, (80 - 16) * sizeof(float));
    /* matrixing: V[0..15] = M * sb_samples, M = cos((2i+1)(k-4)*pi/16) */
    for (int i = 0; i < 16; i++) {
        float s = 0.0f;
        for (int k = 0; k < 8; k++)
            s += sb_samples[k] * cosf((float)((2*i+1)*(k-4)) * (float)M_PI / 16.0f);
        V[i] = s;
    }
    /* windowing + partial sum */
    for (int j = 0; j < 8; j++) {
        float u = 0.0f;
        for (int i = 0; i < 10; i++)
            u += SBC_PROTO_8[i*8 + j] * V[i*8 + j];
        /* clamp to int16 */
        int32_t s = (int32_t)(u * 32768.0f);
        if (s > 32767)  s = 32767;
        if (s < -32768) s = -32768;
        pcm_out[j] = (int16_t)s;
    }
}

/* Apply 4-subband synthesis filter bank. Outputs 4 PCM samples. */
static void synth4(synth_state_t *st, const float *sb_samples, int16_t *pcm_out) {
    float *V = st->V;
    memmove(V + 8, V, (40 - 8) * sizeof(float));
    for (int i = 0; i < 8; i++) {
        float s = 0.0f;
        for (int k = 0; k < 4; k++)
            s += sb_samples[k] * cosf((float)((2*i+1)*(k-2)) * (float)M_PI / 8.0f);
        V[i] = s;
    }
    for (int j = 0; j < 4; j++) {
        float u = 0.0f;
        for (int i = 0; i < 10; i++)
            u += SBC_PROTO_4[i*4 + j] * V[i*4 + j];
        int32_t s = (int32_t)(u * 32768.0f);
        if (s > 32767)  s = 32767;
        if (s < -32768) s = -32768;
        pcm_out[j] = (int16_t)s;
    }
}

/* -----------------------------------------------------------------------
 * Bit allocation (from SBC spec section 12.8)
 * ----------------------------------------------------------------------- */
static void calc_bits(const sbc_frame_header_t *hdr,
                      const uint8_t scale_factor[2][8],
                      uint8_t bits[2][8])
{
    int M = hdr->subbands, N = hdr->nchannels;
    int bitneed[2][8];
    int loudness = (hdr->alloc_method == SBC_ALLOC_LOUDNESS);

    /* Step 1: bitneed[] */
    for (int ch = 0; ch < N; ch++) {
        for (int sb = 0; sb < M; sb++) {
            if (scale_factor[ch][sb] == 0) {
                bitneed[ch][sb] = -5;
            } else if (loudness) {
                const int8_t *off = (M == 8) ? LOUDNESS_OFFSET_8[hdr->sampling_freq]
                                              : LOUDNESS_OFFSET_4[hdr->sampling_freq];
                bitneed[ch][sb] = (int)scale_factor[ch][sb] - off[sb];
            } else {
                bitneed[ch][sb] = (int)scale_factor[ch][sb];
            }
        }
    }

    /* Step 2: find the largest bitneed such that bits can be allocated */
    int bitcount = 0, slicecount = 0, bitslice;
    {
        int max_bitneed = -32768;
        for (int ch = 0; ch < N; ch++)
            for (int sb = 0; sb < M; sb++)
                if (bitneed[ch][sb] > max_bitneed) max_bitneed = bitneed[ch][sb];
        bitslice = max_bitneed + 1;
        do {
            bitslice--;
            bitcount += slicecount;
            slicecount = 0;
            for (int ch = 0; ch < N; ch++)
                for (int sb = 0; sb < M; sb++)
                    if ((bitneed[ch][sb] > bitslice + 1) &&
                        (bitneed[ch][sb] < bitslice + 16))
                        slicecount++;
                    else if (bitneed[ch][sb] == bitslice + 1)
                        slicecount++;
        } while (bitcount + slicecount < hdr->bitpool);

        if (bitcount + slicecount == hdr->bitpool) {
            bitcount += slicecount;
            bitslice--;
        }
    }

    /* Step 3: distribute bits */
    for (int ch = 0; ch < N; ch++) {
        for (int sb = 0; sb < M; sb++) {
            if (bitneed[ch][sb] < bitslice + 2) {
                bits[ch][sb] = 0;
            } else {
                int b = bitneed[ch][sb] - bitslice;
                bits[ch][sb] = (b < 16) ? (uint8_t)b : 16;
            }
        }
    }

    /* Step 4: distribute remaining bits */
    int sb = 0, ch = 0;
    while (bitcount < hdr->bitpool) {
        int add = 0;
        if (bits[ch][sb] < 16 && bitneed[ch][sb] > bitslice + 1 &&
            bits[ch][sb]) add = 1;
        else if (bitneed[ch][sb] == bitslice + 1 && bits[ch][sb] == 0) add = 1;
        if (add) { bits[ch][sb]++; bitcount++; }
        if (N == 2) { ch = 1 - ch; if (ch == 0) sb = (sb + 1) % M; }
        else sb = (sb + 1) % M;
    }
}

/* -----------------------------------------------------------------------
 * Public API
 * ----------------------------------------------------------------------- */
int sbc_parse_header(const uint8_t *buf, size_t len, sbc_frame_header_t *hdr)
{
    if (len < 3 || buf[0] != SBC_SYNCWORD) return -1;

    static const uint8_t block_tbl[4] = {4, 8, 12, 16};
    static const uint8_t sb_tbl[2]    = {4, 8};
    static const uint16_t freq_tbl[4] = {16000, 32000, 44100, 48000};

    uint8_t b1 = buf[1];
    hdr->sampling_freq = (b1 >> 6) & 0x3;
    uint8_t blk_idx    = (b1 >> 4) & 0x3;
    hdr->channel_mode  = (b1 >> 2) & 0x3;
    hdr->alloc_method  = (b1 >> 1) & 0x1;
    uint8_t sb_idx     = b1 & 0x1;
    hdr->bitpool       = buf[2];
    hdr->blocks        = block_tbl[blk_idx];
    hdr->subbands      = sb_tbl[sb_idx];
    hdr->nchannels     = (hdr->channel_mode == SBC_MODE_MONO) ? 1 : 2;
    hdr->sample_rate   = freq_tbl[hdr->sampling_freq];

    /* Frame length = 4 + (4*subbands*nchannels)/8
     *              + ceil(nblocks * bitpool * (joint_bit + nchannels) / 8)
     * Exact formula from spec §12.9 */
    int join_bit = (hdr->channel_mode == SBC_MODE_JOINT) ? 1 : 0;
    int header_bytes = 3;
    int sf_bytes = (4 * hdr->subbands * hdr->nchannels + 7) / 8;

    int samples_bits;
    if (hdr->channel_mode == SBC_MODE_JOINT)
        samples_bits = hdr->blocks * (hdr->subbands + hdr->bitpool);
    else if (hdr->channel_mode == SBC_MODE_DUAL)
        samples_bits = hdr->blocks * hdr->nchannels * hdr->bitpool;
    else
        samples_bits = hdr->blocks * hdr->bitpool;

    /* Additional bit for joint stereo join information per block */
    if (hdr->channel_mode == SBC_MODE_JOINT)
        samples_bits += hdr->subbands; /* join flags per subband */

    hdr->frame_length = (uint16_t)(header_bytes + sf_bytes +
                                   (samples_bits + 7) / 8);
    (void)join_bit;
    return 0;
}

int sbc_decode_frame(const uint8_t *buf, size_t buf_len,
                     const sbc_frame_header_t *hdr,
                     int16_t *pcm_out, int *pcm_samples)
{
    if (buf_len < hdr->frame_length) return -1;

    int M = hdr->subbands, N = hdr->nchannels;
    bs_t bs;
    bs_init(&bs, buf, hdr->frame_length);
    bs_read(&bs, 24); /* skip 3-byte header already parsed */

    /* Joint stereo flags */
    uint8_t join[8] = {0};
    if (hdr->channel_mode == SBC_MODE_JOINT) {
        for (int sb = 0; sb < M - 1; sb++) join[sb] = (uint8_t)bs_read(&bs, 1);
        bs_read(&bs, 1); /* RFA */
    }

    /* Scale factors: 4 bits per subband per channel */
    uint8_t scale_factor[2][8] = {{0}};
    for (int ch = 0; ch < N; ch++)
        for (int sb = 0; sb < M; sb++)
            scale_factor[ch][sb] = (uint8_t)bs_read(&bs, 4);

    /* Bit allocation */
    uint8_t bits[2][8] = {{0}};
    calc_bits(hdr, scale_factor, bits);

    /* Audio samples */
    float sb_sample[16][2][8]; /* [block][channel][subband] */
    for (int blk = 0; blk < hdr->blocks; blk++) {
        for (int ch = 0; ch < N; ch++) {
            for (int sb = 0; sb < M; sb++) {
                if (bits[ch][sb] == 0) {
                    sb_sample[blk][ch][sb] = 0.0f;
                } else {
                    uint32_t raw = bs_read(&bs, bits[ch][sb]);
                    float level = (float)(1 << scale_factor[ch][sb]);
                    /* Reconstruction: (raw + 0.5) / (2^bits - 1) * 2 - 1, scaled */
                    float quant = ((float)raw + 0.5f) /
                                  (float)(1 << (bits[ch][sb] - 1)) - 1.0f;
                    sb_sample[blk][ch][sb] = level * quant;
                }
            }
        }
        /* Joint stereo: undo mid-side coding */
        if (hdr->channel_mode == SBC_MODE_JOINT) {
            for (int sb = 0; sb < M - 1; sb++) {
                if (join[sb]) {
                    float L = sb_sample[blk][0][sb] + sb_sample[blk][1][sb];
                    float R = sb_sample[blk][0][sb] - sb_sample[blk][1][sb];
                    sb_sample[blk][0][sb] = L;
                    sb_sample[blk][1][sb] = R;
                }
            }
        }
    }

    /* Synthesis: convert subband samples to PCM */
    int out_idx = 0;
    for (int blk = 0; blk < hdr->blocks; blk++) {
        int16_t pcm_ch[2][8];
        for (int ch = 0; ch < N; ch++) {
            if (M == 8) synth8(&g_synth[ch], sb_sample[blk][ch], pcm_ch[ch]);
            else        synth4(&g_synth[ch], sb_sample[blk][ch], pcm_ch[ch]);
        }
        /* Interleave L/R */
        for (int s = 0; s < M; s++) {
            if (N == 2) {
                pcm_out[out_idx++] = pcm_ch[0][s];
                pcm_out[out_idx++] = pcm_ch[1][s];
            } else {
                /* Mono → duplicate to both channels */
                pcm_out[out_idx++] = pcm_ch[0][s];
                pcm_out[out_idx++] = pcm_ch[0][s];
            }
        }
    }

    *pcm_samples = out_idx; /* total interleaved samples */
    return (int)hdr->frame_length;
}

int sbc_decode_a2dp_payload(const uint8_t *payload, size_t payload_len,
                             int16_t *pcm_buf, int pcm_capacity,
                             sbc_frame_header_t *hdr_out)
{
    if (payload_len < 1) return -1;
    /* first byte is the media payload header (number of frames) */
    size_t pos    = 0;
    int total_out = 0;
    int first     = 1;

    while (pos < payload_len) {
        sbc_frame_header_t hdr;
        if (sbc_parse_header(payload + pos, payload_len - pos, &hdr) < 0) break;
        if (first && hdr_out) { *hdr_out = hdr; first = 0; }
        if (total_out + hdr.blocks * hdr.subbands * 2 > pcm_capacity) break;
        int samples = 0;
        int consumed = sbc_decode_frame(payload + pos, payload_len - pos,
                                        &hdr, pcm_buf + total_out, &samples);
        if (consumed < 0) break;
        total_out += samples;
        pos       += (size_t)consumed;
    }
    return total_out;
}
