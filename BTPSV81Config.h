/* v8.1: validated copy of immutable index-3 AVDTP config; no Apple dependencies. */
#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
#define BTPS_V81_CONFIG_COPY_BYTES 32u
/* Must only copy an exact 6,3,3 original, preserving all other bytes.
 * trial_seven=0 mirrors unchanged; =1 changes only byte zero to 7. */
int btps_v81_prepare_shadow(const uint8_t *source, size_t source_size,
                            uint8_t out[BTPS_V81_CONFIG_COPY_BYTES], int trial_seven);
#ifdef __cplusplus
}
#endif
