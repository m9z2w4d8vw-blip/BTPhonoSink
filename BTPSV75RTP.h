#pragma once
#include <stddef.h>
#include <stdint.h>
#define BTPS_V75_EXPECTED_PACKETS 258u
#define BTPS_V75_EXPECTED_SBC_FRAMES 258u
#define BTPS_V75_SBC_BYTES_LIMIT 16000u
/* Parse u16-be-length-prefixed RTP, validate SBC frame lengths/metadata,
 * require monotonic sequence+timestamps and a stable SSRC, extract SBC bytes.
 * Does not decode audio; output written only after full pre-validation. */
int btps_v75_extract_sbc(const uint8_t *wire,size_t wire_length,uint8_t *dest,size_t dest_capacity,
                         size_t *dest_written,unsigned *packets,unsigned *frames);
