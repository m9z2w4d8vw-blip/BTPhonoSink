/* Bounded RFC 3550 RTP and A2DP SBC payload parsing. Never touches system state. */
#include "BTPSMedia.h"
#include "sbc_decode.h"
#include <limits.h>
#include <string.h>

static uint16_t read16be(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] << 8 | p[1]);
}
static uint32_t read32be(const uint8_t *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | (uint32_t)p[3];
}

btps_media_result_t btps_media_parse_rtp(const uint8_t *packet, size_t length,
                                          btps_media_view_t *out)
{
    if (!packet || !out) return BTPS_MEDIA_INVALID;
    memset(out, 0, sizeof *out);
    if (length < 12u) return BTPS_MEDIA_TRUNCATED;
    uint8_t first = packet[0];
    if ((first >> 6) != 2u) return BTPS_MEDIA_INVALID;
    unsigned cc = first & 0x0fu;
    size_t pos = 12u + (size_t)cc * 4u;
    if (pos > length) return BTPS_MEDIA_TRUNCATED;
    if (first & 0x10u) {
        if (length - pos < 4u) return BTPS_MEDIA_TRUNCATED;
        size_t words = (size_t)read16be(packet + pos + 2u);
        pos += 4u;
        if (words > (length - pos) / 4u) return BTPS_MEDIA_TRUNCATED;
        pos += words * 4u;
    }
    size_t end = length;
    if (first & 0x20u) {
        if (end == pos) return BTPS_MEDIA_TRUNCATED;
        uint8_t padding = packet[end - 1u];
        if (!padding || padding > end - pos) return BTPS_MEDIA_INVALID;
        end -= padding;
    }
    if (end <= pos) return BTPS_MEDIA_TRUNCATED;

    /* SBC media payload header: F,S,L,RFA,frameCount (four bits). */
    uint8_t payload_header = packet[pos++];
    if (payload_header & 0x80u) return BTPS_MEDIA_UNSUPPORTED_FRAGMENT;
    if (payload_header & 0x70u) return BTPS_MEDIA_INVALID;
    unsigned frames = payload_header & 0x0fu;
    if (frames == 0u) return BTPS_MEDIA_INVALID;
    if (end <= pos) return BTPS_MEDIA_TRUNCATED;

    out->sequence = read16be(packet + 2u);
    out->timestamp = read32be(packet + 4u);
    out->ssrc = read32be(packet + 8u);
    out->payload_type = packet[1] & 0x7fu;
    out->marker = packet[1] >> 7;
    out->media_offset = pos;
    out->media_length = end - pos;
    out->frame_count = (uint8_t)frames;

    size_t off = 0;
    for (unsigned i = 0; i < frames; ++i) {
        sbc_frame_header_t header;
        if (end - pos - off < 4u) return BTPS_MEDIA_TRUNCATED;
        if (sbc_parse_header(packet + pos + off, end - pos - off, &header) != 0)
            return BTPS_MEDIA_BAD_SBC;
        if (header.bitpool < 2u || header.bitpool > 250u)
            return BTPS_MEDIA_BAD_SBC;
        const unsigned max_bitpool = header.channel_mode == SBC_MODE_MONO ||
                header.channel_mode == SBC_MODE_DUAL ? 16u * header.subbands : 32u * header.subbands;
        if (header.bitpool > max_bitpool || header.frame_length < 4u ||
            (size_t)header.frame_length > end - pos - off)
            return BTPS_MEDIA_BAD_SBC;
        if (i && (out->channels != header.nchannels || out->sample_rate != header.sample_rate))
            return BTPS_MEDIA_BAD_SBC;
        if (!i) {
            out->channels = header.nchannels;
            out->sample_rate = header.sample_rate;
        }
        if (off > UINT16_MAX || header.frame_length > UINT16_MAX - off)
            return BTPS_MEDIA_INVALID;
        out->frame_offsets[i] = (uint16_t)off;
        out->frame_lengths[i] = header.frame_length;
        off += header.frame_length;
    }
    if (off != out->media_length) return BTPS_MEDIA_BAD_SBC; /* reject trailing/extra frames */
    return BTPS_MEDIA_OK;
}

btps_media_result_t btps_media_decode_rtp_sbc(const uint8_t *packet, size_t length,
                                               int16_t *pcm_out, size_t pcm_capacity,
                                               size_t *samples_out,
                                               btps_media_view_t *view_out)
{
    if (samples_out) *samples_out = 0;
    if (!pcm_out || !samples_out) return BTPS_MEDIA_INVALID;
    btps_media_view_t view;
    btps_media_result_t ret = btps_media_parse_rtp(packet, length, &view);
    if (ret != BTPS_MEDIA_OK) return ret;
    /* Preflight all frames to prevent partial decoding when PCM storage is too small. */
    size_t total_required = 0;
    for (unsigned i = 0; i < view.frame_count; ++i) {
        sbc_frame_header_t hdr;
        const uint8_t *f = packet + view.media_offset + view.frame_offsets[i];
        if (sbc_parse_header(f, view.frame_lengths[i], &hdr) != 0) return BTPS_MEDIA_BAD_SBC;
        size_t n = (size_t)hdr.blocks * hdr.subbands * 2u; /* decoder emits stereo even for mono */
        if (n > pcm_capacity - total_required) return BTPS_MEDIA_BUFFER_SMALL;
        total_required += n;
    }
    size_t written = 0;
    for (unsigned i = 0; i < view.frame_count; ++i) {
        sbc_frame_header_t hdr;
        const uint8_t *f = packet + view.media_offset + view.frame_offsets[i];
        if (sbc_parse_header(f, view.frame_lengths[i], &hdr) != 0) return BTPS_MEDIA_BAD_SBC;
        int samples = 0;
        if (sbc_decode_frame(f, view.frame_lengths[i], &hdr, pcm_out + written, &samples) < 0)
            return BTPS_MEDIA_BAD_SBC;
        written += (size_t)samples;
    }
    *samples_out = written;
    if (view_out) *view_out = view;
    return BTPS_MEDIA_OK;
}
