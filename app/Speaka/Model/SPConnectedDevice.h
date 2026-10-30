//
//  SPConnectedDevice.h
//  Speaka
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPConnectedDevice : NSObject

/// Best effort: the name of the connected Bluetooth computer, read through the private BluetoothManager framework.
/// Returns nil whenever the framework is unavailable or reports nothing it can be sure of; callers then say
/// "Your PC". Call on the main thread.
+ (nullable NSString *)connectedComputerName;

@end

NS_ASSUME_NONNULL_END
