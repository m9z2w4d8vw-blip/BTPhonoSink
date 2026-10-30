//
//  SPActionMenuButton.m
//  Speaka
//
//  Adapted from Dopamine's DOActionMenuButton.m.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import "SPActionMenuButton.h"
#import "SPGlobalAppearance.h"

@interface SPActionMenuButton () {
    UIView *_separator;
}
@property (nonatomic) UIImpactFeedbackGenerator *feedbackGenerator;
@end

@implementation SPActionMenuButton

+ (SPActionMenuButton *)buttonWithAction:(UIAction *)action chevron:(BOOL)chevron
{
    SPActionMenuButton *button = [SPActionMenuButton buttonWithConfiguration:[SPGlobalAppearance defaultButtonConfiguration]
                                                               primaryAction:action];
    [button.titleLabel setAdjustsFontSizeToFitWidth:YES];
    [button setContentHorizontalAlignment:UIControlContentHorizontalAlignmentLeft];
    if ([SPGlobalAppearance isRTL])
        [button setContentHorizontalAlignment:UIControlContentHorizontalAlignmentRight];

    if (chevron) {
        UIImage *chevronImage = [UIImage systemImageNamed:@"chevron.right"];
        chevronImage = [chevronImage imageWithConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightRegular]];
        UIImageView *chevronView = [[UIImageView alloc] initWithImage:chevronImage];
        chevronView.translatesAutoresizingMaskIntoConstraints = NO;
        chevronView.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
        [button addSubview:chevronView];
        [NSLayoutConstraint activateConstraints:@[
            [chevronView.trailingAnchor constraintEqualToAnchor:button.trailingAnchor constant:-10],
            [chevronView.centerYAnchor constraintEqualToAnchor:button.centerYAnchor],
        ]];
    }

    button.feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [button addTarget:button action:@selector(buttonPressed) forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (void)buttonPressed
{
    [self.feedbackGenerator impactOccurred];
}

- (void)setBottomSeparator:(BOOL)bottomSeparator
{
    _bottomSeparator = bottomSeparator;
    if (_separator)
        [_separator removeFromSuperview];
    _separator = nil;
    if (bottomSeparator) {
        _separator = [[UIView alloc] init];
        _separator.backgroundColor = [UIColor colorWithWhite:0.6 alpha:0.3];
        _separator.translatesAutoresizingMaskIntoConstraints = NO;
        _separator.layer.cornerRadius = 0.5;
        _separator.layer.masksToBounds = YES;
        _separator.userInteractionEnabled = NO;
        [self addSubview:_separator];
        [NSLayoutConstraint activateConstraints:@[
            [_separator.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:10],
            [_separator.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10],
            [_separator.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [_separator.heightAnchor constraintEqualToConstant:1],
        ]];
    }
}

@end
