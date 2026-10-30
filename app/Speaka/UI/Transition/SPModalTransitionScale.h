//
//  SPModalTransitionScale.h
//  Speaka
//
//  Dopamine's DOModalTransitionScale.h, renamed.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface SPModalTransitionScale : NSObject <UIViewControllerAnimatedTransitioning>

- (instancetype)initForwards:(BOOL)forwards;

@end

NS_ASSUME_NONNULL_END
