#pragma once
#import <Foundation/Foundation.h>
#include "sbc_decode.h"
#include "BTPSMedia.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Called by the media-data hook with the raw A2DP media payload.
 * payload = bytes immediately following the 12-byte RTP header.
 * payload_len = remaining bytes in the UDP/L2CAP packet.               */
void btphonosink_on_media_payload(const uint8_t *payload, size_t payload_len);

/* New receive-side integration point. Accepts an entire RTP(v2)/A2DP SBC packet
 * and returns a BTPS_MEDIA_* result. This function is NOT yet connected to a live
 * Bluetooth callback; callers must run in an audio-output-authorized process.
 */
int btphonosink_on_rtp_packet(const uint8_t *packet, size_t packet_len);

/* Start / stop the output engine in a permitted process (NOT called by hooks yet). */
void btphonosink_start(uint32_t sample_rate, uint8_t nchannels);
void btphonosink_stop(void);

/* Returns 1 if the sink is currently running.                           */
int btphonosink_is_running(void);

#ifdef __cplusplus
}
#endif
