//
//  SPConnectedDevice.m
//  Speaka
//
//  Nothing here is required for the speaker to work: every private call is checked with respondsToSelector:
//  first, and any failure just means the connection banner shows "Your PC" instead of the PC's name.
//

#import "SPConnectedDevice.h"
#import <dlfcn.h>
#import <objc/message.h>

// The Bluetooth "Computer" major device class, as BluetoothDevice may report it (masked CoD value or plain index).
static const unsigned int SPMajorClassComputerMasked = 0x100;
static const unsigned int SPMajorClassComputerIndex = 1;

static Class SPBluetoothManagerClass(void)
{
    static Class managerClass = Nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dlopen("/System/Library/PrivateFrameworks/BluetoothManager.framework/BluetoothManager", RTLD_LAZY);
        managerClass = NSClassFromString(@"BluetoothManager");
    });
    return managerClass;
}

@implementation SPConnectedDevice

+ (NSString *)connectedComputerName
{
    Class managerClass = SPBluetoothManagerClass();
    if (!managerClass || ![managerClass respondsToSelector:@selector(sharedInstance)])
        return nil;
    @try {
        id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(sharedInstance));
        if (![manager respondsToSelector:@selector(connectedDevices)])
            return nil;
        id devices = ((id (*)(id, SEL))objc_msgSend)(manager, @selector(connectedDevices));
        if (![devices isKindOfClass:[NSArray class]])
            return nil;
        NSString *onlyName = nil;
        NSUInteger named = 0;
        for (id device in (NSArray *)devices) {
            if (![device respondsToSelector:@selector(name)])
                continue;
            id name = ((id (*)(id, SEL))objc_msgSend)(device, @selector(name));
            if (![name isKindOfClass:[NSString class]] || ((NSString *)name).length == 0)
                continue;
            if ([device respondsToSelector:@selector(majorClass)]) {
                unsigned int major = ((unsigned int (*)(id, SEL))objc_msgSend)(device, @selector(majorClass));
                if (major == SPMajorClassComputerMasked || major == SPMajorClassComputerIndex)
                    return name;
            }
            onlyName = name;
            named++;
        }
        // Without a class to go on, a name is only certain when exactly one device is connected.
        return named == 1 ? onlyName : nil;
    } @catch (NSException *exception) {
        return nil;
    }
}

@end
