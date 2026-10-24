/* BTPSDiagnostics.h -- allocation-free, portable AVDTP diagnostics.
 * These structures are from observation of the analysed bluetoothd build,
 * NOT a public/private stable Apple API. Never mutate capability bytes. */
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

#define BTPS_CAP_RECORD_BYTES 16u
#define BTPS_CAP_MAX_RECORDS 8u

typedef struct {
    unsigned total_records;
    unsigned transport_records;
    unsigned codec_records;
    unsigned delay_records;
    unsigned unknown_records;
    unsigned codec_present;
    uint8_t media_type;     /* record +1: observed 0 for audio */
    uint8_t codec_type;     /* record +2: observed 00 SBC, 02 AAC, ff vendor */
    uint8_t codec_data_len; /* record +3: observed 4, 6, 14 */
    uint32_t fingerprint;   /* FNV-1a of copied capability bytes, diagnostics only */
} btps_caps_info_t;

/* Return 1 for a safe, bounded, whole-record buffer; 0 otherwise.
 * No copies or reads beyond len; out remains zeroed on invalid input. */
int btps_decode_caps(const uint8_t *buffer, size_t len, btps_caps_info_t *out);
const char *btps_codec_name(uint8_t type);
const char *btps_endpoint_name(uint32_t media, uint32_t direction);
const char *btps_registration_result(uint64_t result);
#ifdef __cplusplus
}
#endif
