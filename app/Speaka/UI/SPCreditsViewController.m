//
//  SPCreditsViewController.m
//  Speaka
//

#import "SPCreditsViewController.h"
#import "SPGlobalAppearance.h"
#import "SPTheme.h"

@implementation SPCreditsViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [SPTheme windowColorWithAlpha:1.0];
    self.view.layer.cornerRadius = 14;
    self.view.layer.cornerCurve = kCACornerCurveContinuous;
    self.view.layer.masksToBounds = YES;

    UILabel *titleLabel = [[UILabel alloc] init];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    titleLabel.text = @"Credits";
    titleLabel.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.accessibilityTraits = UIAccessibilityTraitHeader;
    [self.view addSubview:titleLabel];

    __weak __typeof__(self) weakSelf = self;
    UIButtonConfiguration *closeConfiguration = [SPGlobalAppearance defaultButtonConfiguration];
    closeConfiguration.image = [UIImage systemImageNamed:@"xmark" withConfiguration:[SPGlobalAppearance smallIconImageConfiguration]];
    UIButton *closeButton = [UIButton buttonWithConfiguration:closeConfiguration primaryAction:[UIAction actionWithHandler:^(__kindof UIAction *action) {
        [weakSelf.navigationController popViewControllerAnimated:YES];
    }]];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    closeButton.accessibilityLabel = @"Close";
    [self.view addSubview:closeButton];

    UITextView *textView = [[UITextView alloc] init];
    textView.translatesAutoresizingMaskIntoConstraints = NO;
    textView.editable = NO;
    textView.backgroundColor = [UIColor clearColor];
    textView.textContainerInset = UIEdgeInsetsMake(4, 18, 22, 18);
    textView.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    textView.attributedText = [self creditsText];
    [self.view addSubview:textView];

    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:20],
        [titleLabel.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:22],
        [closeButton.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
        [closeButton.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-10],
        [textView.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:12],
        [textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [textView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
}

- (NSAttributedString *)creditsText
{
    NSDictionary *heading = @{ NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold],
                               NSForegroundColorAttributeName: [UIColor whiteColor] };
    NSDictionary *body = @{ NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightRegular],
                            NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.8] };
    NSDictionary *license = @{ NSFontAttributeName: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular],
                               NSForegroundColorAttributeName: [UIColor colorWithWhite:1 alpha:0.6] };

    NSString *path = [[NSBundle mainBundle] pathForResource:@"LICENSE-Dopamine" ofType:@"txt"];
    NSString *licenseText = path ? [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] : nil;
    if (!licenseText.length)
        licenseText = @"MIT License\n\nCopyright (c) 2023-2024 Lars Fröder (opa334)";

    NSMutableAttributedString *text = [[NSMutableAttributedString alloc] init];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"Speaka\n" attributes:heading]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:
        @"The app for the Speaka tweak, which turns this iPhone into a Bluetooth speaker for your PC.\n\n"
        attributes:body]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:@"User interface\n" attributes:heading]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:
        @"Adapted from Dopamine by Lars Fröder (opa334) and its contributors, used under the MIT License:\n\n"
        attributes:body]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:licenseText attributes:license]];
    return text;
}

// VoiceOver's two-finger scrub closes the card, like tapping outside it.
- (BOOL)accessibilityPerformEscape
{
    [self.navigationController popViewControllerAnimated:YES];
    return YES;
}

- (UIStatusBarStyle)preferredStatusBarStyle
{
    return UIStatusBarStyleLightContent;
}

@end
