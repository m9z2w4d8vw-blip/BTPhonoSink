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
    int32_t error, stopping;
    uint64_t dropped;
    uint64_t render_callbacks, submitted_frames, submitted_nonzero, silence_frames;
    AudioQueueRef queue;
} Output;

static void render(void *context,AudioQueueRef queue,AudioQueueBufferRef buffer) {
    Output *o=context;
    if(__atomic_load_n(&o->stopping,__ATOMIC_ACQUIRE)) return;
    __atomic_fetch_add(&o->render_callbacks,1,__ATOMIC_RELAXED);
    int16_t *out=buffer->mAudioData;
    unsigned take=0,nonzero=0;
    memset(out,0,AUDIO_FRAMES*4u);
    /* Never wait on the decoder. If it holds the PCM lock, emit silence. */
    if(pthread_mutex_trylock(&o->lock)==0) {
        take=o->count<AUDIO_FRAMES?o->count:AUDIO_FRAMES;
        for(unsigned i=0;i<take;i++) {
            unsigned slot=(o->read+i)%PCM_CAPACITY;
            out[i*2]=o->pcm[slot*2];out[i*2+1]=o->pcm[slot*2+1];
            nonzero+=(out[i*2]!=0)+(out[i*2+1]!=0);
        }
        o->read=(o->read+take)%PCM_CAPACITY;o->count-=take;
        pthread_mutex_unlock(&o->lock);
    }
    if(__atomic_load_n(&o->stopping,__ATOMIC_ACQUIRE)) return;
    buffer->mAudioDataByteSize=AUDIO_FRAMES*4u;
    OSStatus e=AudioQueueEnqueueBuffer(queue,buffer,0,NULL);
    if(e) {
        /* A stop can begin between the check and enqueue. That is teardown,
         * not a playback fault to carry into the next START. */
        if(!__atomic_load_n(&o->stopping,__ATOMIC_ACQUIRE))
            __atomic_store_n(&o->error,e,__ATOMIC_RELAXED);
    } else {
        __atomic_fetch_add(&o->submitted_frames,take,__ATOMIC_RELAXED);
        __atomic_fetch_add(&o->submitted_nonzero,nonzero,__ATOMIC_RELAXED);
        __atomic_fetch_add(&o->silence_frames,AUDIO_FRAMES-take,__ATOMIC_RELAXED);
    }
}
static void stop_output(Output *o,BTPSV88Shared *s) {
    __atomic_store_n(&o->stopping,1,__ATOMIC_RELEASE);
    if(!o->queue) return;
    AudioQueueStop(o->queue,true);
    AudioQueueDispose(o->queue,true);o->queue=NULL;o->rate=0;
    __atomic_store_n(&o->error,0,__ATOMIC_RELAXED);
    pthread_mutex_lock(&o->lock);o->read=o->count=0;pthread_mutex_unlock(&o->lock);
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:NULL];
    btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,0,1});
}
static int speaker_selected(AVAudioSession *session) {
    NSArray<AVAudioSessionPortDescription *> *ports=session.currentRoute.outputs;
    return ports.count==1 && [ports.firstObject.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker];
}
static void log_route(AVAudioSession *session,const char *stage,unsigned rate,BTPSV88Shared *s) {
    int speaker=speaker_selected(session);
    btps_v88_event(s,1,(BTPSV88Event){BTPS_V881_ROUTE,
        (uint32_t)(session.outputVolume*100.0f+0.5f),rate,speaker?0:-102});
    for(AVAudioSessionPortDescription *port in session.currentRoute.outputs)
        fprintf(stdout,"V881_AUDIO_ROUTE stage=%s type=%s name=%s rate=%u volume=%.3f built_in_speaker=%d\n",
                stage,port.portType.UTF8String,port.portName.UTF8String,rate,session.outputVolume,speaker);
    if(!session.currentRoute.outputs.count)
        fprintf(stdout,"V881_AUDIO_ROUTE stage=%s outputs=0 built_in_speaker=0\n",stage);
    fflush(stdout);
}
static int configure_speaker(unsigned rate,BTPSV88Shared *s) {
    AVAudioSession *session=[AVAudioSession sharedInstance];NSError *error=nil;
    const char *stage="category";
    /* Playback implicitly permits A2DP: v8.8 chose the sending laptop as output.
     * Speaker override is supported only with PlayAndRecord. No input queue,
     * microphone tap, recording request, Bluetooth or AirPlay option is used. */
    BOOL ok=[session setCategory:AVAudioSessionCategoryPlayAndRecord
                           mode:AVAudioSessionModeDefault
                        options:AVAudioSessionCategoryOptionDefaultToSpeaker error:&error];
    if(ok) {stage="activate";ok=[session setActive:YES error:&error];}
    if(ok) {stage="speaker_override";ok=[session overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:&error];}
    if(!ok) {
        fprintf(stderr,"V881_AUDIO_FAIL stage=%s domain=%s code=%ld error=%s\n",stage,
            (error.domain?:@"unknown").UTF8String,(long)error.code,
            (error.localizedDescription?:@"unknown").UTF8String);
        [session setActive:NO error:NULL];
        btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,rate,-100});return -1;
    }
    /* Allow a bounded hardware-route transition on this helper worker only. */
    for(unsigned i=0;i<20 && !speaker_selected(session);i++) usleep(10000);
    log_route(session,"configured",rate,s);
    if(!speaker_selected(session)) {
        fprintf(stderr,"V881_AUDIO_FAIL stage=route_check expected=built_in_speaker\n");
        [session setActive:NO error:NULL];
        btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,rate,-102});return -1;
    }
    return 0;
}
static int start_output(Output *o,unsigned rate,BTPSV88Shared *s) {
    AVAudioSession *session=[AVAudioSession sharedInstance];
    if(configure_speaker(rate,s)) return -1;
    __atomic_store_n(&o->stopping,1,__ATOMIC_RELEASE);
    __atomic_store_n(&o->error,0,__ATOMIC_RELAXED);
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
    if(!e && !speaker_selected(session)) e=-102;
    if(!e) {
        __atomic_store_n(&o->stopping,0,__ATOMIC_RELEASE);
        e=AudioQueueStart(o->queue,NULL);
    }
    btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,rate,e});
    if(e) {stop_output(o,s);[session setActive:NO error:NULL];return -1;}
    o->rate=rate;
    log_route(session,"started",rate,s);return 0;
}
typedef struct { uint32_t samples,nonzero,peak; } PCMLevels;
static void measure_pcm(PCMLevels *level,const int16_t *pcm,unsigned frames) {
    level->samples+=frames*2u;
    for(unsigned i=0;i<frames*2u;i++) {
        int value=pcm[i];unsigned magnitude=value<0?(unsigned)-value:(unsigned)value;
        if(value) level->nonzero++;
        if(magnitude>level->peak) level->peak=magnitude;
    }
}
static void report_progress(Output *o,PCMLevels *level,BTPSV88Shared *s) {
    uint64_t callbacks=__atomic_exchange_n(&o->render_callbacks,0,__ATOMIC_RELAXED);
    uint64_t submitted=__atomic_exchange_n(&o->submitted_frames,0,__ATOMIC_RELAXED);
    uint64_t nonzero=__atomic_exchange_n(&o->submitted_nonzero,0,__ATOMIC_RELAXED);
    uint64_t silence=__atomic_exchange_n(&o->silence_frames,0,__ATOMIC_RELAXED);
    UInt32 running=0,size=sizeof running;
    OSStatus status=o->queue?AudioQueueGetProperty(o->queue,kAudioQueueProperty_IsRunning,&running,&size):-1;
    pthread_mutex_lock(&o->lock);unsigned queued=o->count;pthread_mutex_unlock(&o->lock);
    int speaker=speaker_selected([AVAudioSession sharedInstance]);
    fprintf(stdout,"V881_PCM samples=%u nonzero=%u peak=%u\n",level->samples,level->nonzero,level->peak);
    fprintf(stdout,"V881_RENDER callbacks=%llu pcm_frames=%llu nonzero_samples=%llu silence_frames=%llu queued_frames=%u dropped_frames=%llu queue_running=%u query_status=%d built_in_speaker=%d\n",
        (unsigned long long)callbacks,(unsigned long long)submitted,(unsigned long long)nonzero,
        (unsigned long long)silence,queued,(unsigned long long)o->dropped,(unsigned)running,(int)status,speaker);
    fflush(stdout);
    btps_v88_event(s,1,(BTPSV88Event){BTPS_V881_PCM,level->peak,level->samples,(int32_t)level->nonzero});
    btps_v88_event(s,1,(BTPSV88Event){BTPS_V881_RENDER,(uint32_t)silence,(uint32_t)submitted,(int32_t)callbacks});
    *level=(PCMLevels){0};
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
    unsigned idle=0,retry=0,diagnostic_ticks=0;BOOL interrupted=NO;
    PCMLevels level={0};
    __block int interruption=0,route_changed=0;
    id observer=[[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionInterruptionNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            unsigned type=[note.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntValue];
            __atomic_store_n(&interruption,type==AVAudioSessionInterruptionTypeBegan?1:2,__ATOMIC_RELEASE);
        }];
    id route_observer=[[NSNotificationCenter defaultCenter] addObserverForName:AVAudioSessionRouteChangeNotification
        object:nil queue:nil usingBlock:^(NSNotification *note) {
            (void)note;__atomic_store_n(&route_changed,1,__ATOMIC_RELEASE);
        }];
    for(;;) {
        @autoreleasepool {
            uint8_t byte;ssize_t n=recv(fd,&byte,1,MSG_PEEK);
            if(n==0 || (n<0 && errno!=EAGAIN && errno!=EWOULDBLOCK && errno!=EINTR)) break;
            __atomic_fetch_add(&s->helper_heartbeat,1,__ATOMIC_RELEASE);
            int changed=__atomic_exchange_n(&interruption,0,__ATOMIC_ACQUIRE);
            if(changed) {interrupted=changed==1;stop_output(o,s);btps_v88_decoder_reset(&decoder);}
            if(__atomic_exchange_n(&route_changed,0,__ATOMIC_ACQUIRE) && o->queue) {
                AVAudioSession *session=[AVAudioSession sharedInstance];
                log_route(session,"changed",o->rate,s);
                if(!speaker_selected(session)) {
                    stop_output(o,s);btps_v88_decoder_reset(&decoder);retry=20;
                }
            }
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
                    measure_pcm(&level,pcm,samples);
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
            if(++diagnostic_ticks%200u==0 && ((generation&1u) || level.samples))
                report_progress(o,&level,s);
        }
        usleep(5000); /* shared-memory doorbell polling, <=5ms nominal wake latency */
    }
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [[NSNotificationCenter defaultCenter] removeObserver:route_observer];
    stop_output(o,s);pthread_mutex_destroy(&o->lock);free(o);
    munmap(s,sizeof *s);close(file);
}
int BTPSV88StreamMain(void) {
    fprintf(stdout,"V881_HELPER build=v8.8.1-speaker-route output=built_in_speaker\n");fflush(stdout);
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
