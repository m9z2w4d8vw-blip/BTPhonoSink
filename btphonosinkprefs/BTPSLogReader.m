// BTPSLogReader.m
#import "BTPSLogReader.h"

#import <CoreFoundation/CoreFoundation.h>
#include <notify.h>

#import "BTPSShared.h"

// One snapshot of everything readable from the channels.
@interface BTPSSnapshot : NSObject
@property (nonatomic, copy) NSArray<NSString *> *prefLines;
@property (nonatomic, copy) NSDictionary<NSString *, NSString *> *status;
@property (nonatomic, copy) NSArray<NSString *> *tmpFileLines;
@property (nonatomic, copy) NSArray<NSString *> *altFileLines;
@property (nonatomic, copy) NSString *tmpFileNote;      // why it could not be read, or @"ok"
@property (nonatomic, copy) NSString *altFileNote;
@property (nonatomic, assign) BOOL notifyOK;
@property (nonatomic, assign) uint64_t notifyState;
@end
@implementation BTPSSnapshot
@end

@implementation BTPSLogReader

+ (instancetype)shared
{
    static BTPSLogReader *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[BTPSLogReader alloc] init]; });
    return instance;
}

#pragma mark - reading

static id CopyPreference(NSString *key)
{
    CFPreferencesSynchronize(CFSTR(BTPS_PREFS_DOMAIN), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPropertyListRef v = CFPreferencesCopyValue((__bridge CFStringRef)key, CFSTR(BTPS_PREFS_DOMAIN),
                                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    return CFBridgingRelease(v);
}

static NSArray<NSString *> *ReadFileLines(NSString *path, NSString **note)
{
    NSError *error = nil;
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (!text) {
        *note = error ? [NSString stringWithFormat:@"not readable (%@)", error.localizedFailureReason ?: error.localizedDescription]
                      : @"not readable";
        return @[];
    }
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    while (lines.count && [lines.lastObject length] == 0) [lines removeLastObject];
    if (lines.count > 480) [lines removeObjectsInRange:NSMakeRange(0, lines.count - 480)];
    *note = lines.count ? @"ok" : @"empty";
    return lines;
}

- (BTPSSnapshot *)snapshot
{
    BTPSSnapshot *s = [[BTPSSnapshot alloc] init];

    id lines = CopyPreference(@BTPS_KEY_LOG);
    s.prefLines = [lines isKindOfClass:[NSArray class]] ? lines : @[];
    id status = CopyPreference(@BTPS_KEY_STATUS);
    s.status = [status isKindOfClass:[NSDictionary class]] ? status : @{};

    NSString *note = nil;
    s.tmpFileLines = ReadFileLines(@BTPS_LOG_FILE_TMP, &note);
    s.tmpFileNote = note;
    s.altFileLines = ReadFileLines(@BTPS_LOG_FILE_ALT, &note);
    s.altFileNote = note;

    int token = 0;
    if (notify_register_check(BTPS_NOTIFY_STATE, &token) == NOTIFY_STATUS_OK) {
        uint64_t state = 0;
        if (notify_get_state(token, &state) == NOTIFY_STATUS_OK && state != 0) {
            s.notifyOK = YES;
            s.notifyState = state;
        }
        notify_cancel(token);
    }
    return s;
}

// Prefer the current daemon's in-memory ring copied through preferences.
// File channels append across daemon sessions, so "most lines wins" can show
// stale v4 events in place of a smaller, current v6 session!
- (NSArray<NSString *> *)bestLines:(BTPSSnapshot *)s source:(NSString **)name
{
    if (s.prefLines.count) { *name = @"preferences (current captured session)"; return s.prefLines; }
    if (s.tmpFileLines.count) { *name = @"file in /tmp/FTABHarvest (may span sessions)"; return s.tmpFileLines; }
    if (s.altFileLines.count) { *name = @"file in /var/mobile/Library/Logs (may span sessions)"; return s.altFileLines; }
    *name = @"none";
    return @[];
}

#pragma mark - summaries for the main screen

- (NSString *)loadedSummary
{
    BTPSSnapshot *s = [self snapshot];
    NSString *src = nil;
    NSArray<NSString *> *lines = [self bestLines:s source:&src];

    unsigned loaded = 0, uuidOK = 0, experiments = 0, hooksOK = 0, hooksBad = 0;
    uint32_t last = 0;
    BOOL known = NO;
    if (s.notifyOK) {
        btps_state_unpack(s.notifyState, &loaded, &uuidOK, &experiments, &hooksOK, &hooksBad, &last);
        known = loaded == 1;
    }
    if (!known && (lines.count || s.status.count)) {
        // No notification state: fall back to the status dictionary.
        unsigned ok = 0, bad = 0;
        for (NSString *k in s.status) {
            if (![k hasPrefix:@"hook."]) continue;
            if ([s.status[k] isEqualToString:@"installed"]) ok++; else bad++;
        }
        hooksOK = ok; hooksBad = bad; known = YES;
        uuidOK = [s.status[@"image.match"] hasPrefix:@"yes"];
    }
    if (!known) return @"No data yet";
    if (!uuidOK) return @"Yes - unknown daemon build, no hooks";
    return [NSString stringWithFormat:@"Yes - %u hook%s%@", hooksOK, hooksOK == 1 ? "" : "s",
            hooksBad ? [NSString stringWithFormat:@", %u skipped", hooksBad] : @""];
}

- (NSString *)lastEventSummary
{
    BTPSSnapshot *s = [self snapshot];
    NSString *last = s.status[@"last_event"];
    if (last.length) return last;
    NSString *src = nil;
    NSArray<NSString *> *lines = [self bestLines:s source:&src];
    if (lines.count) {
        NSString *l = lines.lastObject;
        return l.length > 28 ? [l substringToIndex:28] : l;
    }
    return @"-";
}

- (NSString *)channelSummary
{
    BTPSSnapshot *s = [self snapshot];
    return [NSString stringWithFormat:@"prefs %@, file %@, notify %@",
            s.prefLines.count ? @"yes" : @"no",
            (s.tmpFileLines.count || s.altFileLines.count) ? @"yes" : @"no",
            s.notifyOK ? @"yes" : @"no"];
}

#pragma mark - the debug log screen

- (NSString *)fullText
{
    BTPSSnapshot *s = [self snapshot];
    NSString *src = nil;
    NSArray<NSString *> *lines = [self bestLines:s source:&src];

    NSMutableString *out = [NSMutableString string];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"HH:mm:ss";
    [out appendFormat:@"BTPhonoSink debug log - read at %@\n\n", [fmt stringFromDate:[NSDate date]]];

    NSUInteger hookCount = 0;
    for (NSString *key in s.status) {
        if ([key hasPrefix:@"hook."] && [s.status[key] isEqualToString:@"installed"]) hookCount++;
    }
    [out appendString:@"== SESSION AND CHECKLIST ==\n"];
    [out appendFormat:@"build: %@ | pid: %@ | session: %@\n",
        s.status[@"build"] ?: @"unknown", s.status[@"pid"] ?: @"unknown",
        s.status[@"diag.session_id"] ?: @"unknown"];
    [out appendFormat:@"hooks installed: %lu / 5 | native sources: %@ / 6 seen previously\n",
        (unsigned long)hookCount,
        s.status[@"diag.native_source_ok"] ?: @"unknown"];
    [out appendFormat:@"Sink SDP 0x110B: %@\n", s.status[@"diag.sdp_sink_0x110b"] ?: @"not measured"];
    [out appendFormat:@"Incoming audio path: %@\n", s.status[@"diag.audio_receive"] ?: @"not measured"];
    [out appendFormat:@"Configuration callback: %@ | SBC acceptance callback: %@\n",
        s.status[@"seen.SetConfigInd_handler"] ?: @"not seen in current captured status",
        s.status[@"seen.SetConfig_accept_SBC"] ?: @"not seen in current captured status"];
    if (s.notifyOK) {
        unsigned l, u, e, ok, bad; uint32_t t;
        btps_state_unpack(s.notifyState, &l, &u, &e, &ok, &bad, &t);
        NSTimeInterval age = [[NSDate date] timeIntervalSince1970] - (NSTimeInterval)t;
        if (t && age > 180)
            [out appendFormat:@"WARNING: last daemon event is %.0f seconds old; status may be stale.\n", age];
    }
    NSString *localTest = [[NSUserDefaults standardUserDefaults] stringForKey:@"BTPSAudioTestLastResult"];
    [out appendFormat:@"\n== SETTINGS PROCESS AUDIO SELF-TEST ==\n%@\n",
                      localTest ?: @"Not run on this installation. Use the Debug log audio test button."];
    [out appendString:@"This test runs in Preferences.app; it cannot verify receiving Bluetooth audio.\n"];
    NSString *ipcTest = [[NSUserDefaults standardUserDefaults] stringForKey:@"BTPSIPCPlaybackLastResult"];
    [out appendFormat:@"\n== V7.3 INTERPROCESS AUDIO TEST ==\n%@\n",
                      ipcTest ?: @"Not yet run. Start BTPSAudioHelper over SSH; then send PCM from the Debug log button."];
    [out appendString:@"IPC transfer is local to this phone; it does not prove Bluetooth reception or helper audio privileges.\n"];
    NSString *sbcRequest=[[NSUserDefaults standardUserDefaults] stringForKey:@"BTPSV75SBCRequestLastResult"];
    [out appendString:@"\n== V7.5 COMPRESSED SBC RTP TEST ==\n"];
    if(sbcRequest.length)[out appendFormat:@"%@\n",sbcRequest];
    [out appendFormat:@"Daemon status: %@\nThis tests a pre-generated compressed SBC fixture, NOT Bluetooth reception or audio decoding.\n",s.status[@"diag.v75_sbc"]?:@"No result yet."];

    NSString *daemonIPCTest = [[NSUserDefaults standardUserDefaults] stringForKey:@"BTPSDaemonIPCRequestLastResult"];
    [out appendFormat:@"\n== V7.4 BLUETOOTHD-TO-HELPER REQUEST ==\n%@\n",
                      daemonIPCTest ?: @"Not run. Start BTPSAudioHelper --daemon in SSH, then use the Settings button."];
    [out appendFormat:@"Daemon status: %@\n", s.status[@"diag.v74_ipc"] ?: @"No daemon IPC result observed yet."];
    [out appendString:@"A posted notification is NOT a receipt. Look for IPC_RECEIVED on SSH and an actual audible 880 Hz tone. This does not receive Bluetooth media.\n"];

    [out appendString:@"\n== STATUS (written by the tweak inside the daemon) ==\n"];
    if (s.status.count == 0) {
        [out appendString:@"(nothing yet)\n"];
    } else {
        for (NSString *k in [s.status.allKeys sortedArrayUsingSelector:@selector(compare:)])
            [out appendFormat:@"%@: %@\n", k, s.status[k]];
    }

    [out appendString:@"\n== WHAT THIS SCREEN COULD READ ==\n"];
    [out appendFormat:@"preferences : %lu line(s)\n", (unsigned long)s.prefLines.count];
    [out appendFormat:@"/tmp/FTABHarvest file : %@ (%lu line(s))\n", s.tmpFileNote, (unsigned long)s.tmpFileLines.count];
    [out appendFormat:@"/var/mobile/Library/Logs file : %@ (%lu line(s))\n", s.altFileNote, (unsigned long)s.altFileLines.count];
    if (s.notifyOK) {
        unsigned l, u, e, ok, bad; uint32_t last;
        btps_state_unpack(s.notifyState, &l, &u, &e, &ok, &bad, &last);
        [out appendFormat:@"notification state : loaded=%u uuid_ok=%u experiments=%u hooks_ok=%u hooks_bad=%u\n", l, u, e, ok, bad];
    } else {
        [out appendString:@"notification state : not available\n"];
    }

    [out appendFormat:@"\n== LOG (from %@, oldest first) ==\n", src];
    if (lines.count == 0) {
        [out appendString:@"(empty)\n\nIf this stays empty:\n"
                           "- the tweak is not loaded into the Bluetooth daemon (reboot and re-jailbreak with Dopamine), or\n"
                           "- the daemon's sandbox blocks every channel (the STATUS block above then says so once any channel works).\n"];
    } else {
        [out appendString:[lines componentsJoinedByString:@"\n"]];
        [out appendString:@"\n"];
    }
    return out;
}

#pragma mark - clearing

- (NSString *)clearAll
{
    NSMutableArray<NSString *> *done = [NSMutableArray array];

    CFPreferencesSetValue(CFSTR(BTPS_KEY_LOG), NULL, CFSTR(BTPS_PREFS_DOMAIN), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR(BTPS_PREFS_DOMAIN), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    [done addObject:@"preferences"];

    for (NSString *path in @[ @BTPS_LOG_FILE_TMP, @BTPS_LOG_FILE_ALT ]) {
        if (![[NSFileManager defaultManager] fileExistsAtPath:path]) continue;
        NSError *error = nil;
        if ([@"" writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:&error]) [done addObject:path.lastPathComponent];
    }
    return [NSString stringWithFormat:@"Cleared: %@.\nThe tweak refills it as new events happen.", [done componentsJoinedByString:@", "]];
}

@end
