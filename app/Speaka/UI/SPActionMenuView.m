//
//  SPActionMenuView.m
//  Speaka
//
//  Adapted from Dopamine's DOActionMenuView.m.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import "SPActionMenuView.h"
#import "SPGlobalAppearance.h"
#import "SPTheme.h"

@interface SPActionMenuView ()
@property (nonatomic, readwrite) UIStackView *rowsView;
@end

@implementation SPActionMenuView

- (instancetype)initWithRows:(NSArray<UIView *> *)rows
{
    if (self = [super init]) {
        self.backgroundColor = [SPTheme menuColorWithAlpha:1.0];
        self.layer.cornerRadius = 14;
        self.layer.masksToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.translatesAutoresizingMaskIntoConstraints = NO;

        self.rowsView = [[UIStackView alloc] init];
        self.rowsView.axis = UILayoutConstraintAxisVertical;
        self.rowsView.translatesAutoresizingMaskIntoConstraints = NO;
        for (UIView *row in rows) {
            row.translatesAutoresizingMaskIntoConstraints = NO;
            [self.rowsView addArrangedSubview:row];
            [row.widthAnchor constraintEqualToAnchor:self.rowsView.widthAnchor].active = YES;
        }
        [self addSubview:self.rowsView];

        CGFloat innerPadding = [SPGlobalAppearance innerPadding];
        [NSLayoutConstraint activateConstraints:@[
            [self.rowsView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:innerPadding],
            [self.rowsView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-innerPadding],
            [self.rowsView.topAnchor constraintEqualToAnchor:self.topAnchor constant:UI_INNER_TOP_PADDING],
            [self.rowsView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-UI_INNER_TOP_PADDING],
        ]];
    }
    return self;
}

@end
