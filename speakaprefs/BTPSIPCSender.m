#import "BTPSIPCSender.h"
#import "../BTPSIPCProtocol.h"
#import <arpa/inet.h>
#import <math.h>
#import <netinet/in.h>
#import <stdint.h>
#import <sys/socket.h>
#import <sys/time.h>
#import <unistd.h>
#import <string.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
static void put16(uint8_t *p,int16_t n){p[0]=(uint8_t)n;p[1]=(uint8_t)((uint16_t)n>>8);}
static int write_exact(int fd,const uint8_t *data,size_t n) {
    while(n){ssize_t r=send(fd,data,n,0);if(r<=0)return 0;data+=(size_t)r;n-=(size_t)r;}
    return 1;
}
@implementation BTPSIPCSender
+ (void)sendTestPCMWithToken:(uint32_t)token completion:(void (^)(NSString *))completion {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        NSString *result;
        if(token<100000u || token>999999u){result=@"IPC FAIL: token must be six digits";goto finished;}
        {
            NSMutableData *pcm=[NSMutableData dataWithLength:BTPS_IPC_PCM_BYTES];
            uint8_t *buf=pcm.mutableBytes;
            for(uint32_t i=0;i<BTPS_IPC_FRAMES;i++) {
                double fade=fmin(1.0,fmin((double)i/900.0,(double)(BTPS_IPC_FRAMES-1u-i)/900.0));
                int16_t sample=(int16_t)lrint(sin(2.0*M_PI*660.0*i/(double)BTPS_IPC_SAMPLERATE)*12000.0*fade);
                put16(buf+i*2u,sample);
            }
            uint8_t head[BTPS_IPC_HEADER_SIZE];
            btps_ipc_encode(head,token,btps_ipc_crc32(buf,pcm.length));
            int fd=socket(AF_INET,SOCK_STREAM,0);
            if(fd<0){result=@"IPC FAIL: socket() unavailable in Preferences.app";goto finished;}
            int nosigpipe=1;
            setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&nosigpipe,sizeof(nosigpipe));
            struct timeval timeout={5,0};
            setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof(timeout));
            setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof(timeout));
            struct sockaddr_in sa={0};sa.sin_family=AF_INET;
            sa.sin_port=htons(BTPS_IPC_PORT);sa.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
            if(connect(fd,(const struct sockaddr *)&sa,sizeof(sa))!=0){
                result=@"IPC FAIL: cannot connect to helper. Start it over SSH first; keep that SSH session open.";
            } else if(!write_exact(fd,head,sizeof(head)) || !write_exact(fd,buf,pcm.length)) {
                result=@"IPC FAIL: sending PCM to the helper failed.";
            } else {
                char ack[32]={0};ssize_t got=recv(fd,ack,sizeof(ack)-1,0);
                if(got>0 && strncmp(ack,"RECEIVED",8)==0)
                    result=@"IPC PASS: 70,560 PCM bytes arrived at the separate helper and passed CRC validation. Check SSH for AUDIO_FINISHED and confirm whether you heard 660 Hz.";
                else
                    result=[NSString stringWithFormat:@"IPC FAIL: helper rejected data or timed out (reply: %s)",got>0?ack:"none"];
            }
            close(fd);
        }
    finished:
        dispatch_async(dispatch_get_main_queue(), ^{if(completion)completion(result);});
    });
}
@end
