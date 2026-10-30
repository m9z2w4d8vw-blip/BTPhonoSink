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
#import "../BTPSV75RTP.h"
#import "BTPSV76Decode.h"
#import "BTPSV88Stream.h"

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
/* PCM from decoded SBC; stereo, 44.1kHz 16-bit interleaved. */
static NSData *wav_from_sbc_pcm(const int16_t *pcm,size_t frames) {
    size_t nbytes=frames*2u*sizeof(int16_t);
    if(frames!=33024u || nbytes>UINT32_MAX-44u)return nil;
    NSMutableData *wav=[NSMutableData dataWithLength:44u+nbytes];
    uint8_t *w=wav.mutableBytes;
    memcpy(w,"RIFF",4);w32(w+4,(uint32_t)(36u+nbytes));memcpy(w+8,"WAVEfmt ",8);
    w32(w+16,16);w16(w+20,1);w16(w+22,2);w32(w+24,44100);
    w32(w+28,44100u*4u);w16(w+32,4);w16(w+34,16);
    memcpy(w+36,"data",4);w32(w+40,(uint32_t)nbytes);memcpy(w+44,pcm,nbytes);
    return wav;
}
static int play_decoded_sbc(NSData *wav) {
    NSError *err=nil;
    AVAudioSession *session=[AVAudioSession sharedInstance];
    if(![session setCategory:AVAudioSessionCategoryPlayback error:&err] ||
       ![session setActive:YES error:&err]) {
        fprintf(stderr,"AUDIO_FAIL stage=session error=%s\n",(err.localizedDescription?:@"unknown").UTF8String);
        return 1;
    }
    AVAudioPlayer *player=[[AVAudioPlayer alloc]initWithData:wav error:&err];
    if (player) player.volume = 1.0f;
    AVAudioSessionRouteDescription *route = session.currentRoute;
    for (AVAudioSessionPortDescription *output in route.outputs) {
        printf("SBC_AUDIO_ROUTE port=%s name=%s volume=%.3f\n",
               (output.portType ?: @"unknown").UTF8String,
               (output.portName ?: @"unknown").UTF8String,
               session.outputVolume);
    }
    fflush(stdout);
    if(!player || ![player prepareToPlay] || ![player play]) {
        fprintf(stderr,"AUDIO_FAIL stage=player error=%s\n",(err.localizedDescription?:@"start failed").UTF8String);
        [session setActive:NO error:NULL];return 2;
    }
    puts("SBC_AUDIO_STARTED source=decoded_sbc_440Hz stereo=1 rate=44100");fflush(stdout);
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:4.0];
    while(player.isPlaying && [deadline timeIntervalSinceNow]>0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    BOOL completed=!player.isPlaying;
    [player stop];
    [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:NULL];
    printf("SBC_AUDIO_%s API completion; confirm 440 Hz was actually heard\n",completed?"FINISHED":"TIMEOUT");
    fflush(stdout);
    return completed?0:3;
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
        if(argc==2 && strcmp(argv[1],"--stream-service")==0) return BTPSV88StreamMain();
        /* Existing CLI preserved: no args or optional 15..180 second timeout.
         * New --daemon mode expects a v2 frame from bluetoothd, never Settings. */
        int daemon_mode=argc>=2 && strcmp(argv[1],"--daemon")==0;
        int play_sbc_mode=argc>=2 && strcmp(argv[1],"--sbc-play")==0;
        int sbc_mode=play_sbc_mode || (argc>=2 && strcmp(argv[1],"--sbc")==0);
        int at=(daemon_mode||sbc_mode)?2:1;
        if(argc>at+1){fprintf(stderr,"usage: BTPSAudioHelper [--daemon|--sbc|--sbc-play] [timeout_seconds: 15..180]\n");return 2;}
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
        printf("BTPS_HELPER_MODE=%s\n",play_sbc_mode?"SBC_PLAY_DECODE_AND_OUTPUT":(sbc_mode?"SBC_VERIFY_ONLY_NO_SOUND":(daemon_mode?"PCM_DAEMON":"PCM_SETTINGS")));
        printf("BTPS_%s_READY pid=%ld port=%d token=%06u timeout=%ds\n",
               play_sbc_mode?"V76_SBC_PLAY":(sbc_mode?"V75_SBC":(daemon_mode?"V74_DAEMON":"V74_SETTINGS")),(long)getpid(),BTPS_IPC_PORT,token,seconds);
        printf("On iPhone: Settings > Speaka > Debug log > %s; enter token %06u.\n",
               sbc_mode?"Send SBC from bluetoothd (v7.5/7.6)":(daemon_mode?"Send PCM from bluetoothd (v7.4)":"Send PCM to separate helper (v7.3)"),token);
        fflush(stdout);
        fd_set set;FD_ZERO(&set);FD_SET(listener,&set);struct timeval timer={seconds,0};
        int ready=select(listener+1,&set,NULL,NULL,&timer);
        if(ready<=0){printf("IPC_TIMEOUT no client (or select failed)\n");close(listener);return 6;}
        int fd=accept(listener,NULL,NULL);close(listener);
        if(fd<0){perror("accept");return 2;}
        int nosigpipe=1;setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&nosigpipe,sizeof(nosigpipe));
        struct timeval t={5,0};setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&t,sizeof(t));
        if(sbc_mode) {
            uint8_t header75[BTPS_IPC_V75_HEADER_SIZE]={0};
            uint8_t *blob=(uint8_t *)malloc(BTPS_IPC_V75_FIXTURE_SIZE);
            uint8_t *frames=(uint8_t *)malloc(BTPS_V75_SBC_BYTES_LIMIT);
            if(!blob||!frames){reply(fd,"NO_MEM");free(blob);free(frames);close(fd);return 2;}
            size_t decoded_size=0;unsigned packet_count=0,frame_count=0;
            int ok=recv_exact(fd,header75,sizeof header75)==0 &&
                recv_exact(fd,blob,BTPS_IPC_V75_FIXTURE_SIZE)==0 &&
                btps_ipc_validate_sbc_v75(header75,token,blob,BTPS_IPC_V75_FIXTURE_SIZE) &&
                btps_v75_extract_sbc(blob,BTPS_IPC_V75_FIXTURE_SIZE,frames,BTPS_V75_SBC_BYTES_LIMIT,
                                     &decoded_size,&packet_count,&frame_count)==0;
            if(!ok) {
                printf("SBC_REJECT malformed token/CRC/RTP/sequence/SBC frame boundaries\n");fflush(stdout);
                reply(fd,"SBC_REJECT");free(blob);free(frames);close(fd);return 7;
            }
            printf("SBC_RECEIVED source=bluetoothd bytes=%u CRC32=verified packets=%u frames=%u sampleRate=44100 channels=2 extractedSBC=%zu\n",
                   BTPS_IPC_V75_FIXTURE_SIZE,packet_count,frame_count,decoded_size);
            fflush(stdout);
            /* Only a copy of the pre-generated SBC fixture is saved. No live RF capture.
             * A timestamp/PID suffix avoids clobbering an earlier test. */
            NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:
                 [NSString stringWithFormat:@"Documents/Speaka-v75-%ld-%lld.sbc",(long)getpid(),(long long)[[NSDate date] timeIntervalSince1970]]];
            NSString *dir=[path stringByDeletingLastPathComponent];
            NSError *err=nil;
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&err];
            BOOL saved=[[NSData dataWithBytes:frames length:decoded_size] writeToFile:path options:NSDataWritingAtomic error:&err];
            if(saved)printf("SBC_CAPTURE_SAVED path=%s bytes=%zu (compressed SBC; playback occurs only in --sbc-play mode)\n",path.UTF8String,decoded_size);
            else printf("SBC_CAPTURE_SAVE_FAIL %s (transport validation still passed)\n",(err.localizedDescription?:@"unknown").UTF8String);
            /* IMPORTANT: this ACK proves only transport/framing. It is NOT a decode or playback ACK.
             * The daemon's diag.v75_sbc PASS must never be interpreted as audio playback success. */
            reply(fd,"SBC_VERIFIED");close(fd);free(blob);
            if(play_sbc_mode) {
                const size_t slot_count=2u*33024u;
                int16_t *pcm=(int16_t *)calloc(slot_count,sizeof(int16_t));
                size_t fcount=0,nsamples=0;unsigned rate=0,channels=0;
                int dr=pcm ? btps_v76_decode_sbc(frames,decoded_size,pcm,slot_count,&fcount,&nsamples,&rate,&channels) : -20;
                free(frames);
                if(dr!=0) {
                    printf("SBC_DECODE_FAIL code=%d frames=%zu samples_per_channel=%zu\n",dr,fcount,nsamples);
                    puts("BTPS_V76_RESULT ipc=PASS rtp=PASS sbc_frames=PASS decode=FAIL audio_api=NOT_STARTED live_bluetooth=NO");
                    fflush(stdout);free(pcm);return 8;
                }
                size_t clipped=0;long double sumsq=0;
                for(size_t k=0;k<nsamples*2u;k++){
                    int a=pcm[k]<0?-(int)pcm[k]:(int)pcm[k];
                    if(a>=32000)clipped++;
                    sumsq+=(long double)pcm[k]*(long double)pcm[k];
                }
                double rms=sqrt((double)(sumsq/(nsamples*2u)))/32768.0;
                double clip_rate=(double)clipped/(double)(nsamples*2u);
                printf("SBC_DECODE_PASS frames=%zu samples_per_channel=%zu rate=%u channels=%u rms=%.6f clipped=%.4f%%\n",
                       fcount,nsamples,rate,channels,rms,clip_rate*100.0);
                fflush(stdout);
                if(clip_rate>0.01 || rms<0.01 || rms>0.4) {
                    puts("SBC_FIDELITY_FAIL unexpected output levels; playback skipped");
                    puts("BTPS_V76_RESULT ipc=PASS rtp=PASS sbc_frames=PASS decode=PASS fidelity=FAIL audio_api=NOT_STARTED live_bluetooth=NO");
                    fflush(stdout);free(pcm);return 9;
                }
                /* Preserve the unmodified decoded WAV for independent comparison with FFmpeg. */
                NSData *wav=wav_from_sbc_pcm(pcm,nsamples);
                if(!wav){free(pcm);puts("SBC_WAV_FAIL allocation");return 10;}
                NSString *wav_path=[dir stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"Speaka-v76-%ld-%lld.wav",(long)getpid(),(long long)[[NSDate date] timeIntervalSince1970]]];
                NSError *wav_error=nil;
                BOOL saved_pcm=[wav writeToFile:wav_path options:NSDataWritingAtomic error:&wav_error];
                if(saved_pcm)printf("SBC_DECODED_WAV_SAVED path=%s bytes=%zu\n",wav_path.UTF8String,(size_t)wav.length);
                else printf("SBC_WAV_SAVE_FAIL error=%s\n",(wav_error.localizedDescription?:@"unknown").UTF8String);
                fflush(stdout);
                /* The source fixture is low level (roughly -24 dBFS RMS). Boost only
                 * the PLAYBACK copy, never the saved/reference WAV or decoder output.
                 * Capped by peak level and 4x gain to avoid clipping / loud surprises. */
                int peak=0;
                for(size_t k=0;k<nsamples*2u;k++){
                    int v=(int)pcm[k];if(v<0)v=-v;if(v>peak)peak=v;
                }
                double gain = peak>0 ? fmin(4.0,14000.0/(double)peak) : 1.0;
                for(size_t k=0;k<nsamples*2u;k++){
                    pcm[k]=(int16_t)lrint((double)pcm[k]*gain);
                }
                NSData *playbackWav=wav_from_sbc_pcm(pcm,nsamples);
                free(pcm);
                printf("SBC_AUDIO_PREP original_peak=%d playback_gain=%.3f target_max_peak=14000 saved_reference_unmodified=YES\n",peak,gain);
                fflush(stdout);
                if(!playbackWav){puts("SBC_PLAYBACK_WAV_FAIL allocation");return 10;}
                int playback=play_decoded_sbc(playbackWav);
                printf("BTPS_V76_RESULT ipc=PASS rtp=PASS sbc_frames=PASS decode=PASS audio_api=%s live_bluetooth=NO\n",
                    playback==0?"FINISHED":"FAILED");fflush(stdout);
                return playback==0?0:11;
            }
            free(frames);
            printf("BTPS_V75_RESULT ipc=PASS rtp=PASS sbc_frames=PASS pcm_decode=NOT_TESTED live_bluetooth=NO\n");
            fflush(stdout);
            return 0;
        }
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
