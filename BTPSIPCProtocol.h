/* v7.3: deliberately tiny, bounded, loopback-only PCM test protocol.
 * No Bluetooth code uses this. Byte order is little-endian, protocol version 1.
 */
#ifndef BTPS_IPC_PROTOCOL_H
#define BTPS_IPC_PROTOCOL_H
#include <stddef.h>
#include <stdint.h>
#define BTPS_IPC_PORT 37593
#define BTPS_IPC_HEADER_SIZE 24u
#define BTPS_IPC_SAMPLERATE 44100u
#define BTPS_IPC_FRAMES 35280u
#define BTPS_IPC_PCM_BYTES (BTPS_IPC_FRAMES*2u)
#define BTPS_IPC_VERSION 1u
#define BTPS_IPC_V74_HEADER_SIZE (BTPS_IPC_HEADER_SIZE + 4u)
#define BTPS_IPC_V74_VERSION 2u
/* Header layout: 0-3 'BTPS'; 4-5 version; 6-7 channels;
 * 8-11 sampleRate; 12-15 sample frames; 16-19 6-digit token;
 * 20-23 CRC32 of signed 16-bit mono samples. */
uint32_t btps_ipc_crc32(const uint8_t *data, size_t count);
void btps_ipc_encode(uint8_t header[BTPS_IPC_HEADER_SIZE], uint32_t token, uint32_t crc);
/* Version 2 adds an identifying (non-cryptographic) tag BTD4 for controlled
 * bluetoothd sender testing. A successful tag is NOT proof of peer identity.
 * Never use this as security authentication for an internet-accessible service. */
void btps_ipc_encode_daemon_v74(uint8_t header[BTPS_IPC_V74_HEADER_SIZE], uint32_t token, uint32_t crc);
int btps_ipc_validate_daemon_v74(const uint8_t header[BTPS_IPC_V74_HEADER_SIZE], uint32_t expected_token,
                                 const uint8_t *pcm, size_t length);
int btps_ipc_validate(const uint8_t header[BTPS_IPC_HEADER_SIZE], uint32_t expected_token,
                      const uint8_t *pcm, size_t length);
#endif
