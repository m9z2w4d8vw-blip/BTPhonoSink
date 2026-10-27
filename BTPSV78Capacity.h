/* Read-only analysis of bluetoothd AVDTP endpoint slots (exact iOS build only). */
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define BTPS_V78_SLOT_BYTES 40u
#define BTPS_V78_MAX_SLOTS 32u
#define BTPS_V78_SEID_OFFSET 0x19u

typedef struct {
    unsigned total;
    unsigned occupied;
    unsigned vacant;
    unsigned duplicate_seids;
    uint8_t seids[BTPS_V78_MAX_SLOTS];
} BTPSV78Capacity;
/* Buffer must hold exactly (or at least) count * 40 bytes; never reads beyond it. */
int btps_v78_analyze(const uint8_t *slots, size_t bytes, unsigned count, BTPSV78Capacity *out);
#ifdef __cplusplus
}
#endif
