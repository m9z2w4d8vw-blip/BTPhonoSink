/* v8.8 cross-process ABI. No pointers, locks, allocation, or OS calls in queues. */
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define BTPS_V88_MAGIC 0x38565042u
#define BTPS_V88_VERSION 1u
#define BTPS_V88_SLOTS 32u
#define BTPS_V88_PAYLOAD 2048u
#define BTPS_V88_EVENTS 256u
#define BTPS_V88_PORT 37594
#define BTPS_V88_PATH_FORMAT "/tmp/FTABHarvest/BTPS-v88-%u-%016llx.shm"

typedef struct { uint64_t write, read, dropped; } BTPSV88Queue;
typedef struct {
    uint64_t generation;
    uint32_t length, timestamp;
    uint16_t sequence, handle;
    uint8_t data[BTPS_V88_PAYLOAD];
} BTPSV88Packet;
typedef struct { uint64_t turn; BTPSV88Packet value; } BTPSV88PacketSlot;
/* Event additions preserve the existing shared-memory layout/version. */
enum { BTPS_V88_FORWARD=1, BTPS_V88_DECODE=2, BTPS_V88_AUDIO=3,
       BTPS_V881_PCM=4, BTPS_V881_RENDER=5, BTPS_V881_ROUTE=6,
       BTPS_V882_HEALTH=7 };
typedef struct { uint32_t kind, bytes, frames; int32_t result; } BTPSV88Event;
typedef struct { uint64_t turn; BTPSV88Event value; } BTPSV88EventSlot;
typedef struct {
    uint32_t magic, version, size, pid;
    uint64_t token;
    /* generation includes active bit 0; increments on every START/STOP. */
    uint64_t generation, doorbell, helper_heartbeat;
    BTPSV88Queue media, forward_log, decode_log;
    BTPSV88PacketSlot packets[BTPS_V88_SLOTS];
    BTPSV88EventSlot forwarded[BTPS_V88_EVENTS], decoded[BTPS_V88_EVENTS];
} BTPSV88Shared;
typedef struct {
    uint32_t magic, version, size, pid;
    uint64_t token;
} BTPSV88Hello;

void btps_v88_init(BTPSV88Shared *, uint32_t pid, uint64_t token);
/* Bounded retries; on full, claim/discard oldest complete item, never overwrite
 * a reader's slot. If a preempted owner pins a slot, drop the new item instead.
 * This is intentionally not a spin-until-success queue. */
int btps_v88_push(BTPSV88Queue *, void *slots, size_t stride,
                  unsigned capacity, const void *value, size_t bytes);
int btps_v88_pop(BTPSV88Queue *, void *slots, size_t stride,
                 unsigned capacity, void *value, size_t bytes);
int btps_v88_enqueue(BTPSV88Shared *, const BTPSV88Packet *);
int btps_v88_dequeue(BTPSV88Shared *, BTPSV88Packet *);
void btps_v88_event(BTPSV88Shared *, int helper, BTPSV88Event);
#ifdef __cplusplus
}
#endif
