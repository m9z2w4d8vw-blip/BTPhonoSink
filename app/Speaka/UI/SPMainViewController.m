//
//  SPMainViewController.m
//  Speaka
//
//  The layout follows Dopamine's DOMainViewController.m (created by tomt000 on 08/01/2024): a vertically centred
//  stack of the header, the menu and the big button. Speaka adds the connection banner and a second big button.
//  Dopamine: Copyright (c) 2023-2024 Lars Fröder (opa334), MIT License (see LICENSE-Dopamine.txt).
//

#import "SPMainViewController.h"
#include <math.h>
#import "SPActionMenuButton.h"
#import "SPActionMenuView.h"
#import "SPBigButton.h"
#import "SPConnectedDevice.h"
#import "SPCreditsViewController.h"
#import "SPGlobalAppearance.h"
#import "SPHeaderView.h"
#import "SPMarqueeView.h"
#import "SPOutputDropdown.h"
#import "SPTheme.h"
#import "SPTweakClient.h"

static NSString *const SPSeparator = @"  \u00B7  ";   // "  ·  " between the parts of the banner text

@interface SPMainViewController ()
@property (nonatomic) SPHeaderView *headerView;
@property (nonatomic) SPMarqueeView *connectionView;
@property (nonatomic) SPOutputDropdown *outputDropdown;
@property (nonatomic) SPBigButton *startButton;
@property (nonatomic) SPBigButton *stopButton;
@property (nonatomic, nullable) NSTimer *refreshTimer;
@property (nonatomic, nullable) SPRequest *request;
@property (nonatomic, copy, nullable) NSString *headerLine;
@property (nonatomic, copy, nullable) NSString *computerName;
@property (nonatomic, nullable) NSDate *computerNameDate;
@property (nonatomic, nullable) NSDate *outputChangeDate;
@end

@implementation SPMainViewController

- (void)viewDidLoad
{
    [super viewDidLoad];
    [self setupStack];
    [self refresh];

    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(applicationDidBecomeActive) name:UIApplicationDidBecomeActiveNotification object:nil];
    [center addObserver:self selector:@selector(applicationWillResignActive) name:UIApplicationWillResignActiveNotification object:nil];
    [self startRefreshing];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_refreshTimer invalidate];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self refresh];
}

#pragma mark - Layout

- (void)setupStack
{
    UIStackView *stackView = [[UIStackView alloc] init];
    [stackView setAxis:UILayoutConstraintAxisVertical];
    [stackView setAlignment:UIStackViewAlignmentFill];
    [stackView setDistribution:UIStackViewDistributionEqualSpacing];
    [stackView setTranslatesAutoresizingMaskIntoConstraints:NO];
    [self.view addSubview:stackView];

    // As in Dopamine: centred a little below the middle, 73% of the height (78% with a home button). The open
    // output menu may need more, so here the height and centring can give way, but never the safe area.
    int statusBarHeight = fmax(15, [[UIApplication sharedApplication] keyWindow].safeAreaInsets.top - 20);
    NSLayoutConstraint *centre = [stackView.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:statusBarHeight];
    centre.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *height = [stackView.heightAnchor constraintEqualToAnchor:self.view.heightAnchor
                                                                      multiplier:[SPGlobalAppearance isHomeButtonDevice] ? 0.78 : 0.73];
    height.priority = UILayoutPriorityDefaultHigh - 50;
    [NSLayoutConstraint activateConstraints:@[
        centre,
        height,
        [stackView.topAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:8],
        [stackView.bottomAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-8],
    ]];

    if ([[UIDevice currentDevice] userInterfaceIdiom] == UIUserInterfaceIdiomPad) {
        NSLayoutConstraint *relativeWidthConstraint = [stackView.widthAnchor constraintEqualToAnchor:self.view.widthAnchor multiplier:0.8];
        relativeWidthConstraint.priority = UILayoutPriorityDefaultHigh;
        NSLayoutConstraint *maxWidthConstraint = [stackView.widthAnchor constraintLessThanOrEqualToConstant:UI_IPAD_MAX_WIDTH];
        maxWidthConstraint.priority = UILayoutPriorityRequired;
        [NSLayoutConstraint activateConstraints:@[
            relativeWidthConstraint,
            maxWidthConstraint,
            [stackView.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        ]];
    } else {
        [NSLayoutConstraint activateConstraints:@[
            [stackView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:UI_PADDING],
            [stackView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-UI_PADDING],
        ]];
    }

    // Header
    self.headerView = [[SPHeaderView alloc] initWithTitle:@"Speaka" subtitles:@[
        [SPGlobalAppearance mainSubtitleString:@"Bluetooth speaker for your PC"],
        [SPGlobalAppearance secondarySubtitleString:@"Looking for the BTPhonoSink tweak..."],
    ]];
    [stackView addArrangedSubview:self.headerView];

    // Connection banner: who is connected, scrolling to the right
    self.connectionView = [[SPMarqueeView alloc] init];
    [stackView addArrangedSubview:self.connectionView];

    // Menu: where the audio plays, and the credits
    __weak __typeof__(self) weakSelf = self;
    self.outputDropdown = [[SPOutputDropdown alloc] init];
    self.outputDropdown.selectionHandler = ^(NSString *mode) {
        [weakSelf selectOutput:mode];
    };
    UIAction *credits = [UIAction actionWithTitle:@"Credits"
                                            image:[UIImage systemImageNamed:@"info.circle" withConfiguration:[SPGlobalAppearance smallIconImageConfiguration]]
                                       identifier:@"credits"
                                          handler:^(__kindof UIAction *action) {
        [weakSelf.navigationController pushViewController:[[SPCreditsViewController alloc] init] animated:YES];
    }];
    SPActionMenuButton *creditsButton = [SPActionMenuButton buttonWithAction:credits chevron:YES];
    [creditsButton.heightAnchor constraintEqualToConstant:[SPGlobalAppearance actionRowHeight]].active = YES;
    SPActionMenuView *menuView = [[SPActionMenuView alloc] initWithRows:@[ self.outputDropdown, creditsButton ]];
    [stackView addArrangedSubview:menuView];

    // Start and Stop: two of Dopamine's big buttons side by side
    UIAction *start = [UIAction actionWithTitle:@"Start"
                                          image:[UIImage systemImageNamed:@"play.fill" withConfiguration:[SPGlobalAppearance smallIconImageConfiguration]]
                                     identifier:@"start"
                                        handler:^(__kindof UIAction *action) {
        [weakSelf confirmAction:@"start"];
    }];
    UIAction *stop = [UIAction actionWithTitle:@"Stop"
                                         image:[UIImage systemImageNamed:@"stop.fill" withConfiguration:[SPGlobalAppearance smallIconImageConfiguration]]
                                    identifier:@"stop"
                                       handler:^(__kindof UIAction *action) {
        [weakSelf confirmAction:@"stop"];
    }];
    self.startButton = [[SPBigButton alloc] initWithAction:start];
    self.stopButton = [[SPBigButton alloc] initWithAction:stop];
    self.startButton.button.accessibilityHint = @"Turns this iPhone into a Bluetooth speaker. Bluetooth restarts once.";
    self.stopButton.button.accessibilityHint = @"Turns the speaker off. Bluetooth restarts once.";
    UIStackView *buttonsView = [[UIStackView alloc] initWithArrangedSubviews:@[ self.startButton, self.stopButton ]];
    buttonsView.axis = UILayoutConstraintAxisHorizontal;
    buttonsView.distribution = UIStackViewDistributionFillEqually;
    buttonsView.spacing = 12;
    buttonsView.translatesAutoresizingMaskIntoConstraints = NO;
    [stackView addArrangedSubview:buttonsView];
    [buttonsView.heightAnchor constraintEqualToConstant:60].active = YES;
}

#pragma mark - Refreshing

- (void)startRefreshing
{
    if (self.refreshTimer)
        return;
    __weak __typeof__(self) weakSelf = self;
    self.refreshTimer = [NSTimer timerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        [weakSelf tick];
    }];
    [[NSRunLoop mainRunLoop] addTimer:self.refreshTimer forMode:NSRunLoopCommonModes];
}

- (void)stopRefreshing
{
    [self.refreshTimer invalidate];
    self.refreshTimer = nil;
}

- (void)applicationDidBecomeActive
{
    [self refresh];
    [self startRefreshing];
}

- (void)applicationWillResignActive
{
    if (!self.request)   // keep following a Start or Stop that is in flight
        [self stopRefreshing];
}

- (void)tick
{
    if (self.request && [[SPTweakClient sharedClient] pollRequest:self.request] == SPRequestFinished) {
        SPRequest *finished = self.request;
        self.request = nil;
        [self refresh];
        [self alertWithTitle:finished.resultTitle ?: @"Done" message:finished.resultMessage ?: @""];
        return;
    }
    [self refresh];
}

- (void)refresh
{
    SPStatus *status = [[SPTweakClient sharedClient] readStatus];
    [self updateHeader:status];
    [self updateConnection:status];
    [self updateButtons:status];
    // Right after a change, the preference may still read the old value for a moment: do not flip back.
    BOOL justChanged = self.outputChangeDate && -[self.outputChangeDate timeIntervalSinceNow] < 2.0;
    if (!self.outputDropdown.expanded && !justChanged)
        self.outputDropdown.selectedMode = status.outputMode;
}

- (void)updateHeader:(SPStatus *)status
{
    NSString *line;
    if (status.session == SPSessionNoTweak)
        line = @"BTPhonoSink tweak not detected";
    else if (status.session == SPSessionOldTweak)
        line = @"BTPhonoSink: restart Bluetooth to finish installing";
    else if (status.build.length)
        line = [NSString stringWithFormat:@"BTPhonoSink %@", [status.build componentsSeparatedByString:@"-"].firstObject];
    else
        line = @"BTPhonoSink";
    if ([line isEqualToString:self.headerLine])
        return;
    self.headerLine = line;
    [self.headerView setSubtitles:@[
        [SPGlobalAppearance mainSubtitleString:@"Bluetooth speaker for your PC"],
        [SPGlobalAppearance secondarySubtitleString:line],
    ]];
}

// The PC's name is looked up at most every 5 s; nil means "say Your PC".
- (NSString *)currentComputerName
{
    if (!self.computerNameDate || -[self.computerNameDate timeIntervalSinceNow] > 5.0) {
        self.computerName = [SPConnectedDevice connectedComputerName];
        self.computerNameDate = [NSDate date];
    }
    return self.computerName;
}

- (void)updateConnection:(SPStatus *)status
{
    NSString *symbol = @"speaker.slash";
    UIColor *color = [UIColor colorWithWhite:1 alpha:0.7];
    NSString *text;

    if (self.request) {
        BOOL start = [self.request.action isEqualToString:@"start"];
        symbol = @"arrow.triangle.2.circlepath";
        if (self.request.relaunched)
            text = start ? [@"Bluetooth restarted" stringByAppendingFormat:@"%@registering the iPhone as a speaker", SPSeparator]
                         : @"Bluetooth restarted";
        else
            text = start ? [@"Starting the speaker" stringByAppendingFormat:@"%@Bluetooth restarts once and your devices reconnect by themselves", SPSeparator]
                         : [@"Stopping the speaker" stringByAppendingFormat:@"%@Bluetooth restarts once", SPSeparator];
    } else if (status.session == SPSessionOn && status.receiving) {
        NSString *who = [self currentComputerName] ?: @"Your PC";
        symbol = @"laptopcomputer";
        color = [SPTheme accentColor];
        if (status.playing) {
            NSString *where = status.playingOn.length ? status.playingOn : @"this iPhone";
            text = [NSString stringWithFormat:@"%@ connected%@playing on %@", who, SPSeparator, where];
            if (status.volumeZero)
                text = [text stringByAppendingFormat:@"%@the volume is at 0%%", SPSeparator];
        } else {
            NSString *reason = status.waitingReason.length ? status.waitingReason : @"no output yet";
            text = [NSString stringWithFormat:@"%@ connected%@waiting: %@", who, SPSeparator, reason];
        }
    } else if (status.session == SPSessionOn) {
        symbol = @"dot.radiowaves.left.and.right";
        color = [SPTheme accentColor];
        text = [@"Ready" stringByAppendingFormat:@"%@on your PC, connect to this iPhone and choose it as the audio output", SPSeparator];
    } else if (status.session == SPSessionStarting) {
        symbol = @"hourglass";
        text = @"Starting the speaker...";
    } else if (status.session == SPSessionLost) {
        symbol = @"exclamationmark.arrow.circlepath";
        text = [@"Bluetooth was turned off and on" stringByAppendingFormat:@"%@tap Start again", SPSeparator];
    } else if (status.session == SPSessionFailed || status.session == SPSessionRefused) {
        symbol = @"xmark.octagon";
        text = [@"Speaker not started" stringByAppendingFormat:@"%@%@", SPSeparator, status.detail];
    } else if (status.session == SPSessionNoTweak) {
        symbol = @"exclamationmark.triangle";
        text = [@"The BTPhonoSink tweak is not running" stringByAppendingFormat:@"%@install it, then open Speaka again", SPSeparator];
    } else if (status.session == SPSessionOldTweak) {
        symbol = @"exclamationmark.triangle";
        text = [@"Bluetooth still runs an older BTPhonoSink" stringByAppendingFormat:@"%@restart Bluetooth once to finish installing", SPSeparator];
    } else {
        text = [@"Speaker is off" stringByAppendingFormat:@"%@tap Start to turn this iPhone into a Bluetooth speaker", SPSeparator];
    }

    self.connectionView.symbolName = symbol;
    self.connectionView.symbolColor = color;
    self.connectionView.text = text;
}

- (void)updateButtons:(SPStatus *)status
{
    BOOL busy = self.request != nil;
    BOOL starting = busy && [self.request.action isEqualToString:@"start"];
    [self.startButton setBusy:starting title:@"Starting..."];
    [self.stopButton setBusy:(busy && !starting) title:@"Stopping..."];
    BOOL running = status.session == SPSessionOn || status.session == SPSessionStarting;
    [self.startButton setTitle:(running ? @"Running" : @"Start") symbolName:(running ? @"checkmark.circle.fill" : @"play.fill")];
    self.startButton.enabled = !busy && status.canStart;
    self.stopButton.enabled = !busy && status.canStop;
}

#pragma mark - Actions

- (void)confirmAction:(NSString *)action
{
    if (self.request)   // one request at a time
        return;
    SPStatus *status = [[SPTweakClient sharedClient] readStatus];
    if (status.session == SPSessionNoTweak) {
        [self alertWithTitle:@"BTPhonoSink is not running"
                     message:@"Speaka controls the BTPhonoSink tweak, which runs inside the Bluetooth daemon, and it has "
                             @"not reported anything yet. Install the BTPhonoSink package; its install script restarts "
                             @"Bluetooth once. Then open Speaka again."];
        return;
    }
    if (status.session == SPSessionOldTweak) {
        [self alertWithTitle:@"Restart Bluetooth once to finish installing"
                     message:@"Bluetooth is still running the BTPhonoSink version it started with, which has no Start "
                             @"button, so nothing would answer. Restart the Bluetooth daemon once: reinstalling the "
                             @"package does it automatically, or run your usual sudo killall -9 bluetoothd command, or "
                             @"use Reboot Userspace in Dopamine. After that, Start works.\n\n"
                             @"Turning Bluetooth off and on does not restart the daemon."];
        return;
    }

    BOOL start = [action isEqualToString:@"start"];
    NSString *title = start ? @"Start the Bluetooth speaker?" : @"Stop the Bluetooth speaker?";
    NSString *message = start
        ? @"Bluetooth restarts once, which takes a few seconds. AirPods, a watch and other devices reconnect by themselves."
        : @"Bluetooth restarts once without the speaker, back to normal.";
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak __typeof__(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:(start ? @"Start" : @"Stop")
                                              style:(start ? UIAlertActionStyleDefault : UIAlertActionStyleDestructive)
                                            handler:^(UIAlertAction *chosen) {
        [weakSelf sendAction:action];
    }]];
    [self presentAlert:alert];
}

- (void)sendAction:(NSString *)action
{
    NSString *error = nil;
    SPRequest *request = [[SPTweakClient sharedClient] sendAction:action error:&error];
    if (!request) {
        [self alertWithTitle:@"Nothing was changed" message:error ?: @"The request could not be sent."];
        return;
    }
    self.request = request;
    [self startRefreshing];
    [self refresh];
}

- (void)selectOutput:(NSString *)mode
{
    self.outputChangeDate = [NSDate date];
    if (![[SPTweakClient sharedClient] setOutputMode:mode]) {
        self.outputChangeDate = nil;
        [self alertWithTitle:@"Could not change the output"
                     message:@"The setting could not be saved. Try again, or use Settings > BTPhonoSink."];
        [self refresh];
    }
}

#pragma mark - Alerts

- (void)alertWithTitle:(NSString *)title message:(NSString *)message
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentAlert:alert];
}

// Present from whatever is on top, so an alert also appears while the credits card is open.
- (void)presentAlert:(UIAlertController *)alert
{
    UIViewController *presenter = self.navigationController ?: self;
    while (presenter.presentedViewController)
        presenter = presenter.presentedViewController;
    [presenter presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Status Bar

- (UIStatusBarStyle)preferredStatusBarStyle
{
    return UIStatusBarStyleLightContent;
}

@end
