#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
int BTPSV88Prepare(void);
void BTPSV88SetActive(int active);
/* Control/idle-check threads only; queries a short worker-issued health lease. */
int BTPSV882SinkHealthy(void);
/* The sole media callback path; length is native w4, not an RTP length. */
void BTPSV88Forward(uint32_t handle, uint32_t sequence, uint32_t timestamp,
                    const uint8_t *payload, uint32_t length, uint32_t error,
                    uint32_t expected_handle);
#ifdef __cplusplus
}
#endif
