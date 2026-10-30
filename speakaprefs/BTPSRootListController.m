// BTPSRootListController.m
#import "BTPSRootListController.h"
#import "BTPSLogReader.h"
#import "BTPSLogViewController.h"

#import <AVFoundation/AVFoundation.h>
#import <AVKit/AVKit.h>
#import <CoreFoundation/CoreFoundation.h>
#include <notify.h>

#import "BTPSShared.h"

#pragma mark - preferences (same domain and scope as the tweak and the switches on this page)

static id BTPSCopyPref(NSString *key)
{
    CFPreferencesAppSynchronize(CFSTR(BTPS_PREFS_DOMAIN));
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR(BTPS_PREFS_DOMAIN)));
}

static BOOL BTPSWritePref(NSString *key, id value)   // nil removes the key
{
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, CFSTR(BTPS_PREFS_DOMAIN));
    return CFPreferencesAppSynchronize(CFSTR(BTPS_PREFS_DOMAIN));
}

static NSString *BTPSString(id value)
{
    return [value isKindOfClass:[NSString class]] ? value : @"";
}

static NSDictionary *BTPSDaemonStatus(void)
{
    id status = BTPSCopyPref(@BTPS_KEY_STATUS);
    return [status isKindOfClass:[NSDictionary class]] ? status : @{};
}

// One line for the Session row, from the status the tweak publishes inside bluetoothd.
static NSString *BTPSSessionSummary(NSDictionary *status)
{
    NSString *trial = BTPSString(status[@"diag.v82.trial"]);
    NSString *sep = BTPSString(status[@"diag.v82.sep"]);
    NSString *table = BTPSString(status[@"diag.v83.audio_table"]);
    if ([sep hasPrefix:@"LOST"]) return @"Off - Bluetooth was turned off and on; tap Start";
    if (status.count && !status[@"diag.v89.build"]) return @"Old version running - see Start";
    if ([trial hasPrefix:@"ARMED"]) {
        for (NSString *bad in @[ @"REFUSED", @"ROLLED BACK", @"UNSAFE", @"FAILED", @"SDP publish failed" ])
            if ([table hasPrefix:bad]) return [@"Failed: " stringByAppendingString:table];
        if ([sep containsString:@"register=0"] && [sep containsString:@"SEID=7"]) return @"On";
        return @"Starting...";
    }
    if ([trial hasPrefix:@"REFUSED"]) return [@"Refused: " stringByAppendingString:trial];
    return status.count ? @"Off" : @"Unknown (no status from the tweak yet)";
}

// What BTPSAudioHelper last reported, or nil if it is older than maxAge seconds.
static NSDictionary *BTPSHelperStatus(NSTimeInterval maxAge)
{
    id helper = BTPSCopyPref(@BTPS_KEY_V89_HELPER);
    if (![helper isKindOfClass:[NSDictionary class]]) return nil;
    id when = helper[@"time"];
    double t = [when isKindOfClass:[NSNumber class]] ? [when doubleValue] : 0.0;
    if ([NSDate date].timeIntervalSince1970 - t > maxAge) return nil;
    return helper;
}

static BOOL BTPSIsBuiltIn(NSString *type)
{
    return [type isEqualToString:AVAudioSessionPortBuiltInSpeaker] ||
           [type isEqualToString:AVAudioSessionPortBuiltInReceiver];
}

// v8.9.3: say what kind of device it is, so the laptop's own Bluetooth connection is recognizable as an output.
static NSString *BTPSTypeLabel(NSString *type)
{
    if ([type isEqualToString:AVAudioSessionPortBluetoothA2DP] || [type isEqualToString:AVAudioSessionPortBluetoothLE] ||
        [type isEqualToString:AVAudioSessionPortBluetoothHFP]) return @"Bluetooth";
    if ([type isEqualToString:AVAudioSessionPortHeadphones]) return @"wired";
    if ([type isEqualToString:AVAudioSessionPortUSBAudio]) return @"USB";
    if ([type isEqualToString:AVAudioSessionPortAirPlay]) return @"AirPlay";
    if ([type isEqualToString:AVAudioSessionPortCarAudio]) return @"CarPlay";
    return nil;
}

static NSString *BTPSOutputName(NSDictionary *output)
{
    NSString *type = BTPSString(output[@"type"]);
    if ([type isEqualToString:AVAudioSessionPortBuiltInSpeaker]) return @"iPhone speaker";
    if ([type isEqualToString:AVAudioSessionPortBuiltInReceiver]) return @"iPhone earpiece";
    NSString *name = BTPSString(output[@"name"]);
    if (!name.length) name = @"(unnamed device)";
    NSString *label = BTPSTypeLabel(type);
    return label ? [NSString stringWithFormat:@"%@ (%@)", name, label] : name;
}

static NSString *BTPSOutputsDescription(id outputs)
{
    if (![outputs isKindOfClass:[NSArray class]]) return @"";
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (id output in (NSArray *)outputs)
        if ([output isKindOfClass:[NSDictionary class]]) [names addObject:BTPSOutputName(output)];
    return [names componentsJoinedByString:@" + "];
}

static UIControl *BTPSFindControl(UIView *view)
{
    for (UIView *sub in view.subviews) {
        if ([sub isKindOfClass:[UIControl class]]) return (UIControl *)sub;
        UIControl *nested = BTPSFindControl(sub);
        if (nested) return nested;
    }
    return nil;
}

@interface BTPSRootListController ()
@property (nonatomic, strong) NSTimer *refreshTimer;
@property (nonatomic, strong) AVRoutePickerView *routePicker;
@property (nonatomic, weak) UIAlertController *progressAlert;
@property (nonatomic, copy) NSString *pendingNonce;
@property (nonatomic, copy) NSString *pendingAction;
@property (nonatomic, strong) NSDate *pendingStarted;
@property (nonatomic, assign) BOOL pendingRelaunched;
@end

@implementation BTPSRootListController

- (NSArray *)specifiers
{
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reloadSpecifiers];           // refresh the status rows every time the page is shown
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    [self.refreshTimer invalidate];
    __weak __typeof__(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshLiveRows];
    }];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)refreshLiveRows
{
    if (![self respondsToSelector:@selector(reloadSpecifierID:)]) return;
    for (NSString *row in @[ @"session", @"playing", @"never" ]) [self reloadSpecifierID:row];
}

#pragma mark - values for the rows in Root.plist (the "get" selectors)

- (id)loadedValue:(id)specifier       { return [[BTPSLogReader shared] loadedSummary]; }
- (id)lastEventValue:(id)specifier    { return [[BTPSLogReader shared] lastEventSummary]; }
- (id)channelValue:(id)specifier      { return [[BTPSLogReader shared] channelSummary]; }

- (id)sessionValue:(id)specifier
{
    NSString *summary = BTPSSessionSummary(BTPSDaemonStatus());
    if ([summary isEqualToString:@"On"]) {
        NSString *state = BTPSString(BTPSHelperStatus(20.0)[@"state"]);
        if ([state isEqualToString:@"playing"] || [state isEqualToString:@"waiting"]) return @"On - receiving audio";
        return @"On - connect from your PC";
    }
    return summary;
}

- (id)playingValue:(id)specifier
{
    NSDictionary *helper = BTPSHelperStatus(20.0);
    NSString *state = BTPSString(helper[@"state"]);
    NSString *reason = BTPSString(helper[@"reason"]);
    if ([state isEqualToString:@"playing"]) {
        NSString *where = BTPSOutputsDescription(helper[@"outputs"]);
        if (!where.length) where = @"Playing";
        id volume = helper[@"volume"];
        if ([volume isKindOfClass:[NSNumber class]] && [volume doubleValue] < 0.05)
            where = [where stringByAppendingString:@" - volume 0%"];
        return where;
    }
    if ([state isEqualToString:@"waiting"]) return reason.length ? [@"Waiting: " stringByAppendingString:reason] : @"Waiting";
    return @"Not playing";
}

- (NSArray<NSDictionary *> *)neverList
{
    id list = BTPSCopyPref(@BTPS_KEY_V89_NEVER);
    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    if ([list isKindOfClass:[NSArray class]])
        for (id item in (NSArray *)list)
            if ([item isKindOfClass:[NSDictionary class]]) [items addObject:item];
    return items;
}

- (id)neverValue:(id)specifier
{
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *item in [self neverList]) [names addObject:BTPSOutputName(item)];
    return names.count ? [names componentsJoinedByString:@", "] : @"None";
}

#pragma mark - buttons (the "action" selectors)

- (void)showLog:(id)specifier
{
    [self.navigationController pushViewController:[[BTPSLogViewController alloc] init] animated:YES];
}

- (void)copyLog:(id)specifier
{
    [UIPasteboard generalPasteboard].string = [[BTPSLogReader shared] fullText];
    [self say:@"Copied the debug log to the clipboard."];
}

- (void)clearLog:(id)specifier
{
    [self say:[[BTPSLogReader shared] clearAll]];
    [self reloadSpecifiers];
}

#pragma mark - one-tap Start / Stop

- (void)startSink:(id)specifier { [self confirmSession:@"start"]; }
- (void)stopSink:(id)specifier  { [self confirmSession:@"stop"]; }

// True when the bluetoothd that is running right now contains the Start/Stop listener (v8.9 or later). Installing a
// package updates this Settings page immediately, but bluetoothd keeps whatever tweak it launched with.
- (BOOL)daemonHasSessionListener
{
    return BTPSDaemonStatus()[@"diag.v89.build"] != nil;
}

- (void)confirmSession:(NSString *)action
{
    if (self.pendingNonce) return;     // one request at a time
    if (![self daemonHasSessionListener]) {
        [self alertWithTitle:@"Restart Bluetooth once to finish installing"
                     message:@"Bluetooth is still running the Speaka tweak version it started with, which has no Start "
                             @"button, so nothing would answer. Restart the Bluetooth daemon once: reinstalling this "
                             @"package does it automatically, or run your usual sudo killall -9 bluetoothd command, or "
                             @"use Reboot Userspace in Dopamine. After that, Start works without the PC.\n\n"
                             @"Turning Bluetooth off and on does not restart the daemon."];
        return;
    }
    BOOL start = [action isEqualToString:@"start"];
    NSString *title = start ? @"Start the Bluetooth speaker?" : @"Stop the Bluetooth speaker?";
    NSString *message = start
        ? @"Bluetooth restarts once, which takes a few seconds. AirPods, a watch and other devices reconnect by themselves."
        : @"Bluetooth restarts once without the speaker experiment, back to normal.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak __typeof__(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:(start ? @"Start" : @"Stop")
                                              style:(start ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive)
                                            handler:^(UIAlertAction *chosen) { [weakSelf sendSession:action]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// Writes the request, then wakes the tweak inside bluetoothd. The tweak validates and deletes the request, sets or
// clears the two one-shot switches itself and restarts bluetoothd. Settings never writes those switches directly.
- (void)sendSession:(NSString *)action
{
    NSString *nonce = [NSUUID UUID].UUIDString;
    NSDictionary *request = @{ @"action": action, @"nonce": nonce, @"time": @([NSDate date].timeIntervalSince1970) };
    if (!BTPSWritePref(@BTPS_KEY_V89_REQUEST, request)) {
        [self say:@"Could not save the request (preferences did not synchronize). Nothing was changed."];
        return;
    }
    uint32_t posted = notify_post(BTPS_NOTIFY_V89_SESSION);
    if (posted != NOTIFY_STATUS_OK) {
        BTPSWritePref(@BTPS_KEY_V89_REQUEST, nil);
        [self say:[NSString stringWithFormat:@"Could not reach Bluetooth (notify_post=%u). Nothing was changed.", posted]];
        return;
    }
    self.pendingNonce = nonce;
    self.pendingAction = action;
    self.pendingStarted = [NSDate date];
    self.pendingRelaunched = NO;
    UIAlertController *progress = [UIAlertController alertControllerWithTitle:@"Restarting Bluetooth..."
                                                                      message:@"Waiting for Bluetooth to restart."
                                                               preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:progress animated:YES completion:nil];
    self.progressAlert = progress;
    [self schedulePoll];
}

- (void)schedulePoll
{
    __weak __typeof__(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf pollSession];
    });
}

- (void)pollSession
{
    if (!self.pendingNonce) return;
    NSDictionary *status = BTPSDaemonStatus();
    NSString *session = BTPSString(status[@BTPS_STATUS_V89_SESSION]);
    BOOL mine = [session containsString:[@"nonce=" stringByAppendingString:self.pendingNonce]];
    BOOL start = [self.pendingAction isEqualToString:@"start"];
    NSTimeInterval elapsed = -[self.pendingStarted timeIntervalSinceNow];

    if (mine && [session hasPrefix:@"REFUSED"]) {
        [self finishSession:@"Bluetooth was not restarted" message:session];
        return;
    }
    if (mine && !self.pendingRelaunched) {
        self.pendingRelaunched = YES;
        if (!start) {
            [self finishSession:@"Bluetooth restarted"
                        message:@"The speaker experiment is off and Bluetooth is back to normal."];
            return;
        }
        if ([session containsString:@"result=REFUSED"]) {
            NSString *why = BTPSString(status[@"diag.v82.trial"]);
            [self finishSession:@"Speaker not started"
                        message:[NSString stringWithFormat:@"Bluetooth restarted, but the tweak refused the trial.\n\n%@",
                                                           why.length ? why : session]];
            return;
        }
        self.progressAlert.message = @"Bluetooth restarted. Registering the iPhone as a speaker...";
    }
    if (self.pendingRelaunched && start) {
        NSString *summary = BTPSSessionSummary(status);
        if ([summary isEqualToString:@"On"]) {
            [self finishSession:@"The iPhone is now a Bluetooth speaker"
                        message:@"On your PC, connect to this iPhone and choose it as the audio output.\n\n"
                                @"This lasts until Bluetooth restarts. Turning Bluetooth or Airplane Mode off and on "
                                @"also removes it; tap Start again after any of these."];
            return;
        }
        if ([summary hasPrefix:@"Failed"] || [summary hasPrefix:@"Refused"]) {
            [self finishSession:@"Speaker not started" message:summary];
            return;
        }
    }
    if (elapsed > (self.pendingRelaunched ? 45.0 : 25.0)) {
        // Never suggest turning Bluetooth off and on: that does NOT restart bluetoothd, and it removes a running
        // speaker endpoint until the next restart.
        NSString *message = self.pendingRelaunched
            ? @"Bluetooth restarted and the trial is armed, but the speaker registration has not been reported yet. "
              @"Make sure Bluetooth is turned on, then check the Session row in a few seconds or open the debug log."
            : @"Bluetooth did not report a restart. If devices do not reconnect within a minute, restart the Bluetooth "
              @"daemon from the PC with your usual sudo killall -9 bluetoothd command, then try Start again.";
        [self finishSession:@"Still waiting" message:message];
        return;
    }
    [self schedulePoll];
}

- (void)finishSession:(NSString *)title message:(NSString *)message
{
    self.pendingNonce = nil;
    self.pendingAction = nil;
    __weak __typeof__(self) weakSelf = self;
    void (^show)(void) = ^{
        [weakSelf reloadSpecifiers];
        [weakSelf alertWithTitle:title message:message];
    };
    UIAlertController *progress = self.progressAlert;
    if (progress && progress.presentingViewController) [progress dismissViewControllerAnimated:YES completion:show];
    else show();
}

#pragma mark - audio output

- (void)chooseOutput:(id)specifier
{
    if (!self.routePicker) {
        AVRoutePickerView *picker = [[AVRoutePickerView alloc] initWithFrame:CGRectMake(0, 0, 44, 44)];
        picker.alpha = 0.02;               // stays in the hierarchy so it can present; effectively invisible
        picker.userInteractionEnabled = NO; // never intercepts taps on the rows beneath it
        [self.view addSubview:picker];
        self.routePicker = picker;
    }
    [self.routePicker layoutIfNeeded];
    UIControl *control = BTPSFindControl(self.routePicker);
    if (control) {
        [control sendActionsForControlEvents:UIControlEventTouchUpInside];
    } else {
        [self say:@"Open Control Center, press and hold the music controls, then tap the AirPlay icon to choose "
                  @"where audio plays."];
    }
}

// Candidates for the never-play list: what the helper is (or was just) using, minus the iPhone's own speaker and
// earpiece. Falls back to the route this Settings process sees when the helper reports nothing external.
- (NSArray<NSDictionary *> *)currentExternalOutputs
{
    NSMutableArray<NSDictionary *> *result = [NSMutableArray array];
    id reported = BTPSHelperStatus(60.0)[@"outputs"];
    if ([reported isKindOfClass:[NSArray class]])
        for (id output in (NSArray *)reported)
            if ([output isKindOfClass:[NSDictionary class]] && !BTPSIsBuiltIn(BTPSString(output[@"type"])))
                [result addObject:output];
    if (!result.count)
        for (AVAudioSessionPortDescription *port in [AVAudioSession sharedInstance].currentRoute.outputs)
            if (!BTPSIsBuiltIn(port.portType))
                [result addObject:@{ @"name": port.portName ?: @"", @"type": port.portType ?: @"", @"uid": port.UID ?: @"" }];
    return result;
}

- (void)neverPlayCurrent:(id)specifier
{
    NSArray<NSDictionary *> *candidates = [self currentExternalOutputs];
    if (!candidates.count) {
        [self say:@"The iPhone is not using an external output right now, so there is nothing to add. Start playback "
                  @"from the PC first; if Playing on shows the PC, tap this again."];
        return;
    }
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (NSDictionary *candidate in candidates) [names addObject:BTPSOutputName(candidate)];
    NSString *title = [NSString stringWithFormat:@"Never play to %@?", [names componentsJoinedByString:@" + "]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:@"Use this for the PC that sends the audio: iOS can list it as an output because it is connected over "
                @"Bluetooth, and playing there is silent. You can clear the list at any time."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak __typeof__(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Never play there" style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *chosen) {
        NSMutableArray<NSDictionary *> *list = [[weakSelf neverList] mutableCopy];
        for (NSDictionary *candidate in candidates) {
            NSString *uid = BTPSString(candidate[@"uid"]);
            NSString *name = BTPSString(candidate[@"name"]);
            BOOL known = NO;
            for (NSDictionary *item in list)
                if ((uid.length && [BTPSString(item[@"uid"]) isEqualToString:uid]) ||
                    (name.length && [BTPSString(item[@"name"]) isEqualToString:name])) known = YES;
            if (!known && (uid.length || name.length)) [list addObject:@{ @"uid": uid, @"name": name }];
        }
        if (!BTPSWritePref(@BTPS_KEY_V89_NEVER, list)) {
            [weakSelf say:@"Could not save the never-play list."];
            return;
        }
        notify_post(BTPS_NOTIFY_V89_OUTPUT);
        [weakSelf reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearNeverPlay:(id)specifier
{
    BTPSWritePref(@BTPS_KEY_V89_NEVER, nil);
    notify_post(BTPS_NOTIFY_V89_OUTPUT);
    [self reloadSpecifiers];
    [self say:@"The never-play list is now empty."];
}

#pragma mark - alerts

- (void)say:(NSString *)message
{
    [self alertWithTitle:nil message:message];
}

- (void)alertWithTitle:(NSString *)title message:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end
