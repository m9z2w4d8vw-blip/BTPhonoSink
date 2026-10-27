/* Tested auxiliary-helper-only SBC decoder adapter; NOT loaded in bluetoothd. */
#include "BTPSV76Decode.h"
#include "vendor_sbc/sbc.h"
#include <string.h>
#include <stdint.h>
#define BTPS_V76_MAX_FRAMES 300u
#define BTPS_V76_MAX_PER_CHANNEL (300u * SBC_MAX_SAMPLES)
int btps_v76_decode_sbc(const uint8_t *src,size_t src_bytes,int16_t *pcm,size_t pcm_slots,
                        size_t *frames_out,size_t *samples_out,unsigned *rate_out,unsigned *channels_out) {
    if(frames_out)*frames_out=0;
    if(samples_out)*samples_out=0;
    if(rate_out)*rate_out=0;
    if(channels_out)*channels_out=0;
    if(!src||!pcm||!frames_out||!samples_out||!rate_out||!channels_out||
       src_bytes==0||src_bytes>20000u||pcm_slots>BTPS_V76_MAX_PER_CHANNEL*2u)return -1;
    sbc_t decoder;
    memset(&decoder,0,sizeof decoder);sbc_reset(&decoder);
    size_t offset=0,frames=0,per_channel=0;
    while(offset<src_bytes){
        struct sbc_frame frame;
        if(src_bytes-offset < SBC_HEADER_SIZE || sbc_probe(src+offset,&frame)!=0)return -2;
        unsigned frame_len=sbc_get_frame_size(&frame);
        unsigned channels=frame.mode==SBC_MODE_MONO?1u:2u;
        unsigned sr=(unsigned)sbc_get_freq_hz(frame.freq);
        size_t n=(size_t)frame.nblocks*(size_t)frame.nsubbands;
        if(frame_len<SBC_HEADER_SIZE || frame_len>src_bytes-offset ||
           channels!=2u||sr!=44100u||n==0||n>SBC_MAX_SAMPLES)return -3;
        if(frames>=BTPS_V76_MAX_FRAMES || per_channel > BTPS_V76_MAX_PER_CHANNEL-n ||
           n>pcm_slots/2u || per_channel > (pcm_slots/2u)-n) return -4;
        /* SBC API accepts output pitch for channel-interleaved PCM. */
        if(sbc_decode(&decoder,src+offset,frame_len,&frame,
                      pcm+per_channel*2u,2,pcm+per_channel*2u+1u,2)!=0)return -5;
        offset+=frame_len;per_channel+=n;frames++;
    }
    if(frames!=258u || per_channel!=33024u || offset!=src_bytes)return -6;
    *frames_out=frames;*samples_out=per_channel;*rate_out=44100u;*channels_out=2u;
    return 0;
}
