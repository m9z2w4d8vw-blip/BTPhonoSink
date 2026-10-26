#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

/* Runs in Preferences.app, NEVER in bluetoothd. This probes a permitted audio
 * output process only; it does not confirm live Bluetooth reception. */
@interface BTPSAudioProbe : NSObject <AVAudioPlayerDelegate>
@property(nonatomic,copy) void (^completion)(NSString *status);
- (BOOL)startWithError:(NSError **)error;
- (void)stop;
@end
