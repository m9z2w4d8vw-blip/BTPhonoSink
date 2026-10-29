#include "BTPSV88Control.h"
int btps_v88_signal(BTPSV88Control *s,unsigned direction,uint64_t cid,
                    const uint8_t *p,size_t length) {
    if(direction>1 || length<2 || ((p[0]>>2)&3u) || (p[1]&0xc0u)) return -1;
    unsigned tx=p[0]>>4,msg=p[0]&3u,sig=p[1]&63u;
    if(msg==0) {
        BTPSV88Transaction *t=&s->pending[direction][tx];
        t->valid=0; /* transaction label reused */
        if(sig!=7 && sig!=8 && sig!=9 && sig!=10) return -1;
        unsigned seid=direction?s->remote_seid:s->local_seid;
        int matches=0;
        for(size_t i=2;i<length;i++) if(seid && p[i]==(seid<<2)) matches=1;
        if(!matches) return -1;
        t->cid=cid;t->signal=sig;t->valid=1;
        /* Suspend/close/abort silence immediately, even if later rejected. */
        return sig==7?-1:0;
    }
    BTPSV88Transaction *t=&s->pending[1u-direction][tx];
    if(!t->valid || t->cid!=cid || t->signal!=sig) return -1;
    t->valid=0;
    if(msg==2 && length==2) return sig==7?1:0;
    return -1;
}
