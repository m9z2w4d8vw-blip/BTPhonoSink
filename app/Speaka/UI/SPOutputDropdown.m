//
//  SPOutputDropdown.m
//  Speaka
//
//  Rows are SPActionMenuButtons (Dopamine's DOActionMenuButton), so the menu looks and feels like Dopamine's;
//  the unfolding uses Dopamine's spring animation.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import "SPOutputDropdown.h"
#import "SPActionMenuButton.h"
#import "SPGlobalAppearance.h"
#import "SPTheme.h"
#import "SPTweakClient.h"

@interface SPOutputDropdown ()
@property (nonatomic) SPActionMenuButton *headerButton;
@property (nonatomic) UIImageView *chevronView;
@property (nonatomic) UIView *optionsClip;
@property (nonatomic) UIStackView *optionsStack;
@property (nonatomic) NSLayoutConstraint *optionsHeight;
@property (nonatomic) NSMutableDictionary<NSString *, UIImageView *> *checkmarks;
@property (nonatomic) NSMutableDictionary<NSString *, SPActionMenuButton *> *optionRows;
@property (nonatomic, readwrite, getter=isExpanded) BOOL expanded;
@property (nonatomic) CGFloat rowHeight;
@end

@implementation SPOutputDropdown

- (instancetype)init
{
    if (self = [super init]) {
        _selectedMode = @"speaker";
        _checkmarks = [NSMutableDictionary dictionary];
        _optionRows = [NSMutableDictionary dictionary];
        _rowHeight = [SPGlobalAppearance actionRowHeight];
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.clipsToBounds = YES;

        // The button: "Audio output" with the current choice as its subtitle, and a chevron that turns over. The
        // choice is part of the button's own configuration, so it can never overlap the title, whatever the width.
        __weak __typeof__(self) weakSelf = self;
        UIAction *toggle = [UIAction actionWithHandler:^(__kindof UIAction *action) {
            [weakSelf setExpanded:!weakSelf.expanded animated:YES];
        }];
        UIImage *speaker = [UIImage systemImageNamed:@"speaker.wave.2" withConfiguration:[SPGlobalAppearance smallIconImageConfiguration]];
        self.headerButton = [SPActionMenuButton buttonWithTitle:@"Audio output" image:speaker action:toggle chevron:NO];
        UIButtonConfiguration *headerConfiguration = self.headerButton.configuration;
        headerConfiguration.titleAlignment = UIButtonConfigurationTitleAlignmentLeading;
        headerConfiguration.titlePadding = 2;
        NSDirectionalEdgeInsets headerInsets = headerConfiguration.contentInsets;
        headerInsets.trailing = 34;   // room for the chevron, which sits on top of the button
        headerConfiguration.contentInsets = headerInsets;
        headerConfiguration.subtitleTextAttributesTransformer = [SPOutputDropdown subtitleAttributes];
        self.headerButton.configuration = headerConfiguration;
        self.headerButton.translatesAutoresizingMaskIntoConstraints = NO;
        self.headerButton.bottomSeparator = YES;
        self.headerButton.accessibilityHint = @"Shows where the audio can play";
        [self addSubview:self.headerButton];

        UIImage *chevron = [UIImage systemImageNamed:@"chevron.down"
                                   withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:14 weight:UIImageSymbolWeightSemibold]];
        self.chevronView = [[UIImageView alloc] initWithImage:chevron];
        self.chevronView.translatesAutoresizingMaskIntoConstraints = NO;
        self.chevronView.tintColor = [UIColor colorWithWhite:1 alpha:0.6];
        self.chevronView.userInteractionEnabled = NO;
        [self.headerButton addSubview:self.chevronView];

        // The list it turns into: one row per output, revealed by growing the clip view's height.
        self.optionsClip = [[UIView alloc] init];
        self.optionsClip.translatesAutoresizingMaskIntoConstraints = NO;
        self.optionsClip.clipsToBounds = YES;
        self.optionsClip.alpha = 0.0;
        [self addSubview:self.optionsClip];

        self.optionsStack = [[UIStackView alloc] init];
        self.optionsStack.axis = UILayoutConstraintAxisVertical;
        self.optionsStack.translatesAutoresizingMaskIntoConstraints = NO;
        [self.optionsClip addSubview:self.optionsStack];

        NSArray<NSDictionary<NSString *, NSString *> *> *modes = [SPTweakClient outputModes];
        for (NSDictionary<NSString *, NSString *> *mode in modes)
            [self addOption:mode];

        self.optionsHeight = [self.optionsClip.heightAnchor constraintEqualToConstant:0];
        [NSLayoutConstraint activateConstraints:@[
            [self.headerButton.topAnchor constraintEqualToAnchor:self.topAnchor],
            [self.headerButton.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.headerButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.headerButton.heightAnchor constraintEqualToConstant:self.rowHeight],
            [self.chevronView.trailingAnchor constraintEqualToAnchor:self.headerButton.trailingAnchor constant:-10],
            [self.chevronView.centerYAnchor constraintEqualToAnchor:self.headerButton.centerYAnchor],
            [self.optionsClip.topAnchor constraintEqualToAnchor:self.headerButton.bottomAnchor],
            [self.optionsClip.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [self.optionsClip.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [self.optionsClip.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            self.optionsHeight,
            [self.optionsStack.topAnchor constraintEqualToAnchor:self.optionsClip.topAnchor],
            [self.optionsStack.leadingAnchor constraintEqualToAnchor:self.optionsClip.leadingAnchor],
            [self.optionsStack.trailingAnchor constraintEqualToAnchor:self.optionsClip.trailingAnchor],
        ]];
        [self updateSelection];
    }
    return self;
}

- (void)addOption:(NSDictionary<NSString *, NSString *> *)mode
{
    NSString *key = mode[@"key"];
    __weak __typeof__(self) weakSelf = self;
    UIAction *choose = [UIAction actionWithTitle:mode[@"title"]
                                           image:[UIImage systemImageNamed:mode[@"symbol"] withConfiguration:[SPGlobalAppearance smallIconImageConfiguration]]
                                      identifier:key
                                         handler:^(__kindof UIAction *action) {
        [weakSelf choose:key];
    }];
    SPActionMenuButton *row = [SPActionMenuButton buttonWithAction:choose chevron:NO];
    UIButtonConfiguration *configuration = row.configuration;
    configuration.subtitle = mode[@"detail"];
    configuration.titleAlignment = UIButtonConfigurationTitleAlignmentLeading;
    configuration.titlePadding = 2;
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(6, 18, 6, 34);   // indented; room for the checkmark
    configuration.subtitleTextAttributesTransformer = [SPOutputDropdown subtitleAttributes];
    row.configuration = configuration;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.bottomSeparator = YES;   // the list is always followed by another row of the menu
    [self.optionsStack addArrangedSubview:row];
    [row.heightAnchor constraintEqualToConstant:self.rowHeight].active = YES;

    UIImage *checkImage = [UIImage systemImageNamed:@"checkmark"
                                  withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold]];
    UIImageView *check = [[UIImageView alloc] initWithImage:checkImage];
    check.translatesAutoresizingMaskIntoConstraints = NO;
    check.tintColor = [SPTheme accentColor];
    check.userInteractionEnabled = NO;
    [row addSubview:check];
    [NSLayoutConstraint activateConstraints:@[
        [check.trailingAnchor constraintEqualToAnchor:row.trailingAnchor constant:-10],
        [check.centerYAnchor constraintEqualToAnchor:row.centerYAnchor],
    ]];
    self.checkmarks[key] = check;
    self.optionRows[key] = row;
}

// Subtitles in the menu: smaller and dimmer than the titles.
+ (UIConfigurationTextAttributesTransformer)subtitleAttributes
{
    return ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *attributes) {
        NSMutableDictionary<NSAttributedStringKey, id> *changed = attributes.mutableCopy;
        changed[NSForegroundColorAttributeName] = [UIColor colorWithWhite:1 alpha:0.6];
        changed[NSFontAttributeName] = [UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
        return changed;
    };
}

- (void)choose:(NSString *)key
{
    self.selectedMode = key;
    if (self.selectionHandler)
        self.selectionHandler(key);
    [self setExpanded:NO animated:YES];
}

- (void)setSelectedMode:(NSString *)selectedMode
{
    if ([selectedMode isEqualToString:_selectedMode])
        return;
    _selectedMode = [selectedMode copy];
    [self updateSelection];
}

- (void)updateSelection
{
    for (NSDictionary<NSString *, NSString *> *mode in [SPTweakClient outputModes]) {
        NSString *key = mode[@"key"];
        BOOL selected = [key isEqualToString:self.selectedMode];
        self.checkmarks[key].hidden = !selected;
        SPActionMenuButton *row = self.optionRows[key];
        if (selected) {
            UIButtonConfiguration *configuration = self.headerButton.configuration;
            configuration.subtitle = mode[@"title"];
            self.headerButton.configuration = configuration;
            self.headerButton.accessibilityValue = mode[@"title"];
            row.accessibilityTraits |= UIAccessibilityTraitSelected;
        } else {
            row.accessibilityTraits &= ~UIAccessibilityTraitSelected;
        }
    }
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated
{
    if (expanded == self.expanded)
        return;
    self.expanded = expanded;
    UIView *root = self.window ?: self.superview;
    [root layoutIfNeeded];
    self.optionsHeight.constant = expanded ? self.rowHeight * (CGFloat)self.optionsStack.arrangedSubviews.count : 0;
    void (^changes)(void) = ^{
        self.optionsClip.alpha = expanded ? 1.0 : 0.0;
        // Just under half a turn, so it turns clockwise when opening and back when closing.
        self.chevronView.transform = expanded ? CGAffineTransformMakeRotation((CGFloat)(M_PI * 0.999)) : CGAffineTransformIdentity;
        [root layoutIfNeeded];
    };
    if (animated)
        [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:2.0
                            options:UIViewAnimationOptionCurveEaseInOut animations:changes completion:nil];
    else
        changes();
    UIAccessibilityPostNotification(UIAccessibilityLayoutChangedNotification,
                                    expanded ? self.optionsStack.arrangedSubviews.firstObject : self.headerButton);
}

@end
