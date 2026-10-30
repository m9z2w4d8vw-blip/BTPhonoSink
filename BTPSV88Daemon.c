/* Only this worker performs IPC/logging. Never called from the media thread. */
#include "BTPSV88Daemon.h"
#include "BTPSV88Shared.h"
#include "BTPSV882Health.h"
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
#include <time.h>
#include <unistd.h>

static BTPSV88Shared *g_shared;
static BTPSV88Hello g_hello;

/* v8.9.3: one V88_FORWARD and one V88_DECODE line per packet filled 94% of the log, so a Settings export showed only
 * the last ~7 seconds of a session. Successful packets are now counted and summarized every two seconds (and right
 * before any stream state change); anything unusual is still logged individually, at most BTPS_V893_DETAILS_PER_WINDOW
 * lines per window, with a count of what was held back. */
#define BTPS_V893_SUMMARY_MS 2000u
#define BTPS_V893_DETAILS_PER_WINDOW 8u
typedef struct {
    uint64_t forwarded, forward_ok, forward_inactive, forward_other, forward_bytes;
    uint64_t decoded, decode_ok, decode_partial, decode_bad, decode_frames;
    unsigned details, held_back;
} BTPSV893Tally;
static BTPSV893Tally g_v893_tally;
static uint64_t g_v893_window_ms;
static BTPSV88Event g_v893_pending_pcm;     /* the helper sends PCM then RENDER; they are logged as one line */
static int g_v893_have_pcm;
static int v893_detail_allowed(void) {
    if(g_v893_tally.details<BTPS_V893_DETAILS_PER_WINDOW) {g_v893_tally.details++;return 1;}
    g_v893_tally.held_back++;return 0;
}
/* Writes the window's summary (if anything happened) and starts a new window. force=1 flushes immediately. */
static void v893_flush_tally(uint64_t now,int force) {
    if(!g_v893_window_ms) g_v893_window_ms=now;
    if(!force && now-g_v893_window_ms<BTPS_V893_SUMMARY_MS) return;
    const BTPSV893Tally *t=&g_v893_tally;
    if(t->forwarded || t->decoded || t->held_back)
        BTPSLogNow("V893_RX %llums forwarded=%llu ok=%llu inactive=%llu other=%llu bytes=%llu "
                   "decoded=%llu ok=%llu partial=%llu bad=%llu frames=%llu held_back=%u",
                   (unsigned long long)(now>=g_v893_window_ms?now-g_v893_window_ms:0),
                   (unsigned long long)t->forwarded,(unsigned long long)t->forward_ok,
                   (unsigned long long)t->forward_inactive,(unsigned long long)t->forward_other,
                   (unsigned long long)t->forward_bytes,(unsigned long long)t->decoded,
                   (unsigned long long)t->decode_ok,(unsigned long long)t->decode_partial,
                   (unsigned long long)t->decode_bad,(unsigned long long)t->decode_frames,t->held_back);
    memset(&g_v893_tally,0,sizeof g_v893_tally);
    g_v893_window_ms=now;
}
static uint64_t g_health_generation,g_health_deadline_ms;
static uint64_t monotonic_ms(void) {
    struct timespec ts;
    if(clock_gettime(CLOCK_MONOTONIC,&ts)) return 0;
    return (uint64_t)ts.tv_sec*1000u+(uint64_t)ts.tv_nsec/1000000u;
}
int BTPSV882SinkHealthy(void) {
    BTPSV88Shared *s=__atomic_load_n(&g_shared,__ATOMIC_ACQUIRE);
    if(!s) return 0;
    uint64_t healthy_generation=__atomic_load_n(&g_health_generation,__ATOMIC_ACQUIRE);
    uint64_t deadline=__atomic_load_n(&g_health_deadline_ms,__ATOMIC_ACQUIRE);
    uint64_t generation=__atomic_load_n(&s->generation,__ATOMIC_ACQUIRE);
    uint64_t now=monotonic_ms();
    return (generation&1u) && now && now<deadline &&
        healthy_generation==generation;
}

void BTPSV88SetActive(int active) {
    BTPSV88Shared *s=__atomic_load_n(&g_shared,__ATOMIC_ACQUIRE);
    if(!s) return;
    __atomic_store_n(&g_health_deadline_ms,0,__ATOMIC_RELEASE);
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
static void drain_logs(BTPSV88Shared *s,BTPSV882Health *health,uint64_t now) {
    BTPSV88Event e;
    for(unsigned i=0;i<BTPS_V88_EVENTS;i++) {
        if(!btps_v88_pop(&s->forward_log,s->forwarded,sizeof s->forwarded[0],
                        BTPS_V88_EVENTS,&e,sizeof e)) break;
        g_v893_tally.forwarded++;g_v893_tally.forward_bytes+=e.bytes;
        if(e.result==0) g_v893_tally.forward_ok++;
        else if(e.result==-1) g_v893_tally.forward_inactive++;   /* expected just after STOP/SUSPEND */
        else {
            g_v893_tally.forward_other++;
            if(v893_detail_allowed()) BTPSLogNow("V88_FORWARD bytes=%u handle=%u result=%d",e.bytes,e.frames,e.result);
        }
    }
    for(unsigned i=0;i<BTPS_V88_EVENTS;i++) {
        if(!btps_v88_pop(&s->decode_log,s->decoded,sizeof s->decoded[0],
                        BTPS_V88_EVENTS,&e,sizeof e)) break;
        if(e.kind==BTPS_V882_HEALTH)
            btps_v882_health_render(health,e.bytes,e.frames,e.result==1,now);
        else if(e.kind==BTPS_V88_DECODE) {
            g_v893_tally.decoded++;g_v893_tally.decode_frames+=e.frames;
            if(e.result==0) g_v893_tally.decode_ok++;
            else if(e.result==1) g_v893_tally.decode_partial++;      /* SBC fragment still being reassembled */
            else {
                g_v893_tally.decode_bad++;
                if(v893_detail_allowed()) BTPSLogNow("V88_DECODE frames=%u bytes=%u result=%d",e.frames,e.bytes,e.result);
            }
        }
        else if(e.kind==BTPS_V881_PCM) {g_v893_pending_pcm=e;g_v893_have_pcm=1;}
        else if(e.kind==BTPS_V881_RENDER) {
            if(g_v893_have_pcm)
                BTPSLogNow("V881_PCM samples=%u nonzero=%d peak=%u | RENDER callbacks=%d pcm_frames=%u silence_frames=%u",
                           g_v893_pending_pcm.frames,g_v893_pending_pcm.result,g_v893_pending_pcm.bytes,
                           e.result,e.frames,e.bytes);
            else BTPSLogNow("V881_RENDER callbacks=%d pcm_frames=%u silence_frames=%u",e.result,e.frames,e.bytes);
            g_v893_have_pcm=0;
        }
        else if(e.kind==BTPS_V881_ROUTE)
            BTPSLogNow("V881_ROUTE route_ok=%u volume_pct=%u rate=%u",(unsigned)(e.result==0),e.bytes,e.frames);
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
    int fd=-1,last_ready=-1; unsigned ticks=0, retry=0, stale=0;
    uint64_t heartbeat=0,last_generation=0,last_drops=0,last_logs=0;
    BTPSV882Health health={0};
    for(;;) {
        uint64_t now=monotonic_ms();
        uint64_t generation=__atomic_load_n(&s->generation,__ATOMIC_ACQUIRE);
        uint64_t media=__atomic_load_n(&s->doorbell,__ATOMIC_ACQUIRE);
        uint64_t helper=__atomic_load_n(&s->helper_heartbeat,__ATOMIC_ACQUIRE);
        if(health.generation!=generation)
            btps_v882_health_reset(&health,generation,media,helper);
        btps_v882_health_sample(&health,media,helper,now);
        drain_logs(s,&health,now);
        v893_flush_tally(now,generation!=last_generation);
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
                btps_v882_health_reset(&health,generation,media,helper);
                BTPSLogNow("V88_HELPER disconnected; retry remains off receive thread");
            }
        }
        if(retry) retry--;
        if(fd<0 && (generation&1u) && !retry) {
            fd=attach_helper();retry=100;
            BTPSLogNow("V88_HELPER %s port=%u",fd>=0?"mapped shared ring":"activation failed",BTPS_V88_PORT);
        }
        /* The lease also expires if this worker stalls. A real STOP changes
         * generation immediately, so an old lease cannot keep it alive. */
        int ready=now && btps_v882_health_ready(&health,fd>=0,now);
        if(__atomic_load_n(&g_health_generation,__ATOMIC_RELAXED)!=generation) {
            __atomic_store_n(&g_health_deadline_ms,0,__ATOMIC_RELEASE);
            __atomic_store_n(&g_health_generation,generation,__ATOMIC_RELEASE);
        }
        __atomic_store_n(&g_health_deadline_ms,ready?now+500u:0,__ATOMIC_RELEASE);
        if(ready!=last_ready) {
            BTPSLogNow("V882_HEALTH ready=%d generation=%llu connected=%d playing=%u media_age_ms=%lld heartbeat_age_ms=%lld render_age_ms=%lld",
                ready,(unsigned long long)(generation>>1),fd>=0,health.playing,
                health.media_seen?(long long)(now-health.media_ms):-1ll,
                health.heartbeat_seen?(long long)(now-health.heartbeat_ms):-1ll,
                health.render_seen?(long long)(now-health.render_ms):-1ll);
            last_ready=ready;
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
