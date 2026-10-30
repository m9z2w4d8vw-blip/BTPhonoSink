//
//  SPNavigationController.m
//  Speaka
//
//  Adapted from Dopamine's DONavigationController.m: the full-screen background, the dimming behind cards, the
//  card-sized frame for pushed screens and the scale/push transitions. The background is Speaka's own.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import "SPNavigationController.h"
#include <math.h>
#import "SPGlobalAppearance.h"
#import "SPMainViewController.h"
#import "SPModalBackAction.h"
#import "SPModalTransitionPush.h"
#import "SPModalTransitionScale.h"
#import "SPTheme.h"

@interface SPNavigationController ()
@property (nonatomic) UIImageView *backgroundImageView;
@property (nonatomic) SPModalBackAction *backAction;
@property (nonatomic) CGSize backgroundSize;
@end

@interface UINavigationController (Private)
- (CGRect)_frameForViewController:(id)viewController;
@end

@implementation SPNavigationController

- (void)viewDidLoad
{
    [self setupBackground];
    [super viewDidLoad];
    [self setNavigationBarHidden:YES];
    [self pushViewController:[[SPMainViewController alloc] init] animated:NO];
    [self setDelegate:self];
    [self setOverrideUserInterfaceStyle:UIUserInterfaceStyleDark];
}

- (void)setupBackground
{
    self.view.backgroundColor = [UIColor blackColor];
    self.backgroundImageView = [[UIImageView alloc] init];
    self.backgroundImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.backgroundImageView.translatesAutoresizingMaskIntoConstraints = NO;
    self.backgroundImageView.userInteractionEnabled = NO;
    self.backgroundImageView.layer.zPosition = -1;
    [self.view insertSubview:self.backgroundImageView atIndex:0];
    [NSLayoutConstraint activateConstraints:@[
        [self.backgroundImageView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.backgroundImageView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.backgroundImageView.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:-100],
        [self.backgroundImageView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:100],
    ]];

    __weak __typeof__(self) weakSelf = self;
    self.backAction = [[SPModalBackAction alloc] initWithAction:^{
        [weakSelf popViewControllerAnimated:YES];
    }];
    self.backAction.translatesAutoresizingMaskIntoConstraints = NO;
    self.backAction.hidden = YES;
    [self.view insertSubview:self.backAction atIndex:2];
    [NSLayoutConstraint activateConstraints:@[
        [self.backAction.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.backAction.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.backAction.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.backAction.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

// Speaka draws the background for the actual screen size (Dopamine loads a photo), again after a rotation.
- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGSize size = self.view.bounds.size;
    if (size.width > 0 && !CGSizeEqualToSize(size, self.backgroundSize)) {
        self.backgroundSize = size;
        self.backgroundImageView.image = [SPTheme backgroundImageWithSize:CGSizeMake(size.width, size.height + 200)];
    }
}

- (void)setBackgroundDimmed:(BOOL)dimmed
{
    [UIView animateWithDuration:0.3 animations:^{
        self.backgroundImageView.alpha = dimmed ? 0.4 : 1;
    }];
    self.backgroundImageView.userInteractionEnabled = dimmed;
    self.backAction.hidden = !dimmed;
}

- (UIViewController *)childViewControllerForStatusBarStyle
{
    return self.topViewController;
}

- (UIViewController *)childViewControllerForStatusBarHidden
{
    return self.topViewController;
}

#pragma mark - Delegate

- (id<UIViewControllerAnimatedTransitioning>)navigationController:(UINavigationController *)navigationController
                                  animationControllerForOperation:(UINavigationControllerOperation)operation
                                               fromViewController:(UIViewController *)fromVC
                                                 toViewController:(UIViewController *)toVC
{
    if (fromVC.class == SPMainViewController.class || toVC.class == SPMainViewController.class)
        return [[SPModalTransitionScale alloc] initForwards:operation == UINavigationControllerOperationPush];
    return [[SPModalTransitionPush alloc] initForwards:operation == UINavigationControllerOperationPush];
}

- (void)navigationController:(UINavigationController *)navigationController
      willShowViewController:(UIViewController *)viewController
                    animated:(BOOL)animated
{
    [self setBackgroundDimmed:![viewController isKindOfClass:[SPMainViewController class]]];
    [self.backAction setIgnoreFrame:[self _frameForViewController:viewController]];
}

#pragma mark - Overrides

// Pushed screens become centred cards, as in Dopamine.
- (CGRect)_frameForViewController:(id)viewController
{
    CGRect orig = [super _frameForViewController:viewController];
    if ([[viewController class] isEqual:[SPMainViewController class]])
        return orig;
    orig.size.width = fmin(orig.size.width - UI_MODAL_PADDING * 2, UI_IPAD_MAX_WIDTH);
    orig.size.height *= [SPGlobalAppearance isSmallDevice] ? 0.8 : 0.7;
    orig.origin.x = (self.view.frame.size.width - orig.size.width) / 2;
    orig.origin.y = (self.view.frame.size.height - orig.size.height) / 2;
    return orig;
}

@end
