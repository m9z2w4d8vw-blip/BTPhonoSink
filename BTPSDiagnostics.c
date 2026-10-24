#include "BTPSDiagnostics.h"
#include <string.h>

int btps_decode_caps(const uint8_t *buffer, size_t len, btps_caps_info_t *out)
{
    if (!out) return 0;
    memset(out, 0, sizeof *out);
    if (!buffer || !len || (len % BTPS_CAP_RECORD_BYTES) ||
        len > BTPS_CAP_RECORD_BYTES * BTPS_CAP_MAX_RECORDS) return 0;

    uint32_t hash = 2166136261u;
    for (size_t i = 0; i < len; i++) hash = (hash ^ buffer[i]) * 16777619u;
    out->fingerprint = hash;
    out->total_records = (unsigned)(len / BTPS_CAP_RECORD_BYTES);
    for (size_t off = 0; off < len; off += BTPS_CAP_RECORD_BYTES) {
        switch (buffer[off]) {
            case 1: out->transport_records++; break;
            case 7:
                out->codec_records++;
                if (!out->codec_present) {
                    out->codec_present = 1;
                    out->media_type = buffer[off + 1];
                    out->codec_type = buffer[off + 2];
                    out->codec_data_len = buffer[off + 3];
                }
                break;
            case 8: out->delay_records++; break;
            default: out->unknown_records++; break;
        }
    }
    return 1;
}

const char *btps_codec_name(uint8_t type)
{
    switch (type) {
        case 0x00: return "SBC";
        case 0x01: return "MPEG-1/2 Audio";
        case 0x02: return "AAC";
        case 0x04: return "ATRAC";
        case 0xff: return "Vendor-specific";
        default: return "Unknown";
    }
}

const char *btps_endpoint_name(uint32_t media, uint32_t direction)
{
    if (media != 0) return "other-media";
    if (direction == 0) return "Audio Source";
    if (direction == 1) return "Audio Sink";
    return "unknown-direction";
}

const char *btps_registration_result(uint64_t result)
{
    if (result == 0) return "accepted";
    if (result == 0x68) return "0x68 (previously observed at endpoint exhaustion; meaning not ABI-verified)";
    return "nonzero (meaning not ABI-verified)";
}
