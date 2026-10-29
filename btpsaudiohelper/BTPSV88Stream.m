/* Live SBC is decoded and played only in this auxiliary process. */
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include "BTPSV88Stream.h"
#include "BTPSV88Decode.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <unistd.h>

#define PCM_CAPACITY 16384u /* stereo frames, <= 372ms; discard oldest on overflow */
#define AUDIO_FRAMES 512u
typedef struct {
    pthread_mutex_t lock;
    int16_t pcm[PCM_CAPACITY*2];
    unsigned read, count, rate;
    int32_t error;
    uint64_t dropped;
    AudioQueueRef queue;
} Output;

static void render(void *context,AudioQueueRef queue,AudioQueueBufferRef buffer) {
    Output *o=context;
    int16_t *out=buffer->mAudioData;
    memset(out,0,AUDIO_FRAMES*4u);
    /* Never wait on the decoder. If it holds the PCM lock, emit silence. */
    if(pthread_mutex_trylock(&o->lock)==0) {
        unsigned take=o->count<AUDIO_FRAMES?o->count:AUDIO_FRAMES;
        for(unsigned i=0;i<take;i++) {
            unsigned slot=(o->read+i)%PCM_CAPACITY;
            out[i*2]=o->pcm[slot*2];out[i*2+1]=o->pcm[slot*2+1];
        }
        o->read=(o->read+take)%PCM_CAPACITY;o->count-=take;
        pthread_mutex_unlock(&o->lock);
    }
    buffer->mAudioDataByteSize=AUDIO_FRAMES*4u;
    OSStatus e=AudioQueueEnqueueBuffer(queue,buffer,0,NULL);
    if(e) __atomic_store_n(&o->error,e,__ATOMIC_RELAXED);
}
static void stop_output(Output *o,BTPSV88Shared *s) {
    if(!o->queue) return;
    AudioQueueStop(o->queue,true);
    AudioQueueDispose(o->queue,true);o->queue=NULL;o->rate=0;
    pthread_mutex_lock(&o->lock);o->read=o->count=0;pthread_mutex_unlock(&o->lock);
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:NULL];
    btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,0,1});
}
static int start_output(Output *o,unsigned rate,BTPSV88Shared *s) {
    NSError *error=nil;
    AVAudioSession *session=[AVAudioSession sharedInstance];
    if(![session setCategory:AVAudioSessionCategoryPlayback error:&error] ||
       ![session setActive:YES error:&error]) {
        fprintf(stderr,"V88_AUDIO session failed: %s\n",error.localizedDescription.UTF8String);
        btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,rate,-100});return -1;
    }
    AudioStreamBasicDescription format={0};
    format.mSampleRate=rate;format.mFormatID=kAudioFormatLinearPCM;
    format.mFormatFlags=kLinearPCMFormatFlagIsSignedInteger|kLinearPCMFormatFlagIsPacked;
    format.mBytesPerPacket=4;format.mFramesPerPacket=1;format.mBytesPerFrame=4;
    format.mChannelsPerFrame=2;format.mBitsPerChannel=16;
    OSStatus e=AudioQueueNewOutput(&format,render,o,NULL,NULL,0,&o->queue);
    for(unsigned i=0;!e && i<3;i++) {
        AudioQueueBufferRef b=NULL;
        e=AudioQueueAllocateBuffer(o->queue,AUDIO_FRAMES*4u,&b);
        if(!e) {
            memset(b->mAudioData,0,AUDIO_FRAMES*4u);b->mAudioDataByteSize=AUDIO_FRAMES*4u;
            e=AudioQueueEnqueueBuffer(o->queue,b,0,NULL);
        }
    }
    if(!e) e=AudioQueueStart(o->queue,NULL);
    btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,rate,e});
    if(e) {stop_output(o,s);[session setActive:NO error:NULL];return -1;}
    o->rate=rate;
    for(AVAudioSessionPortDescription *port in session.currentRoute.outputs)
        fprintf(stdout,"V88_AUDIO_ROUTE type=%s name=%s rate=%u volume=%.3f\n",
                port.portType.UTF8String,port.portName.UTF8String,rate,session.outputVolume);
    fflush(stdout);return 0;
}
static void write_pcm(Output *o,const int16_t *pcm,unsigned frames) {
    pthread_mutex_lock(&o->lock);
    if(frames>PCM_CAPACITY-o->count) {
        unsigned discard=frames-(PCM_CAPACITY-o->count);
        o->read=(o->read+discard)%PCM_CAPACITY;o->count-=discard;o->dropped+=discard;
    }
    for(unsigned i=0;i<frames;i++) {
        unsigned slot=(o->read+o->count+i)%PCM_CAPACITY;
        o->pcm[slot*2]=pcm[i*2];o->pcm[slot*2+1]=pcm[i*2+1];
    }
    o->count+=frames;pthread_mutex_unlock(&o->lock);
}
static int read_exact(int fd,void *dst,size_t size) {
    uint8_t *p=dst;
    while(size) {
        ssize_t n=recv(fd,p,size,0);
        if(n<0 && errno==EINTR) continue;
        if(n<=0) return -1;
        p+=n;size-=(size_t)n;
    }
    return 0;
}
static void stream(int fd) {
    struct timeval timeout={2,0};int one=1;
    setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof timeout);
    setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof timeout);
    setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof one);
    BTPSV88Hello hello;
    if(read_exact(fd,&hello,sizeof hello) || hello.magic!=BTPS_V88_MAGIC ||
       hello.version!=BTPS_V88_VERSION || hello.size!=sizeof(BTPSV88Shared) || !hello.pid) return;
    char path[160];snprintf(path,sizeof path,BTPS_V88_PATH_FORMAT,hello.pid,(unsigned long long)hello.token);
    int file=open(path,O_RDWR|O_NOFOLLOW);if(file<0) {perror("V88_MAP open");return;}
    struct stat st;
    if(fstat(file,&st) || !S_ISREG(st.st_mode) || st.st_uid!=geteuid() ||
       (st.st_mode&0777)!=0600 || st.st_size!=(off_t)sizeof(BTPSV88Shared) ||
       st.st_nlink!=1 || flock(file,LOCK_EX|LOCK_NB)) {close(file);return;}
    BTPSV88Shared *s=mmap(NULL,sizeof *s,PROT_READ|PROT_WRITE,MAP_SHARED,file,0);
    if(s==MAP_FAILED) {close(file);return;}
    if(__atomic_load_n(&s->magic,__ATOMIC_ACQUIRE)!=hello.magic ||
       s->version!=hello.version || s->size!=hello.size || s->pid!=hello.pid || s->token!=hello.token) {
        munmap(s,sizeof *s);close(file);return;
    }
    Output *o=calloc(1,sizeof *o);
    if(!o) {munmap(s,sizeof *s);close(file);return;}
    pthread_mutex_init(&o->lock,NULL);
    uint8_t ack=88;
    int flags=fcntl(fd,F_GETFL,0);
    if(send(fd,&ack,1,0)!=1 || flags<0 || fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0) {
        pthread_mutex_destroy(&o->lock);free(o);munmap(s,sizeof *s);close(file);return;
    }
    BTPSV88Decoder decoder;btps_v88_decoder_reset(&decoder);
    BTPSV88Packet packet;int16_t pcm[BTPS_V88_PCM_SAMPLES];
    uint64_t generation=0,doorbell=UINT64_MAX;
    unsigned idle=0,retry=0;BOOL interrupted=NO;
    __block int interruption=0;
    id observer=[[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            unsigned type=[note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntValue];
            __atomic_store_n(&interruption,type==AVAudioSessionInterruptionTypeBegan?1:2,__ATOMIC_RELEASE);
        }];
    for(;;) {
        @autoreleasepool {
            uint8_t byte;ssize_t n=recv(fd,&byte,1,MSG_PEEK);
            if(n==0 || (n<0 && errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR)) break;
            __atomic_fetch_add(&s->helper_heartbeat,1,__ATOMIC_RELEASE);
            int changed=__atomic_exchange_n(&interruption,0,__ATOMIC_ACQUIRE);
            if(changed) {interrupted=changed==1;stop_output(o,s);btps_v88_decoder_reset(&decoder);}
            uint64_t current=__atomic_load_n(&s->generation,__ATOMIC_ACQUIRE);
            if(current!=generation) {
                stop_output(o,s);btps_v88_decoder_reset(&decoder);generation=current;retry=0;
            }
            int32_t audio_error=__atomic_exchange_n(&o->error,0,__ATOMIC_RELAXED);
            if(audio_error) {
                btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,o->rate,audio_error});
                stop_output(o,s);retry=100;
            }
            if(retry) retry--;
            unsigned processed=0;
            uint64_t signal=__atomic_load_n(&s->doorbell,__ATOMIC_ACQUIRE);
            if(signal!=doorbell) {
                for(unsigned i=0;i<BTPS_V88_SLOTS && btps_v88_dequeue(s,&packet);i++) {
                    if(!(generation&1u) || packet.generation!=generation || interrupted) continue;
                    unsigned frames=0,samples=0,rate=0;
                    int result=btps_v88_decode(&decoder,&packet,pcm,BTPS_V88_PCM_SAMPLES,&frames,&samples,&rate);
                    btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_DECODE,packet.length,frames,result});
                    processed++;
                    if(result || !samples) continue;
                    /* Recheck after decoding so a concurrent STOP cannot queue stale PCM. */
                    if(__atomic_load_n(&s->generation,__ATOMIC_ACQUIRE)!=generation) break;
                    if(o->queue && o->rate!=rate) stop_output(o,s);
                    if(!o->queue && !retry && start_output(o,rate,s)) retry=100;
                    if(o->queue) write_pcm(o,pcm,samples);
                }
                /* If bounded drain left packets, poll again instead of losing a wakeup. */
                if(__atomic_load_n(&s->media.read,__ATOMIC_RELAXED)==
                   __atomic_load_n(&s->media.write,__ATOMIC_ACQUIRE)) doorbell=signal;
            }
            idle=processed?0:idle+1;
            if(idle==400) {stop_output(o,s);btps_v88_decoder_reset(&decoder);}
        }
        usleep(5000); /* shared-memory doorbell polling, <=5ms nominal wake latency */
    }
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    stop_output(o,s);pthread_mutex_destroy(&o->lock);free(o);
    munmap(s,sizeof *s);close(file);
}
int BTPSV88StreamMain(void) {
    int (*activate)(const char *,int **,size_t *)=dlsym(RTLD_DEFAULT,"launch_activate_socket");
    int *fds=NULL;size_t count=0;
    if(!activate || activate("Stream",&fds,&count) || !count) {
        fprintf(stderr,"V88_SERVICE socket activation unavailable; run via launchd\n");free(fds);return 2;
    }
    int listener=fds[0];for(size_t i=1;i<count;i++) close(fds[i]);free(fds);
    for(;;) {
        fd_set set;FD_ZERO(&set);FD_SET(listener,&set);struct timeval idle={10,0};
        int ready=select(listener+1,&set,NULL,NULL,&idle);
        if(ready<0 && errno==EINTR) continue;
        if(ready<=0) break;
        int fd=accept(listener,NULL,NULL);
        if(fd>=0) {@autoreleasepool {stream(fd);} close(fd);}
    }
    close(listener);return 0;
}
