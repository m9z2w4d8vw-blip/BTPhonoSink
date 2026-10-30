//
//  SPTweakClient.m
//  Speaka
//
//  Every rule here mirrors speakaprefs/BTPSRootListController.m (the Settings page), so the app and Settings
//  always agree about the speaker's state. tests/test_speaka_app.py checks that they stay in step.
//

#import "SPTweakClient.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <notify.h>
#import "BTPSShared.h"

#pragma mark - preferences (same domain and scope as the tweak and the Settings page)

static void SPSynchronize(void)
{
    CFPreferencesAppSynchronize(CFSTR(BTPS_PREFS_DOMAIN));
}

static id SPCopyPref(NSString *key)   // call SPSynchronize() first
{
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(BTPS_PREFS_DOMAIN)));
}

static BOOL SPWritePref(NSString *key, id value)   // nil removes the key
{
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR(BTPS_PREFS_DOMAIN));
    return CFPreferencesAppSynchronize(CFSTR(BTPS_PREFS_DOMAIN));
}

static NSString *SPString(id value)
{
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSDictionary *SPDaemonStatus(void)
{
    id status = SPCopyPref(@BTPS_KEY_STATUS);
    return [status isKindOfClass:[NSDictionary class]] ? status : @{};
}

#pragma mark - output names (as BTPSTypeLabel / BTPSOutputName / BTPSOutputsDescription)

static NSString *SPTypeLabel(NSString *type)
{
    if ([type isEqualToString:AVAudioSessionPortBluetoothA2DP] || [type isEqualToString:AVAudioSessionPortBluetoothLE] ||
        [type isEqualToString:AVAudioSessionPortBluetoothHFP]) return @"Bluetooth";
    if ([type isEqualToString:AVAudioSessionPortHeadphones]) return @"wired";
    if ([type isEqualToString:AVAudioSessionPortUSBAudio]) return @"USB";
    if ([type isEqualToString:AVAudioSessionPortAirPlay]) return @"AirPlay";
    if ([type isEqualToString:AVAudioSessionPortCarAudio]) return @"CarPlay";
    return nil;
}

static NSString *SPOutputName(NSDictionary *output)
{
    NSString *type = SPString(output[@"type"]);
    if ([type isEqualToString:AVAudioSessionPortBuiltInSpeaker]) return @"iPhone speaker";
    if ([type isEqualToString:AVAudioSessionPortBuiltInReceiver]) return @"iPhone earpiece";
    NSString *name = SPString(output[@"name"]);
    if (!name.length) name = @"(unnamed device)";
    NSString *label = SPTypeLabel(type);
    return label ? [NSString stringWithFormat:@"%@ (%@)", name, label] : name;
}

static NSString *SPOutputsDescription(id outputs)
{
    if (![outputs isKindOfClass:[NSArray class]]) return @"";
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id output in (NSArray *)outputs)
        if ([output isKindOfClass:[NSDictionary class]]) [names addObject:SPOutputName(output)];
    return [names componentsJoinedByString:@" + "];
}

#pragma mark - SPStatus

@implementation SPStatus

- (instancetype)init
{
    if (self = [super init]) {
        _detail = @"";
        _build = @"";
        _outputMode = @"speaker";
        _playingOn = @"";
        _waitingReason = @"";
    }
    return self;
}

- (BOOL)canStart
{
    return self.session != SPSessionOn && self.session != SPSessionStarting;
}

- (BOOL)canStop
{
    return self.session == SPSessionOn || self.session == SPSessionStarting || self.session == SPSessionLost ||
           self.session == SPSessionFailed;
}

@end

#pragma mark - SPRequest

@interface SPRequest ()
@property (nonatomic, copy, readwrite) NSString *action;
@property (nonatomic, copy, readwrite) NSString *nonce;
@property (nonatomic, strong, readwrite) NSDate *started;
@end

@implementation SPRequest
@end

#pragma mark - SPTweakClient

@implementation SPTweakClient

+ (instancetype)sharedClient
{
    static SPTweakClient *client = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        client = [[SPTweakClient alloc] init];
    });
    return client;
}

+ (NSArray<NSDictionary<NSString *, NSString *> *> *)outputModes
{
    // Titles match the "Play audio on" list in speakaprefs/Resources/Root.plist.
    return @[
        @{ @"key": @"speaker", @"title": @"iPhone speaker", @"shortTitle": @"iPhone speaker",
           @"symbol": @"speaker.wave.2.fill", @"detail": @"Always the built-in loudspeaker" },
        @{ @"key": @"headphones", @"title": @"Wired headphones or earbuds", @"shortTitle": @"Wired headphones",
           @"symbol": @"headphones", @"detail": @"A plugged-in headset; never Bluetooth" },
        @{ @"key": @"any", @"title": @"Any device (follow iOS)", @"shortTitle": @"Any device",
           @"symbol": @"airplayaudio", @"detail": @"Wherever iOS plays, including Bluetooth" },
    ];
}

- (SPStatus *)readStatus
{
    SPSynchronize();
    SPStatus *s = [[SPStatus alloc] init];
    NSDictionary *status = SPDaemonStatus();
    s.build = SPString(status[@"diag.v89.build"]);

    // The same rules, in the same order, as BTPSSessionSummary() in the Settings page.
    NSString *trial = SPString(status[@"diag.v82.trial"]);
    NSString *sep = SPString(status[@"diag.v82.sep"]);
    NSString *table = SPString(status[@"diag.v83.audio_table"]);
    if (status.count == 0) {
        s.session = SPSessionNoTweak;
    } else if ([sep hasPrefix:@"LOST"]) {
        s.session = SPSessionLost;
    } else if (!status[@"diag.v89.build"]) {
        s.session = SPSessionOldTweak;
    } else if ([trial hasPrefix:@"ARMED"]) {
        s.session = SPSessionStarting;
        for (NSString *bad in @[ @"REFUSED", @"ROLLED BACK", @"UNSAFE", @"FAILED", @"SDP publish failed" ]) {
            if ([table hasPrefix:bad]) {
                s.session = SPSessionFailed;
                s.detail = table;
                break;
            }
        }
        if (s.session == SPSessionStarting && [sep containsString:@"register=0"] && [sep containsString:@"SEID=7"])
            s.session = SPSessionOn;
    } else if ([trial hasPrefix:@"REFUSED"]) {
        s.session = SPSessionRefused;
        s.detail = trial;
    } else {
        s.session = SPSessionOff;
    }

    // What BTPSAudioHelper last reported, ignored once it is more than 20 s old (as in Settings).
    id helperValue = SPCopyPref(@BTPS_KEY_V89_HELPER);
    NSDictionary *helper = [helperValue isKindOfClass:[NSDictionary class]] ? helperValue : nil;
    id when = helper[@"time"];
    double time = [when isKindOfClass:[NSNumber class]] ? [when doubleValue] : 0.0;
    if (helper && [NSDate date].timeIntervalSince1970 - time > 20.0)
        helper = nil;
    NSString *state = SPString(helper[@"state"]);
    s.playing = [state isEqualToString:@"playing"];
    s.receiving = s.session == SPSessionOn && (s.playing || [state isEqualToString:@"waiting"]);
    s.waitingReason = [state isEqualToString:@"waiting"] ? SPString(helper[@"reason"]) : @"";
    s.playingOn = s.playing ? SPOutputsDescription(helper[@"outputs"]) : @"";
    id volume = helper[@"volume"];
    s.volumeZero = s.playing && [volume isKindOfClass:[NSNumber class]] && [volume doubleValue] < 0.05;

    NSString *mode = SPString(SPCopyPref(@BTPS_KEY_V89_OUTPUT_MODE));
    s.outputMode = [[[SPTweakClient outputModes] valueForKey:@"key"] containsObject:mode] ? mode : @"speaker";
    return s;
}

- (BOOL)setOutputMode:(NSString *)mode
{
    if (![[[SPTweakClient outputModes] valueForKey:@"key"] containsObject:mode])
        return NO;
    if (!SPWritePref(@BTPS_KEY_V89_OUTPUT_MODE, mode))
        return NO;
    // The audio helper re-reads the mode when this is posted, so the change applies mid-song.
    notify_post(BTPS_NOTIFY_V89_OUTPUT);
    return YES;
}

// Writes the request, then wakes the tweak inside bluetoothd. The tweak validates and deletes the request, sets or
// clears the two one-shot switches itself and restarts bluetoothd. The app never writes those switches directly.
- (SPRequest *)sendAction:(NSString *)action error:(NSString **)error
{
    NSString *nonce = [NSUUID UUID].UUIDString;
    NSDictionary *request = @{ @"action": action, @"nonce": nonce, @"time": @([NSDate date].timeIntervalSince1970) };
    if (!SPWritePref(@BTPS_KEY_V89_REQUEST, request)) {
        if (error) *error = @"Could not save the request (preferences did not synchronize). Nothing was changed.";
        return nil;
    }
    uint32_t posted = notify_post(BTPS_NOTIFY_V89_SESSION);
    if (posted != NOTIFY_STATUS_OK) {
        SPWritePref(@BTPS_KEY_V89_REQUEST, nil);
        if (error) *error = [NSString stringWithFormat:@"Could not reach Bluetooth (notify_post=%u). Nothing was changed.", posted];
        return nil;
    }
    SPRequest *pending = [[SPRequest alloc] init];
    pending.action = action;
    pending.nonce = nonce;
    pending.started = [NSDate date];
    return pending;
}

- (SPRequestState)finish:(SPRequest *)request ok:(BOOL)ok title:(NSString *)title message:(NSString *)message
{
    request.succeeded = ok;
    request.resultTitle = title;
    request.resultMessage = message;
    return SPRequestFinished;
}

// The state machine of -pollSession in the Settings page.
- (SPRequestState)pollRequest:(SPRequest *)request
{
    SPSynchronize();
    NSDictionary *status = SPDaemonStatus();
    NSString *session = SPString(status[@BTPS_STATUS_V89_SESSION]);
    BOOL mine = [session containsString:[@"nonce=" stringByAppendingString:request.nonce]];
    BOOL start = [request.action isEqualToString:@"start"];
    NSTimeInterval elapsed = -[request.started timeIntervalSinceNow];

    if (mine && [session hasPrefix:@"REFUSED"])
        return [self finish:request ok:NO title:@"Bluetooth was not restarted" message:session];
    if (mine && !request.relaunched) {
        request.relaunched = YES;
        if (!start)
            return [self finish:request ok:YES title:@"Bluetooth restarted"
                        message:@"The speaker is off and Bluetooth is back to normal."];
        if ([session containsString:@"result=REFUSED"]) {
            NSString *why = SPString(status[@"diag.v82.trial"]);
            return [self finish:request ok:NO title:@"Speaker not started"
                        message:[NSString stringWithFormat:@"Bluetooth restarted, but the tweak refused the trial.\n\n%@",
                                                           why.length ? why : session]];
        }
    }
    if (request.relaunched && start) {
        SPStatus *now = [self readStatus];
        if (now.session == SPSessionOn)
            return [self finish:request ok:YES title:@"The iPhone is now a Bluetooth speaker"
                        message:@"On your PC, connect to this iPhone and choose it as the audio output.\n\n"
                                @"This lasts until Bluetooth restarts. Turning Bluetooth or Airplane Mode off and on "
                                @"also removes it; tap Start again after any of these."];
        if (now.session == SPSessionFailed || now.session == SPSessionRefused)
            return [self finish:request ok:NO title:@"Speaker not started" message:now.detail];
    }
    if (elapsed > (request.relaunched ? 45.0 : 25.0)) {
        // Never suggest turning Bluetooth off and on: that does NOT restart bluetoothd, and it removes a running
        // speaker endpoint until the next restart.
        NSString *message = request.relaunched
            ? @"Bluetooth restarted and the speaker is armed, but its registration has not been reported yet. "
              @"Make sure Bluetooth is turned on, then check again in a few seconds."
            : @"Bluetooth did not report a restart. If devices do not reconnect within a minute, restart the Bluetooth "
              @"daemon with your usual sudo killall -9 bluetoothd command, then try Start again.";
        return [self finish:request ok:NO title:@"Still waiting" message:message];
    }
    return SPRequestWaiting;
}

@end
