//
//  SPSceneDelegate.m
//  Speaka
//
//  Adapted from Dopamine's DOSceneDelegate.m.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import "SPSceneDelegate.h"
#import "SPNavigationController.h"

@implementation SPSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions
{
    if (![scene isKindOfClass:[UIWindowScene class]])
        return;
    UIWindow *window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    window.rootViewController = [[SPNavigationController alloc] init];
    [window makeKeyAndVisible];
    self.window = window;
}

@end
