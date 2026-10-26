#import <Foundation/Foundation.h>
/* A diagnostic-only sender in Preferences.app; never called from bluetoothd. */
@interface BTPSIPCSender : NSObject
+ (void)sendTestPCMWithToken:(uint32_t)token completion:(void (^)(NSString *result))completion;
@end
