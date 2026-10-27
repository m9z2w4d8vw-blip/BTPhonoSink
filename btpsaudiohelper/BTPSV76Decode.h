#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* All capacities are int16 samples (not bytes); no allocation in library. */
int btps_v76_decode_sbc(const uint8_t *sbc, size_t sbc_size, int16_t *pcm,
                        size_t pcm_slots, size_t *frames_out, size_t *samples_per_channel_out,
                        unsigned *rate_out, unsigned *channels_out);
#ifdef __cplusplus
}
#endif
