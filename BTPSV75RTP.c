#include "BTPSV75RTP.h"
#include "BTPSMedia.h"
#include "sbc_decode.h"
#include <string.h>
int btps_v75_extract_sbc(const uint8_t *wire,size_t size,uint8_t *dest,size_t capacity,
                         size_t *written,unsigned *packet_count,unsigned *frame_count) {
    if(written)*written=0;
    if(packet_count)*packet_count=0;
    if(frame_count)*frame_count=0;
    if(!wire||!dest||!written||!packet_count||!frame_count||!size||size>20000u) return -1;
    size_t p=0,out=0; unsigned n=0,frames=0; uint16_t prev_seq=0;uint32_t prev_ts=0,ssrc=0;
    uint32_t expected_advance=0;
    /* First pass: prevalidate everything before touching dest. */
    for(int pass=0;pass<2;pass++) {
        p=0;n=0;frames=0;out=0;
        while(p<size) {
            if(size-p<2)return -2;
            size_t packet_size=((size_t)wire[p]<<8)|wire[p+1];p+=2;
            if(packet_size<14u||packet_size>512u||packet_size>size-p)return -3;
            btps_media_view_t v;
            if(btps_media_parse_rtp(wire+p,packet_size,&v)!=BTPS_MEDIA_OK)return -4;
            if(v.sample_rate!=44100u||v.channels!=2u||v.frame_count==0u||v.payload_type!=96u)return -5;
            if(n && (v.sequence!=(uint16_t)(prev_seq+1u) || v.timestamp!=prev_ts+expected_advance || v.ssrc!=ssrc))return -6;
            if(!n) ssrc=v.ssrc;
            prev_seq=v.sequence;prev_ts=v.timestamp;
            size_t offset=v.media_offset;
            expected_advance=0;
            for(unsigned j=0;j<v.frame_count;j++) {
                sbc_frame_header_t h;
                if(sbc_parse_header(wire+p+offset+v.frame_offsets[j],v.frame_lengths[j],&h)!=0)return -7;
                expected_advance+=(uint32_t)h.blocks*(uint32_t)h.subbands;
            }
            if(v.media_length>capacity-out)return -8;
            if(pass==1)memcpy(dest+out,wire+p+v.media_offset,v.media_length);
            out+=v.media_length;frames+=v.frame_count;p+=packet_size;n++;
            if(n>BTPS_V75_EXPECTED_PACKETS)return -9;
        }
        if(n!=BTPS_V75_EXPECTED_PACKETS||frames!=BTPS_V75_EXPECTED_SBC_FRAMES||p!=size)return -10;
    }
    *written=out;*packet_count=n;*frame_count=frames;
    return 0;
}
