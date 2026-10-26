/* v7.4: opt-in, bounded diagnostic PCM sender in bluetoothd.
 * No private Bluetooth ABI changes, no receive-path hooks, no launch daemon.
 */
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
void BTPSDaemonProbeStart(void);
#ifdef __cplusplus
}
#endif

void BTPSDaemonProbeStartV75(void);
