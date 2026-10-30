// BTPSLogReader.h - reads the debug log back from every channel the tweak writes to (see BTPSShared.h).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface BTPSLogReader : NSObject
+ (instancetype)shared;

/// Status block + channel report + the log lines. This is what the "Debug log" screen shows.
- (NSString *)fullText;

/// Short values for the rows on the main screen.
- (NSString *)loadedSummary;
- (NSString *)lastEventSummary;
- (NSString *)channelSummary;

/// Removes the log from every channel Settings is allowed to write to. Returns a one-line result for the user.
- (NSString *)clearAll;
@end

NS_ASSUME_NONNULL_END
