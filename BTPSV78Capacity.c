#include "BTPSV78Capacity.h"
#include <string.h>
int btps_v78_analyze(const uint8_t *slots, size_t bytes, unsigned count, BTPSV78Capacity *out) {
    if (!out || !slots || count == 0 || count > BTPS_V78_MAX_SLOTS ||
        bytes < (size_t)count * BTPS_V78_SLOT_BYTES) return -1;
    BTPSV78Capacity result;
    memset(&result, 0, sizeof result);
    result.total = count;
    for (unsigned i = 0; i < count; ++i) {
        uint8_t seid = slots[(size_t)i * BTPS_V78_SLOT_BYTES + BTPS_V78_SEID_OFFSET];
        result.seids[i] = seid;
        if (seid) {
            ++result.occupied;
            for (unsigned j = 0; j < i; ++j)
                if (result.seids[j] == seid) { ++result.duplicate_seids; break; }
        } else ++result.vacant;
    }
    *out = result;
    return 0;
}
