#include "BTPSV77Sink.h"
#include <string.h>
#include <stdint.h>

int btps_v77_prepare_sink_caps(BTPSV77SinkCaps *dst,
                               const uint8_t raw[48], const uint8_t codec[4]) {
    if (!dst || !raw || !codec) return -1;
    /* Only mirror the three fully observed SBC capability categories. The
       16-byte records encode (category, ... , codec_type, length, pointer).
       Do not infer Sink capability support from this layout alone. */
    if (raw[0] != 0x01u || raw[16] != 0x07u || raw[18] != 0x00u ||
        raw[19] != 0x04u || raw[32] != 0x08u || raw[17] != 0x00u)
        return -2;
    /* Fail if the observed SBC codec data has no supported parameters. This
       checks for a nonzero advertised frequency/mode and block/subbands. */
    if (!codec[0] || !codec[1]) return -3;
    memset(dst, 0, sizeof *dst);
    memcpy(dst->caps_words, raw, 48u);
    memcpy(dst->codec_bytes, codec, 4u);
    uint64_t owned_ptr = (uint64_t)(uintptr_t)dst->codec_bytes;
    /* The codec descriptor begins at raw offset 16, its data pointer +8. */
    memcpy((uint8_t*)dst->caps_words + 24u, &owned_ptr, sizeof owned_ptr);
    return 0;
}
