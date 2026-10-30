//
//  main.m
//  Speaka
//

#import <UIKit/UIKit.h>
#import "SPAppDelegate.h"

int main(int argc, char *argv[])
{
    NSString *appDelegateClassName;
    @autoreleasepool {
        appDelegateClassName = NSStringFromClass([SPAppDelegate class]);
    }
    return UIApplicationMain(argc, argv, nil, appDelegateClassName);
}
