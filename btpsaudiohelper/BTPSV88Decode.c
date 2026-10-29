#include "BTPSV88Decode.h"
#include <string.h>
void btps_v88_decoder_reset(BTPSV88Decoder *d) {
    memset(d,0,sizeof *d); sbc_reset(&d->sbc);
}
static int decode_frames(BTPSV88Decoder *d,const uint8_t *data,size_t size,
                         unsigned count,int16_t *pcm,size_t capacity,
                         unsigned *samples,unsigned *rate) {
    struct sbc_frame frames[15]; unsigned lengths[15];
    size_t at=0; unsigned needed=0,hz=0;
    /* Preflight the whole packet before changing codec state or publishing PCM. */
    if(!count || count>15) return -2;
    for(unsigned i=0;i<count;i++) {
        if(size-at<SBC_HEADER_SIZE || sbc_probe(data+at,&frames[i])) return -3;
        struct sbc_frame *f=&frames[i];
        lengths[i]=sbc_get_frame_size(f);
        unsigned sr=sbc_get_freq_hz(f->freq), n=f->nblocks*f->nsubbands;
        if(f->msbc || (sr!=44100 && sr!=48000) || (hz && hz!=sr) ||
           !n || n>SBC_MAX_SAMPLES || lengths[i]<SBC_HEADER_SIZE || lengths[i]>size-at) return -4;
        hz=sr; needed+=n; at+=lengths[i];
    }
    if(at!=size || needed*2u>capacity) return -5;
    if(d->rate && hz!=d->rate) sbc_reset(&d->sbc);
    d->rate=hz; at=0; unsigned written=0;
    for(unsigned i=0;i<count;i++) {
        struct sbc_frame *f=&frames[i];unsigned n=f->nblocks*f->nsubbands;
        if(sbc_decode(&d->sbc,data+at,lengths[i],f,pcm+written*2,2,pcm+written*2+1,2)) return -6;
        if(f->mode==SBC_MODE_MONO)
            for(unsigned j=0;j<n;j++) pcm[(written+j)*2+1]=pcm[(written+j)*2];
        at+=lengths[i];written+=n;
    }
    *samples=written;*rate=hz;return 0;
}
int btps_v88_decode(BTPSV88Decoder *d,const BTPSV88Packet *p,int16_t *pcm,
                    size_t capacity,unsigned *frames,unsigned *samples,unsigned *rate) {
    *frames=*samples=*rate=0;
    if(!p->length || p->length>BTPS_V88_PAYLOAD) return -1;
    if(d->generation!=p->generation || (d->seen && d->next_sequence!=p->sequence)) {
        btps_v88_decoder_reset(d);d->generation=p->generation;
    }
    d->seen=1;d->next_sequence=(uint16_t)(p->sequence+1);
    const uint8_t *data=p->data+1;size_t size=p->length-1;
    unsigned h=p->data[0],count=h&15u;
    int r=0;
    if(h&0x10u) r=-7; /* reserved bit */
    else if(h&0x80u) {
        if(h&0x40u) d->fragment_bytes=0; /* first fragment */
        else if(!d->fragment_bytes) r=-8;
        if(!r && (!size || size>sizeof d->fragment-d->fragment_bytes)) r=-9;
        if(!r) {
            memcpy(d->fragment+d->fragment_bytes,data,size);d->fragment_bytes+=(unsigned)size;
            if(!(h&0x20u)) return 1;
            data=d->fragment;size=d->fragment_bytes;count=1;
        }
    } else if(h&0x60u) r=-10;
    if(!r) r=decode_frames(d,data,size,count,pcm,capacity,samples,rate);
    d->fragment_bytes=0;
    if(r<0) {sbc_reset(&d->sbc);return r;}
    *frames=count;return 0;
}
