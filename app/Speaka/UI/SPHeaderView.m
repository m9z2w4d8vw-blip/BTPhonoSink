//
//  SPHeaderView.m
//  Speaka
//
//  Adapted from Dopamine's DOHeaderView.m.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import "SPHeaderView.h"

@interface SPHeaderView ()
@property (nonatomic) UIStackView *stackView;
@property (nonatomic) UILabel *titleLabel;
@property (nonatomic) NSMutableArray<UILabel *> *subtitleLabels;
@end

@implementation SPHeaderView

- (instancetype)initWithTitle:(NSString *)title subtitles:(NSArray<NSAttributedString *> *)subtitles
{
    if (self = [super init]) {
        self.stackView = [[UIStackView alloc] init];
        self.stackView.axis = UILayoutConstraintAxisVertical;
        self.stackView.spacing = 2;
        self.stackView.translatesAutoresizingMaskIntoConstraints = NO;
        self.stackView.alignment = UIStackViewAlignmentLeading;
        [self addSubview:self.stackView];
        [NSLayoutConstraint activateConstraints:@[
            [self.stackView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.stackView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.stackView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.stackView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];

        // 1 - The title, where Dopamine shows its logo image (40 pt high there too)
        UIFont *font = [UIFont systemFontOfSize:38 weight:UIFontWeightHeavy];
        UIFontDescriptor *rounded = [font.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
        if (rounded)
            font = [UIFont fontWithDescriptor:rounded size:38];
        self.titleLabel = [[UILabel alloc] init];
        self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.text = title;
        self.titleLabel.font = font;
        self.titleLabel.textColor = [UIColor whiteColor];
        self.titleLabel.accessibilityTraits = UIAccessibilityTraitHeader;
        [self.stackView addArrangedSubview:self.titleLabel];
        [self.titleLabel.heightAnchor constraintEqualToConstant:46].active = YES;

        // 2 - The subtitles
        self.subtitleLabels = [NSMutableArray array];
        [self setSubtitles:subtitles];

        self.translatesAutoresizingMaskIntoConstraints = NO;
        // Dopamine's titleShadow, always on here: it keeps the text readable on the bright glows.
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeZero;
        self.layer.shadowRadius = 30;
        self.layer.shadowOpacity = 0.3;
    }
    return self;
}

- (void)setSubtitles:(NSArray<NSAttributedString *> *)subtitles
{
    for (UILabel *label in self.subtitleLabels)
        [label removeFromSuperview];
    [self.subtitleLabels removeAllObjects];
    for (NSAttributedString *formattedText in subtitles) {
        UILabel *label = [[UILabel alloc] init];
        label.attributedText = formattedText;
        label.numberOfLines = 1;
        label.adjustsFontSizeToFitWidth = YES;
        label.minimumScaleFactor = 0.8;
        label.translatesAutoresizingMaskIntoConstraints = NO;
        [self.stackView addArrangedSubview:label];
        [self.subtitleLabels addObject:label];
    }
}

@end
