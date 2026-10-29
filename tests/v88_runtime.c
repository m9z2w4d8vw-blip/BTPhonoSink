#include "BTPSV88Shared.h"
#include "BTPSV88Control.h"
#include "btpsaudiohelper/BTPSV88Decode.h"
#include "btpsaudiohelper/BTPSV76Decode.h"
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

static void queues(void) {
    BTPSV88Shared *s=mmap(NULL,sizeof *s,PROT_READ|PROT_WRITE,MAP_ANON|MAP_SHARED,-1,0);
    assert(s!=MAP_FAILED);btps_v88_init(s,123,456);
    BTPSV88Packet p={0},out;
    p.length=BTPS_V88_PAYLOAD;p.generation=3;
    for(unsigned i=0;i<100;i++) {p.timestamp=i;memset(p.data,i,sizeof p.data);assert(btps_v88_enqueue(s,&p));}
    assert(s->media.dropped==68);
    for(unsigned i=68;i<100;i++) {
        assert(btps_v88_dequeue(s,&out));assert(out.timestamp==i);
        for(unsigned j=0;j<out.length;j++) assert(out.data[j]==(uint8_t)i);
    }
    assert(!btps_v88_dequeue(s,&out));
    /* A consumer that already claimed slot 0 owns its bytes until release.
       Force producer wraparound and verify it never touches that slot. */
    btps_v88_init(s,123,456);
    for(unsigned i=0;i<32;i++) {p.timestamp=i;assert(btps_v88_enqueue(s,&p));}
    __atomic_store_n(&s->media.read,1,__ATOMIC_RELAXED);
    BTPSV88Packet held=s->packets[0].value;
    for(unsigned i=0;i<64;i++) (void)btps_v88_enqueue(s,&p);
    assert(!memcmp(&held,&s->packets[0].value,sizeof held));
    __atomic_store_n(&s->packets[0].turn,32,__ATOMIC_RELEASE);
    assert(btps_v88_enqueue(s,&p));
    btps_v88_init(s,123,456);
    pid_t child=fork();assert(child>=0);
    if(!child) {
        unsigned seen=0,last=0;
        for(;;) {
            if(btps_v88_dequeue(s,&out)) {
                assert(out.length==BTPS_V88_PAYLOAD);
                assert(!seen || out.timestamp>last);last=out.timestamp;seen++;
                for(unsigned j=0;j<out.length;j++) assert(out.data[j]==(uint8_t)last);
            } else if(__atomic_load_n(&s->helper_heartbeat,__ATOMIC_ACQUIRE) &&
                      s->media.read==s->media.write) break;
        }
        assert(seen);_exit(0);
    }
    for(unsigned i=0;i<100000;i++) {
        p.timestamp=i;memset(p.data,(uint8_t)i,sizeof p.data);btps_v88_enqueue(s,&p);
    }
    __atomic_store_n(&s->helper_heartbeat,1,__ATOMIC_RELEASE);
    int status;assert(waitpid(child,&status,0)==child);assert(WIFEXITED(status) && WEXITSTATUS(status)==0);
    munmap(s,sizeof *s);puts("queue overflow, pinned reader, forked shared-memory stress: PASS");
}
static void control(void) {
    BTPSV88Control c={0};c.local_seid=7;c.remote_seid=52;
    uint8_t start[]={0x30,7,0x1c},accept[]={0x32,7},wrong[]={0x42,7},reject[]={0x33,7,0x31};
    assert(btps_v88_signal(&c,0,0xc0b,start,3)==-1);
    assert(btps_v88_signal(&c,1,0xc0b,wrong,2)==-1);
    assert(btps_v88_signal(&c,1,0x60a,accept,2)==-1);
    assert(btps_v88_signal(&c,1,0xc0b,accept,2)==1);
    assert(btps_v88_signal(&c,1,0xc0b,accept,2)==-1);
    assert(btps_v88_signal(&c,0,0xc0b,start,3)==-1);
    assert(btps_v88_signal(&c,1,0xc0b,reject,3)==-1);
    assert(btps_v88_signal(&c,1,0xc0b,accept,2)==-1);
    uint8_t suspend[]={0x50,9,0xd0};assert(btps_v88_signal(&c,1,0xc0b,suspend,3)==0);
    start[2]=0xd0;assert(btps_v88_signal(&c,1,0xc0b,start,3)==-1);
    assert(btps_v88_signal(&c,0,0xc0b,accept,2)==1);
    /* Works beyond the old 128-line log sampling cutoff, including label wrap. */
    for(unsigned i=0;i<500;i++) {
        start[0]=(i&15)<<4;accept[0]=start[0]|2;
        btps_v88_signal(&c,1,0xc0b,start,3);
        assert(btps_v88_signal(&c,0,0xc0b,accept,2)==1);
    }
    puts("START correlation, reject, direction, CID, suspend, 500 restarts: PASS");
}
static void decode(const char *path) {
    FILE *f=fopen(path,"rb");assert(f);uint8_t src[20000];size_t size=fread(src,1,sizeof src,f);fclose(f);
    int16_t *reference=calloc(33024*2,2),*actual=calloc(33024*2,2);assert(reference && actual);
    size_t total_frames=0,total_samples=0;unsigned rate=0,channels=0;
    assert(!btps_v76_decode_sbc(src,size,reference,33024*2,&total_frames,&total_samples,&rate,&channels));
    BTPSV88Decoder d;btps_v88_decoder_reset(&d);BTPSV88Packet p={0};p.generation=3;
    size_t offset=0,written=0,frames=0;
    int16_t pcm[BTPS_V88_PCM_SAMPLES];unsigned nf,ns,hz;
    while(offset<size) {
        p.length=1;p.data[0]=0;
        for(unsigned i=0;i<7 && offset<size;i++) {
            struct sbc_frame frame;assert(!sbc_probe(src+offset,&frame));unsigned n=sbc_get_frame_size(&frame);
            assert(p.length+n<=BTPS_V88_PAYLOAD);memcpy(p.data+p.length,src+offset,n);
            p.length+=n;p.data[0]++;offset+=n;
        }
        assert(!btps_v88_decode(&d,&p,pcm,BTPS_V88_PCM_SAMPLES,&nf,&ns,&hz));
        assert(hz==44100);memcpy(actual+written*2,pcm,ns*4);written+=ns;frames+=nf;p.sequence++;
    }
    assert(frames==258 && written==33024);assert(!memcmp(actual,reference,written*4));
    /* Fragmented frame, sequence gap, truncated frame and bad CRC. */
    struct sbc_frame first;assert(!sbc_probe(src,&first));unsigned len=sbc_get_frame_size(&first);
    btps_v88_decoder_reset(&d);p.sequence=65535;p.data[0]=0xc0;p.length=1+len/2;
    memcpy(p.data+1,src,len/2);
    assert(btps_v88_decode(&d,&p,pcm,BTPS_V88_PCM_SAMPLES,&nf,&ns,&hz)==1);
    p.sequence=0;p.data[0]=0xa0;p.length=1+len-len/2;memcpy(p.data+1,src+len/2,len-len/2);
    assert(!btps_v88_decode(&d,&p,pcm,BTPS_V88_PCM_SAMPLES,&nf,&ns,&hz));assert(nf==1);
    p.sequence=2;assert(btps_v88_decode(&d,&p,pcm,BTPS_V88_PCM_SAMPLES,&nf,&ns,&hz)<0);
    p.sequence++;p.length=len;p.data[0]=1;memcpy(p.data+1,src,len-1);
    assert(btps_v88_decode(&d,&p,pcm,BTPS_V88_PCM_SAMPLES,&nf,&ns,&hz)<0);
    p.sequence++;p.length=len+1;memcpy(p.data+1,src,len);p.data[4]^=0xff;
    assert(btps_v88_decode(&d,&p,pcm,BTPS_V88_PCM_SAMPLES,&nf,&ns,&hz)<0);
    /* Real encoded 48kHz stereo and mono, not a mutated 44.1kHz header. */
    sbc_t encoder;memset(&encoder,0,sizeof encoder);sbc_reset(&encoder);
    struct sbc_frame frame={.freq=SBC_FREQ_48K,.mode=SBC_MODE_STEREO,.bam=SBC_BAM_LOUDNESS,
                             .nblocks=16,.nsubbands=8,.bitpool=32};
    int16_t input[256];for(unsigned i=0;i<256;i++) input[i]=(i%32)*200-3000;
    for(unsigned mono=0;mono<2;mono++) {
        frame.mode=mono?SBC_MODE_MONO:SBC_MODE_STEREO;
        p.sequence++;p.generation+=2;p.data[0]=1;p.length=1+sbc_get_frame_size(&frame);
        assert(!sbc_encode(&encoder,input,2,input+1,2,&frame,p.data+1,p.length-1));
        assert(!btps_v88_decode(&d,&p,pcm,BTPS_V88_PCM_SAMPLES,&nf,&ns,&hz));
        assert(nf==1 && ns==128 && hz==48000);
        if(mono) for(unsigned i=0;i<ns;i++) assert(pcm[i*2]==pcm[i*2+1]);
    }
    /* Bounded malformed input corpus, including every payload-header bit. */
    unsigned seed=0x12345;
    for(unsigned i=0;i<10000;i++) {
        p.sequence++;p.length=1+i%BTPS_V88_PAYLOAD;
        for(unsigned j=0;j<p.length;j++) {seed=1664525u*seed+1013904223u;p.data[j]=seed>>24;}
        int r=btps_v88_decode(&d,&p,pcm,BTPS_V88_PCM_SAMPLES,&nf,&ns,&hz);
        assert(r || (nf<=15 && ns<=15*128));
    }
    free(reference);free(actual);puts("continuous reference PCM, fragments, gaps, CRC, 48k mono/stereo, malformed corpus: PASS");
}
int main(int argc,char **argv) {assert(argc==2);queues();control();decode(argv[1]);return 0;}
