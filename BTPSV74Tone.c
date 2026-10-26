#include "BTPSV74Tone.h"
#include "BTPSIPCProtocol.h"
#include <math.h>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif
int btps_v74_make_tone(uint8_t *out, size_t capacity)
{
    if(!out || capacity < BTPS_IPC_PCM_BYTES) return 0;
    for(uint32_t i=0;i<BTPS_IPC_FRAMES;i++) {
        uint32_t end=BTPS_IPC_FRAMES-1u-i;
        double edge=(double)(i<end?i:end)/900.0;
        double fade=edge<1.0?edge:1.0;
        int16_t v=(int16_t)lrint(sin(2.0*M_PI*880.0*(double)i/(double)BTPS_IPC_SAMPLERATE)*12000.0*fade);
        out[i*2u]=(uint8_t)v;
        out[i*2u+1u]=(uint8_t)((uint16_t)v>>8);
    }
    return 1;
}
