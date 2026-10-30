//
//  SPBigButton.m
//  Speaka
//
//  Adapted from Dopamine's DOJailbreakButton.m.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import "SPBigButton.h"
#import "SPDoubleHelixIndicator.h"
#import "SPGlobalAppearance.h"
#import "SPTheme.h"

@interface SPBigButton ()
@property (nonatomic, readwrite) SPActionMenuButton *button;
@property (nonatomic, readwrite, getter=isBusy) BOOL busy;
@property (nonatomic) UIView *busyView;
@property (nonatomic) UILabel *busyLabel;
@property (nonatomic, copy) NSString *shownTitle;
@property (nonatomic, copy) NSString *shownSymbol;
@end

@implementation SPBigButton

- (instancetype)initWithAction:(UIAction *)action
{
    if (self = [super init]) {
        _enabled = YES;
        self.backgroundColor = [SPTheme menuColorWithAlpha:1.0];
        self.layer.cornerRadius = 14;
        self.layer.masksToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.translatesAutoresizingMaskIntoConstraints = NO;

        self.button = [SPActionMenuButton buttonWithTitle:action.title image:action.image action:action chevron:NO];
        [self.button setContentHorizontalAlignment:UIControlContentHorizontalAlignmentCenter];
        self.button.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:self.button];
        [NSLayoutConstraint activateConstraints:@[
            [self.button.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.button.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.button.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.button.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];

        // The working state: Dopamine's "Jailbreaking" title with the double helix beside it (see setupTitle).
        self.busyView = [[UIView alloc] init];
        self.busyView.translatesAutoresizingMaskIntoConstraints = NO;
        self.busyView.userInteractionEnabled = NO;
        self.busyView.alpha = 0.0;
        [self addSubview:self.busyView];

        self.busyLabel = [[UILabel alloc] init];
        self.busyLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.busyLabel.textColor = [UIColor whiteColor];
        self.busyLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightRegular];
        self.busyLabel.textAlignment = NSTextAlignmentCenter;
        self.busyLabel.adjustsFontSizeToFitWidth = YES;
        self.busyLabel.minimumScaleFactor = 0.7;
        [self.busyView addSubview:self.busyLabel];

        SPDoubleHelixIndicator *indicator = [[SPDoubleHelixIndicator alloc] init];
        indicator.translatesAutoresizingMaskIntoConstraints = NO;
        [self.busyView addSubview:indicator];

        [NSLayoutConstraint activateConstraints:@[
            [self.busyView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.busyView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.busyView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.busyView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [self.busyLabel.centerXAnchor constraintEqualToAnchor:self.busyView.centerXAnchor constant:20],
            [self.busyLabel.centerYAnchor constraintEqualToAnchor:self.busyView.centerYAnchor],
            [self.busyLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.busyView.trailingAnchor constant:-8],
            [indicator.trailingAnchor constraintEqualToAnchor:self.busyLabel.leadingAnchor constant:-10],
            [indicator.centerYAnchor constraintEqualToAnchor:self.busyLabel.centerYAnchor],
            [indicator.widthAnchor constraintEqualToConstant:30],
            [indicator.heightAnchor constraintEqualToConstant:12],
        ]];
    }
    return self;
}

- (void)setTitle:(NSString *)title symbolName:(NSString *)symbolName
{
    if ([title isEqualToString:self.shownTitle] && [symbolName isEqualToString:self.shownSymbol])
        return;
    self.shownTitle = title;
    self.shownSymbol = symbolName;
    UIButtonConfiguration *configuration = self.button.configuration;
    configuration.title = title;
    configuration.image = [UIImage systemImageNamed:symbolName withConfiguration:[SPGlobalAppearance smallIconImageConfiguration]];
    self.button.configuration = configuration;
}

- (void)setBusy:(BOOL)busy title:(NSString *)title
{
    if (busy == self.busy && (!busy || [title isEqualToString:self.busyLabel.text]))
        return;
    self.busy = busy;
    self.busyLabel.text = title;
    [self applyInteraction];
    [UIView animateWithDuration:0.2 animations:^{
        self.button.alpha = busy ? 0.0 : 1.0;
        self.busyView.alpha = busy ? 1.0 : 0.0;
    }];
    if (busy)
        UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, title);
}

// As in Dopamine: a disabled button stays visible at 70% and stops taking touches.
- (void)setEnabled:(BOOL)enabled
{
    if (enabled == _enabled)
        return;
    _enabled = enabled;
    [self applyInteraction];
}

- (void)applyInteraction
{
    BOOL interactive = self.enabled && !self.busy;
    self.button.userInteractionEnabled = interactive;
    self.alpha = (self.enabled || self.busy) ? 1.0 : 0.7;
    if (interactive)
        self.button.accessibilityTraits &= ~UIAccessibilityTraitNotEnabled;
    else
        self.button.accessibilityTraits |= UIAccessibilityTraitNotEnabled;
}

@end
