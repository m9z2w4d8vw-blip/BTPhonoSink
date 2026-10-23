#pragma once
#import <Foundation/Foundation.h>
#include "sbc_decode.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Called by the media-data hook with the raw A2DP media payload.
 * payload = bytes immediately following the 12-byte RTP header.
 * payload_len = remaining bytes in the UDP/L2CAP packet.               */
void btphonosink_on_media_payload(const uint8_t *payload, size_t payload_len);

/* Start / stop the output engine.  Called from the SetConfigInd hook.  */
void btphonosink_start(uint32_t sample_rate, uint8_t nchannels);
void btphonosink_stop(void);

/* Returns 1 if the sink is currently running.                           */
int btphonosink_is_running(void);

#ifdef __cplusplus
}
#endif
