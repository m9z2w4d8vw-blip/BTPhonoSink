#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct { uint64_t cid; unsigned signal,valid; } BTPSV88Transaction;
typedef struct {
    unsigned local_seid,remote_seid;
    BTPSV88Transaction pending[2][16];
} BTPSV88Control;
/* Serialized by caller; direction 0=RX, 1=successfully queued TX.
 * -1=no change; 0=stop; 1=matched START accept. */
int btps_v88_signal(BTPSV88Control *,unsigned direction,uint64_t cid,
                    const uint8_t *,size_t length);
#ifdef __cplusplus
}
#endif
