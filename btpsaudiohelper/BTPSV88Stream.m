/* Live SBC is decoded and played only in this auxiliary process.
 * v8.9: the output follows Settings > BTPhonoSink > Audio output - the built-in speaker (default), headphones
 * only, or any device iOS is using - minus a user-maintained never-play list. Policy: BTPSV89Output.h. */
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#include "BTPSV88Stream.h"
#include "BTPSV88Decode.h"
#include "BTPSV89Output.h"
#include "BTPSShared.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <notify.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdlib.h>
#include <stdbool.h>
#include <string.h>
#include <sys/file.h>
#include <sys/mman.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* v8.9 output selection; only the stream thread reads or writes these. */
static int g_output_mode=BTPS_V89_MODE_SPEAKER;
static NSArray<NSDictionary *> *g_never_outputs;
static int g_output_notify=-1;
static void publish_status(NSString *state,NSString *reason,BOOL force);
/* v8.9.3: every helper line gets the same HH:MM:SS.mmm prefix as the daemon log, so the two can be read side by
 * side (the Settings export now shows both). Defined above PCM_CAPACITY: the render callback below never logs. */
static void hlog(FILE *stream,const char *fmt,...) __attribute__((format(printf,2,3)));
static void hlog(FILE *stream,const char *fmt,...) {
    struct timespec ts;struct tm tm;
    if(clock_gettime(CLOCK_REALTIME,&ts)) {ts.tv_sec=time(NULL);ts.tv_nsec=0;}
    time_t secs=ts.tv_sec;localtime_r(&secs,&tm);
    fprintf(stream,"%02d:%02d:%02d.%03ld ",tm.tm_hour,tm.tm_min,tm.tm_sec,(long)(ts.tv_nsec/1000000L));
    va_list ap;va_start(ap,fmt);vfprintf(stream,fmt,ap);va_end(ap);
    fflush(stream);
}

#define PCM_CAPACITY 16384u /* stereo frames, <= 372ms; discard oldest on overflow */
#define AUDIO_FRAMES 512u
typedef struct {
    pthread_mutex_t lock;
    int16_t pcm[PCM_CAPACITY*2];
    unsigned read, count, rate;
    int32_t error, stopping;
    uint64_t dropped;
    uint64_t render_callbacks, submitted_frames, submitted_nonzero, silence_frames;
    uint64_t render_tick; /* cumulative enqueued PCM frames; never reset by logs */
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
        __atomic_fetch_add(&o->render_tick,take,__ATOMIC_RELAXED);
        __atomic_fetch_add(&o->submitted_frames,take,__ATOMIC_RELAXED);
        __atomic_fetch_add(&o->submitted_nonzero,nonzero,__ATOMIC_RELAXED);
        __atomic_fetch_add(&o->silence_frames,AUDIO_FRAMES-take,__ATOMIC_RELAXED);
    }
}
static void stop_output(Output *o,BTPSV88Shared *s,const char *reason) {
    __atomic_store_n(&o->stopping,1,__ATOMIC_RELEASE);
    if(!o->queue) return;
    uint64_t current_generation=__atomic_load_n(&s->generation,__ATOMIC_ACQUIRE);
    hlog(stdout,"V882_AUDIO_STOP reason=%s generation=%llu active=%u\n",reason,
        (unsigned long long)(current_generation>>1),(unsigned)(current_generation&1u));fflush(stdout);
    btps_v88_event(s,1,(BTPSV88Event){BTPS_V882_HEALTH,
        (uint32_t)current_generation,
        (uint32_t)__atomic_load_n(&o->render_tick,__ATOMIC_RELAXED),0});
    AudioQueueStop(o->queue,true);
    AudioQueueDispose(o->queue,true);o->queue=NULL;o->rate=0;
    __atomic_store_n(&o->error,0,__ATOMIC_RELAXED);
    pthread_mutex_lock(&o->lock);o->read=o->count=0;pthread_mutex_unlock(&o->lock);
    [[AVAudioSession sharedInstance] setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:NULL];
    btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,0,1});
    publish_status(@"idle",[NSString stringWithUTF8String:reason]?:@"",NO);
}
static int speaker_selected(AVAudioSession *session) {
    NSArray<AVAudioSessionPortDescription *> *ports=session.currentRoute.outputs;
    return ports.count==1 && [ports.firstObject.portType isEqualToString:AVAudioSessionPortBuiltInSpeaker];
}
/* ---- v8.9 output selection ---------------------------------------------------------------------------- */
static btps_v89_kind port_kind(NSString *type) {
    if([type isEqualToString:AVAudioSessionPortBuiltInSpeaker]) return BTPS_V89_PORT_SPEAKER;
    if([type isEqualToString:AVAudioSessionPortBuiltInReceiver]) return BTPS_V89_PORT_RECEIVER;
    if([type isEqualToString:AVAudioSessionPortHeadphones] || [type isEqualToString:AVAudioSessionPortUSBAudio] ||
       [type isEqualToString:AVAudioSessionPortBluetoothA2DP] || [type isEqualToString:AVAudioSessionPortBluetoothLE] ||
       [type isEqualToString:AVAudioSessionPortBluetoothHFP]) return BTPS_V89_PORT_HEADPHONES;
    return BTPS_V89_PORT_OTHER;
}
static NSString *text_field(id item,NSString *key) {
    id value=[item isKindOfClass:[NSDictionary class]]?((NSDictionary *)item)[key]:nil;
    return [value isKindOfClass:[NSString class]]?value:@"";
}
/* Settings writes the mode and the never-play list; re-read on every connection and on BTPS_NOTIFY_V89_OUTPUT. */
static void load_output_settings(void) {
    CFStringRef domain=CFSTR(BTPS_PREFS_DOMAIN);
    (void)CFPreferencesAppSynchronize(domain);
    id mode=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR(BTPS_KEY_V89_OUTPUT_MODE),domain));
    g_output_mode=btps_v89_mode_from_string([mode isKindOfClass:[NSString class]]?[(NSString *)mode UTF8String]:NULL);
    id never=CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR(BTPS_KEY_V89_NEVER),domain));
    NSMutableArray<NSDictionary *> *list=[NSMutableArray array];
    if([never isKindOfClass:[NSArray class]])
        for(id item in (NSArray *)never)
            if([item isKindOfClass:[NSDictionary class]] && list.count<BTPS_V89_MAX_NEVER) [list addObject:item];
    g_never_outputs=list;
    hlog(stdout,"V889_OUTPUT_SETTINGS mode=%s never_play=%lu\n",btps_v89_mode_name(g_output_mode),
            (unsigned long)list.count);
    fflush(stdout);
}
/* BTPS_V89_ROUTE_OK when playback may use iOS's current output route; otherwise the refusal reason. */
static int route_verdict(AVAudioSession *session,NSString **device) {
    NSArray<AVAudioSessionPortDescription *> *outputs=session.currentRoute.outputs;
    btps_v89_port ports[BTPS_V89_MAX_PORTS];btps_v89_never never[BTPS_V89_MAX_NEVER];
    size_t count=outputs.count<BTPS_V89_MAX_PORTS?outputs.count:BTPS_V89_MAX_PORTS,never_count=0,bad=0;
    for(size_t i=0;i<count;i++) {
        AVAudioSessionPortDescription *port=outputs[i];
        ports[i]=(btps_v89_port){port_kind(port.portType),port.UID.UTF8String?:"",port.portName.UTF8String?:""};
    }
    for(NSDictionary *item in g_never_outputs) {
        if(never_count==BTPS_V89_MAX_NEVER) break;
        never[never_count++]=(btps_v89_never){text_field(item,@"uid").UTF8String,text_field(item,@"name").UTF8String};
    }
    int verdict=btps_v89_route_check(g_output_mode,ports,count,never,never_count,&bad);
    if(device) *device=(verdict && bad<count)?outputs[bad].portName:nil;
    return verdict;
}
static dispatch_queue_t g_status_queue;
static NSString *g_status_state,*g_status_reason;
static uint64_t g_status_written_ms;
static uint64_t helper_ms(void) {
    struct timespec ts;
    if(clock_gettime(CLOCK_MONOTONIC,&ts)) return 0;
    return (uint64_t)ts.tv_sec*1000u+(uint64_t)ts.tv_nsec/1000000u;
}
/* Tells Settings what is playing where: immediately on a change, otherwise at most every 5 s. The write happens
 * on a private queue so a slow preferences daemon never stalls packet draining. */
static void publish_status(NSString *state,NSString *reason,BOOL force) {
    uint64_t now=helper_ms();
    reason=reason?:@"";
    BOOL changed=![state isEqualToString:g_status_state] || ![reason isEqualToString:g_status_reason];
    if(!force && !changed && now-g_status_written_ms<5000u) return;
    g_status_state=state;g_status_reason=reason;g_status_written_ms=now;
    AVAudioSession *session=[AVAudioSession sharedInstance];
    NSMutableArray *outputs=[NSMutableArray array];
    for(AVAudioSessionPortDescription *port in session.currentRoute.outputs)
        [outputs addObject:@{@"name":port.portName?:@"",@"type":port.portType?:@"",@"uid":port.UID?:@""}];
    /* v8.9.3: the route's output volume (0..1). The 21:05 log showed 0% while "playing", which is silent. */
    NSDictionary *status=@{@"version":@1,@"state":state,@"reason":reason,
        @"mode":@(btps_v89_mode_name(g_output_mode)),@"outputs":outputs,@"volume":@(session.outputVolume),
        @"time":@([[NSDate date] timeIntervalSince1970]),@"pid":@(getpid())};
    if(!g_status_queue) g_status_queue=dispatch_queue_create("com.parv.btphonosink.helper.status",DISPATCH_QUEUE_SERIAL);
    dispatch_async(g_status_queue,^{
        CFPreferencesSetAppValue(CFSTR(BTPS_KEY_V89_HELPER),(__bridge CFPropertyListRef)status,CFSTR(BTPS_PREFS_DOMAIN));
        (void)CFPreferencesAppSynchronize(CFSTR(BTPS_PREFS_DOMAIN));
    });
}
static void log_route(AVAudioSession *session,const char *stage,unsigned rate,BTPSV88Shared *s) {
    NSString *device=nil;
    int verdict=route_verdict(session,&device);
    btps_v88_event(s,1,(BTPSV88Event){BTPS_V881_ROUTE,
        (uint32_t)(session.outputVolume*100.0f+0.5f),rate,verdict?-102:0});
    for(AVAudioSessionPortDescription *port in session.currentRoute.outputs)
        hlog(stdout,"V889_AUDIO_ROUTE stage=%s mode=%s type=%s name=%s rate=%u volume=%.3f route_ok=%d\n",
                stage,btps_v89_mode_name(g_output_mode),port.portType.UTF8String,port.portName.UTF8String,
                rate,session.outputVolume,!verdict);
    if(!session.currentRoute.outputs.count)
        hlog(stdout,"V889_AUDIO_ROUTE stage=%s mode=%s outputs=0 route_ok=0\n",stage,btps_v89_mode_name(g_output_mode));
    if(verdict)
        hlog(stdout,"V889_ROUTE_REFUSED stage=%s mode=%s reason=%s device=%s\n",stage,
                btps_v89_mode_name(g_output_mode),btps_v89_route_reason(verdict),(device?:@"-").UTF8String);
    fflush(stdout);
}
/* A refused route is reported once per distinct reason/device, not on every retry. */
static int g_last_refusal=-1;
static NSString *g_last_refusal_device;
static void note_refusal(AVAudioSession *session,const char *stage,unsigned rate,BTPSV88Shared *s,
                         int verdict,NSString *device) {
    NSString *name=device?:@"";
    BOOL repeat=verdict==g_last_refusal && [name isEqualToString:g_last_refusal_device?:@""];
    g_last_refusal=verdict;g_last_refusal_device=name;
    NSString *why=[NSString stringWithUTF8String:btps_v89_route_reason(verdict)];
    publish_status(@"waiting",name.length?[NSString stringWithFormat:@"%@: %@",why,name]:why,NO);
    if(repeat) return;
    log_route(session,stage,rate,s);
    btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,rate,-102});
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
        hlog(stderr,"V881_AUDIO_FAIL stage=%s domain=%s code=%ld error=%s\n",stage,
            (error.domain?:@"unknown").UTF8String,(long)error.code,
            (error.localizedDescription?:@"unknown").UTF8String);
        [session setActive:NO error:NULL];
        btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,rate,-100});return -1;
    }
    /* Allow a bounded hardware-route transition on this helper worker only. */
    for(unsigned i=0;i<20 && !speaker_selected(session);i++) usleep(10000);
    log_route(session,"configured",rate,s);
    if(!speaker_selected(session)) {
        hlog(stderr,"V881_AUDIO_FAIL stage=route_check expected=built_in_speaker\n");
        [session setActive:NO error:NULL];
        btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,rate,-102});return -1;
    }
    return 0;
}
/* v8.9 headphones / any device. The Playback category lets iOS use wired, USB, Bluetooth and AirPlay outputs -
 * whatever is picked in Control Center - so no Bluetooth or AirPlay category option is needed or used. The route
 * is checked BEFORE activation, so iOS never starts output on a refused device such as the sending PC, and again
 * after activation. Returns -2 when the route is refused (the caller retries slowly), -1 on other failures. */
static int configure_external(unsigned rate,BTPSV88Shared *s) {
    AVAudioSession *session=[AVAudioSession sharedInstance];NSError *error=nil;NSString *device=nil;
    const char *stage="category";
    BOOL ok=[session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:0 error:&error];
    if(ok) {
        int verdict=route_verdict(session,&device);
        if(verdict) {note_refusal(session,"candidate",rate,s,verdict,device);return -2;}
        stage="activate";ok=[session setActive:YES error:&error];
    }
    if(!ok) {
        hlog(stderr,"V889_AUDIO_FAIL stage=%s domain=%s code=%ld error=%s\n",stage,
            (error.domain?:@"unknown").UTF8String,(long)error.code,
            (error.localizedDescription?:@"unknown").UTF8String);
        [session setActive:NO error:NULL];
        btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,rate,-100});return -1;
    }
    /* Allow a bounded hardware-route transition on this helper worker only. */
    for(unsigned i=0;i<20 && route_verdict(session,NULL);i++) usleep(10000);
    int verdict=route_verdict(session,&device);
    if(verdict) {
        [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:NULL];
        note_refusal(session,"configured",rate,s,verdict,device);return -2;
    }
    log_route(session,"configured",rate,s);
    return 0;
}
static int configure_output(unsigned rate,BTPSV88Shared *s) {
    return g_output_mode==BTPS_V89_MODE_SPEAKER?configure_speaker(rate,s):configure_external(rate,s);
}
static int start_output(Output *o,unsigned rate,BTPSV88Shared *s) {
    AVAudioSession *session=[AVAudioSession sharedInstance];
    int configured=configure_output(rate,s);
    if(configured) return configured;
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
    if(!e && route_verdict(session,NULL)) e=-102;
    if(!e) {
        __atomic_store_n(&o->stopping,0,__ATOMIC_RELEASE);
        e=AudioQueueStart(o->queue,NULL);
    }
    btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,rate,e});
    if(e) {stop_output(o,s,"start_error");[session setActive:NO error:NULL];return -1;}
    o->rate=rate;g_last_refusal=-1;
    log_route(session,"started",rate,s);
    publish_status(@"playing",@"",YES);
    return 0;
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
    int route_ok=!route_verdict([AVAudioSession sharedInstance],NULL);
    hlog(stdout,"V881_PCM samples=%u nonzero=%u peak=%u\n",level->samples,level->nonzero,level->peak);
    hlog(stdout,"V881_RENDER callbacks=%llu pcm_frames=%llu nonzero_samples=%llu silence_frames=%llu queued_frames=%u dropped_frames=%llu queue_running=%u query_status=%d route_ok=%d mode=%s\n",
        (unsigned long long)callbacks,(unsigned long long)submitted,(unsigned long long)nonzero,
        (unsigned long long)silence,queued,(unsigned long long)o->dropped,(unsigned)running,(int)status,route_ok,
        btps_v89_mode_name(g_output_mode));
    fflush(stdout);
    if(o->queue) publish_status(route_ok?@"playing":@"waiting",route_ok?@"":@"output route changed",NO);
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
static void report_health(Output *o,BTPSV88Shared *s,uint64_t generation) {
    UInt32 running=0,size=sizeof running;
    OSStatus status=o->queue?AudioQueueGetProperty(o->queue,kAudioQueueProperty_IsRunning,&running,&size):-1;
    int playing=(generation&1u) && !status && running &&
        !__atomic_load_n(&o->stopping,__ATOMIC_ACQUIRE) &&
        !__atomic_load_n(&o->error,__ATOMIC_RELAXED) &&
        !route_verdict([AVAudioSession sharedInstance],NULL);
    btps_v88_event(s,1,(BTPSV88Event){BTPS_V882_HEALTH,(uint32_t)generation,
        (uint32_t)__atomic_load_n(&o->render_tick,__ATOMIC_RELAXED),playing?1:0});
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
    load_output_settings();g_last_refusal=-1;
    if(g_output_notify<0 && notify_register_check(BTPS_NOTIFY_V89_OUTPUT,&g_output_notify)!=NOTIFY_STATUS_OK)
        g_output_notify=-1;
    if(g_output_notify>=0) {int primed=0;(void)notify_check(g_output_notify,&primed);} /* first check is always "changed" */
    publish_status(@"starting",@"",YES);
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
            if(changed) {
                interrupted=changed==1;
                hlog(stdout,"V882_INTERRUPTION type=%s\n",interrupted?"began":"ended");fflush(stdout);
                stop_output(o,s,interrupted?"interruption_began":"interruption_ended");btps_v88_decoder_reset(&decoder);
            }
            int settings_changed=0;
            if(g_output_notify>=0 && notify_check(g_output_notify,&settings_changed)==NOTIFY_STATUS_OK && settings_changed) {
                load_output_settings();g_last_refusal=-1;
                if(o->queue) {stop_output(o,s,"output_settings_changed");btps_v88_decoder_reset(&decoder);}
                retry=0;
            }
            if(__atomic_exchange_n(&route_changed,0,__ATOMIC_ACQUIRE)) {
                AVAudioSession *session=[AVAudioSession sharedInstance];
                if(o->queue) {
                    log_route(session,"changed",o->rate,s);
                    if(route_verdict(session,NULL)) {
                        stop_output(o,s,"route_changed");btps_v88_decoder_reset(&decoder);retry=20;
                    } else publish_status(@"playing",@"",YES);
                } else retry=0; /* a device was connected or picked: try it with the next packet */
            }
            uint64_t current=__atomic_load_n(&s->generation,__ATOMIC_ACQUIRE);
            if(current!=generation) {
                stop_output(o,s,"stream_generation_changed");btps_v88_decoder_reset(&decoder);generation=current;retry=0;
                if(!(current&1u)) publish_status(@"idle",@"PC paused or stopped the stream",NO);
            }
            int32_t audio_error=__atomic_exchange_n(&o->error,0,__ATOMIC_RELAXED);
            if(audio_error) {
                btps_v88_event(s,1,(BTPSV88Event){BTPS_V88_AUDIO,0,o->rate,audio_error});
                stop_output(o,s,"enqueue_error");retry=100;
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
                    if(o->queue && o->rate!=rate) stop_output(o,s,"sample_rate_changed");
                    if(!o->queue && !retry) {int started=start_output(o,rate,s);if(started) retry=started==-2?400:100;}
                    if(o->queue) write_pcm(o,pcm,samples);
                }
                /* If bounded drain left packets, poll again instead of losing a wakeup. */
                if(__atomic_load_n(&s->media.read,__ATOMIC_RELAXED)==
                   __atomic_load_n(&s->media.write,__ATOMIC_ACQUIRE)) doorbell=signal;
            }
            idle=processed?0:idle+1;
            if(idle==400) {stop_output(o,s,"media_idle");btps_v88_decoder_reset(&decoder);}
            diagnostic_ticks++;
            if(diagnostic_ticks%40u==0) report_health(o,s,generation);
            if(diagnostic_ticks%200u==0 && ((generation&1u) || level.samples))
                report_progress(o,&level,s);
        }
        usleep(5000); /* shared-memory doorbell polling, <=5ms nominal wake latency */
    }
    [[NSNotificationCenter defaultCenter] removeObserver:observer];
    [[NSNotificationCenter defaultCenter] removeObserver:route_observer];
    stop_output(o,s,"ipc_closed");pthread_mutex_destroy(&o->lock);free(o);
    publish_status(@"stopped",@"Bluetooth speaker session ended",YES);
    munmap(s,sizeof *s);close(file);
}
int BTPSV88StreamMain(void) {
    hlog(stdout,"V889_HELPER build=v8.9.3-output-select (v8.8.2 idle guard retained)\n");fflush(stdout);
    int (*activate)(const char *,int **,size_t *)=dlsym(RTLD_DEFAULT,"launch_activate_socket");
    int *fds=NULL;size_t count=0;
    if(!activate || activate("Stream",&fds,&count) || !count) {
        hlog(stderr,"V88_SERVICE socket activation unavailable; run via launchd\n");free(fds);return 2;
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
