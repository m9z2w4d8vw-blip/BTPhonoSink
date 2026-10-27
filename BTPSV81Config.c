#include "BTPSV81Config.h"
#include <string.h>
int btps_v81_prepare_shadow(const uint8_t *source, size_t source_size,
                            uint8_t out[BTPS_V81_CONFIG_COPY_BYTES], int trial_seven)
{
    if (!source || !out || source == out || source_size < BTPS_V81_CONFIG_COPY_BYTES ||
        (trial_seven != 0 && trial_seven != 1)) return -1;
    if (source[0] != 6u || source[1] != 3u || source[2] != 3u) return -2;
    memcpy(out, source, BTPS_V81_CONFIG_COPY_BYTES);
    if (trial_seven) out[0] = 7u;
    return 0;
}
