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
    if (lines.count > 300) [lines removeObjectsInRange:NSMakeRange(0, lines.count - 300)];
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

// The source with the most lines wins (the tweak writes the same lines to all of them).
- (NSArray<NSString *> *)bestLines:(BTPSSnapshot *)s source:(NSString **)name
{
    NSArray<NSString *> *best = s.prefLines;
    *name = @"preferences";
    if (s.tmpFileLines.count > best.count) { best = s.tmpFileLines; *name = @"file in /tmp/FTABHarvest"; }
    if (s.altFileLines.count > best.count) { best = s.altFileLines; *name = @"file in /var/mobile/Library/Logs"; }
    if (best.count == 0) *name = @"none";
    return best;
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

    [out appendString:@"== STATUS (written by the tweak inside the daemon) ==\n"];
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
                           "- the tweak is not loaded into the Bluetooth daemon (restart it: killall -9 bluetoothd), or\n"
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
