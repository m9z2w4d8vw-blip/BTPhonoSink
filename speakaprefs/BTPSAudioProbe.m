#import "BTPSAudioProbe.h"
#import <math.h>
#import <stdint.h>
#import <string.h>
#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

static void BTPSWrite16(uint8_t *d, uint16_t v) {
    d[0] = (uint8_t)v; d[1] = (uint8_t)(v >> 8);
}
static void BTPSWrite32(uint8_t *d, uint32_t v) {
    for (int i = 0; i < 4; ++i) d[i] = (uint8_t)(v >> (8 * i));
}
static NSData *BTPSMakeTone(void) {
    /* 0.8 sec, 44.1 kHz, signed 16-bit mono PCM. Generated locally,
     * no files or microphone permissions. Short fades prevent clicks. */
    const uint32_t rate = 44100, frames = 35280;
    const uint32_t pcmBytes = frames * 2u;
    NSMutableData *data = [NSMutableData dataWithLength:44u + pcmBytes];
    uint8_t *d = (uint8_t *)data.mutableBytes;
    memcpy(d, "RIFF", 4); BTPSWrite32(d + 4, 36u + pcmBytes);
    memcpy(d + 8, "WAVEfmt ", 8); BTPSWrite32(d + 16, 16);
    BTPSWrite16(d + 20, 1); BTPSWrite16(d + 22, 1);
    BTPSWrite32(d + 24, rate); BTPSWrite32(d + 28, rate * 2u);
    BTPSWrite16(d + 32, 2); BTPSWrite16(d + 34, 16);
    memcpy(d + 36, "data", 4); BTPSWrite32(d + 40, pcmBytes);
    for (uint32_t i = 0; i < frames; ++i) {
        double fadeIn = fmin(1.0, (double)i / 900.0);
        double fadeOut = fmin(1.0, (double)(frames - 1 - i) / 900.0);
        double v = sin((2.0 * M_PI * 440.0 * (double)i) / (double)rate)
                   * 0.22 * fmin(fadeIn, fadeOut);
        int16_t pcm = (int16_t)lrint(v * 32767.0);
        BTPSWrite16(d + 44u + (size_t)i * 2u, (uint16_t)pcm);
    }
    return data;
}

@implementation BTPSAudioProbe {
    AVAudioPlayer *_player;
    NSString *_oldCategory;
    NSString *_oldMode;
    AVAudioSessionCategoryOptions _oldOptions;
}

- (BOOL)startWithError:(NSError **)error {
    [self stop];
    AVAudioSession *session = [AVAudioSession sharedInstance];
    _oldCategory = [session.category copy];
    _oldMode = [session.mode copy];
    _oldOptions = session.categoryOptions;
    if (![session setCategory:AVAudioSessionCategoryPlayback error:error] ||
        ![session setActive:YES error:error]) {
        [self stop];
        return NO;
    }
    _player = [[AVAudioPlayer alloc] initWithData:BTPSMakeTone() error:error];
    if (!_player) { [self stop]; return NO; }
    _player.delegate = self;
    _player.volume = 0.35f;
    [_player prepareToPlay];
    if (![_player play]) {
        if (error) *error = [NSError errorWithDomain:@"BTPSAudioProbe" code:1
                    userInfo:@{NSLocalizedDescriptionKey:@"AVAudioPlayer refused to start"}];
        [self stop]; return NO;
    }
    return YES;
}
- (void)stop {
    [_player stop]; _player.delegate = nil; _player = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (_oldCategory.length && _oldMode.length) {
        [session setCategory:_oldCategory mode:_oldMode options:_oldOptions error:NULL];
        [session setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:NULL];
    }
    _oldCategory = nil; _oldMode = nil;
}
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag {
    NSString *message = flag ? @"iOS audio playback API completed the tone; confirm whether you HEARD it. This does not test Bluetooth Sink input."
                             : @"iOS audio player reported unsuccessful completion.";
    [self stop];
    if (self.completion) self.completion(message);
}
@end
