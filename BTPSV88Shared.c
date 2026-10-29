#include "BTPSV88Shared.h"
#include <string.h>
_Static_assert(__atomic_always_lock_free(8, 0), "64-bit atomics must be lock free");
_Static_assert(sizeof(BTPSV88Hello)==24, "IPC layout");
_Static_assert(offsetof(BTPSV88PacketSlot,value)==8, "slot layout");
_Static_assert(offsetof(BTPSV88EventSlot,value)==8, "slot layout");

void btps_v88_init(BTPSV88Shared *s, uint32_t pid, uint64_t token) {
    memset(s,0,sizeof *s);
    s->version=BTPS_V88_VERSION; s->size=sizeof *s; s->pid=pid; s->token=token;
    for(unsigned i=0;i<BTPS_V88_SLOTS;i++) s->packets[i].turn=i;
    for(unsigned i=0;i<BTPS_V88_EVENTS;i++) {
        s->forwarded[i].turn=i; s->decoded[i].turn=i;
    }
    __atomic_store_n(&s->magic,BTPS_V88_MAGIC,__ATOMIC_RELEASE);
}
int btps_v88_pop(BTPSV88Queue *q, void *slots, size_t stride,
                 unsigned n, void *value, size_t bytes) {
    uint64_t pos=__atomic_load_n(&q->read,__ATOMIC_RELAXED);
    for(unsigned attempt=0;attempt<8;attempt++) {
        uint8_t *cell=(uint8_t *)slots+(pos%n)*stride;
        uint64_t turn=__atomic_load_n((uint64_t *)cell,__ATOMIC_ACQUIRE);
        int64_t diff=(int64_t)(turn-(pos+1));
        if(diff<0) return 0;
        if(diff==0 && __atomic_compare_exchange_n(&q->read,&pos,pos+1,0,
                                                  __ATOMIC_RELAXED,__ATOMIC_RELAXED)) {
            if(value) memcpy(value,cell+8,bytes);
            __atomic_store_n((uint64_t *)cell,pos+n,__ATOMIC_RELEASE);
            return 1;
        }
        pos=__atomic_load_n(&q->read,__ATOMIC_RELAXED);
    }
    return 0;
}
int btps_v88_push(BTPSV88Queue *q, void *slots, size_t stride,
                  unsigned n, const void *value, size_t bytes) {
    uint64_t pos=__atomic_load_n(&q->write,__ATOMIC_RELAXED);
    for(unsigned attempt=0;attempt<8;attempt++) {
        uint8_t *cell=(uint8_t *)slots+(pos%n)*stride;
        uint64_t turn=__atomic_load_n((uint64_t *)cell,__ATOMIC_ACQUIRE);
        int64_t diff=(int64_t)(turn-pos);
        if(diff==0 && __atomic_compare_exchange_n(&q->write,&pos,pos+1,0,
                                                  __ATOMIC_RELAXED,__ATOMIC_RELAXED)) {
            memcpy(cell+8,value,bytes);
            __atomic_store_n((uint64_t *)cell,pos+1,__ATOMIC_RELEASE);
            return 1;
        }
        if(diff<0 && btps_v88_pop(q,slots,stride,n,NULL,0))
            __atomic_fetch_add(&q->dropped,1,__ATOMIC_RELAXED);
        pos=__atomic_load_n(&q->write,__ATOMIC_RELAXED);
    }
    __atomic_fetch_add(&q->dropped,1,__ATOMIC_RELAXED);
    return 0;
}
int btps_v88_enqueue(BTPSV88Shared *s,const BTPSV88Packet *p) {
    if(!p->length || p->length>BTPS_V88_PAYLOAD) return 0;
    int ok=btps_v88_push(&s->media,s->packets,sizeof s->packets[0],BTPS_V88_SLOTS,
                         p,offsetof(BTPSV88Packet,data)+p->length);
    /* Shared-memory doorbell: helper polls this, no kernel notification here. */
    if(ok) __atomic_fetch_add(&s->doorbell,1,__ATOMIC_RELEASE);
    return ok;
}
int btps_v88_dequeue(BTPSV88Shared *s,BTPSV88Packet *p) {
    return btps_v88_pop(&s->media,s->packets,sizeof s->packets[0],BTPS_V88_SLOTS,p,sizeof *p);
}
void btps_v88_event(BTPSV88Shared *s,int helper,BTPSV88Event event) {
    btps_v88_push(helper?&s->decode_log:&s->forward_log,
                  helper?(void *)s->decoded:(void *)s->forwarded,
                  sizeof(BTPSV88EventSlot),BTPS_V88_EVENTS,&event,sizeof event);
}
