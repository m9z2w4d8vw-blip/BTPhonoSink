/* BTPSAudioHelper: separate process playback test, invoked manually over SSH.
 * Receives one bounded, CRC-verified PCM message over loopback, attempts AVAudioPlayer playback,
 * prints observable status. DOES NOT modify bluetoothd, connect to Bluetooth, or daemonize.
 */
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <arpa/inet.h>
#import <errno.h>
#import <math.h>
#import <netinet/in.h>
#import <stdint.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/select.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>
#import "../BTPSIPCProtocol.h"

static void w16(uint8_t *p,uint16_t v){p[0]=(uint8_t)v;p[1]=(uint8_t)(v>>8);}
static void w32(uint8_t *p,uint32_t v){for(int i=0;i<4;i++)p[i]=(uint8_t)(v>>(i*8));}
static NSData *wav_from_pcm(const uint8_t *pcm) {
    NSMutableData *wav=[NSMutableData dataWithLength:44u+BTPS_IPC_PCM_BYTES];
    uint8_t *w=wav.mutableBytes;
    memcpy(w,"RIFF",4);w32(w+4,36u+BTPS_IPC_PCM_BYTES);memcpy(w+8,"WAVEfmt ",8);
    w32(w+16,16);w16(w+20,1);w16(w+22,1);w32(w+24,BTPS_IPC_SAMPLERATE);
    w32(w+28,BTPS_IPC_SAMPLERATE*2u);w16(w+32,2);w16(w+34,16);
    memcpy(w+36,"data",4);w32(w+40,BTPS_IPC_PCM_BYTES);
    memcpy(w+44,pcm,BTPS_IPC_PCM_BYTES);
    return wav;
}
static int recv_exact(int fd,void *buffer,size_t n) {
    uint8_t *p=buffer;
    while(n) {ssize_t r=recv(fd,p,n,0);if(r<=0) return -1;p+=(size_t)r;n-=(size_t)r;}
    return 0;
}
static void reply(int fd,const char *code){(void)send(fd,code,strlen(code),0);}
static int play_pcm(const uint8_t *pcm, int daemon_mode) {
    NSError *err=nil;
    AVAudioSession *session=[AVAudioSession sharedInstance];
    if (![session setCategory:AVAudioSessionCategoryPlayback error:&err] ||
        ![session setActive:YES error:&err]) {
        fprintf(stderr,"AUDIO_FAIL stage=session error=%s\n",(err.localizedDescription?:@"unknown").UTF8String);
        return 3;
    }
    AVAudioPlayer *player=[[AVAudioPlayer alloc] initWithData:wav_from_pcm(pcm) error:&err];
    if (!player || ![player prepareToPlay] || ![player play]) {
        fprintf(stderr,"AUDIO_FAIL stage=player error=%s\n",(err.localizedDescription?:@"play returned false").UTF8String);
        [session setActive:NO error:NULL];
        return 4;
    }
    fprintf(stdout,"AUDIO_STARTED process=BTPSAudioHelper pid=%ld duration=0.8s frequency=%dHz source=%s\n",(long)getpid(),daemon_mode?880:660,daemon_mode?"bluetoothd-request":"Settings-request");
    fflush(stdout);
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3.0];
    while(player.isPlaying && [deadline timeIntervalSinceNow]>0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    BOOL finished=!player.isPlaying;
    [player stop];
    [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:NULL];
    fprintf(stdout,"AUDIO_%s API finished; human must confirm sound was heard\n",finished?"FINISHED":"TIMEOUT");
    return finished?0:5;
}
int main(int argc,const char **argv) {
    @autoreleasepool {
        /* Existing CLI preserved: no args or optional 15..180 second timeout.
         * New --daemon mode expects a v2 frame from bluetoothd, never Settings. */
        int daemon_mode=argc>=2 && strcmp(argv[1],"--daemon")==0;
        int at=daemon_mode?2:1;
        if(argc>at+1){fprintf(stderr,"usage: BTPSAudioHelper [--daemon] [timeout_seconds: 15..180]\n");return 2;}
        int seconds=120;
        if(argc==at+1){char *end=NULL;long val=strtol(argv[at],&end,10);
            if(!end||*end||val<15||val>180){fprintf(stderr,"timeout must be 15..180 seconds\n");return 2;} seconds=(int)val;}
        uint32_t token=100000u+arc4random_uniform(900000u);
        int listener=socket(AF_INET,SOCK_STREAM,0);
        if(listener<0){perror("socket");return 2;}
        struct sockaddr_in address={0};address.sin_family=AF_INET;
        address.sin_port=htons(BTPS_IPC_PORT);address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
        int reuse=1;setsockopt(listener,SOL_SOCKET,SO_REUSEADDR,&reuse,sizeof(reuse));
        if(bind(listener,(struct sockaddr*)&address,sizeof(address))!=0 || listen(listener,1)!=0){
            perror("bind/listen loopback");close(listener);return 2;}
        printf("BTPS_V74_%s_READY pid=%ld port=%d token=%06u timeout=%ds\n",
               daemon_mode?"DAEMON":"SETTINGS",(long)getpid(),BTPS_IPC_PORT,token,seconds);
        printf("On iPhone: Settings > BTPhonoSink > Debug log > %s; enter token %06u.\n",
               daemon_mode?"Send PCM from bluetoothd (v7.4)":"Send PCM to separate helper (v7.3)",token);
        fflush(stdout);
        fd_set set;FD_ZERO(&set);FD_SET(listener,&set);struct timeval timer={seconds,0};
        int ready=select(listener+1,&set,NULL,NULL,&timer);
        if(ready<=0){printf("IPC_TIMEOUT no client (or select failed)\n");close(listener);return 6;}
        int fd=accept(listener,NULL,NULL);close(listener);
        if(fd<0){perror("accept");return 2;}
        int nosigpipe=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&nosigpipe,sizeof(nosigpipe));
        struct timeval t={5,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&t,sizeof(t));
        uint8_t header[BTPS_IPC_V74_HEADER_SIZE]={0};
        uint8_t *pcm=(uint8_t*)malloc(BTPS_IPC_PCM_BYTES);
        if(!pcm){reply(fd,"NO_MEM");close(fd);return 2;}
        size_t header_size=daemon_mode?BTPS_IPC_V74_HEADER_SIZE:BTPS_IPC_HEADER_SIZE;
        if(recv_exact(fd,header,header_size)!=0 || recv_exact(fd,pcm,BTPS_IPC_PCM_BYTES)!=0 ||
           !(daemon_mode?btps_ipc_validate_daemon_v74(header,token,pcm,BTPS_IPC_PCM_BYTES)
                         :btps_ipc_validate(header,token,pcm,BTPS_IPC_PCM_BYTES))){
            printf("IPC_REJECT malformed frame / CRC mismatch / incorrect token / sender mode mismatch\n");fflush(stdout);
            reply(fd,"REJECT");free(pcm);close(fd);return 7;}
        printf("IPC_RECEIVED mode=%s bytes=%u CRC32=verified sampleRate=44100 channels=1 duration=0.8s\n",
               daemon_mode?"bluetoothd":"Settings",BTPS_IPC_PCM_BYTES);
        fflush(stdout);
        reply(fd,"RECEIVED");close(fd);
        int playback=play_pcm(pcm,daemon_mode);free(pcm);
        printf("BTPS_V74_TEST_RESULT source=%s ipc=PASS audio_api=%s\n",
               daemon_mode?"bluetoothd":"Settings",playback==0?"FINISHED":"FAILED");
        fflush(stdout);
        return playback;
    }
}
