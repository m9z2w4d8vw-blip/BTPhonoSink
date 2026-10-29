#pragma once
#include "vendor_sbc/sbc.h"
#include "../BTPSV88Shared.h"
#define BTPS_V88_PCM_SAMPLES (15u*SBC_MAX_SAMPLES*2u)
typedef struct {
    sbc_t sbc;
    uint64_t generation;
    unsigned rate, next_sequence, seen, fragment_bytes;
    uint8_t fragment[BTPS_V88_PAYLOAD];
} BTPSV88Decoder;
void btps_v88_decoder_reset(BTPSV88Decoder *);
/* Always emits interleaved stereo; duplicates mono. 0=OK, 1=fragment pending. */
int btps_v88_decode(BTPSV88Decoder *,const BTPSV88Packet *,int16_t *pcm,
                    size_t capacity,unsigned *frames,unsigned *samples,unsigned *rate);
