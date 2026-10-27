/* v7.7 experimental AVDTP Sink SEP probe: buffer preparation only.
 * NEVER call private bluetooth APIs from this module. The caller supplies
 * four copied SBC codec bytes; all pointer fields refer to owned storage.
 */
#pragma once
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    uint64_t caps_words[6]; /* three 16-byte service capability records */
    uint8_t codec_bytes[4];
    uint8_t assigned_seid; /* distinct from any native Source output byte */
} BTPSV77SinkCaps;
/* Returns zero on success; never reads beyond raw[48]/codec[4]. */
int btps_v77_prepare_sink_caps(BTPSV77SinkCaps *dst,
                               const uint8_t raw[48],const uint8_t codec[4]);
#ifdef __cplusplus
}
#endif
