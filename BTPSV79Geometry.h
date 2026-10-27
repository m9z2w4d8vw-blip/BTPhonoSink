/* v7.9: pure, read-only analysis of the AVDTP initialization geometry.
 * No Apple APIs, no allocation, no mutation. */
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define BTPS_V79_CONTEXT_SIZE 0x68u
#define BTPS_V79_ENDPOINT_STRIDE 0x28u
#define BTPS_V79_SECONDARY_STRIDE 0x90u
#define BTPS_V79_TERTIARY_STRIDE 0x40u
#define BTPS_V79_MAX_COUNT 64u

typedef struct {
    uint8_t configured[3];
    uint8_t observed[3];
    unsigned bytes[3];
    unsigned config_matches_context;
    unsigned missing_table_mask;
} BTPSV79Geometry;
/* first 3 config bytes; first 3 live-context bytes at +0x60;
 * pointer_present bits 0/1/2 for context+0/+8/+0x10. */
int btps_v79_analyze(const uint8_t config[3], const uint8_t context_counts[3],
                     unsigned pointer_present, BTPSV79Geometry *out);
#ifdef __cplusplus
}
#endif
