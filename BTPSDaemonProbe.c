/* Speaka v7.4: explicit one-shot bluetoothd -> BTPSAudioHelper test.
 *
 * A Settings request is delivered by a Darwin notification. The notify
 * callback runs on an isolated serial dispatch queue, NEVER a Bluetooth hook
 * or the daemon's event loop. It reads one short request from a shared
 * preferences key and writes at most 70,588 bytes to the loopback-only helper.
 * No background listener is opened in bluetoothd, no streaming, and no
 * private Bluetooth API/AVDTP/SDP data is accessed or modified.
 *
 * This is deliberately a test, not a production IPC channel. The 6-digit
 * one-time token and v2 BTD4 sender marker are NOT cryptographic identity.
 */
#include "BTPSDaemonProbe.h"
#include "BTPSIPCProtocol.h"
#include "BTPSLog.h"
#include "BTPSShared.h"
#include "BTPSV74Tone.h"
#include "BTPSV75Fixture.h"
#include <CoreFoundation/CoreFoundation.h>
#include <dispatch/dispatch.h>
#include <notify.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <time.h>
#include <unistd.h>


static dispatch_queue_t g_v74_queue;
static int g_v74_notify_token=-1;
static char g_v74_last_uuid[37]={0};
static time_t g_v74_last_time=0;

static int get_request(CFStringRef key,uint32_t *token_out,char uuid_out[37])
{
    /* Domain and key match the existing prefs writes from Settings.
     * Synchronize on the WORKER queue to avoid cached defaults after a post. */
    CFStringRef domain=CFSTR(BTPS_PREFS_DOMAIN);
    (void)CFPreferencesSynchronize(domain,kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
    CFPropertyListRef value=CFPreferencesCopyValue(key,domain,
                                                  kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
    if(!value) return 0;
    int ok=0;
    if(CFGetTypeID(value)==CFStringGetTypeID()) {
        char raw[90]={0};
        if(CFStringGetCString((CFStringRef)value,raw,sizeof raw,kCFStringEncodingASCII) && strlen(raw)==43 && raw[6]=='.') {
            uint32_t token=0;
            int valid=1;
            for(int i=0;i<6;i++) {
                if(raw[i]<'0' || raw[i]>'9') {valid=0;break;}
                token=token*10u+(uint32_t)(raw[i]-'0');
            }
            if(token<100000u || token>999999u) valid=0;
            for(int i=7;i<43 && valid;i++) {
                const char c=raw[i];
                int hyphen=(i==15||i==20||i==25||i==30);
                if(hyphen ? c!='-' : !((c>='0'&&c<='9')||(c>='a'&&c<='f')||(c>='A'&&c<='F'))) valid=0;
            }
            if(valid) {
                *token_out=token;
                memcpy(uuid_out,raw+7,36);uuid_out[36]='\0';
                ok=1;
            }
        }
    }
    CFRelease(value);
    return ok;
}

static int timed_connect_port(int fd, uint16_t port)
{
    int flags=fcntl(fd,F_GETFL,0);
    if(flags<0 || fcntl(fd,F_SETFL,flags|O_NONBLOCK)<0) return -1;
    struct sockaddr_in address={0};
    address.sin_family=AF_INET;
    address.sin_port=htons(port);
    address.sin_addr.s_addr=htonl(INADDR_LOOPBACK);
    int r=connect(fd,(const struct sockaddr *)&address,sizeof address);
    if(r<0 && errno!=EINPROGRESS) return -1;
    if(r<0) {
        fd_set wfds;
        FD_ZERO(&wfds);FD_SET(fd,&wfds);
        struct timeval timeout={1,0};
        if(select(fd+1,NULL,&wfds,NULL,&timeout)!=1) { errno=ETIMEDOUT;return -1; }
        int e=0;socklen_t n=sizeof e;
        if(getsockopt(fd,SOL_SOCKET,SO_ERROR,&e,&n)<0) return -1;
        if(e) {errno=e;return -1;}
    }
    if(fcntl(fd,F_SETFL,flags)<0) return -1;
    struct timeval timeout={2,0};
    (void)setsockopt(fd,SOL_SOCKET,SO_SNDTIMEO,&timeout,sizeof timeout);
    (void)setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,sizeof timeout);
    int nosigpipe=1;(void)setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&nosigpipe,sizeof nosigpipe);
    return 0;
}

int BTPSDaemonConnectLoopback(uint16_t port)
{
    int fd=socket(AF_INET,SOCK_STREAM,0);
    if(fd>=0 && timed_connect_port(fd,port)<0) {close(fd);return -1;}
    return fd;
}
static int timed_connect_loopback(int fd) { return timed_connect_port(fd,BTPS_IPC_PORT); }

static int send_exact(int fd,const uint8_t *p,size_t n)
{
    while(n) {
        size_t batch=n>4096u?4096u:n;
        ssize_t sent=send(fd,p,batch,0);
        if(sent<=0) return -1;
        p+=(size_t)sent;n-=(size_t)sent;
    }
    return 0;
}

static void attempt_test(int notify_token)
{
    (void)notify_token;
    uint32_t request_token=0;
    char request_uuid[37]={0};
    if(!get_request(CFSTR(BTPS_KEY_DAEMON_PROBE),&request_token,request_uuid)) {
        BTPSSetStatus("diag.v74_ipc","REQUEST IGNORED: malformed or unreadable shared preference");
        BTPSLogNow("V74_IPC request ignored: malformed/unreadable request");
        return;
    }
    if(strcmp(g_v74_last_uuid,request_uuid)==0) {
        BTPSSetStatus("diag.v74_ipc","REQUEST IGNORED: duplicate request UUID");
        return;
    }
    /* No unlimited retries or background stream; explicit new user request only. */
    time_t now=time(NULL);
    if(g_v74_last_time && now>=g_v74_last_time && now-g_v74_last_time<10) {
        BTPSSetStatus("diag.v74_ipc","THROTTLED: wait 10 seconds and request again");
        return;
    }
    snprintf(g_v74_last_uuid,sizeof g_v74_last_uuid,"%s",request_uuid);
    g_v74_last_time=now;

    BTPSSetStatus("diag.v74_ipc","STARTED: daemon worker attempted v2 loopback PCM send");
    BTPSLogNow("V74_IPC daemon worker started pid=%d request_id=%.8s (no Bluetooth media)",getpid(),request_uuid);
    uint8_t *pcm=(uint8_t *)malloc(BTPS_IPC_PCM_BYTES);
    if(!pcm) {
        BTPSSetStatus("diag.v74_ipc","FAIL: PCM allocation");
        BTPSLogNow("V74_IPC FAIL allocation of %u bytes",(unsigned)BTPS_IPC_PCM_BYTES);
        return;
    }
    if(!btps_v74_make_tone(pcm,BTPS_IPC_PCM_BYTES)) {
        BTPSSetStatus("diag.v74_ipc","FAIL: PCM generator declined buffer");
        free(pcm);return;
    }
    uint8_t header[BTPS_IPC_V74_HEADER_SIZE];
    btps_ipc_encode_daemon_v74(header,request_token,btps_ipc_crc32(pcm,BTPS_IPC_PCM_BYTES));
    int fd=socket(AF_INET,SOCK_STREAM,0);
    if(fd<0) {
        int e=errno;
        BTPSSetStatus("diag.v74_ipc","FAIL: socket denied errno=%d",e);
        BTPSLogNow("V74_IPC FAIL socket errno=%d",e);
        free(pcm);return;
    }
    if(timed_connect_loopback(fd)<0) {
        int e=errno;
        BTPSSetStatus("diag.v74_ipc","FAIL: helper loopback connect errno=%d",e);
        BTPSLogNow("V74_IPC FAIL loopback connect errno=%d",e);
        close(fd);free(pcm);return;
    }
    if(send_exact(fd,header,sizeof header)<0 || send_exact(fd,pcm,BTPS_IPC_PCM_BYTES)<0) {
        int e=errno;
        BTPSSetStatus("diag.v74_ipc","FAIL: send errno=%d",e);
        BTPSLogNow("V74_IPC FAIL send errno=%d",e);
        close(fd);free(pcm);return;
    }
    char ack[16]={0};
    ssize_t got=recv(fd,ack,sizeof ack-1u,0);
    close(fd);free(pcm);
    if(got>0 && strncmp(ack,"RECEIVED",8)==0) {
        BTPSSetStatus("diag.v74_ipc","PASS: helper verified v2 880Hz PCM CRC, audible sound unverified");
        BTPSLogNow("V74_IPC PASS: helper ACK RECEIVED for 70560 bytes; confirm 880 Hz heard on device");
    } else {
        BTPSSetStatus("diag.v74_ipc","FAIL: helper rejected or no ACK (recv=%ld)",(long)got);
        BTPSLogNow("V74_IPC FAIL: helper ACK recv=%ld payload=%s",(long)got,got>0?ack:"none");
    }
}

void BTPSDaemonProbeStart(void)
{
    g_v74_queue=dispatch_queue_create("com.parv.speaka.v74.ipc.worker",DISPATCH_QUEUE_SERIAL);
    if(!g_v74_queue) {
        BTPSSetStatus("diag.v74_ipc","UNAVAILABLE: no worker queue");
        return;
    }
    int r=notify_register_dispatch(BTPS_NOTIFY_DAEMON_PROBE,&g_v74_notify_token,g_v74_queue,^(int t){
        attempt_test(t); /* all prefs, PCM and sockets on the dedicated queue */
    });
    if(r==NOTIFY_STATUS_OK) {
        BTPSSetStatus("diag.v74_ipc","ARMED: awaiting explicit Settings request (no sockets active)");
        BTPSLogNow("V74_IPC armed: notify_register_dispatch ok; zero automatic requests");
    } else {
        BTPSSetStatus("diag.v74_ipc","UNAVAILABLE: notify_register_dispatch=%d",r);
        BTPSLogNow("V74_IPC unavailable: Darwin notification registration status=%d",r);
    }
}

/* v7.5: independent, explicitly triggered compressed RTP/SBC fixture send.
 * Runs on the existing worker queue, never from a Bluetooth hook. */
static int g_v75_notify_token=-1;
static char g_v75_last_uuid[37]={0};
static time_t g_v75_last_time=0;
static void send_v75_sbc(int t) {
    (void)t;
    uint32_t token=0;char uuid[37]={0};
    if(!get_request(CFSTR(BTPS_KEY_V75_SBC),&token,uuid)) {
        BTPSSetStatus("diag.v75_sbc","FAIL: unreadable/malformed Settings request");return;
    }
    if(strcmp(uuid,g_v75_last_uuid)==0)return;
    time_t now=time(NULL);
    if(g_v75_last_time && now>=g_v75_last_time && now-g_v75_last_time<10) {
        BTPSSetStatus("diag.v75_sbc","THROTTLED: wait at least 10 seconds");return;
    }
    memcpy(g_v75_last_uuid,uuid,37);g_v75_last_time=now;
    if(btps_v75_reference_size!=BTPS_IPC_V75_FIXTURE_SIZE) {
        BTPSSetStatus("diag.v75_sbc","FAIL: compiled fixture size differs");return;
    }
    BTPSSetStatus("diag.v75_sbc","STARTED: daemon sending bounded reference RTP/SBC (not over-air)");
    BTPSLogNow("V75_SBC start pid=%d sampleBytes=%u request=%.8s NOT live Bluetooth",
               getpid(),(unsigned)btps_v75_reference_size,uuid);
    uint8_t h[BTPS_IPC_V75_HEADER_SIZE];
    btps_ipc_encode_sbc_v75(h,token,btps_ipc_crc32(btps_v75_reference_rtp,btps_v75_reference_size));
    int fd=socket(AF_INET,SOCK_STREAM,0);
    if(fd<0){int e=errno; BTPSSetStatus("diag.v75_sbc","FAIL: socket errno=%d",e);return;}
    if(timed_connect_loopback(fd)<0){int e=errno;BTPSSetStatus("diag.v75_sbc","FAIL: connect errno=%d",e);close(fd);return;}
    if(send_exact(fd,h,sizeof h)!=0||send_exact(fd,btps_v75_reference_rtp,btps_v75_reference_size)!=0){
        int e=errno;BTPSSetStatus("diag.v75_sbc","FAIL: send errno=%d",e);close(fd);return;
    }
    char ack[20]={0};ssize_t got=recv(fd,ack,sizeof ack-1u,0);close(fd);
    if(got>=12 && memcmp(ack,"SBC_VERIFIED",12)==0) {
        BTPSSetStatus("diag.v75_sbc","PASS: helper verified complete compressed SBC RTP transfer");
        BTPSLogNow("V75_SBC PASS verified fixture frames in separate helper, no audio playback");
    } else {
        BTPSSetStatus("diag.v75_sbc","FAIL: no SBC_VERIFIED helper ACK (recv=%ld)",(long)got);
        BTPSLogNow("V75_SBC FAIL ACK recv=%ld",(long)got);
    }
}
void BTPSDaemonProbeStartV75(void) {
    if(!g_v74_queue){BTPSSetStatus("diag.v75_sbc","UNAVAILABLE: v7.4 worker queue absent");return;}
    int r=notify_register_dispatch(BTPS_NOTIFY_V75_SBC,&g_v75_notify_token,g_v74_queue,^(int t){send_v75_sbc(t);});
    if(r==NOTIFY_STATUS_OK){
        BTPSSetStatus("diag.v75_sbc","ARMED: compressed SBC fixture transfer opt-in, no active sockets");
        BTPSLogNow("V75_SBC armed: 440Hz ffmpeg-encoded SBC RTP fixture, no live Bluetooth");
    } else {
        BTPSSetStatus("diag.v75_sbc","UNAVAILABLE: notify registration error %d",r);
    }
}
