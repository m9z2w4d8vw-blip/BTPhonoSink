// BTPSLogViewController.m
// Debug log screen. Export uses the public Files picker from Preferences.app;
// it does not change the bluetoothd tweak, its sandbox or its runtime behavior.
#import "BTPSLogViewController.h"
#import "BTPSLogReader.h"
#import "BTPSAudioProbe.h"
#import "BTPSIPCSender.h"
#import <CoreFoundation/CoreFoundation.h>
#import <notify.h>
#import "../BTPSShared.h"

@interface BTPSLogViewController () <UIDocumentPickerDelegate>
@end

@implementation BTPSLogViewController {
    UITextView *_textView;
    NSTimer *_timer;
    NSURL *_pendingExportURL;
    BTPSAudioProbe *_audioProbe;
}

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.title = @"Debug log";
    self.view.backgroundColor = [UIColor systemBackgroundColor];

    _textView = [[UITextView alloc] initWithFrame:CGRectZero];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.editable = NO;
    _textView.alwaysBounceVertical = YES;
    _textView.font = [UIFont monospacedSystemFontOfSize:10.0 weight:UIFontWeightRegular];
    _textView.textColor = [UIColor labelColor];
    _textView.backgroundColor = [UIColor systemBackgroundColor];
    _textView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    [self.view addSubview:_textView];

    // Keep this action visible even while the user scrolls through a long trace.
    UIButton *exportButton = [UIButton buttonWithType:UIButtonTypeSystem];
    exportButton.translatesAutoresizingMaskIntoConstraints = NO;
    [exportButton setTitle:@"Save Log to iCloud Drive…" forState:UIControlStateNormal];
    [exportButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    exportButton.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    exportButton.backgroundColor = [UIColor systemBlueColor];
    exportButton.layer.cornerRadius = 11.0;
    [exportButton addTarget:self action:@selector(exportToFiles) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:exportButton];

    UIStackView *actions = [[UIStackView alloc] initWithFrame:CGRectZero];
    actions.axis = UILayoutConstraintAxisVertical;
    actions.spacing = 2.0;
    actions.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:actions];
    UIButton *checkButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [checkButton setTitle:@"Verify Test Checklist" forState:UIControlStateNormal];
    [checkButton addTarget:self action:@selector(showChecklist) forControlEvents:UIControlEventTouchUpInside];
    [actions addArrangedSubview:checkButton];
    UIButton *audioButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [audioButton setTitle:@"Test iOS Audio Output (440 Hz)" forState:UIControlStateNormal];
    [audioButton addTarget:self action:@selector(confirmAudioTest) forControlEvents:UIControlEventTouchUpInside];
    [actions addArrangedSubview:audioButton];
    UIButton *ipcButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [ipcButton setTitle:@"Send PCM to Separate Helper (v7.3)" forState:UIControlStateNormal];
    [ipcButton addTarget:self action:@selector(promptIPCTest) forControlEvents:UIControlEventTouchUpInside];
    [actions addArrangedSubview:ipcButton];
    UIButton *daemonButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [daemonButton setTitle:@"Send PCM from bluetoothd (v7.4)" forState:UIControlStateNormal];
    [daemonButton addTarget:self action:@selector(promptDaemonIPCTest) forControlEvents:UIControlEventTouchUpInside];
    [actions addArrangedSubview:daemonButton];
    UIButton *sbcButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [sbcButton setTitle:@"Send SBC from bluetoothd (v7.5/7.6)" forState:UIControlStateNormal];
    [sbcButton addTarget:self action:@selector(promptSBCIPCTest) forControlEvents:UIControlEventTouchUpInside];
    [actions addArrangedSubview:sbcButton];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_textView.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [_textView.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [_textView.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [_textView.bottomAnchor constraintEqualToAnchor:actions.topAnchor constant:-6.0],
        [actions.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12.0],
        [actions.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [actions.bottomAnchor constraintEqualToAnchor:exportButton.topAnchor constant:-6.0],
        [exportButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12.0],
        [exportButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12.0],
        [exportButton.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12.0],
        [exportButton.heightAnchor constraintEqualToConstant:48.0]
    ]];

    UIBarButtonItem *copy = [[UIBarButtonItem alloc] initWithTitle:@"Copy" style:UIBarButtonItemStylePlain
                                                            target:self action:@selector(copyAll)];
    UIBarButtonItem *refresh = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
                                                                             target:self action:@selector(reload)];
    self.navigationItem.rightBarButtonItems = @[ copy, refresh ];
}

- (void)viewWillAppear:(BOOL)animated
{
    [super viewWillAppear:animated];
    [self reload];
    __weak __typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:2.0 repeats:YES block:^(NSTimer *t) { [weakSelf reload]; }];
}

- (void)viewWillDisappear:(BOOL)animated
{
    [super viewWillDisappear:animated];
    [_timer invalidate];
    _timer = nil;
    [_audioProbe stop];
}

- (void)reload
{
    // Keep following the newest line only if the reader was already at the bottom; otherwise leave the scroll alone.
    CGFloat bottom = _textView.contentOffset.y + _textView.bounds.size.height;
    BOOL atBottom = _textView.text.length == 0 || bottom >= _textView.contentSize.height - 40.0;
    CGPoint keep = _textView.contentOffset;

    _textView.text = [[BTPSLogReader shared] fullText];
    [_textView layoutIfNeeded];

    if (atBottom) {
        CGFloat y = _textView.contentSize.height - _textView.bounds.size.height + _textView.adjustedContentInset.bottom;
        if (y < -_textView.adjustedContentInset.top) y = -_textView.adjustedContentInset.top;
        [_textView setContentOffset:CGPointMake(0, y) animated:NO];
    } else {
        _textView.contentOffset = keep;
    }
}

- (void)showMessage:(NSString *)message title:(NSString *)title
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)copyAll
{
    [UIPasteboard generalPasteboard].string = _textView.text;
    [self showMessage:@"Copied the debug log." title:nil];
}

#pragma mark - Export current log to Files / iCloud Drive

- (void)cleanupPendingExport
{
    if (_pendingExportURL) {
        [[NSFileManager defaultManager] removeItemAtURL:_pendingExportURL error:NULL];
        _pendingExportURL = nil;
    }
}

- (void)exportToFiles
{
    // Use a new, complete snapshot rather than only the visible / potentially stale text.
    NSString *log = [[BTPSLogReader shared] fullText];
    if (log.length == 0) {
        [self showMessage:@"There is no diagnostic log available to export." title:@"Nothing to save"];
        return;
    }

    // A timestamp and short UUID make exports distinguishable across restarts and repeated taps.
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    fmt.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    NSString *suffix = [[[NSUUID UUID] UUIDString] substringToIndex:8];
    NSString *filename = [NSString stringWithFormat:@"BTPhonoSink-%@-%@.txt",
                          [fmt stringFromDate:[NSDate date]], suffix];
    NSURL *fileURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
                      URLByAppendingPathComponent:filename];

    NSError *error = nil;
    if (![log writeToURL:fileURL atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        [self showMessage:error.localizedDescription ?: @"Could not create the temporary log file."
                    title:@"Export failed"];
        return;
    }

    [self cleanupPendingExport];
    _pendingExportURL = fileURL;

    // iOS offers all enabled Files locations. The user chooses iCloud Drive and taps Save.
    // This does not require iCloud entitlements or write access from the bluetoothd process.
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
                                            initForExportingURLs:@[fileURL] asCopy:YES];
    picker.delegate = self;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
    didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls
{
    // The picker copied the file to the chosen provider; remove only our staging file.
    [self cleanupPendingExport];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller
{
    [self cleanupPendingExport];
}


#pragma mark - Guided checks and local output test (Preferences process only)

- (void)showChecklist
{
    NSString *log = [[BTPSLogReader shared] fullText];
    BOOL correctBuild = [log containsString:@"build: v7.6-sbc-playback"];
    BOOL hooks = [log containsString:@"hooks installed: 5 / 5"];
    BOOL sources = [log containsString:@"diag.native_source_ok: 6"];
    BOOL legacyOff = [log containsString:@"experiments: off (v7 forced-passive, stored=off)"];
    BOOL probe = [log containsString:@"diag.sdp_probe: installed"];
    BOOL sdpsource = [log containsString:@"diag.sdp_source_seen: yes"];
    BOOL daemonArmed = [log containsString:@"diag.v74_ipc: ARMED"] || [log containsString:@"diag.v74_ipc: PASS"];
    BOOL sbcArmed = [log containsString:@"diag.v75_sbc: ARMED"] || [log containsString:@"diag.v75_sbc: PASS"];
    BOOL sbc = [log containsString:@"seen.SetConfig_accept_SBC:"] && ![log containsString:@"seen.SetConfig_accept_SBC: 0 call(s)"];
    NSString *check = [NSString stringWithFormat:
       @"%@ v7.6 is running\n%@ Five original hooks installed\n%@ Six original Source endpoints\n%@ Legacy experiment is OFF\n%@ Optional SDP observer installed\n%@ Audio Source SDP record observed\n%@ SBC negotiation callback seen\n%@ Daemon-to-helper test is ARMED or PASS\n%@ Compressed SBC transport is ARMED or PASS\n\nMANUAL: Confirm headphones play after reconnecting.\nMANUAL: Export and send the log using Save Log to iCloud Drive.\nMANUAL v7.4: Start helper with --daemon in SSH, then tap Send PCM from bluetoothd and enter its token. Check SSH and diag.v74_ipc; confirm 880 Hz audibility.\nMANUAL v7.6: start helper with --sbc-play then tap Send Compressed SBC; expect SBC_DECODE_PASS, AUDIO_FINISHED, and a 440 Hz tone.  --sbc still performs the silent integrity test.\n\nThe Settings local tone and the new v7.6 decoded SBC playback are different tests. V7.3 sends 660 Hz PCM from Settings; V7.4 sends 880 Hz PCM from bluetoothd. None receive live Bluetooth audio from Windows.",
       correctBuild ? @"PASS" : @"CHECK", hooks ? @"PASS" : @"CHECK",
       sources ? @"PASS" : @"CHECK", legacyOff ? @"PASS" : @"CHECK",
       probe ? @"PASS" : @"NOT ENABLED", sdpsource ? @"PASS" : @"NOT SEEN",
       sbc ? @"PASS" : @"NOT YET SEEN", daemonArmed ? @"PASS" : @"NOT ARMED",sbcArmed?@"PASS":@"NOT ARMED"];
    [self showMessage:check title:@"BTPhonoSink test checklist"];
}

- (void)confirmAudioTest
{
    UIAlertController *ask = [UIAlertController alertControllerWithTitle:@"Local audio output test"
        message:@"Disconnect Bluetooth headphones first if you want the tone to play through the iPhone speaker. This plays a short 440 Hz tone from Settings, NOT from bluetoothd and NOT from a Bluetooth Source device."
        preferredStyle:UIAlertControllerStyleAlert];
    [ask addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak __typeof(self) weakSelf = self;
    [ask addAction:[UIAlertAction actionWithTitle:@"Play test tone" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [weakSelf playLocalAudioTest];
    }]];
    [self presentViewController:ask animated:YES completion:nil];
}

- (void)playLocalAudioTest
{
    _audioProbe = [[BTPSAudioProbe alloc] init];
    __weak __typeof(self) weakSelf = self;
    _audioProbe.completion = ^(NSString *status) {
        [[NSUserDefaults standardUserDefaults] setObject:status forKey:@"BTPSAudioTestLastResult"];
        [weakSelf showMessage:status title:@"Audio output test"];
    };
    NSError *error = nil;
    if (![_audioProbe startWithError:&error]) {
        NSString *message = [NSString stringWithFormat:@"Audio output test failed: %@", error.localizedDescription ?: @"unknown error"];
        [[NSUserDefaults standardUserDefaults] setObject:message forKey:@"BTPSAudioTestLastResult"];
        [self showMessage:message title:@"Audio output test"];
    }
}

#pragma mark - Cross-process playback test (v7.3)

- (void)promptIPCTest
{
    UIAlertController *ask = [UIAlertController alertControllerWithTitle:@"Separate-process PCM test"
        message:@"FIRST on Windows PowerShell, run:\nssh -t mobile@10.5.82.212 '/var/jb/usr/bin/BTPSAudioHelper'\n\nKeep SSH open. Enter the six-digit token printed by the helper. Settings will send 0.8 seconds of 660 Hz PCM over 127.0.0.1. The helper, NOT Settings, will attempt playback. This does not test Bluetooth Sink reception."
        preferredStyle:UIAlertControllerStyleAlert];
    [ask addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Six-digit helper token";
        field.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [ask addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak __typeof(self) weakSelf = self;
    [ask addAction:[UIAlertAction actionWithTitle:@"Send to helper" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *entered = ask.textFields.firstObject.text ?: @"";
        NSCharacterSet *nonDigits = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        if(entered.length!=6 || [entered rangeOfCharacterFromSet:nonDigits].location!=NSNotFound){
            [weakSelf showMessage:@"Enter exactly six digits from the SSH helper output." title:@"Invalid token"];
            return;
        }
        uint32_t token=(uint32_t)entered.intValue;
        [BTPSIPCSender sendTestPCMWithToken:token completion:^(NSString *status) {
            [[NSUserDefaults standardUserDefaults] setObject:status forKey:@"BTPSIPCPlaybackLastResult"];
            [weakSelf reload];
            [weakSelf showMessage:status title:@"Interprocess test"];
        }];
    }]];
    [self presentViewController:ask animated:YES completion:nil];
}


#pragma mark - Explicit daemon-to-helper IPC test (v7.4)

- (void)promptDaemonIPCTest
{
    UIAlertController *ask = [UIAlertController alertControllerWithTitle:@"bluetoothd → separate helper (v7.4)"
        message:@"1. First run over Windows PowerShell:\nssh -t mobile@10.5.82.212 '/var/jb/usr/bin/BTPSAudioHelper --daemon'\n\n2. Keep SSH open and enter the NEW six-digit token below.\n\n3. This sends a one-shot Darwin notification to bluetoothd. A worker in bluetoothd attempts a bounded, CRC-verified 880 Hz PCM transfer. The helper plays the tone if CoreAudio permits. Never enables Legacy Sink or receives Windows Bluetooth audio."
        preferredStyle:UIAlertControllerStyleAlert];
    [ask addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"Six-digit token from --daemon helper";
        field.keyboardType = UIKeyboardTypeNumberPad;
    }];
    [ask addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak __typeof(self) weakSelf = self;
    [ask addAction:[UIAlertAction actionWithTitle:@"Request daemon transfer" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *entered = ask.textFields.firstObject.text ?: @"";
        NSCharacterSet *nonDigits = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
        if (entered.length != 6 || [entered rangeOfCharacterFromSet:nonDigits].location != NSNotFound || entered.intValue < 100000) {
            [weakSelf showMessage:@"Enter exactly six digits from BTPSAudioHelper --daemon." title:@"Invalid token"];
            return;
        }
        /* Unique one-shot request ID prevents notification replay; Settings owns the trigger.
         * The daemon MUST perform any socket calls on its own worker queue, never in a BT hook. */
        NSString *request = [NSString stringWithFormat:@"%@.%@", entered, [[NSUUID UUID] UUIDString]];
        CFPreferencesSetValue(CFSTR(BTPS_KEY_DAEMON_PROBE), (__bridge CFStringRef)request,
                              CFSTR(BTPS_PREFS_DOMAIN), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        Boolean synced = CFPreferencesSynchronize(CFSTR(BTPS_PREFS_DOMAIN), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (!synced) {
            [weakSelf showMessage:@"Preferences sync failed; no daemon request sent. Check that the tweak is installed." title:@"Daemon IPC test"];
            return;
        }
        uint32_t notifyResult = notify_post(BTPS_NOTIFY_DAEMON_PROBE);
        NSString *result = notifyResult == NOTIFY_STATUS_OK
             ? @"Request notification posted. Check the SSH terminal for IPC_RECEIVED / AUDIO_FINISHED, and refresh the debug log for diag.v74_ipc. This is not proof of delivery."
             : [NSString stringWithFormat:@"notify_post failed: %u. No successful transfer can be inferred.", (unsigned)notifyResult];
        [[NSUserDefaults standardUserDefaults] setObject:result forKey:@"BTPSDaemonIPCRequestLastResult"];
        [weakSelf reload];
        [weakSelf showMessage:result title:@"Daemon IPC request"];
    }]];
    [self presentViewController:ask animated:YES completion:nil];
}

#pragma mark - v7.5 opt-in compressed RTP/SBC diagnostic
- (void)promptSBCIPCTest
{
    UIAlertController *ask=[UIAlertController alertControllerWithTitle:@"bluetoothd → SBC helper (v7.6)"
        message:@"To decode AND play, first run over SSH:\nssh -t mobile@10.5.82.212 '/var/jb/usr/bin/BTPSAudioHelper --sbc-play'\n\nEnter the NEW six-digit token. Transfers the same finite built-in compressed fixture; the helper should play 440 Hz if its audio route works. Does NOT receive Bluetooth radio packets. Legacy Sink OFF."
        preferredStyle:UIAlertControllerStyleAlert];
    [ask addTextFieldWithConfigurationHandler:^(UITextField *f){f.placeholder=@"Six-digit --sbc-play token";f.keyboardType=UIKeyboardTypeNumberPad;}];
    [ask addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    __weak __typeof(self) weakSelf=self;
    [ask addAction:[UIAlertAction actionWithTitle:@"Request compressed transfer" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){
        NSString *entered=ask.textFields.firstObject.text?:@"";
        NSCharacterSet *invalid=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
        if(entered.length!=6 || [entered rangeOfCharacterFromSet:invalid].location!=NSNotFound || entered.intValue<100000) {
            [weakSelf showMessage:@"Enter the exact six-digit token from the --sbc-play helper." title:@"Invalid token"];return;
        }
        NSString *request=[NSString stringWithFormat:@"%@.%@",entered,[[NSUUID UUID] UUIDString]];
        CFPreferencesSetValue(CFSTR(BTPS_KEY_V75_SBC),(__bridge CFStringRef)request,CFSTR(BTPS_PREFS_DOMAIN),kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
        if(!CFPreferencesSynchronize(CFSTR(BTPS_PREFS_DOMAIN),kCFPreferencesCurrentUser,kCFPreferencesAnyHost)) {
            [weakSelf showMessage:@"Preference synchronization failed; no request sent." title:@"SBC test"];return;
        }
        uint32_t code=notify_post(BTPS_NOTIFY_V75_SBC);
        NSString *report=code==NOTIFY_STATUS_OK
           ? @"Request posted. Check SSH for SBC_RECEIVED, SBC_DECODE_PASS and SBC_AUDIO_FINISHED. With --sbc-play the helper should attempt to play a short 440 Hz tone; with --sbc it performs a silent transfer. This is NOT live Bluetooth radio reception."
           : [NSString stringWithFormat:@"Notification failed: %u",(unsigned)code];
        [[NSUserDefaults standardUserDefaults] setObject:report forKey:@"BTPSV75SBCRequestLastResult"];
        [weakSelf reload];[weakSelf showMessage:report title:@"Compressed SBC test"];
    }]];
    [self presentViewController:ask animated:YES completion:nil];
}

@end
