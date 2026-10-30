/* Speaka daemon-side diagnostic workers.
 * v7.4 PCM and v7.5 compressed SBC entry points are implemented in C
 * (BTPSDaemonProbe.c), but called from Objective-C++ (Tweak.xm).
 * Both MUST use C linkage, or linking fails on arm64 / arm64e.
 */
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

int BTPSDaemonConnectLoopback(uint16_t port);
void BTPSDaemonProbeStart(void);
void BTPSDaemonProbeStartV75(void);

#ifdef __cplusplus
}
#endif
