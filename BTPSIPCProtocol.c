#include "BTPSIPCProtocol.h"
#include <string.h>
static uint16_t r16(const uint8_t *p) { return (uint16_t)(p[0] | ((uint16_t)p[1]<<8)); }
static uint32_t r32(const uint8_t *p) { return (uint32_t)p[0] | ((uint32_t)p[1]<<8) | ((uint32_t)p[2]<<16) | ((uint32_t)p[3]<<24); }
static void w16(uint8_t *p,uint16_t n) {p[0]=(uint8_t)n;p[1]=(uint8_t)(n>>8);}
static void w32(uint8_t *p,uint32_t n) {p[0]=(uint8_t)n;p[1]=(uint8_t)(n>>8);p[2]=(uint8_t)(n>>16);p[3]=(uint8_t)(n>>24);}
uint32_t btps_ipc_crc32(const uint8_t *data, size_t count) {
    if (!data && count) return 0;
    uint32_t c=0xffffffffu;
    for(size_t i=0;i<count;i++) {
        c^=data[i];
        for (int b=0;b<8;b++) c=(c>>1)^((c&1u)?0xedb88320u:0u);
    }
    return ~c;
}
void btps_ipc_encode(uint8_t h[BTPS_IPC_HEADER_SIZE],uint32_t token,uint32_t crc) {
    memset(h,0,BTPS_IPC_HEADER_SIZE);
    memcpy(h,"BTPS",4); w16(h+4,BTPS_IPC_VERSION); w16(h+6,1u);
    w32(h+8,BTPS_IPC_SAMPLERATE); w32(h+12,BTPS_IPC_FRAMES);
    w32(h+16,token); w32(h+20,crc);
}
int btps_ipc_validate(const uint8_t h[BTPS_IPC_HEADER_SIZE],uint32_t token,const uint8_t *pcm,size_t n) {
    if (!h || !pcm || n!=BTPS_IPC_PCM_BYTES) return 0;
    if (memcmp(h,"BTPS",4)!=0 || r16(h+4)!=BTPS_IPC_VERSION || r16(h+6)!=1u) return 0;
    if (r32(h+8)!=BTPS_IPC_SAMPLERATE || r32(h+12)!=BTPS_IPC_FRAMES || r32(h+16)!=token) return 0;
    return btps_ipc_crc32(pcm,n)==r32(h+20);
}

void btps_ipc_encode_daemon_v74(uint8_t h[BTPS_IPC_V74_HEADER_SIZE],uint32_t token,uint32_t crc) {
    btps_ipc_encode(h,token,crc);
    w16(h+4,BTPS_IPC_V74_VERSION);
    memcpy(h+BTPS_IPC_HEADER_SIZE,"BTD4",4);
}
int btps_ipc_validate_daemon_v74(const uint8_t h[BTPS_IPC_V74_HEADER_SIZE],uint32_t token,
                                 const uint8_t *pcm,size_t n) {
    if(!h || !pcm || n!=BTPS_IPC_PCM_BYTES) return 0;
    if(memcmp(h,"BTPS",4)!=0 || r16(h+4)!=BTPS_IPC_V74_VERSION || r16(h+6)!=1u) return 0;
    if(memcmp(h+BTPS_IPC_HEADER_SIZE,"BTD4",4)!=0) return 0;
    if(r32(h+8)!=BTPS_IPC_SAMPLERATE || r32(h+12)!=BTPS_IPC_FRAMES || r32(h+16)!=token) return 0;
    return btps_ipc_crc32(pcm,n)==r32(h+20);
}

void btps_ipc_encode_sbc_v75(uint8_t h[BTPS_IPC_V75_HEADER_SIZE],uint32_t token,uint32_t crc) {
    memset(h,0,BTPS_IPC_V75_HEADER_SIZE);
    memcpy(h,"BTPS",4); w16(h+4,BTPS_IPC_V75_VERSION); w16(h+6,2u); /* A2DP RTP/SBC sample */
    w32(h+8,BTPS_IPC_V75_FIXTURE_SIZE); w32(h+12,BTPS_IPC_V75_PACKET_COUNT);
    w32(h+16,token);w32(h+20,crc);memcpy(h+24,"BTD5",4);w32(h+28,44100u);
}
int btps_ipc_validate_sbc_v75(const uint8_t h[BTPS_IPC_V75_HEADER_SIZE],uint32_t token,
                               const uint8_t *payload,size_t count) {
    if(!h||!payload||count!=BTPS_IPC_V75_FIXTURE_SIZE) return 0;
    if(memcmp(h,"BTPS",4)!=0 || r16(h+4)!=BTPS_IPC_V75_VERSION || r16(h+6)!=2u) return 0;
    if(r32(h+8)!=BTPS_IPC_V75_FIXTURE_SIZE || r32(h+12)!=BTPS_IPC_V75_PACKET_COUNT ||
       r32(h+16)!=token || memcmp(h+24,"BTD5",4)!=0 || r32(h+28)!=44100u) return 0;
    return btps_ipc_crc32(payload,count)==r32(h+20);
}
