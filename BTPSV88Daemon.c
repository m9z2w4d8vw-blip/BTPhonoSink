/* Only this worker performs IPC/logging. Never called from the media thread. */
#include "BTPSV88Daemon.h"
#include "BTPSV88Shared.h"
#include "BTPSDaemonProbe.h"
#include "BTPSLog.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

static BTPSV88Shared *g_shared;
static BTPSV88Hello g_hello;

void BTPSV88SetActive(int active) {
    BTPSV88Shared *s=__atomic_load_n(&g_shared,__ATOMIC_ACQUIRE);
    if(!s) return;
    uint64_t old=__atomic_load_n(&s->generation,__ATOMIC_RELAXED);
    /* Signaling is serialized by the native AVDTP dispatcher. */
    __atomic_store_n(&s->generation,((old&~1ull)+2u)|(active?1u:0u),__ATOMIC_RELEASE);
}
void BTPSV88Forward(uint32_t handle,uint32_t sequence,uint32_t timestamp,
                    const uint8_t *payload,uint32_t length,uint32_t error,
                    uint32_t expected_handle) {
    BTPSV88Shared *s=__atomic_load_n(&g_shared,__ATOMIC_ACQUIRE);
    if(!s) return; /* callback is installed only after Prepare succeeds */
    uint64_t generation=__atomic_load_n(&s->generation,__ATOMIC_ACQUIRE);
    int result=!(generation&1u)?-1:
        (!handle || handle!=expected_handle)?-3:
        error?-4:(!payload || !length || length>BTPS_V88_PAYLOAD)?-5:0;
    if(result==0) {
        BTPSV88Packet p;
        p.generation=generation; p.length=length; p.timestamp=timestamp;
        p.sequence=(uint16_t)sequence; p.handle=(uint16_t)handle;
        memcpy(p.data,payload,length);
        result=btps_v88_enqueue(s,&p)?0:-2;
    }
    BTPSV88Event event={BTPS_V88_FORWARD,length,handle,result};
    btps_v88_event(s,0,event);
}
static void drain_logs(BTPSV88Shared *s) {
    BTPSV88Event e;
    for(unsigned i=0;i<BTPS_V88_EVENTS;i++) {
        if(!btps_v88_pop(&s->forward_log,s->forwarded,sizeof s->forwarded[0],
                        BTPS_V88_EVENTS,&e,sizeof e)) break;
        BTPSLogNow("V88_FORWARD bytes=%u handle=%u result=%d",e.bytes,e.frames,e.result);
    }
    for(unsigned i=0;i<BTPS_V88_EVENTS;i++) {
        if(!btps_v88_pop(&s->decode_log,s->decoded,sizeof s->decoded[0],
                        BTPS_V88_EVENTS,&e,sizeof e)) break;
        if(e.kind==BTPS_V88_DECODE)
            BTPSLogNow("V88_DECODE frames=%u bytes=%u result=%d",e.frames,e.bytes,e.result);
        else if(e.kind==BTPS_V881_PCM)
            BTPSLogNow("V881_PCM samples=%u nonzero=%d peak=%u",e.frames,e.result,e.bytes);
        else if(e.kind==BTPS_V881_RENDER)
            BTPSLogNow("V881_RENDER callbacks=%d pcm_frames=%u silence_frames=%u",e.result,e.frames,e.bytes);
        else if(e.kind==BTPS_V881_ROUTE)
            BTPSLogNow("V881_ROUTE built_in_speaker=%u volume_pct=%u rate=%u",(unsigned)(e.result==0),e.bytes,e.frames);
        else BTPSLogNow("V88_AUDIO status=%d rate=%u (0=started 1=stopped; errors are OSStatus)",e.result,e.frames);
    }
}
static int attach_helper(void) {
    int fd=BTPSDaemonConnectLoopback(BTPS_V88_PORT);
    if(fd<0) return -1;
    const uint8_t *p=(const uint8_t *)&g_hello;
    size_t at=0;
    while(at<sizeof g_hello) {
        ssize_t n=send(fd,p+at,sizeof g_hello-at,0);
        if(n<0 && errno==EINTR) continue;
        if(n<=0) {close(fd);return -1;} at+=(size_t)n;
    }
    uint8_t ack=0;
    if(recv(fd,&ack,1,0)!=1 || ack!=88) {close(fd);return -1;}
    int flags=fcntl(fd,F_GETFL,0);
    if(flags<0 || fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0) {close(fd);return -1;}
    return fd;
}
static void *worker(void *arg) {
    BTPSV88Shared *s=arg;
    int fd=-1; unsigned ticks=0, retry=0, stale=0;
    uint64_t heartbeat=0,last_generation=0,last_drops=0,last_logs=0;
    for(;;) {
        drain_logs(s);
        uint64_t generation=__atomic_load_n(&s->generation,__ATOMIC_ACQUIRE);
        if(generation!=last_generation) {
            BTPSLogNow("V88_STREAM active=%u generation=%llu",(unsigned)(generation&1u),
                       (unsigned long long)(generation>>1));
            last_generation=generation;
        }
        if(fd>=0) {
            uint8_t c; ssize_t n=recv(fd,&c,1,MSG_PEEK);
            uint64_t h=__atomic_load_n(&s->helper_heartbeat,__ATOMIC_ACQUIRE);
            stale=h==heartbeat?stale+1:0;heartbeat=h;
            if(n==0 || (n<0 && errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR) || stale>250) {
                close(fd);fd=-1;retry=50;stale=0;
                BTPSLogNow("V88_HELPER disconnected; retry remains off receive thread");
            }
        }
        if(retry) retry--;
        if(fd<0 && (generation&1u) && !retry) {
            fd=attach_helper();retry=100;
            BTPSLogNow("V88_HELPER %s port=%u",fd>=0?"mapped shared ring":"activation failed",BTPS_V88_PORT);
        }
        if(++ticks%50==0) {
            uint64_t drops=__atomic_load_n(&s->media.dropped,__ATOMIC_RELAXED);
            uint64_t logs=__atomic_load_n(&s->forward_log.dropped,__ATOMIC_RELAXED)+
                          __atomic_load_n(&s->decode_log.dropped,__ATOMIC_RELAXED);
            if(drops!=last_drops || logs!=last_logs)
                BTPSLogNow("V88_DROP packets=%llu log_records=%llu",(unsigned long long)drops,(unsigned long long)logs);
            last_drops=drops;last_logs=logs;
        }
        usleep(20000); /* dedicated worker, never the Bluetooth receive thread */
    }
    return NULL;
}
int BTPSV88Prepare(void) {
    if(g_shared) return 1;
    uint64_t token; arc4random_buf(&token,sizeof token);
    char path[160];
    snprintf(path,sizeof path,BTPS_V88_PATH_FORMAT,(unsigned)getpid(),(unsigned long long)token);
    int fd=open(path,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(fd<0) {BTPSLogNow("V88_PREPARE open failed errno=%d",errno);return 0;}
    BTPSV88Shared *s=MAP_FAILED;
    if(ftruncate(fd,sizeof *s)==0) s=mmap(NULL,sizeof *s,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    close(fd);
    if(s==MAP_FAILED) {unlink(path);BTPSLogNow("V88_PREPARE mapping failed errno=%d",errno);return 0;}
    btps_v88_init(s,(uint32_t)getpid(),token); /* touches every page before use */
    if(mlock(s,sizeof *s)!=0) {
        BTPSLogNow("V88_PREPARE mlock failed errno=%d; live forwarding refused",errno);
        munmap(s,sizeof *s);unlink(path);return 0;
    }
    g_hello=(BTPSV88Hello){BTPS_V88_MAGIC,BTPS_V88_VERSION,sizeof *s,(uint32_t)getpid(),token};
    pthread_t thread;
    int e=pthread_create(&thread,NULL,worker,s);
    if(e) {munlock(s,sizeof *s);munmap(s,sizeof *s);unlink(path);return 0;}
    pthread_detach(thread);
    __atomic_store_n(&g_shared,s,__ATOMIC_RELEASE);
    BTPSLogNow("V88_PREPARE ready ring_bytes=%zu payload_capacity=65536 locked=1; helper waits for accepted START",sizeof *s);
    return 1;
}
