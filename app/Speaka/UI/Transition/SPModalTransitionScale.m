//
//  SPModalTransitionScale.m
//  Speaka
//
//  Dopamine's DOModalTransitionScale.m, renamed.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import "SPModalTransitionScale.h"

@interface SPModalTransitionScale ()
@property (nonatomic, assign) BOOL forwards;
@end

@implementation SPModalTransitionScale

- (instancetype)initForwards:(BOOL)forwards
{
    self = [super init];
    if (self) {
        _forwards = forwards;
    }
    return self;
}

- (NSTimeInterval)transitionDuration:(nullable id<UIViewControllerContextTransitioning>)transitionContext
{
    return 0.5;
}

- (void)animateTransition:(id<UIViewControllerContextTransitioning>)transitionContext
{
    UIViewController *toViewController = [transitionContext viewControllerForKey:UITransitionContextToViewControllerKey];
    UIViewController *fromViewController = [transitionContext viewControllerForKey:UITransitionContextFromViewControllerKey];
    [[transitionContext containerView] addSubview:toViewController.view];

    CGFloat scaleIn = _forwards ? 0.7 : 0.9;
    CGFloat scaleOut = _forwards ? 0.9 : 0.7;

    toViewController.view.alpha = 0;
    toViewController.view.transform = CGAffineTransformScale(CGAffineTransformIdentity, scaleIn, scaleIn);

    [UIView animateWithDuration:0.2 animations:^{
        fromViewController.view.alpha = 0;
    }];
    [UIView animateWithDuration:0.6 delay:0.0 usingSpringWithDamping:0.9 initialSpringVelocity:2.0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        toViewController.view.alpha = 1;
        toViewController.view.transform = CGAffineTransformIdentity;
        fromViewController.view.transform = CGAffineTransformScale(CGAffineTransformIdentity, scaleOut, scaleOut);
    } completion:^(BOOL finished) {
        fromViewController.view.transform = CGAffineTransformIdentity;
        [transitionContext completeTransition:!transitionContext.transitionWasCancelled];
    }];
}

@end
