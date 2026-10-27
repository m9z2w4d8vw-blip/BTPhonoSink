#include "BTPSV79Geometry.h"
#include <string.h>
int btps_v79_analyze(const uint8_t config[3], const uint8_t context_counts[3],
                     unsigned pointer_present, BTPSV79Geometry *out) {
    if (!out || !config || !context_counts || (pointer_present & ~7u)) return -1;
    /* The verified binary uses 8-bit counts. Reject nonsensical values rather
       than interpreting arbitrary bytes as a safe table size. */
    for (unsigned i = 0; i < 3; ++i)
        if (config[i] > BTPS_V79_MAX_COUNT || context_counts[i] > BTPS_V79_MAX_COUNT)
            return -2;
    if (context_counts[0] == 0u) return -3;
    BTPSV79Geometry r;
    memset(&r, 0, sizeof r);
    const unsigned strides[3] = {
        BTPS_V79_ENDPOINT_STRIDE, BTPS_V79_SECONDARY_STRIDE, BTPS_V79_TERTIARY_STRIDE
    };
    r.config_matches_context = 1u;
    for (unsigned i = 0; i < 3; ++i) {
        r.configured[i] = config[i];
        r.observed[i] = context_counts[i];
        r.bytes[i] = (unsigned)context_counts[i] * strides[i];
        if (config[i] != context_counts[i]) r.config_matches_context = 0u;
        if (context_counts[i] && !(pointer_present & (1u << i)))
            r.missing_table_mask |= (1u << i);
    }
    *out = r;
    return 0;
}
